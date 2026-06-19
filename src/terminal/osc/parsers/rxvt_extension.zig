const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_rxvt_extension);

/// Parse OSC 777
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    // ensure that we are sentinel terminated
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const k = std.mem.indexOfScalar(u8, data, ';') orelse {
        parser.state = .invalid;
        return null;
    };
    const ext = data[0..k];

    // Ghostty extension: OSC 777;agent;<state> reports a coding agent's
    // lifecycle state (e.g. from a Claude Code shell hook) so the surface
    // can show an activity indicator. <state> is one of idle|working|
    // waiting|done|end (end is treated as idle/cleared).
    if (std.mem.eql(u8, ext, "agent")) {
        const state_str = data[k + 1 .. data.len - 1];
        const state: Command.AgentState.State =
            if (std.mem.eql(u8, state_str, "working"))
                .working
            else if (std.mem.eql(u8, state_str, "waiting"))
                .waiting
            else if (std.mem.eql(u8, state_str, "done"))
                .done
            else if (std.mem.eql(u8, state_str, "idle") or
            std.mem.eql(u8, state_str, "end"))
                .idle
            else {
                log.warn("unknown agent state: {s}", .{state_str});
                parser.state = .invalid;
                return null;
            };
        parser.command = .{ .agent_state = .{ .state = state } };
        return &parser.command;
    }

    if (!std.mem.eql(u8, ext, "notify")) {
        log.warn("unknown rxvt extension: {s}", .{ext});
        parser.state = .invalid;
        return null;
    }
    const t = std.mem.indexOfScalarPos(u8, data, k + 1, ';') orelse {
        log.warn("rxvt notify extension is missing the title", .{});
        parser.state = .invalid;
        return null;
    };
    data[t] = 0;
    const title = data[k + 1 .. t :0];
    const body = data[t + 1 .. data.len - 1 :0];
    parser.command = .{
        .show_desktop_notification = .{
            .title = title,
            .body = body,
        },
    };
    return &parser.command;
}

test "OSC: OSC 777 show desktop notification with title" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
}

test "OSC: OSC 777 agent state working" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;agent;working";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .agent_state);
    try testing.expectEqual(Command.AgentState.State.working, cmd.agent_state.state);
}

test "OSC: OSC 777 agent state end maps to idle" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;agent;end";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .agent_state);
    try testing.expectEqual(Command.AgentState.State.idle, cmd.agent_state.state);
}

test "OSC: OSC 777 agent state unknown is invalid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;agent;bogus";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}
