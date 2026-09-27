//! Jev as fx's decision maker: registers lifecycle handlers that ask Jev
//! before the agent loop commits to a decision.
//!
//! The plan gate runs on `PreToolUse` before the first file change of a
//! turn: a substantial request needs a stated plan that covers it, and the
//! change is held (at most twice per turn) until one exists.
//!
//! The completion gate runs on `Stop` for root interactive and `fx ask`
//! turns. It sends the agent back once when Jev cannot confirm the final
//! answer is backed by the turn's tool results. When Jev is unreachable, has
//! no key, or answers incompletely, the turn finishes normally and the
//! decision log records why.

const std = @import("std");
const hooks = @import("../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const typesafe = @import("../../gateway/typesafe.zig");
const jev_config = @import("jev_config.zig");
const completion_gate = @import("completion_gate.zig");
const plan_gate = @import("plan_gate.zig");
const decision_log = @import("decision_log.zig");

const Allocator = std.mem.Allocator;

pub const Gate = struct {
    alloc: Allocator,
    config: jev_config.Config = .{},
    mutex: std.Io.Mutex = .init,
    /// Continuation text lent to the hook dispatcher, which copies it.
    feedback: ?[]u8 = null,
    /// Plan-gate state for the turn in progress.
    plan_turn: ?u64 = null,
    plan_settled: bool = false,
    plan_holds: u8 = 0,

    /// Loads the profile configuration. Jev stays inactive unless enabled.
    pub fn init(alloc: Allocator) Gate {
        const config = jev_config.load(alloc) catch |err| blk: {
            debug_trace.logf("jev", "config unavailable err={s}", .{@errorName(err)});
            break :blk jev_config.Config{};
        };
        return .{ .alloc = alloc, .config = config };
    }

    pub fn deinit(self: *Gate) void {
        if (self.feedback) |text| self.alloc.free(text);
        self.config.deinit(self.alloc);
        self.* = undefined;
    }

    /// Registers the enabled gates. Must run before the runtime is frozen.
    pub fn register(self: *Gate, runtime: *hooks.Runtime) !void {
        if (!self.config.enabled) return;
        if (self.config.plan_gate) {
            try runtime.registerPreToolUse(.{
                .name = "fx.jev.plan",
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

    /// Holds per turn before the gate lets changes through regardless.
    const max_plan_holds = 2;

    fn preToolUseHandler(raw: *anyopaque, input: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
        const self: *Gate = @ptrCast(@alignCast(raw));
        switch (input.invocation.scope.kind) {
            .interactive, .ask => {},
            .acp, .subagent => return .continue_,
        }
        if (!plan_gate.isFileChange(input.tool_name)) return .continue_;
        if (std.mem.trim(u8, input.user_request, " \t\r\n").len == 0) return .continue_;

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const turn = input.invocation.turn_id orelse return .continue_;
        if (self.plan_turn == null or self.plan_turn.? != turn) {
            self.plan_turn = turn;
            self.plan_settled = false;
            self.plan_holds = 0;
        }
        if (self.plan_settled) return .continue_;
        return self.checkPlan(input) catch |err| {
            debug_trace.logf("jev", "plan gate failed err={s}", .{@errorName(err)});
            self.plan_settled = true;
            return .continue_;
        };
    }

    fn checkPlan(self: *Gate, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
        const alloc = self.alloc;
        const started = io_mod.milliTimestamp();
        var entry = decision_log.Entry{
            .gate = "plan",
            .session_id = input.invocation.scope.session_id,
            .turn_id = input.invocation.turn_id,
            .model = self.config.model,
            .threshold = self.config.plan_threshold,
            .outcome = "allow",
            .latency_ms = 0,
        };
        if (self.plan_holds >= max_plan_holds) {
            self.plan_settled = true;
            entry.outcome = "allow";
            entry.detail = "hold budget spent";
            decision_log.append(alloc, entry);
            return .continue_;
        }

        var key = (try jev_config.loadApiKey(alloc)) orelse {
            self.plan_settled = true;
            entry.outcome = "unavailable";
            entry.detail = "no API key";
            decision_log.append(alloc, entry);
            return .continue_;
        };
        defer key.deinit(alloc);

        const state = try plan_gate.buildState(alloc, .{
            .user_request = input.user_request,
            .turn_messages = input.turn_messages,
            .assistant_text = input.assistant_text,
            .tool_name = input.tool_name,
            .arguments_json = input.arguments_json,
        });
        defer alloc.free(state);

        var response = typesafe.systemOne(alloc, .{
            .base_url = self.config.base_url,
            .api_key = key.value,
            .model = self.config.model,
            .state_json = state,
            .questions = &plan_gate.questions,
        }) catch |err| {
            self.plan_settled = true;
            entry.outcome = "unavailable";
            entry.detail = @errorName(err);
            entry.latency_ms = io_mod.milliTimestamp() - started;
            decision_log.append(alloc, entry);
            return .continue_;
        };
        defer response.deinit();
        entry.model = response.model;
        entry.latency_ms = io_mod.milliTimestamp() - started;
        entry.input_tokens = response.input_tokens;
        entry.answers = response.answers;

        const verdict = plan_gate.evaluate(&response, self.config.plan_threshold) catch |err| {
            self.plan_settled = true;
            entry.outcome = "unavailable";
            entry.detail = @errorName(err);
            decision_log.append(alloc, entry);
            return .continue_;
        };
        switch (verdict) {
            .not_substantial => {
                self.plan_settled = true;
                entry.outcome = "skip";
                entry.detail = "not substantial";
                decision_log.append(alloc, entry);
                return .continue_;
            },
            .approved => {
                self.plan_settled = true;
                entry.outcome = "allow";
                decision_log.append(alloc, entry);
                return .continue_;
            },
            .needs_plan => |needs| {
                const reason = try plan_gate.blockReason(alloc, needs);
                if (self.feedback) |old| alloc.free(old);
                self.feedback = reason;
                self.plan_holds += 1;
                entry.outcome = "hold";
                decision_log.append(alloc, entry);
                return .{ .block = reason };
            },
        }
    }

    fn stopHandler(raw: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
        const self: *Gate = @ptrCast(@alignCast(raw));
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
        const alloc = self.alloc;
        const started = io_mod.milliTimestamp();
        var entry = decision_log.Entry{
            .gate = "stop",
            .session_id = input.invocation.scope.session_id,
            .turn_id = input.invocation.turn_id,
            .model = self.config.model,
            .threshold = self.config.stop_threshold,
            .outcome = "allow",
            .latency_ms = 0,
        };

        var key = (try jev_config.loadApiKey(alloc)) orelse {
            entry.outcome = "unavailable";
            entry.detail = "no API key";
            decision_log.append(alloc, entry);
            return .allow;
        };
        defer key.deinit(alloc);

        const state = try completion_gate.buildState(alloc, .{
            .user_request = input.user_request,
            .final_message = input.assistant_text,
            .turn_messages = input.turn_messages,
        });
        defer alloc.free(state);

        var response = typesafe.systemOne(alloc, .{
            .base_url = self.config.base_url,
            .api_key = key.value,
            .model = self.config.model,
            .state_json = state,
            .questions = &completion_gate.questions,
        }) catch |err| {
            entry.outcome = "unavailable";
            entry.detail = @errorName(err);
            entry.latency_ms = io_mod.milliTimestamp() - started;
            decision_log.append(alloc, entry);
            return .allow;
        };
        defer response.deinit();
        entry.model = response.model;
        entry.latency_ms = io_mod.milliTimestamp() - started;
        entry.input_tokens = response.input_tokens;
        entry.answers = response.answers;

        const verdict = completion_gate.evaluate(&response, self.config.stop_threshold) catch |err| {
            entry.outcome = "unavailable";
            entry.detail = @errorName(err);
            decision_log.append(alloc, entry);
            return .allow;
        };
        switch (verdict) {
            .skipped => |reason| {
                entry.outcome = "skip";
                entry.detail = reason;
                decision_log.append(alloc, entry);
                return .allow;
            },
            .passed => {
                entry.outcome = "allow";
                decision_log.append(alloc, entry);
                return .allow;
            },
            .failed => |failed| {
                const text = try completion_gate.feedback(alloc, failed);
                if (self.feedback) |old| alloc.free(old);
                self.feedback = text;
                entry.outcome = "continue";
                decision_log.append(alloc, entry);
                return .{ .continue_once = text };
            },
        }
    }
};

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

test "the plan handler ignores reads, subagents and settled turns without calling Jev" {
    var gate = Gate{ .alloc = std.testing.allocator, .config = .{ .enabled = true } };
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
    gate.plan_turn = 7;
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
