//! The SDD workspace layout.
//!
//! - `sdd/specs/<capability>.md`: how the system behaves today. Every `## `
//!   heading is one rule; the text under it describes the rule.
//! - `sdd/changes/<yyyy-mm-dd>-<slug>.md`: one file per change, with a flat
//!   front matter (`status: proposed|approved|done`, `specs: [a, b]`), a
//!   `# Title`, and `Why`, `What`, `Tasks` (`- [ ]` checkboxes) and `Notes`
//!   sections.
//!
//! Only fx changes a change's `status`; everything else is plain Markdown
//! the user and the agent edit.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const root_dir = "sdd";
pub const specs_dir = "sdd/specs";
pub const changes_dir = "sdd/changes";

pub const max_files = 128;
const max_file_bytes = 256 * 1024;

pub const Status = enum { proposed, approved, done };

pub const Change = struct {
    /// File name inside `changes_dir`.
    file: []const u8,
    title: []const u8,
    /// Null when the front matter has no known status.
    status: ?Status,
    tasks_done: usize,
    tasks_total: usize,
    /// Text after the front matter.
    body: []const u8,
    /// `tdd: manual`: the change is checked in the running app, not by tests.
    tdd_manual: bool = false,
};

pub const Rule = struct {
    /// Spec file stem, for example `reservas`.
    capability: []const u8,
    title: []const u8,
    /// Text under the heading, up to the next rule.
    body: []const u8,
};

const FrontMatter = struct {
    fields: []const u8,
    body: []const u8,
};

fn splitFrontMatter(text: []const u8) FrontMatter {
    if (!std.mem.startsWith(u8, text, "---\n")) return .{ .fields = "", .body = text };
    const end = std.mem.find(u8, text[4..], "\n---") orelse return .{ .fields = "", .body = text };
    const after = 4 + end + 4;
    return .{
        .fields = text[4 .. 4 + end],
        .body = std.mem.trimStart(u8, text[@min(after, text.len)..], "\r\n"),
    };
}

fn frontField(fields: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, fields, '\n');
    while (lines.next()) |line| {
        if (line.len <= name.len or !std.mem.startsWith(u8, line, name) or line[name.len] != ':') continue;
        const value = std.mem.trim(u8, line[name.len + 1 ..], " \t\r\"'");
        return if (value.len == 0) null else value;
    }
    return null;
}

pub fn parseChange(file: []const u8, text: []const u8) Change {
    const front = splitFrontMatter(text);
    var change = Change{
        .file = file,
        .title = std.mem.trimEnd(u8, file, ".md"),
        .status = if (frontField(front.fields, "status")) |value| std.meta.stringToEnum(Status, value) else null,
        .tasks_done = 0,
        .tasks_total = 0,
        .body = front.body,
        .tdd_manual = if (frontField(front.fields, "tdd")) |value| std.mem.eql(u8, value, "manual") else false,
    };
    var title_found = false;
    var lines = std.mem.splitScalar(u8, front.body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!title_found and std.mem.startsWith(u8, line, "# ")) {
            change.title = std.mem.trim(u8, line[2..], " \t");
            title_found = true;
        } else if (std.mem.startsWith(u8, line, "- [ ]")) {
            change.tasks_total += 1;
        } else if (std.mem.startsWith(u8, line, "- [x]") or std.mem.startsWith(u8, line, "- [X]")) {
            change.tasks_total += 1;
            change.tasks_done += 1;
        }
    }
    return change;
}

/// Splits a spec into its `## ` rules. Text before the first rule is not a
/// rule. The returned rules borrow from `text`.
pub fn parseRules(arena: Allocator, capability: []const u8, text: []const u8) ![]Rule {
    const body = splitFrontMatter(text).body;
    var rules: std.ArrayList(Rule) = .empty;
    var current: ?Rule = null;
    var body_start: usize = 0;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const line_start = offset;
        offset += line.len + 1;
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (current) |*rule| {
            rule.body = std.mem.trim(u8, body[body_start..line_start], " \t\r\n");
            try rules.append(arena, rule.*);
        }
        current = .{ .capability = capability, .title = std.mem.trim(u8, line[3..], " \t\r"), .body = "" };
        body_start = @min(offset, body.len);
    }
    if (current) |*rule| {
        rule.body = std.mem.trim(u8, body[body_start..], " \t\r\n");
        try rules.append(arena, rule.*);
    }
    return rules.toOwnedSlice(arena);
}

fn markdownNames(arena: Allocator, root: std.Io.Dir, dir_path: []const u8) ![]const []const u8 {
    const io = io_mod.getIo();
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (names.items.len == max_files) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md") or std.mem.startsWith(u8, entry.name, "_")) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, "README.md")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn readIn(arena: Allocator, root: std.Io.Dir, dir_path: []const u8, name: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, name }) catch return null;
    return root.readFileAlloc(io_mod.getIo(), path, arena, .limited(max_file_bytes)) catch null;
}

/// Changes sorted by file name (oldest first). Everything is allocated in
/// `arena`.
pub fn listChanges(arena: Allocator, root: std.Io.Dir) ![]const Change {
    const names = try markdownNames(arena, root, changes_dir);
    var changes: std.ArrayList(Change) = .empty;
    for (names) |name| {
        const text = readIn(arena, root, changes_dir, name) orelse continue;
        try changes.append(arena, parseChange(name, text));
    }
    return changes.items;
}

/// Every rule of every spec, in file order. Everything is allocated in `arena`.
pub fn listRules(arena: Allocator, root: std.Io.Dir) ![]const Rule {
    const names = try markdownNames(arena, root, specs_dir);
    var rules: std.ArrayList(Rule) = .empty;
    for (names) |name| {
        const text = readIn(arena, root, specs_dir, name) orelse continue;
        try rules.appendSlice(arena, try parseRules(arena, std.mem.trimEnd(u8, name, ".md"), text));
    }
    return rules.items;
}

pub fn countSpecs(arena: Allocator, root: std.Io.Dir) !usize {
    return (try markdownNames(arena, root, specs_dir)).len;
}

pub const Pick = union(enum) {
    found: Change,
    none,
    ambiguous,
    not_found,
};

/// Picks the change named `name` (file name, stem, or slug without the date
/// prefix), or, with no name, the only change in `status`.
pub fn pick(changes: []const Change, name: ?[]const u8, status: Status) Pick {
    if (name) |wanted| {
        for (changes) |change| {
            if (matchesName(change.file, wanted)) return .{ .found = change };
        }
        return .not_found;
    }
    var found: ?Change = null;
    for (changes) |change| {
        if (change.status != status) continue;
        if (found != null) return .ambiguous;
        found = change;
    }
    return if (found) |change| .{ .found = change } else .none;
}

fn matchesName(file: []const u8, wanted: []const u8) bool {
    if (std.mem.eql(u8, file, wanted)) return true;
    const stem = std.mem.trimEnd(u8, file, ".md");
    if (std.mem.eql(u8, stem, wanted)) return true;
    // `2026-09-27-pagos-parciales` matches `pagos-parciales`.
    return stem.len > 11 and stem[10] == '-' and std.mem.eql(u8, stem[11..], wanted);
}

/// The first change in `status`, if any.
pub fn firstWithStatus(changes: []const Change, status: Status) ?Change {
    for (changes) |change| {
        if (change.status == status) return change;
    }
    return null;
}

/// Returns `text` with its front matter `status` set to `status`, adding a
/// front matter when there is none. Caller owns the result.
pub fn withStatus(alloc: Allocator, text: []const u8, status: Status) ![]u8 {
    const value = @tagName(status);
    if (!std.mem.startsWith(u8, text, "---\n") or std.mem.find(u8, text[4..], "\n---") == null) {
        return std.fmt.allocPrint(alloc, "---\nstatus: {s}\n---\n\n{s}", .{ value, text });
    }
    const end = 4 + std.mem.find(u8, text[4..], "\n---").?;
    const fields = text[4..end];
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("---\n");
    var replaced = false;
    var lines = std.mem.splitScalar(u8, fields, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try w.writeByte('\n');
        first = false;
        if (!replaced and std.mem.startsWith(u8, line, "status:")) {
            try w.print("status: {s}", .{value});
            replaced = true;
        } else {
            try w.writeAll(line);
        }
    }
    if (!replaced) {
        if (!first) try w.writeByte('\n');
        try w.print("status: {s}", .{value});
    }
    try w.writeAll(text[end..]);
    return out.toOwnedSlice();
}

/// Rewrites a change's `status` on disk.
pub fn setStatus(alloc: Allocator, root: std.Io.Dir, file: []const u8, status: Status) !void {
    const io = io_mod.getIo();
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ changes_dir, file });
    defer alloc.free(path);
    const text = try root.readFileAlloc(io, path, alloc, .limited(max_file_bytes));
    defer alloc.free(text);
    const updated = try withStatus(alloc, text, status);
    defer alloc.free(updated);
    try root.writeFile(io, .{ .sub_path = path, .data = updated });
}

/// Whether `slug` is lowercase words joined by single hyphens.
pub fn validSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 64 or slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    var previous_hyphen = false;
    for (slug) |byte| {
        const hyphen = byte == '-';
        if (hyphen and previous_hyphen) return false;
        if (!hyphen and !std.ascii.isLower(byte) and !std.ascii.isDigit(byte)) return false;
        previous_hyphen = hyphen;
    }
    return true;
}

/// Today's UTC date as `yyyy-mm-dd`.
pub fn today(buf: *[10]u8) []const u8 {
    const now_secs: i64 = @max(@divFloor(io_mod.milliTimestamp(), 1000), 0);
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 }) catch unreachable;
}

/// The starting text of a new change. Caller owns the result.
pub fn template(alloc: Allocator, slug: []const u8) ![]u8 {
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(alloc);
    for (slug, 0..) |byte, index| {
        const char: u8 = if (byte == '-') ' ' else if (index == 0) std.ascii.toUpper(byte) else byte;
        try title.append(alloc, char);
    }
    return std.fmt.allocPrint(alloc,
        \\---
        \\status: proposed
        \\specs: []
        \\---
        \\# {s}
        \\
        \\## Why
        \\
        \\## What
        \\
        \\## Tasks
        \\- [ ]
        \\
        \\## Notes
        \\
    , .{title.items});
}

/// Creates `sdd/changes/<date>-<slug>.md`. Returns its path relative to
/// `root`; caller owns it.
pub fn newChange(alloc: Allocator, root: std.Io.Dir, slug: []const u8, date: []const u8) ![]u8 {
    if (!validSlug(slug)) return error.InvalidSlug;
    const io = io_mod.getIo();
    try root.createDirPath(io, changes_dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}-{s}.md", .{ changes_dir, date, slug });
    errdefer alloc.free(path);
    if (root.access(io, path, .{})) |_| return error.ChangeExists else |_| {}
    const text = try template(alloc, slug);
    defer alloc.free(text);
    try root.writeFile(io, .{ .sub_path = path, .data = text });
    return path;
}

/// Whether a tool path points inside the workspace's `sdd/` directory.
/// Relative paths are taken from the workspace root.
pub fn isSddPath(workspace_root: []const u8, path: []const u8) bool {
    var relative = path;
    if (std.fs.path.isAbsolute(path)) {
        const root = std.mem.trimEnd(u8, workspace_root, "/");
        if (root.len == 0 or !std.mem.startsWith(u8, path, root) or path.len <= root.len or path[root.len] != '/') return false;
        relative = path[root.len + 1 ..];
    }
    while (std.mem.startsWith(u8, relative, "./")) relative = relative[2..];
    if (std.mem.find(u8, relative, "..") != null) return false;
    return std.mem.startsWith(u8, relative, root_dir ++ "/");
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

test "parseChange reads status, title and task progress" {
    const change = parseChange("2026-09-27-boletos.md",
        \\---
        \\status: approved
        \\specs: [ministerio]
        \\---
        \\# Boletos desde PDF
        \\
        \\## Tasks
        \\- [x] Registry model
        \\- [X] Mimi ingestion
        \\  - [ ] Coverage column
    );
    try std.testing.expectEqual(Status.approved, change.status.?);
    try std.testing.expectEqualStrings("Boletos desde PDF", change.title);
    try std.testing.expectEqual(@as(usize, 2), change.tasks_done);
    try std.testing.expectEqual(@as(usize, 3), change.tasks_total);

    try std.testing.expect(!change.tdd_manual);
    try std.testing.expect(parseChange("m.md", "---\nstatus: approved\ntdd: manual\n---\n").tdd_manual);

    const bare = parseChange("x.md", "no front matter");
    try std.testing.expect(bare.status == null);
    try std.testing.expectEqualStrings("x", bare.title);
}

test "parseRules splits a spec on second-level headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = try parseRules(arena.allocator(), "ministerio",
        \\# Ministerio
        \\Intro text is not a rule.
        \\
        \\## Boletos from a PDF are read-only
        \\A boleto linked to a PDF shows "Ver PDF".
        \\### Detail stays in the rule
        \\
        \\## Boletos are unique by receiptSerie
        \\Re-uploading never duplicates rows.
    );
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings("Boletos from a PDF are read-only", rules[0].title);
    try std.testing.expect(std.mem.find(u8, rules[0].body, "### Detail stays in the rule") != null);
    try std.testing.expectEqualStrings("Re-uploading never duplicates rows.", rules[1].body);
    try std.testing.expectEqualStrings("ministerio", rules[1].capability);
}

test "withStatus replaces or adds the status field" {
    const alloc = std.testing.allocator;
    const replaced = try withStatus(alloc, "---\nstatus: proposed\nspecs: [a]\n---\n# T\n", .approved);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("---\nstatus: approved\nspecs: [a]\n---\n# T\n", replaced);
    const added = try withStatus(alloc, "---\nspecs: [a]\n---\n# T\n", .done);
    defer alloc.free(added);
    try std.testing.expectEqualStrings("---\nspecs: [a]\nstatus: done\n---\n# T\n", added);
    const fresh = try withStatus(alloc, "# T\n", .approved);
    defer alloc.free(fresh);
    try std.testing.expectEqualStrings("---\nstatus: approved\n---\n\n# T\n", fresh);
}

test "pick matches names and the only change in a status" {
    const changes = [_]Change{
        parseChange("2026-09-01-old.md", "---\nstatus: done\n---\n"),
        parseChange("2026-09-27-pagos-parciales.md", "---\nstatus: proposed\n---\n"),
    };
    try std.testing.expectEqualStrings("2026-09-27-pagos-parciales.md", pick(&changes, null, .proposed).found.file);
    try std.testing.expectEqualStrings("2026-09-27-pagos-parciales.md", pick(&changes, "pagos-parciales", .approved).found.file);
    try std.testing.expect(pick(&changes, null, .approved) == .none);
    try std.testing.expect(pick(&changes, "missing", .approved) == .not_found);
    const two = [_]Change{ changes[1], changes[1] };
    try std.testing.expect(pick(&two, null, .proposed) == .ambiguous);
}

test "slugs, templates and sdd paths" {
    try std.testing.expect(validSlug("pagos-parciales"));
    try std.testing.expect(validSlug("v2"));
    try std.testing.expect(!validSlug("Pagos"));
    try std.testing.expect(!validSlug("a--b"));
    try std.testing.expect(!validSlug("-a"));
    try std.testing.expect(!validSlug("../x"));

    const text = try template(std.testing.allocator, "pagos-parciales");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "---\nstatus: proposed\n"));
    try std.testing.expect(std.mem.find(u8, text, "# Pagos parciales\n") != null);
    try std.testing.expectEqual(Status.proposed, parseChange("x.md", text).status.?);

    try std.testing.expect(isSddPath("/repo", "sdd/changes/x.md"));
    try std.testing.expect(isSddPath("/repo/", "/repo/sdd/specs/a.md"));
    try std.testing.expect(isSddPath("/repo", "./sdd/specs/a.md"));
    try std.testing.expect(!isSddPath("/repo", "src/sdd/a.md"));
    try std.testing.expect(!isSddPath("/repo", "/repository/sdd/a.md"));
    try std.testing.expect(!isSddPath("/repo", "sdd/../src/a.ts"));
}

test "newChange writes the template once and lists it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const path = try newChange(alloc, tmp.dir, "pagos-parciales", "2026-09-27");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("sdd/changes/2026-09-27-pagos-parciales.md", path);
    try std.testing.expectError(error.ChangeExists, newChange(alloc, tmp.dir, "pagos-parciales", "2026-09-27"));
    try std.testing.expectError(error.InvalidSlug, newChange(alloc, tmp.dir, "Bad Slug", "2026-09-27"));

    try setStatus(alloc, tmp.dir, "2026-09-27-pagos-parciales.md", .approved);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const changes = try listChanges(arena.allocator(), tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(Status.approved, changes[0].status.?);
    try std.testing.expectEqual(@as(usize, 0), (try listRules(arena.allocator(), tmp.dir)).len);
}
