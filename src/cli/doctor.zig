const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const agent = @import("agent_ipc.zig");
const socket = @import("../apprt/socket.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    /// Query an isolated Linux instance (valid GTK application ID).
    class: ?[:0]const u8 = null,
    /// Output format. Only JSON is supported.
    format: []const u8 = "json",
    /// Bound discovery in milliseconds. Must be positive.
    @"timeout-ms": u32 = 1000,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
    }
    pub fn help(_: Options) !void {
        return Action.help_error;
    }
};

/// The `doctor` command checks Automator without launching or changing terminals.
///
/// JSON reports the executable, runtime, socket reachability, compiled platform
/// capabilities, selected surface, and the next command as an argument array.
/// Exit status is zero when the socket returns a compatible surface list, even
/// when the list is empty. An unreachable instance exits with status one.
///
/// Flags:
///
///   * `--class=<id>`: Query an isolated Linux instance. Unsupported on macOS.
///   * `--format=json`: JSON output (default and only supported format).
///   * `--timeout-ms=<ms>`: Discovery deadline (default: 1000).
///
/// Examples:
///
///     ghostty-automator +doctor
///     ghostty-automator +doctor --class=com.example.agent
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return runArgs(alloc, &iter);
}

fn runArgs(gpa: Allocator, iter: anytype) !u8 {
    var options: Options = .{};
    defer options.deinit();
    args.parse(Options, gpa, &options, iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => return agent.printFailure(.{ .code = @errorName(err), .message = "Invalid arguments. Run +doctor --help." }),
    };
    if (agent.validateOptions(options)) |failure| return agent.printFailure(failure);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var binary_failure: ?agent.Failure = null;
    const executable: ?[]const u8 = agent.executable(alloc) catch |err| blk: {
        binary_failure = .{
            .code = "ExecutableUnavailable",
            .message = try std.fmt.allocPrint(alloc, "Cannot resolve the Automator executable: {s}. Check the installation and /proc access on Linux.", .{@errorName(err)}),
        };
        break :blk @as(?[]const u8, null);
    };
    const path = try socket.getSocketPath(alloc, options.class);
    if (agent.validateSocketPath(path)) |failure| return agent.printFailure(failure);
    const found = agent.probe(alloc, agent.target(options.class), options.@"timeout-ms");
    const surface = agent.selectSurface(found.windows);
    var next: std.ArrayList([]const u8) = .empty;
    try next.appendSlice(alloc, &.{ agent.launcher(executable), if (surface != null) "+get-screen" else "+bootstrap" });
    if (options.class) |class| try next.append(alloc, try std.fmt.allocPrint(alloc, "--class={s}", .{class}));
    if (surface) |id| try next.append(alloc, try std.fmt.allocPrint(alloc, "--surface={s}", .{id}));
    try agent.printJson(.{
        .schema_version = @as(u32, 1),
        .ok = found.reachable and binary_failure == null,
        .data = .{
            .binary = agent.Binary{ .path = executable },
            .socket = .{ .path = path, .reachable = found.reachable, .@"error" = found.@"error" },
            .capabilities = agent.Capabilities{},
            .surface_id = surface,
            .next_command = next.items,
        },
        .@"error" = if (binary_failure) |failure| @as(?agent.Failure, failure) else if (!found.reachable) @as(?agent.Failure, .{
            .code = found.@"error" orelse "Unreachable",
            .message = found.message orelse if (found.@"error" != null and std.mem.eql(u8, found.@"error".?, "IPCTimedOut"))
                "Automator did not respond before the deadline. Inspect the running instance; bootstrap will not replace an unresponsive app."
            else
                "Automator is unreachable. Check the socket error and installation before starting it with +bootstrap.",
        }) else null,
    });
    return if (found.reachable and binary_failure == null) 0 else 1;
}

test "doctor options reject unknown flags and unsupported formats" {
    const testing = std.testing;
    var options: Options = .{};
    defer options.deinit();
    var iter = try std.process.ArgIteratorGeneral(.{}).init(testing.allocator, "--unknown=value");
    defer iter.deinit();
    try testing.expectError(error.InvalidField, args.parse(Options, testing.allocator, &options, &iter));
    options.format = "text";
    try testing.expectEqualStrings("InvalidFormat", agent.validateOptions(options).?.code);
    options.format = "json";
    options.@"timeout-ms" = 0;
    try testing.expectEqualStrings("InvalidTimeout", agent.validateOptions(options).?.code);
}
