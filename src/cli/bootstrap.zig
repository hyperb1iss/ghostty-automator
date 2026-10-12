const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const args = @import("args.zig");
const agent = @import("agent_ipc.zig");
const socket = @import("../apprt/socket.zig");
const build_config = @import("../build_config.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    /// Isolate a Linux instance using a valid GTK application ID.
    class: ?[:0]const u8 = null,
    /// Output format. Only JSON is supported.
    format: []const u8 = "json",
    /// Bound the entire discovery/startup process in milliseconds.
    @"timeout-ms": u32 = 10000,
    /// Working directory for a new terminal (default: current directory).
    @"working-directory": ?[]const u8 = null,
    /// Command for a new terminal. Reused terminals are never changed.
    command: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
    }
    pub fn help(_: Options) !void {
        return Action.help_error;
    }
};

const Data = struct {
    surface_id: ?[]const u8 = null,
    socket_path: []const u8,
    started: bool = false,
    status: []const u8 = "unreachable",
    windows: []const socket.Response.Window = &.{},
    log_path: ?[]const u8 = null,
};

/// The `bootstrap` command finds a usable Automator terminal in one operation.
/// It reuses an existing surface without changing focus, creates a window when
/// a running instance is empty, or launches this Automator installation.
/// Readiness is checked through IPC, with a deadline and retained startup logs.
///
/// JSON contains `data.surface_id`, the full `data.windows` hierarchy, the
/// socket path, startup status, and a diagnostic log path when launched.
/// `data.started` is true only for a directly launched Linux application.
/// macOS LaunchServices does not expose ownership of the GUI process.
/// Linux launches the resolved executable; macOS opens its owning app bundle.
/// macOS has a single default socket and does not support class isolation.
///
/// Flags:
///
///   * `--class=<id>`: Isolate a Linux instance. Unsupported on macOS.
///   * `--format=json`: JSON output (default and only supported format).
///   * `--timeout-ms=<ms>`: Whole startup deadline (default: 10000).
///   * `--working-directory=<path>`: Directory for a new terminal (default: cwd).
///   * `--command=<command>`: Command for a new terminal; ignored on reuse.
///
/// Examples:
///
///     ghostty-automator +bootstrap
///     ghostty-automator +bootstrap --class=com.example.agent
///     ghostty-automator +bootstrap --command='bash --noprofile --norc'
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
        else => return agent.printFailure(.{ .code = @errorName(err), .message = "Invalid arguments. Run +bootstrap --help." }),
    };
    if (agent.validateOptions(options)) |failure| return agent.printFailure(failure);
    if (comptime builtin.os.tag != .macos and
        !(builtin.os.tag == .linux and build_config.app_runtime == .gtk))
        return agent.printFailure(.{ .code = "UnsupportedRuntime", .message = "Bootstrap requires the Linux GTK application or a macOS Automator app bundle." });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var timer = try std.time.Timer.start();
    var data: Data = .{ .socket_path = try socket.getSocketPath(alloc, options.class) };
    if (agent.validateSocketPath(data.socket_path)) |failure| return agent.printFailure(failure);
    var failure: ?agent.Failure = null;
    bootstrap(alloc, options, &timer, &data, &failure) catch |err| {
        const detail: []const u8 = switch (@as(anyerror, err)) {
            error.HandedOffToExistingInstance => "An existing application accepted startup but is unreachable through this socket. Check its class and runtime directory; bootstrap did not activate another window",
            error.ChildExitedWithoutStatus => "The Automator starter exited without a wait status and no reachable instance appeared",
            error.StartupTimedOut => "Automator did not provide an initialized terminal before --timeout-ms",
            else => @errorName(err),
        };
        const message = try std.fmt.allocPrint(alloc, "{s}. Check display access, the Automator installation, and the startup log{s}.", .{ detail, if (data.log_path) |path| try std.fmt.allocPrint(alloc, " at {s}", .{path}) else "" });
        try agent.printJson(.{ .schema_version = @as(u32, 1), .ok = false, .data = data, .@"error" = agent.Failure{
            .code = if (failure) |f| f.code else @errorName(err),
            .message = if (failure) |f| f.message else message,
        } });
        return 1;
    };
    try agent.printJson(.{ .schema_version = @as(u32, 1), .ok = true, .data = data, .@"error" = @as(?agent.Failure, null) });
    return 0;
}

fn remaining(timer: *std.time.Timer, timeout_ms: u32) !u32 {
    const budget = @as(u64, timeout_ms) * std.time.ns_per_ms;
    const elapsed = timer.read();
    if (elapsed >= budget) return error.StartupTimedOut;
    return @intCast(std.math.divCeil(u64, budget - elapsed, std.time.ns_per_ms) catch unreachable);
}

fn pause(timer: *std.time.Timer, timeout_ms: u32) !void {
    const ms = @min(50, try remaining(timer, timeout_ms));
    // Empty Zig slices can carry poison pointers that older kernels reject,
    // even when poll receives zero file descriptors.
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
}

fn discover(alloc: Allocator, options: Options, timer: *std.time.Timer) !agent.Probe {
    return agent.probe(alloc, agent.target(options.class), @min(1000, try remaining(timer, options.@"timeout-ms")));
}

fn ready(data: *Data, found: agent.Probe) bool {
    if (!found.reachable) return false;
    data.windows = found.windows;
    data.surface_id = agent.selectSurface(found.windows);
    return data.surface_id != null;
}

fn canLaunch(found: agent.Probe) bool {
    const reason = found.@"error" orelse return false;
    return std.mem.eql(u8, reason, "FileNotFound") or std.mem.eql(u8, reason, "ConnectionRefused");
}

fn hasSurfaces(windows: []const socket.Response.Window) bool {
    for (windows) |window| for (window.tabs) |tab| {
        if (tab.surfaces.len != 0) return true;
    };
    return false;
}

fn createWindow(alloc: Allocator, options: Options, timer: *std.time.Timer, terminal_args: []const []const u8, failure: *?agent.Failure) !void {
    const window_args = try alloc.alloc([:0]const u8, terminal_args.len);
    for (terminal_args, 0..) |arg, i| window_args[i] = try alloc.dupeZ(u8, arg);
    const response = try agent.query(alloc, agent.target(options.class), try remaining(timer, options.@"timeout-ms"), .new_window, .{
        .arguments = window_args,
    });
    if (!response.ok) {
        failure.* = .{ .code = "RemoteRejected", .message = response.@"error" orelse "Automator refused to create a window." };
        return error.RemoteRejected;
    }
}

fn bootstrap(alloc: Allocator, options: Options, timer: *std.time.Timer, data: *Data, failure: *?agent.Failure) !void {
    var found = try discover(alloc, options, timer);
    if (ready(data, found)) {
        data.status = "reused";
        return;
    }
    // Only startup is coordinated. Two launchers must not compete to own the
    // same listening socket; existing-instance requests remain independent.
    const dir = try socket.getSocketDir(alloc);
    posix.mkdir(dir, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try socket.validateSocketDirectory(data.socket_path);
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.bootstrap.lock", .{data.socket_path});
    const lock_file: std.fs.File = .{ .handle = try posix.open(lock_path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0o600) };
    defer lock_file.close();
    while (!try lock_file.tryLock(.exclusive)) try pause(timer, options.@"timeout-ms");
    defer lock_file.unlock();

    // Another launcher may have made the instance ready while we held no lock.
    found = try discover(alloc, options, timer);
    if (ready(data, found)) {
        data.status = "reused";
        return;
    }
    const working_directory = try std.fs.cwd().realpathAlloc(alloc, options.@"working-directory" orelse ".");
    var terminal_args: std.ArrayList([]const u8) = .empty;
    try terminal_args.append(alloc, try std.fmt.allocPrint(alloc, "--working-directory={s}", .{working_directory}));
    if (options.command) |command| try terminal_args.append(alloc, try std.fmt.allocPrint(alloc, "--command={s}", .{command}));

    var child: ?posix.pid_t = null;
    var launch_requested = false;
    var window_requested = false;
    errdefer if (builtin.os.tag == .linux) {
        if (child) |pid| {
            stopChild(pid);
            data.started = false;
            data.status = "failed";
        }
    };
    if (!found.reachable) {
        // An unresponsive or incompatible live socket is an error, not license
        // to launch another app and replace its socket.
        if (!canLaunch(found)) {
            if (found.message) |message| failure.* = .{ .code = found.@"error" orelse "InstanceUnresponsive", .message = message };
            return error.InstanceUnresponsive;
        }
        if (builtin.os.tag == .linux and posix.getenv("DISPLAY") == null and posix.getenv("WAYLAND_DISPLAY") == null)
            return error.NoDisplay;
        const executable = try agent.executable(alloc);
        data.log_path = try std.fmt.allocPrint(alloc, "{s}/startup-{x}.log", .{ dir, std.crypto.random.int(u64) });
        var launch_args: std.ArrayList([]const u8) = .empty;
        if (builtin.os.tag == .macos) {
            const bundle = owningBundle(executable) orelse return error.ExecutableOutsideAppBundle;
            try launch_args.appendSlice(alloc, &.{ "/usr/bin/open", "-g", "-a", bundle, "--stdout", data.log_path.?, "--stderr", data.log_path.?, "--args" });
        } else {
            try launch_args.append(alloc, executable);
            try launch_args.append(alloc, "--gtk-single-instance=true");
            try launch_args.append(alloc, try std.fmt.allocPrint(alloc, "--class={s}", .{options.class orelse ""}));
        }
        // Apply command/cwd through one IPC window after the app is reachable.
        // Launching without activation also avoids reopening an unreachable
        // existing GTK primary when single-instance registration hands off.
        try launch_args.append(alloc, "--initial-window=false");
        child = try launch(alloc, launch_args.items, data.log_path.?);
        launch_requested = true;
        data.started = builtin.os.tag == .linux;
        data.status = "launching";
    } else data.status = "reused";

    while (true) {
        if (ready(data, found)) {
            if (launch_requested) data.status = "launched";
            return;
        }
        if (found.reachable and !window_requested and !hasSurfaces(found.windows)) {
            try createWindow(alloc, options, timer, terminal_args.items, failure);
            window_requested = true;
            if (!launch_requested) data.status = "created";
        }
        if (child) |pid| {
            switch (try childState(pid)) {
                .running => {},
                .exited => |status| {
                    child = null;
                    data.started = false;
                    if (!posix.W.IFEXITED(status) or posix.W.EXITSTATUS(status) != 0) {
                        data.status = "failed";
                        return error.LaunchFailed;
                    }
                    if (builtin.os.tag == .linux) {
                        found = try discover(alloc, options, timer);
                        if (!found.reachable) {
                            data.status = "handoff";
                            return error.HandedOffToExistingInstance;
                        }
                        launch_requested = false;
                        data.status = if (window_requested) "created" else "reused";
                    }
                    // A successful macOS `open` is a LaunchServices handoff.
                    // Keep probing without claiming ownership of a GUI PID.
                },
                .gone => {
                    child = null;
                    data.started = false;
                    if (builtin.os.tag == .linux) {
                        found = try discover(alloc, options, timer);
                        if (!found.reachable) {
                            data.status = "failed";
                            return error.ChildExitedWithoutStatus;
                        }
                        launch_requested = false;
                    }
                },
            }
        }
        try pause(timer, options.@"timeout-ms");
        found = try discover(alloc, options, timer);
    }
}

const ChildState = union(enum) { running, exited: u32, gone };

/// Unlike std.posix.waitpid, libc ECHILD is handled rather than unreachable.
fn childState(pid: posix.pid_t) !ChildState {
    var status: c_int = 0;
    while (true) {
        const result = std.c.waitpid(pid, &status, @intCast(posix.W.NOHANG));
        switch (posix.errno(result)) {
            .SUCCESS => return if (result == 0) .running else .{ .exited = @bitCast(status) },
            .INTR => continue,
            .CHILD => return .gone,
            else => return error.ChildWaitFailed,
        }
    }
}

fn stopChild(pid: posix.pid_t) void {
    // This PID is our unreaped child, so it cannot have been reassigned. Kill
    // only this failed startup; never signal an instance found through IPC.
    posix.kill(pid, posix.SIG.KILL) catch return;
    var status: c_int = 0;
    while (true) {
        const result = std.c.waitpid(pid, &status, 0);
        if (posix.errno(result) == .INTR) continue;
        return;
    }
}

/// Identify a bundle from the executable itself, including renamed app bundles.
fn owningBundle(executable: []const u8) ?[]const u8 {
    const marker = ".app/Contents/MacOS/";
    const offset = std.mem.lastIndexOf(u8, executable, marker) orelse return null;
    const binary = executable[offset + marker.len ..];
    if (binary.len == 0 or std.mem.indexOfScalar(u8, binary, '/') != null) return null;
    return executable[0 .. offset + ".app".len];
}

/// Prepare allocations before fork and leave the GUI detached with real file
/// descriptors for diagnostics. Pipe-backed child output dies with the CLI.
fn launch(alloc: Allocator, argv: []const []const u8, log_path: []const u8) !posix.pid_t {
    const args_z = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| args_z[i] = (try alloc.dupeZ(u8, arg)).ptr;
    var environment = try std.process.getEnvMap(alloc);
    defer environment.deinit();
    const env_z = try std.process.createEnvironFromMap(alloc, &environment, .{ .zig_progress_fd = -1 });
    const log_file = try std.fs.createFileAbsolute(log_path, .{ .exclusive = true, .mode = 0o600 });
    defer log_file.close();
    const null_fd = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer posix.close(null_fd);
    // Agent harnesses can inherit SIGCHLD=SIG_IGN. Restore ordinary child
    // ownership before fork so a failed starter cannot be silently auto-reaped.
    var action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.CHLD, &action, null);
    const pid = try posix.fork();
    if (pid == 0) {
        _ = posix.setsid() catch childFailure("setsid failed\n");
        posix.dup2(null_fd, posix.STDIN_FILENO) catch childFailure("stdin setup failed\n");
        posix.dup2(log_file.handle, posix.STDOUT_FILENO) catch childFailure("stdout setup failed\n");
        posix.dup2(log_file.handle, posix.STDERR_FILENO) catch childFailure("stderr setup failed\n");
        const err = posix.execveZ(args_z[0].?, args_z.ptr, env_z.ptr);
        _ = posix.write(posix.STDERR_FILENO, @errorName(err)) catch {};
        childFailure("\nAutomator executable launch failed\n");
    }
    return pid;
}

fn childFailure(message: []const u8) noreturn {
    _ = posix.write(posix.STDERR_FILENO, message) catch {};
    if (builtin.link_libc) std.c._exit(127);
    posix.exit(127);
}

test "bootstrap owning bundle uses executable path without guessing app name" {
    try std.testing.expectEqualStrings("/Applications/Renamed Automator.app", owningBundle("/Applications/Renamed Automator.app/Contents/MacOS/Ghostty").?);
    try std.testing.expectEqualStrings("/opt/homebrew/libexec/Ghostty.app", owningBundle("/opt/homebrew/libexec/Ghostty.app/Contents/MacOS/Ghostty").?);
    try std.testing.expect(owningBundle("/usr/local/bin/ghostty-automator") == null);
    try std.testing.expect(owningBundle("/Applications/Ghostty.app/Contents/MacOS/") == null);
    try std.testing.expect(owningBundle("/Applications/Ghostty.app/Contents/MacOS/subdir/Ghostty") == null);
}

test "bootstrap refuses to launch over a hung or incompatible socket" {
    try std.testing.expect(canLaunch(.{ .reachable = false, .@"error" = "FileNotFound" }));
    try std.testing.expect(canLaunch(.{ .reachable = false, .@"error" = "ConnectionRefused" }));
    try std.testing.expect(!canLaunch(.{ .reachable = false, .@"error" = "IPCTimedOut" }));
    try std.testing.expect(!canLaunch(.{ .reachable = false, .@"error" = "InvalidResponse" }));
    try std.testing.expect(!canLaunch(.{ .reachable = false, .@"error" = "AccessDenied" }));
}

test "bootstrap report preserves selected surface and complete hierarchy" {
    const windows = [_]socket.Response.Window{.{ .id = "window", .tabs = &.{.{ .id = "tab", .surfaces = &.{.{ .id = "surface", .rows = 24, .cols = 80 }} }} }};
    var data: Data = .{ .socket_path = "/tmp/test.sock" };
    try std.testing.expect(ready(&data, .{ .reachable = true, .windows = &windows }));
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, data, .{});
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("surface", parsed.value.object.get("surface_id").?.string);
    try std.testing.expectEqualStrings("window", parsed.value.object.get("windows").?.array.items[0].object.get("id").?.string);
    try std.testing.expect(!parsed.value.object.get("started").?.bool);
}

test "bootstrap distinguishes empty instances from initializing surfaces" {
    try std.testing.expect(!hasSurfaces(&.{}));
    const initializing = [_]socket.Response.Window{.{ .id = "w", .tabs = &.{.{ .id = "t", .surfaces = &.{.{ .id = "surface" }} }} }};
    try std.testing.expect(hasSurfaces(&initializing));
    var data: Data = .{ .socket_path = "/tmp/test.sock" };
    try std.testing.expect(!ready(&data, .{ .reachable = true, .windows = &initializing }));
}

test "bootstrap child status tolerates ECHILD" {
    switch (try childState(std.c.getpid())) {
        .gone => {},
        else => return error.TestUnexpectedResult,
    }
}
