//! Jev as fx's decision maker: registers lifecycle handlers that ask Jev
//! before the agent loop commits to a decision.
//!
//! `PreToolUse` gates, in order of the call they inspect:
//! - ask: Jev answers the agent's multiple-choice question when the request
//!   and the agent's findings already settle it; otherwise the user is asked.
//! - routing: a temporary subagent without a model gets one of the user's
//!   configured routes.
//! - plan: the first file change of a substantial request is held (at most
//!   twice per turn) until the agent states a plan that covers it.
//! - action (opt-in): file changes and shell commands are held when they look
//!   off-task or damaging in ways the user did not ask for (at most three
//!   times per turn).
//!
//! The completion gate runs on `Stop`. It sends the agent back once when Jev
//! cannot confirm the final answer is backed by the turn's tool results.
//! When the work passes and the turn changed files in a workspace with
//! decision records and SDD on (`fx sdd on`), the drift check flags records
//! the uncommitted changes contradict and asks the agent to update them
//! (each record once per process).
//!
//! Gates run for root interactive and `fx ask` turns only. When Jev is
//! unreachable, has no key, or answers incompletely, the call or turn goes
//! ahead normally and the decision log records why.

const std = @import("std");
const hooks = @import("../hooks/hooks.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const typesafe = @import("../../gateway/typesafe.zig");
const jev_contract = @import("jev_contract.zig");
const jev_config = @import("jev_config.zig");
const completion_gate = @import("completion_gate.zig");
const plan_gate = @import("plan_gate.zig");
const action_gate = @import("action_gate.zig");
const ask_gate = @import("ask_gate.zig");
const routing = @import("routing.zig");
const drift = @import("drift.zig");
const decision_log = @import("decision_log.zig");
const sdd_mode = @import("../sdd/sdd_mode.zig");
const sdd_layout = @import("../sdd/sdd_layout.zig");
const sdd_gate = @import("sdd_gate.zig");
const tdd_gate = @import("tdd_gate.zig");

const Allocator = std.mem.Allocator;

pub const Gate = struct {
    alloc: Allocator,
    config: jev_config.Config = .{},
    mutex: std.Io.Mutex = .init,
    /// Live on/off switch for registered handlers (`/jev on|off`).
    active: std.atomic.Value(bool) = .init(true),
    /// Text lent to the hook dispatcher (block reasons, continuations,
    /// rewritten arguments), which copies it before the next call.
    lent: ?[]u8 = null,
    /// Per-turn state; reset when a new turn id arrives.
    turn: ?u64 = null,
    plan_settled: bool = false,
    plan_holds: u8 = 0,
    action_holds: u8 = 0,
    /// SDD mode for this turn's workspace, loaded on the first file change.
    sdd_turn_mode: ?sdd_mode.Mode = null,
    /// The route this turn's work goes through once code may change; null
    /// when no route applies (SDD off, unclear, Jev unavailable).
    sdd_route: ?SddRoute = null,
    /// Titles of the spec rules the request changes. Owned.
    sdd_touched: std.ArrayList([]u8) = .empty,
    tdd_holds: u8 = 0,
    growth_held: bool = false,
    tdd_green_asked: bool = false,
    tdd_weak_asked: bool = false,
    tdd_uncited_asked: bool = false,
    /// The SDD route needs no more checks this turn.
    sdd_settled: bool = false,
    /// Set when this turn routed to change; later file changes re-check the
    /// change files without asking Jev again.
    sdd_change: ?sdd_gate.Verdict = null,
    sdd_incomplete_held: bool = false,
    /// Decision files already flagged by the drift check. Owned keys.
    drift_reported: std.StringHashMapUnmanaged(void) = .empty,

    const max_plan_holds = 2;
    const max_action_holds = 3;

    const SddRoute = struct {
        route: sdd_gate.Route,
        bug: bool = false,
        /// The work is checked in the running app, not by tests.
        manual: bool = false,
    };

    /// Loads the profile configuration. Jev stays inactive unless enabled.
    pub fn init(alloc: Allocator) Gate {
        const config = jev_config.load(alloc) catch |err| blk: {
            debug_trace.logf("jev", "config unavailable err={s}", .{@errorName(err)});
            break :blk jev_config.Config{};
        };
        return .{ .alloc = alloc, .config = config };
    }

    pub fn deinit(self: *Gate) void {
        if (self.lent) |text| self.alloc.free(text);
        self.clearTouched();
        self.sdd_touched.deinit(self.alloc);
        var reported = self.drift_reported.keyIterator();
        while (reported.next()) |key| self.alloc.free(key.*);
        self.drift_reported.deinit(self.alloc);
        self.config.deinit(self.alloc);
        self.* = undefined;
    }

    /// Whether handlers were registered for this runtime.
    pub fn registered(self: *const Gate) bool {
        return self.config.enabled and (self.config.usesPreToolUse() or self.config.stop_gate);
    }

    /// Turns registered handlers on or off for the rest of the process.
    pub fn setActive(self: *Gate, value: bool) void {
        self.active.store(value, .release);
    }

    pub fn isActive(self: *const Gate) bool {
        return self.registered() and self.active.load(.acquire);
    }

    /// Registers the enabled gates. Must run before the runtime is frozen.
    pub fn register(self: *Gate, runtime: *hooks.Runtime) !void {
        if (!self.config.enabled) return;
        if (self.config.usesPreToolUse()) {
            try runtime.registerPreToolUse(.{
                .name = "fx.jev.pre_tool",
                .ctx = self,
                .run = preToolUseHandler,
            });
        }
        if (self.config.stop_gate) {
            try runtime.registerStop(.{
                .name = "fx.jev.completion",
                .ctx = self,
                .run = stopHandler,
            });
        }
    }

    fn clearTouched(self: *Gate) void {
        for (self.sdd_touched.items) |title| self.alloc.free(title);
        self.sdd_touched.clearRetainingCapacity();
    }

    /// Whether this turn's route requires test-first work.
    fn requiresTests(self: *const Gate) bool {
        const mode = self.sdd_turn_mode orelse return false;
        if (mode.tdd == .off) return false;
        const route = self.sdd_route orelse return false;
        if (route.manual) return false;
        return switch (route.route) {
            .spec, .change => true,
            .fix => route.bug,
            .unclear => false,
        };
    }

    fn lend(self: *Gate, text: []u8) []const u8 {
        if (self.lent) |old| self.alloc.free(old);
        self.lent = text;
        return text;
    }

    fn resetForTurn(self: *Gate, turn: u64) void {
        if (self.turn != null and self.turn.? == turn) return;
        self.turn = turn;
        self.plan_settled = false;
        self.plan_holds = 0;
        self.action_holds = 0;
        self.sdd_turn_mode = null;
        self.sdd_route = null;
        self.clearTouched();
        self.tdd_holds = 0;
        self.growth_held = false;
        self.tdd_green_asked = false;
        self.tdd_weak_asked = false;
        self.tdd_uncited_asked = false;
        self.sdd_settled = false;
        self.sdd_change = null;
        self.sdd_incomplete_held = false;
    }

    fn newEntry(self: *const Gate, gate: []const u8, invocation: hooks.Invocation, threshold: f64) decision_log.Entry {
        return .{
            .gate = gate,
            .session_id = invocation.scope.session_id,
            .turn_id = invocation.turn_id,
            .model = self.config.model,
            .threshold = threshold,
            .outcome = "allow",
            .latency_ms = 0,
        };
    }

    /// Calls Jev. On failure logs `entry` as unavailable and returns null.
    /// On success fills the entry's model, latency, tokens and answers; the
    /// answers borrow from the returned response.
    fn consult(
        self: *Gate,
        entry: *decision_log.Entry,
        state_json: []const u8,
        questions: []const jev_contract.Question,
    ) ?jev_contract.Response {
        const alloc = self.alloc;
        const started = io_mod.milliTimestamp();
        var key = (jev_config.loadApiKey(alloc) catch null) orelse {
            entry.outcome = "unavailable";
            entry.detail = "no API key";
            decision_log.append(alloc, entry.*);
            return null;
        };
        defer key.deinit(alloc);
        const response = typesafe.systemOne(alloc, .{
            .base_url = self.config.base_url,
            .api_key = key.value,
            .model = self.config.model,
            .state_json = state_json,
            .questions = questions,
        }) catch |err| {
            entry.outcome = "unavailable";
            entry.detail = @errorName(err);
            entry.latency_ms = io_mod.milliTimestamp() - started;
            decision_log.append(alloc, entry.*);
            return null;
        };
        entry.model = response.model;
        entry.latency_ms = io_mod.milliTimestamp() - started;
        entry.input_tokens = response.input_tokens;
        entry.answers = response.answers;
        return response;
    }

    fn logIncomplete(self: *Gate, entry: *decision_log.Entry, err: anyerror) void {
        entry.outcome = "unavailable";
        entry.detail = @errorName(err);
        decision_log.append(self.alloc, entry.*);
    }

    fn preToolUseHandler(raw: *anyopaque, input: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
        const self: *Gate = @ptrCast(@alignCast(raw));
        if (!self.active.load(.acquire)) return .continue_;
        switch (input.invocation.scope.kind) {
            .interactive, .ask => {},
            .acp, .subagent => return .continue_,
        }
        if (std.mem.trim(u8, input.user_request, " \t\r\n").len == 0) return .continue_;
        const turn = input.invocation.turn_id orelse return .continue_;

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.resetForTurn(turn);

        const config = &self.config;
        const tool = input.tool_name;
        const action = blk: {
            if (config.ask_gate and std.mem.eql(u8, tool, ask_gate.tool_name)) break :blk self.checkAsk(input);
            if (config.routes.len != 0 and std.mem.eql(u8, tool, routing.tool_name)) break :blk self.routeSubagent(input);
            if (config.sdd_gate and plan_gate.isFileChange(tool)) {
                if (!self.sdd_settled) {
                    const sdd_action = self.checkSdd(input) catch |err| sdd: {
                        debug_trace.logf("jev", "sdd gate failed err={s}", .{@errorName(err)});
                        self.sdd_settled = true;
                        break :sdd hooks.PreToolUseAction.continue_;
                    };
                    if (sdd_action != .continue_) break :blk sdd_action;
                }
                if (self.sdd_route != null) {
                    const tdd_action = self.checkTdd(input) catch |err| tdd: {
                        debug_trace.logf("jev", "tdd gate failed err={s}", .{@errorName(err)});
                        break :tdd hooks.PreToolUseAction.continue_;
                    };
                    if (tdd_action != .continue_) break :blk tdd_action;
                }
            }
            if (config.plan_gate and !self.plan_settled and plan_gate.isFileChange(tool)) {
                const plan_action = self.checkPlan(input) catch |err| plan: {
                    debug_trace.logf("jev", "plan gate failed err={s}", .{@errorName(err)});
                    self.plan_settled = true;
                    break :plan hooks.PreToolUseAction.continue_;
                };
                if (plan_action != .continue_) break :blk plan_action;
            }
            if (config.action_gate and self.action_holds < max_action_holds and action_gate.isChecked(tool)) break :blk self.checkAction(input);
            break :blk hooks.PreToolUseAction.continue_;
        };
        return action catch |err| {
            debug_trace.logf("jev", "pre-tool gate failed tool={s} err={s}", .{ tool, @errorName(err) });
            return .continue_;
        };
    }

    fn checkAsk(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = (try ask_gate.parse(arena, input.arguments_json)) orelse return .continue_;
        var entry = self.newEntry("ask", input.invocation, self.config.ask_threshold);
        const state = try ask_gate.buildState(self.alloc, arena, .{
            .user_request = input.user_request,
            .turn_messages = input.turn_messages,
            .assistant_text = input.assistant_text,
            .arguments_json = input.arguments_json,
        }, parsed);
        defer self.alloc.free(state);
        var response = self.consult(&entry, state, parsed.questions) orelse return .continue_;
        defer response.deinit();
        const verdict = ask_gate.evaluate(arena, parsed, &response, self.config.ask_threshold) catch |err| {
            self.logIncomplete(&entry, err);
            return .continue_;
        };
        switch (verdict) {
            .ask_user => {
                entry.outcome = "ask_user";
                decision_log.append(self.alloc, entry);
                return .continue_;
            },
            .answered => |answers| {
                entry.outcome = "answered";
                decision_log.append(self.alloc, entry);
                return .{ .block = self.lend(try ask_gate.answerText(self.alloc, answers)) };
            },
        }
    }

    fn routeSubagent(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const task = routing.routableTask(arena, input.arguments_json) orelse return .continue_;
        var entry = self.newEntry("routing", input.invocation, routing.min_confidence);
        const state = try routing.buildState(self.alloc, task);
        defer self.alloc.free(state);
        const questions = try routing.questions(arena, self.config.routes);
        var response = self.consult(&entry, state, questions) orelse return .continue_;
        defer response.deinit();
        const route = routing.pick(self.config.routes, &response) orelse {
            entry.outcome = "skip";
            entry.detail = "no confident route";
            decision_log.append(self.alloc, entry);
            return .continue_;
        };
        const rewritten = try routing.rewriteArguments(self.alloc, input.arguments_json, route);
        entry.outcome = "route";
        entry.detail = route.name;
        decision_log.append(self.alloc, entry);
        return .{ .rewrite_arguments = self.lend(rewritten) };
    }

    fn checkSdd(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        const root_path = input.invocation.scope.workspace_root;
        if (self.sdd_turn_mode == null) self.sdd_turn_mode = sdd_mode.load(self.alloc, root_path);
        if (!self.sdd_turn_mode.?.enabled) {
            self.sdd_settled = true;
            return .continue_;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // Proposals and specs are always writable; only code waits.
        if (toolPath(arena, input.arguments_json)) |path| {
            if (sdd_layout.isSddPath(root_path, path)) return .continue_;
        }
        const io = io_mod.getIo();
        var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
        defer root.close(io);
        const changes = try sdd_layout.listChanges(arena, root);
        var entry = self.newEntry("sdd", input.invocation, sdd_gate.rule_threshold);
        if (sdd_layout.firstWithStatus(changes, .approved)) |approved| {
            self.sdd_settled = true;
            self.sdd_route = .{ .route = .change, .manual = approved.tdd_manual };
            entry.outcome = "change";
            entry.detail = approved.file;
            decision_log.append(self.alloc, entry);
            return .continue_;
        }
        const proposed = sdd_layout.firstWithStatus(changes, .proposed);
        if (self.sdd_change) |verdict| {
            // Already routed to change this turn: hold until approved.
            entry.outcome = "hold";
            entry.detail = "change";
            decision_log.append(self.alloc, entry);
            return .{ .block = self.lend(try self.changeHold(verdict, proposed)) };
        }

        const rules = try sdd_layout.listRules(arena, root);
        const with_proposal = proposed != null;
        const state = try sdd_gate.buildState(self.alloc, .{
            .user_request = input.user_request,
            .turn_messages = input.turn_messages,
            .assistant_text = input.assistant_text,
            .tool_name = input.tool_name,
            .arguments_json = input.arguments_json,
            .rules = rules,
            .proposal = if (proposed) |change| change.body else null,
        });
        defer self.alloc.free(state);
        const questions = try sdd_gate.questions(arena, rules.len, with_proposal);
        var response = self.consult(&entry, state, questions) orelse {
            self.sdd_settled = true;
            return .continue_;
        };
        defer response.deinit();
        const verdict = sdd_gate.evaluate(arena, &response, rules.len, with_proposal) catch |err| {
            self.logIncomplete(&entry, err);
            if (self.sdd_incomplete_held) {
                self.sdd_settled = true;
                return .continue_;
            }
            self.sdd_incomplete_held = true;
            return .{ .block = sdd_gate.incomplete_reason };
        };
        if (proposed) |change| {
            if (verdict.approves) {
                try sdd_layout.setStatus(self.alloc, root, change.file, .approved);
                self.sdd_settled = true;
                self.sdd_route = .{ .route = .change, .manual = change.tdd_manual };
                entry.outcome = "approved";
                entry.detail = change.file;
                decision_log.append(self.alloc, entry);
                // Held once so the agent knows the status changed under it;
                // the retry goes through.
                return .{ .block = self.lend(try sdd_gate.approvedNotice(self.alloc, change.file)) };
            }
        }
        entry.outcome = @tagName(verdict.route);
        decision_log.append(self.alloc, entry);
        switch (verdict.route) {
            .fix => {
                self.sdd_settled = true;
                self.sdd_route = .{ .route = .fix, .bug = verdict.bug };
                return .continue_;
            },
            .spec => {
                self.sdd_settled = true;
                var manual = true;
                for (verdict.touched) |index| {
                    if (!tdd_gate.isManual(rules[index].title)) manual = false;
                    try self.sdd_touched.append(self.alloc, try self.alloc.dupe(u8, rules[index].title));
                }
                self.sdd_route = .{ .route = .spec, .bug = verdict.bug, .manual = manual };
                return .{ .block = self.lend(try sdd_gate.specReason(self.alloc, rules, verdict.touched)) };
            },
            .unclear => {
                self.sdd_settled = true;
                return .{ .block = sdd_gate.unclear_reason };
            },
            .change => {
                self.sdd_change = .{ .route = .change, .high_stakes = verdict.high_stakes, .substantial = verdict.substantial };
                return .{ .block = self.lend(try self.changeHold(self.sdd_change.?, proposed)) };
            },
        }
    }

    /// Growth and test-first checks for a source change once the route is
    /// known.
    fn checkTdd(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        const route = self.sdd_route.?;
        const mode = self.sdd_turn_mode orelse return .continue_;
        const root_path = input.invocation.scope.workspace_root;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = toolPath(arena, input.arguments_json) orelse return .continue_;
        if (!tdd_gate.isSourceChange(root_path, path)) return .continue_;
        const evidence = try tdd_gate.scan(arena, input.turn_messages, root_path, mode.testCommand(), .{ .path = path });

        if ((route.route == .fix or route.route == .spec) and !self.growth_held and evidence.source_files > tdd_gate.growth_limit) {
            self.growth_held = true;
            var entry = self.newEntry("sdd", input.invocation, tdd_gate.growth_limit);
            entry.outcome = "hold";
            entry.detail = "grew past a small change";
            decision_log.append(self.alloc, entry);
            return .{ .block = self.lend(try tdd_gate.growthReason(self.alloc, evidence.source_files)) };
        }
        if (!self.requiresTests() or evidence.source_changed or evidence.red) return .continue_;
        const max_holds: u8 = if (mode.tdd == .strict) 4 else 2;
        var entry = self.newEntry("tdd", input.invocation, 0);
        if (self.tdd_holds >= max_holds) {
            entry.detail = "hold budget spent";
            decision_log.append(self.alloc, entry);
            return .continue_;
        }
        self.tdd_holds += 1;
        entry.outcome = "hold";
        entry.detail = "no failing test before the source change";
        decision_log.append(self.alloc, entry);
        return .{ .block = tdd_gate.red_reason };
    }

    /// Green, meaningful-test and (strict) citation checks at the end of a
    /// turn. Null lets the turn go on to the drift check.
    fn checkTddStop(self: *Gate, input: hooks.StopInput) !?hooks.StopAction {
        if (!self.requiresTests()) return null;
        const mode = self.sdd_turn_mode.?;
        const root_path = input.invocation.scope.workspace_root;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const evidence = try tdd_gate.scan(arena, input.turn_messages, root_path, mode.testCommand(), null);
        if (!evidence.source_changed) return null;
        var entry = self.newEntry("tdd", input.invocation, tdd_gate.meaningful_threshold);
        if (!evidence.green) {
            if (self.tdd_green_asked) return null;
            self.tdd_green_asked = true;
            entry.outcome = "continue";
            entry.detail = "no passing test run after the last source change";
            decision_log.append(self.alloc, entry);
            return .{ .continue_once = tdd_gate.green_reason };
        }
        if (evidence.tests.len != 0 and !self.tdd_weak_asked) {
            self.tdd_weak_asked = true;
            const state = try tdd_gate.buildState(self.alloc, input.user_request, evidence);
            defer self.alloc.free(state);
            var response = self.consult(&entry, state, &tdd_gate.questions) orelse return null;
            defer response.deinit();
            const meaningful = tdd_gate.meaningful(&response) orelse {
                self.logIncomplete(&entry, error.IncompleteJevAnswer);
                return null;
            };
            if (!meaningful) {
                entry.outcome = "continue";
                entry.detail = "tests would pass without the behavior";
                decision_log.append(self.alloc, entry);
                return .{ .continue_once = tdd_gate.weak_test_reason };
            }
            decision_log.append(self.alloc, entry);
        }
        if (mode.tdd == .strict and !self.tdd_uncited_asked and self.sdd_touched.items.len != 0) {
            self.tdd_uncited_asked = true;
            const citations = specCitations(arena, root_path);
            var rules: std.ArrayList(sdd_layout.Rule) = .empty;
            var indices: std.ArrayList(usize) = .empty;
            for (self.sdd_touched.items, 0..) |title, index| {
                try rules.append(arena, .{ .capability = "", .title = title, .body = "" });
                try indices.append(arena, index);
            }
            const missing = try tdd_gate.uncitedRules(arena, rules.items, indices.items, citations);
            if (missing.len != 0) {
                var strict_entry = self.newEntry("tdd", input.invocation, 0);
                strict_entry.outcome = "continue";
                strict_entry.detail = "changed rules without a citing test";
                decision_log.append(self.alloc, strict_entry);
                return .{ .continue_once = self.lend(try tdd_gate.uncitedReason(self.alloc, missing)) };
            }
        }
        return null;
    }

    fn changeHold(self: *Gate, verdict: sdd_gate.Verdict, proposed: ?sdd_layout.Change) ![]u8 {
        if (proposed) |change| return sdd_gate.pendingReason(self.alloc, change.file);
        var date_buf: [10]u8 = undefined;
        return sdd_gate.changeReason(self.alloc, verdict, sdd_layout.today(&date_buf));
    }

    fn checkPlan(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        var entry = self.newEntry("plan", input.invocation, self.config.plan_threshold);
        if (self.plan_holds >= max_plan_holds) {
            self.plan_settled = true;
            entry.detail = "hold budget spent";
            decision_log.append(self.alloc, entry);
            return .continue_;
        }
        const state = try plan_gate.buildState(self.alloc, .{
            .user_request = input.user_request,
            .turn_messages = input.turn_messages,
            .assistant_text = input.assistant_text,
            .tool_name = input.tool_name,
            .arguments_json = input.arguments_json,
        });
        defer self.alloc.free(state);
        var response = self.consult(&entry, state, &plan_gate.questions) orelse {
            self.plan_settled = true;
            return .continue_;
        };
        defer response.deinit();
        const verdict = plan_gate.evaluate(&response, self.config.plan_threshold) catch |err| {
            self.plan_settled = true;
            self.logIncomplete(&entry, err);
            return .continue_;
        };
        switch (verdict) {
            .not_substantial => {
                self.plan_settled = true;
                entry.outcome = "skip";
                entry.detail = "not substantial";
                decision_log.append(self.alloc, entry);
                return .continue_;
            },
            .approved => {
                self.plan_settled = true;
                decision_log.append(self.alloc, entry);
                return .continue_;
            },
            .needs_plan => |needs| {
                self.plan_holds += 1;
                entry.outcome = "hold";
                decision_log.append(self.alloc, entry);
                return .{ .block = self.lend(try plan_gate.blockReason(self.alloc, needs)) };
            },
        }
    }

    fn checkAction(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        var entry = self.newEntry("action", input.invocation, self.config.action_threshold);
        const state = try action_gate.buildState(self.alloc, .{
            .user_request = input.user_request,
            .turn_messages = input.turn_messages,
            .assistant_text = input.assistant_text,
            .tool_name = input.tool_name,
            .arguments_json = input.arguments_json,
        });
        defer self.alloc.free(state);
        var response = self.consult(&entry, state, &action_gate.questions) orelse return .continue_;
        defer response.deinit();
        const verdict = action_gate.evaluate(&response, self.config.action_threshold) catch |err| {
            self.logIncomplete(&entry, err);
            return .continue_;
        };
        switch (verdict) {
            .allowed => {
                decision_log.append(self.alloc, entry);
                return .continue_;
            },
            .held => |held| {
                self.action_holds += 1;
                entry.outcome = "hold";
                entry.detail = input.tool_name;
                decision_log.append(self.alloc, entry);
                return .{ .block = self.lend(try action_gate.holdReason(self.alloc, held)) };
            },
        }
    }

    fn stopHandler(raw: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
        const self: *Gate = @ptrCast(@alignCast(raw));
        if (!self.active.load(.acquire)) return .allow;
        switch (input.invocation.scope.kind) {
            .interactive, .ask => {},
            .acp, .subagent => return .allow,
        }
        if (!input.can_continue) return .allow;
        if (std.mem.trim(u8, input.user_request, " \t\r\n").len == 0) return .allow;

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.checkCompletion(input) catch |err| {
            debug_trace.logf("jev", "completion gate failed err={s}", .{@errorName(err)});
            return .allow;
        };
    }

    fn checkCompletion(self: *Gate, input: hooks.StopInput) !hooks.StopAction {
        var entry = self.newEntry("stop", input.invocation, self.config.stop_threshold);
        const state = try completion_gate.buildState(self.alloc, .{
            .user_request = input.user_request,
            .final_message = input.assistant_text,
            .turn_messages = input.turn_messages,
        });
        defer self.alloc.free(state);
        var response = self.consult(&entry, state, &completion_gate.questions) orelse return .allow;
        defer response.deinit();
        const verdict = completion_gate.evaluate(&response, self.config.stop_threshold) catch |err| {
            self.logIncomplete(&entry, err);
            return .allow;
        };
        switch (verdict) {
            .skipped => |reason| {
                entry.outcome = "skip";
                entry.detail = reason;
                decision_log.append(self.alloc, entry);
                return .allow;
            },
            .passed => {
                decision_log.append(self.alloc, entry);
                if (self.config.sdd_gate) {
                    const tdd_action = self.checkTddStop(input) catch |err| tdd: {
                        debug_trace.logf("jev", "tdd stop check failed err={s}", .{@errorName(err)});
                        break :tdd null;
                    };
                    if (tdd_action) |action| return action;
                }
                if (self.config.drift_gate and changedFiles(input.turn_messages) and
                    sdd_mode.load(self.alloc, input.invocation.scope.workspace_root).enabled)
                {
                    return self.checkDrift(input) catch |err| {
                        debug_trace.logf("jev", "drift check failed err={s}", .{@errorName(err)});
                        return .allow;
                    };
                }
                return .allow;
            },
            .failed => |failed| {
                entry.outcome = "continue";
                decision_log.append(self.alloc, entry);
                return .{ .continue_once = self.lend(try completion_gate.feedback(self.alloc, failed)) };
            },
        }
    }

    fn checkDrift(self: *Gate, input: hooks.StopInput) !hooks.StopAction {
        const root_path = input.invocation.scope.workspace_root;
        var root = std.Io.Dir.cwd().openDir(io_mod.getIo(), root_path, .{}) catch return .allow;
        const dir_path = drift.findDir(root) orelse {
            root.close(io_mod.getIo());
            return .allow;
        };
        root.close(io_mod.getIo());

        var entry = self.newEntry("drift", input.invocation, drift.contradiction_threshold);
        const started = io_mod.milliTimestamp();
        var key = (try jev_config.loadApiKey(self.alloc)) orelse return .allow;
        defer key.deinit(self.alloc);
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = drift.check(arena, .{
            .base_url = self.config.base_url,
            .api_key = key.value,
            .model = self.config.model,
        }, root_path, "HEAD", dir_path) catch |err| {
            entry.outcome = "unavailable";
            entry.detail = @errorName(err);
            entry.latency_ms = io_mod.milliTimestamp() - started;
            decision_log.append(self.alloc, entry);
            return .allow;
        };
        entry.latency_ms = io_mod.milliTimestamp() - started;

        var fresh: std.ArrayList(drift.Finding) = .empty;
        var fresh_keys: std.ArrayList([]const u8) = .empty;
        for (report.findings) |finding| {
            if (!finding.stale) continue;
            // Spec rules share a file, so the title is part of the key.
            const report_key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ finding.decision.file, finding.decision.title });
            if (self.drift_reported.contains(report_key)) continue;
            try fresh.append(arena, finding);
            try fresh_keys.append(arena, report_key);
        }
        const answers = try arena.alloc(jev_contract.NamedAnswer, report.findings.len);
        for (report.findings, 0..) |finding, index| answers[index] = .{ .id = finding.decision.file, .answer = .{ .noul = finding.contradiction } };
        entry.answers = answers;
        if (fresh.items.len == 0) {
            entry.outcome = if (report.findings.len == 0) "skip" else "allow";
            decision_log.append(self.alloc, entry);
            return .allow;
        }
        for (fresh_keys.items) |report_key| {
            const owned = try self.alloc.dupe(u8, report_key);
            self.drift_reported.put(self.alloc, owned, {}) catch |err| {
                self.alloc.free(owned);
                return err;
            };
        }
        entry.outcome = "continue";
        decision_log.append(self.alloc, entry);
        return .{ .continue_once = self.lend(try drift.feedback(self.alloc, dir_path, fresh.items)) };
    }
};

/// Lines citing spec rules (`spec: <spec> › <rule>`) in tracked files.
/// Empty when git is unavailable.
fn specCitations(arena: Allocator, root_path: []const u8) []const u8 {
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ "git", "grep", "-h", "-I", "-F", "-e", "spec:", "--", ".", ":(exclude)" ++ sdd_layout.root_dir },
        .cwd = .{ .path = root_path },
    }) catch return "";
    return result.stdout;
}

/// The `path` argument of a file tool call, if present.
fn toolPath(arena: Allocator, arguments_json: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (parsed != .object) return null;
    const path = parsed.object.get("path") orelse return null;
    return if (path == .string) path.string else null;
}

/// Whether the turn changed a file through the file tools.
fn changedFiles(messages: []const types.ChatMessage) bool {
    for (messages) |message| {
        if (message.role != .tool or message.tool_result_status != .success) continue;
        const name = message.tool_name orelse continue;
        if (plan_gate.isFileChange(name)) return true;
    }
    return false;
}

test "a disabled gate registers no handlers" {
    var runtime = hooks.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var gate = Gate{ .alloc = std.testing.allocator };
    defer gate.deinit();
    try gate.register(&runtime);
    const view = runtime.freeze();
    try std.testing.expect(!view.hasStop());
}

test "an enabled gate registers the plan and completion handlers" {
    var runtime = hooks.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var gate = Gate{ .alloc = std.testing.allocator, .config = .{ .enabled = true } };
    defer gate.deinit();
    try gate.register(&runtime);
    const view = runtime.freeze();
    try std.testing.expect(view.hasStop());
    try std.testing.expectEqual(@as(usize, 1), view.pre_tool_use_handlers.len);
}

test "the pre-tool handler ignores reads, subagents and settled turns without calling Jev" {
    var gate = Gate{ .alloc = std.testing.allocator, .config = .{ .enabled = true, .ask_gate = false } };
    defer gate.deinit();
    const base = hooks.PreToolUseInput{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/w" }, .turn_id = 7 },
        .step_index = 0,
        .call_id = "c1",
        .tool_name = "read_file",
        .arguments_json = "{}",
        .user_request = "build the feature",
    };
    try std.testing.expect((try Gate.preToolUseHandler(&gate, base)) == .continue_);
    var subagent = base;
    subagent.tool_name = "write_file";
    subagent.invocation.scope.kind = .subagent;
    try std.testing.expect((try Gate.preToolUseHandler(&gate, subagent)) == .continue_);
    var settled = base;
    settled.tool_name = "edit_file";
    gate.turn = 7;
    gate.plan_settled = true;
    try std.testing.expect((try Gate.preToolUseHandler(&gate, settled)) == .continue_);
}

test "the completion handler allows subagent and final-step turns without calling Jev" {
    var gate = Gate{ .alloc = std.testing.allocator, .config = .{ .enabled = true } };
    defer gate.deinit();
    const base = hooks.StopInput{
        .invocation = .{ .scope = .{ .kind = .subagent, .workspace_root = "/w" } },
        .step_index = 1,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
        .user_request = "do it",
    };
    try std.testing.expect((try Gate.stopHandler(&gate, base)) == .allow);
    var last_step = base;
    last_step.invocation.scope.kind = .interactive;
    last_step.can_continue = false;
    try std.testing.expect((try Gate.stopHandler(&gate, last_step)) == .allow);
    var no_request = base;
    no_request.invocation.scope.kind = .ask;
    no_request.user_request = "  ";
    try std.testing.expect((try Gate.stopHandler(&gate, no_request)) == .allow);
}

test "an inactive gate lets file changes and turn ends through" {
    var gate = Gate{ .alloc = std.testing.allocator, .config = .{ .enabled = true } };
    defer gate.deinit();
    gate.setActive(false);
    try std.testing.expect(!gate.isActive());
    const change = hooks.PreToolUseInput{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/w" }, .turn_id = 1 },
        .step_index = 0,
        .call_id = "c1",
        .tool_name = "write_file",
        .arguments_json = "{}",
        .user_request = "build the feature",
    };
    try std.testing.expect((try Gate.preToolUseHandler(&gate, change)) == .continue_);
    const stop = hooks.StopInput{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/w" }, .turn_id = 1 },
        .step_index = 1,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
        .user_request = "build the feature",
    };
    try std.testing.expect((try Gate.stopHandler(&gate, stop)) == .allow);
}

test "unparseable questions and routed calls with a model skip Jev" {
    var gate = Gate{ .alloc = std.testing.allocator, .config = .{ .enabled = true } };
    defer gate.deinit();
    var input = hooks.PreToolUseInput{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/w" }, .turn_id = 3 },
        .step_index = 0,
        .call_id = "c1",
        .tool_name = ask_gate.tool_name,
        .arguments_json = "{\"questions\":[]}",
        .user_request = "pick one",
    };
    try std.testing.expect((try Gate.preToolUseHandler(&gate, input)) == .continue_);
    input.tool_name = routing.tool_name;
    input.arguments_json = "{\"request\":{\"action\":\"run\",\"task\":\"t\",\"model\":\"m\"}}";
    try std.testing.expect((try Gate.preToolUseHandler(&gate, input)) == .continue_);
}

test "changedFiles looks for successful file tool results" {
    const edited = [_]types.ChatMessage{
        .{ .role = .tool, .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .tool, .tool_name = "edit_file", .tool_result_status = .success },
    };
    try std.testing.expect(changedFiles(&edited));
    const failed = [_]types.ChatMessage{.{ .role = .tool, .tool_name = "write_file", .tool_result_status = .failure }};
    try std.testing.expect(!changedFiles(&failed));
}
