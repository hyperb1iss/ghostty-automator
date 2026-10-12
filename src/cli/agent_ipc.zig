//! Shared discovery and structured diagnostics for agent entry points.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const socket = @import("../apprt/socket.zig");
const ipc = @import("../apprt/ipc.zig");
const build_config = @import("../build_config.zig");

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
};

pub const Capabilities = struct {
    screen_text: bool = supported,
    styled_cells: bool = builtin.os.tag == .macos,
    styled_cells_transport: ?[]const u8 = if (builtin.os.tag == .macos) "raw_socket" else null,
    screenshots: bool = supported,
    key_input: bool = supported,
    mouse_input: bool = supported,
    scroll_input: bool = supported,
    instance_isolation: bool = builtin.os.tag == .linux and build_config.app_runtime == .gtk,
    /// Capabilities describe this build; protocol v1 has no remote negotiation.
    source: []const u8 = "compiled-runtime",

    const supported = builtin.os.tag == .macos or
        (builtin.os.tag == .linux and build_config.app_runtime == .gtk);
};

pub const Binary = struct {
    path: ?[]const u8,
    version: []const u8 = build_config.version_string,
    platform: []const u8 = @tagName(builtin.os.tag),
    runtime: []const u8 = @tagName(build_config.app_runtime),
};

pub const Probe = struct {
    reachable: bool,
    windows: []const socket.Response.Window = &.{},
    @"error": ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn target(class: ?[:0]const u8) ipc.Target {
    return if (class) |c| .{ .class = c } else .detect;
}

/// Reject invalid IDs before a launch can silently fall back to the default app.
pub fn validateClass(class: []const u8) bool {
    if (class.len == 0 or class.len > 255) return false;
    var components = std.mem.splitScalar(u8, class, '.');
    var count: usize = 0;
    while (components.next()) |component| {
        if (component.len == 0 or std.ascii.isDigit(component[0])) return false;
        for (component) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
        count += 1;
    }
    return count >= 2;
}

pub fn validateOptions(options: anytype) ?Failure {
    if (!std.mem.eql(u8, options.format, "json")) return .{
        .code = "InvalidFormat",
        .message = "Use --format=json. Agent commands return JSON by default.",
    };
    if (options.@"timeout-ms" == 0 or options.@"timeout-ms" > std.math.maxInt(i32)) return .{
        .code = "InvalidTimeout",
        .message = "--timeout-ms must be between 1 and 2147483647.",
    };
    if (options.class) |class| {
        if (builtin.os.tag != .linux) return .{
            .code = "UnsupportedIsolation",
            .message = "--class isolation is supported on Linux only. macOS uses one default Automator socket.",
        };
        if (!validateClass(class)) return .{
            .code = "InvalidClass",
            .message = "--class must be a valid GTK application ID (for example com.example.agent).",
        };
    }
    return null;
}

pub fn validateSocketPath(path: []const u8) ?Failure {
    if (path.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) return .{
        .code = "PathTooLong",
        .message = "The Unix socket path is too long. Choose a shorter --class or XDG_RUNTIME_DIR/TMPDIR path.",
    };
    return null;
}

pub fn query(
    alloc: Allocator,
    instance: ipc.Target,
    timeout_ms: u32,
    comptime action: ipc.Action.Key,
    value: ipc.Action.Value(action),
) !socket.Response {
    var client = try socket.Client.initWithOptions(alloc, instance, .{
        .quiet = true,
        .timeout_ms = timeout_ms,
    });
    defer client.deinit();
    const request = try socket.serializeRequest(alloc, instance, action, value);
    defer alloc.free(request);
    return try client.sendRequest(request);
}

pub fn probe(alloc: Allocator, instance: ipc.Target, timeout_ms: u32) Probe {
    const response = query(alloc, instance, timeout_ms, .list_surfaces, {}) catch |err| return .{
        .reachable = false,
        .@"error" = @errorName(err),
    };
    return probeResponse(response);
}

fn probeResponse(response: socket.Response) Probe {
    if (!response.ok) return .{
        .reachable = false,
        .@"error" = "RemoteRejected",
        .message = response.@"error" orelse "Automator rejected the IPC request.",
    };
    const data = response.data orelse return .{ .reachable = false, .@"error" = "InvalidResponse" };
    const windows = data.windows orelse return .{ .reachable = false, .@"error" = "InvalidResponse" };
    return .{ .reachable = true, .windows = windows };
}

/// Selection is deterministic and never changes the user's focus.
pub fn selectSurface(windows: []const socket.Response.Window) ?[]const u8 {
    var first: ?[]const u8 = null;
    var active: ?[]const u8 = null;
    for (windows) |window| {
        for (window.tabs) |tab| {
            for (tab.surfaces) |surface| {
                if (surface.id.len == 0 or surface.rows == 0 or surface.cols == 0) continue;
                if (surface.focused) return surface.id;
                if (first == null) first = surface.id;
                if (active == null and tab.active) active = surface.id;
            }
        }
    }
    return active orelse first;
}

pub fn executable(alloc: Allocator) ![]const u8 {
    const path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(path);
    return try std.fs.cwd().realpathAlloc(alloc, path);
}

/// Installed launchers retain resource and dynamic-library environment setup
/// across independent agent tool calls; the resolved ELF alone cannot do so.
pub fn launcher(executable_path: ?[]const u8) []const u8 {
    if (std.posix.getenv("GHOSTTY_AUTOMATOR_LAUNCHER")) |path| {
        if (validLauncher(path)) return path;
    }
    return executable_path orelse "ghostty-automator";
}

fn validLauncher(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    const stat = std.fs.cwd().statFile(path) catch return false;
    if (stat.kind != .file) return false;
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

pub fn printJson(value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

pub fn printFailure(failure: Failure) !u8 {
    try printJson(.{ .schema_version = @as(u32, 1), .ok = false, .data = @as(?u8, null), .@"error" = failure });
    return 1;
}

test "agent IPC class validation prevents fallback and path traversal" {
    try std.testing.expect(validateClass("com.example.agent-1"));
    try std.testing.expect(!validateClass("agent"));
    try std.testing.expect(!validateClass("com..agent"));
    try std.testing.expect(!validateClass("com.1agent"));
    try std.testing.expect(!validateClass("../../agent"));
    try std.testing.expect(!validateClass("com.example/agent"));
}

test "agent IPC socket path limit returns actionable diagnostics" {
    try std.testing.expect(validateSocketPath("/tmp/short.sock") == null);
    const path = [_]u8{'x'} ** 256;
    try std.testing.expectEqualStrings("PathTooLong", validateSocketPath(&path).?.code);
}

test "agent IPC surface selection prefers focus then active tab" {
    const Surface = socket.Response.Surface;
    const windows = [_]socket.Response.Window{.{ .id = "w", .tabs = &.{
        .{ .id = "a", .surfaces = &.{Surface{ .id = "first", .rows = 24, .cols = 80 }} },
        .{ .id = "b", .active = true, .surfaces = &.{Surface{ .id = "active", .rows = 24, .cols = 80 }} },
        .{ .id = "c", .surfaces = &.{Surface{ .id = "focused", .focused = true, .rows = 24, .cols = 80 }} },
    } }};
    try std.testing.expectEqualStrings("focused", selectSurface(&windows).?);
    const active_windows = [_]socket.Response.Window{.{ .id = "w", .tabs = windows[0].tabs[0..2] }};
    try std.testing.expectEqualStrings("active", selectSurface(&active_windows).?);
    const first_windows = [_]socket.Response.Window{.{ .id = "w", .tabs = windows[0].tabs[0..1] }};
    try std.testing.expectEqualStrings("first", selectSurface(&first_windows).?);
    try std.testing.expect(selectSurface(&.{}) == null);
}

test "agent IPC surface readiness excludes unrealized terminals" {
    const windows = [_]socket.Response.Window{.{ .id = "w", .tabs = &.{.{ .id = "t", .surfaces = &.{
        .{ .id = "uninitialized", .focused = true },
        .{ .id = "height-only", .rows = 24 },
        .{ .id = "width-only", .cols = 80 },
        .{ .id = "ready", .rows = 24, .cols = 80 },
    } }} }};
    try std.testing.expectEqualStrings("ready", selectSurface(&windows).?);
    const uninitialized = [_]socket.Response.Window{.{ .id = "w", .tabs = &.{.{ .id = "t", .surfaces = windows[0].tabs[0].surfaces[0..3] }} }};
    try std.testing.expect(selectSurface(&uninitialized) == null);
}

test "agent IPC remote errors preserve message with stable code" {
    const found = probeResponse(.{ .ok = false, .@"error" = "Failed to read request" });
    try std.testing.expectEqualStrings("RemoteRejected", found.@"error".?);
    try std.testing.expectEqualStrings("Failed to read request", found.message.?);
    try std.testing.expect(!validLauncher("relative/launcher"));
    try std.testing.expect(!validLauncher("/path/to/nonexistent/launcher"));
    try std.testing.expect(!validLauncher("/tmp"));
}

test "agent IPC launcher accepts an absolute executable" {
    const path = try std.fs.selfExePathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(validLauncher(path));
}
