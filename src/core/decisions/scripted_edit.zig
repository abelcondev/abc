//! Scripted edits: shell commands that rewrite files in place (`sed -i`,
//! `perl -pi`, a Python script that writes files) skip the exact-match check
//! `edit_file` makes, and in practice they cut a closing `);` or a whole
//! block without anyone noticing until a later test run.
//!
//! When the agent runs one, Jev judges whether it is a targeted change to a
//! few known spots, where `edit_file` is the right tool, or a mechanical
//! change across many files, where a script is reasonable. A targeted one is
//! held once per turn with that advice; the retry goes through.

const std = @import("std");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;

pub const targeted_id = "targeted_edit";
pub const threshold = 0.6;

pub const questions = [_]jev_contract.Question{.{
    .id = targeted_id,
    .instructions = "`command` rewrites the contents of one or a few files at specific spots that exact find-and-replace edits could change one by one; it is not a mechanical rename or replacement repeated across many files, and `user_request` does not ask for a script, sed or perl",
    .kind = .noul,
}};

/// Whether a shell command edits files in place or runs a script that
/// writes files.
pub fn isScriptedEdit(command: []const u8) bool {
    const in_place = [_][]const u8{ "sed -i", "sed -E -i", "gsed -i", "perl -pi", "perl -0pi", "perl -i", "perl -0777 -pi", "ruby -pi", "ruby -i", "awk -i inplace", "gawk -i inplace" };
    for (in_place) |marker| {
        if (std.mem.find(u8, command, marker) != null) return true;
    }
    const scripts = [_][]const u8{ "python3 -", "python -", "python3 -c", "python -c", "node -e", "bun -e", "ruby -e" };
    for (scripts) |marker| {
        if (std.mem.find(u8, command, marker) == null) continue;
        inline for (.{ ".write(", "write_text(", "writeFileSync", "Bun.write", "File.write" }) |writer| {
            if (std.mem.find(u8, command, writer) != null) return true;
        }
    }
    return false;
}

pub fn buildState(alloc: Allocator, user_request: []const u8, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(.{
        .user_request = turn_text.clip(user_request, 2 * 1024),
        .command = turn_text.clip(command, 6 * 1024),
    });
    return out.toOwnedSlice();
}

pub const hold_reason =
    "Scripted edit: use edit_file for this change.\n" ++
    "This command rewrites specific spots in a few files. Scripted in-place edits skip the exact-match check, and a wrong " ++
    "pattern silently cuts or duplicates code. Make the change with edit_file (one call per spot, after reading the file). " ++
    "If this really is a mechanical rename or replacement across many files, run it again, then read back a changed spot or " ++
    "run the tests before moving on.";

test "isScriptedEdit spots in-place edits and writing scripts" {
    try std.testing.expect(isScriptedEdit("cd . && perl -pi -e 's/a/b/' src/x.ts"));
    try std.testing.expect(isScriptedEdit("sed -i '' 's/foo/bar/g' src/*.ts"));
    try std.testing.expect(isScriptedEdit("python3 - <<'EOF'\ns=open(p).read()\nopen(p,'w').write(s)\nEOF"));
    try std.testing.expect(isScriptedEdit("node -e \"require('fs').writeFileSync('a.json', '{}')\""));
    try std.testing.expect(!isScriptedEdit("python3 - <<'EOF'\nprint(open('a').read())\nEOF"));
    try std.testing.expect(!isScriptedEdit("sed -n '1,40p' src/x.ts"));
    try std.testing.expect(!isScriptedEdit("bun test"));
}
