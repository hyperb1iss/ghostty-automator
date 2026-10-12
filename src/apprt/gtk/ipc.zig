//! IPC handler implementations for GTK.
//!
//! This module provides the handler methods required by the IPC server.
//! These handlers are called from the socket server to perform actions
//! like listing surfaces, sending text, taking screenshots, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gobject = @import("gobject");
const adw = @import("adw");

const apprt = @import("../structs.zig");
const input = @import("../../input.zig");
const ipc = @import("../ipc/mod.zig");
const socket = @import("../socket.zig");
const Response = socket.Response;
const CoreSurface = @import("../../Surface.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;
const surface_registry = @import("ipc/surface_registry.zig");

const log = std.log.scoped(.gtk_ipc);

/// List all surfaces in the application.
pub fn listSurfaces(app: *Application, alloc: Allocator) Response {
    _ = app;

    var windows: std.ArrayListUnmanaged(Response.Window) = .empty;

    // Iterate over all top-level windows
    const window_list = gtk.Window.listToplevels();
    defer window_list.free();

    var node: ?*glib.List = @ptrCast(window_list);
    while (node) |n| : (node = n.f_next) {
        const data = n.f_data orelse continue;
        const widget: *gtk.Widget = @ptrCast(@alignCast(data));

        // Only process our Window type
        if (!gobject.ext.isA(widget, Window)) continue;
        const window: *Window = @ptrCast(widget);

        const window_id = formatObjectId(alloc, window) catch continue;
        const is_focused = window.as(gtk.Window).isActive() != 0;

        var tabs: std.ArrayListUnmanaged(Response.Tab) = .empty;
        collectTabs(window, &tabs, alloc) catch continue;

        windows.append(alloc, .{
            .id = window_id,
            .focused = is_focused,
            .tabs = tabs.toOwnedSlice(alloc) catch &.{},
        }) catch continue;
    }

    return ipc.successData(.{
        .windows = windows.toOwnedSlice(alloc) catch &.{},
    });
}

/// Send text to a surface.
pub fn sendText(app: *Application, surface_id: []const u8, text: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Get the core surface and write to it
    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Use writeRaw to bypass bracketed paste mode
    core.writeRaw(text) catch {
        return ipc.err("Failed to write to surface");
    };

    return ipc.success();
}

/// Send a mouse event to a surface.
pub fn sendMouse(
    app: *Application,
    surface_id: []const u8,
    x: f64,
    y: f64,
    button_str: ?[]const u8,
    action_str: ?[]const u8,
    mods_str: ?[]const u8,
) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Parse modifiers
    const mods = parseMods(mods_str);

    // Create cursor position
    const pos: apprt.CursorPos = .{
        .x = @floatCast(x),
        .y = @floatCast(y),
    };

    // If no button specified, this is a motion event
    if (button_str == null) {
        core.cursorPosCallback(pos, mods) catch {
            return ipc.err("Failed to process mouse motion");
        };
        return ipc.success();
    }

    // Parse button
    const button = parseMouseButton(button_str.?) orelse {
        return ipc.err("Invalid mouse button");
    };

    // Parse action (default to press if not specified)
    const action: input.MouseButtonState = if (action_str) |a| blk: {
        if (std.mem.eql(u8, a, "press")) break :blk .press;
        if (std.mem.eql(u8, a, "release")) break :blk .release;
        return ipc.err("Invalid button action (use 'press' or 'release')");
    } else .press;

    // Update cursor position first (mouse events need position context)
    core.cursorPosCallback(pos, mods) catch {
        return ipc.err("Failed to update cursor position");
    };

    // Send button event
    _ = core.mouseButtonCallback(action, button, mods) catch {
        return ipc.err("Failed to process mouse button");
    };

    return ipc.success();
}

/// Get screen content from a surface.
pub fn getScreen(app: *Application, alloc: Allocator, surface_id: []const u8, screen_type: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Get screen content using core API
    const content = core.getScreenContent(alloc, screen_type) catch {
        return ipc.err("Failed to get screen content");
    };

    // Get cursor position
    const cursor_pos = core.getCursorPosition();

    return ipc.successData(.{
        .content = content,
        .cursor_x = cursor_pos.x,
        .cursor_y = cursor_pos.y,
    });
}

/// Focus a surface (bring its window to front).
pub fn focusSurface(app: *Application, surface_id: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Get the window containing this surface
    const root = surface.as(gtk.Widget).getRoot() orelse {
        return ipc.err("Surface has no window");
    };

    // Present the window (brings to front)
    if (gobject.ext.cast(gtk.Window, root)) |gtk_window| {
        gtk_window.present();
    }

    // Focus the specific surface within the window
    _ = surface.as(gtk.Widget).grabFocus();

    return ipc.success();
}

/// Close a surface.
pub fn closeSurface(app: *Application, surface_id: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Request close through the surface's close method
    surface.close();

    return ipc.success();
}

/// Resize a surface's window.
pub fn resizeSurface(app: *Application, surface_id: []const u8, rows: u32, cols: u32) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Get current grid size if needed
    const current_grid = core.size.grid();
    const new_rows = if (rows > 0) rows else current_grid.rows;
    const new_cols = if (cols > 0) cols else current_grid.columns;

    if (core.size.cell.width == 0 or core.size.cell.height == 0) {
        return ipc.err("Invalid cell size");
    }

    // Get the window and resize it
    const root = surface.as(gtk.Widget).getRoot() orelse {
        return ipc.err("Surface has no window");
    };

    if (gobject.ext.cast(gtk.Window, root)) |gtk_window| {
        const widget = gtk_window.as(gtk.Widget);
        const scale: u64 = @intCast(@max(1, widget.getScaleFactor()));
        // GL viewport and cell metrics use physical pixels; GTK window sizes
        // use logical pixels. Keep the measured chrome outside the viewport.
        const width_px = @as(u64, new_cols) * core.size.cell.width +
            core.size.padding.left + core.size.padding.right;
        const height_px = @as(u64, new_rows) * core.size.cell.height +
            core.size.padding.top + core.size.padding.bottom;
        const chrome_width = @as(i64, widget.getAllocatedWidth()) -
            @as(i64, @intCast(std.math.divCeil(u64, core.size.screen.width, scale) catch unreachable));
        const chrome_height = @as(i64, widget.getAllocatedHeight()) -
            @as(i64, @intCast(std.math.divCeil(u64, core.size.screen.height, scale) catch unreachable));
        const new_width = std.math.cast(c_int, @as(i64, @intCast(std.math.divCeil(u64, width_px, scale) catch unreachable)) + chrome_width) orelse
            return ipc.err("Requested width is too large");
        const new_height = std.math.cast(c_int, @as(i64, @intCast(std.math.divCeil(u64, height_px, scale) catch unreachable)) + chrome_height) orelse
            return ipc.err("Requested height is too large");
        gtk_window.setDefaultSize(new_width, new_height);
    } else {
        return ipc.err("Surface has no resizable window");
    }

    return ipc.success();
}

/// Take a screenshot of a surface.
/// Captures the last rendered GL frame and saves it as a PNG file.
pub fn screenshotSurface(app: *Application, alloc: Allocator, surface_id: []const u8, output_path: []const u8) Response {
    _ = app;

    // Validate path — require absolute path, reject traversal components
    if (output_path.len == 0 or output_path[0] != '/') {
        return ipc.err("Output path must be absolute");
    }
    // Reject path components that are ".." to prevent directory traversal.
    // We check for the component rather than substring to allow filenames
    // like "report..2024.png".
    {
        var path_iter = std.mem.tokenizeScalar(u8, output_path, '/');
        while (path_iter.next()) |component| {
            if (std.mem.eql(u8, component, "..")) {
                return ipc.err("Path traversal not allowed");
            }
        }
    }

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    writeScreenshotAtomically(alloc, surface, output_path) catch |err| {
        log.warn("screenshot failed path={s} err={}", .{ output_path, err });
        return ipc.err("Failed to capture screenshot");
    };

    return ipc.success();
}

/// Create a new window.
pub fn newWindow(app: *Application, arguments: ?[]const []const u8) Response {
    if (!app.ipcNewWindow(arguments)) return ipc.err("Failed to create new window");
    return ipc.success();
}

/// Create a new tab.
pub fn newTab(app: *Application, arguments: ?[]const []const u8) Response {
    if (!app.ipcNewTab(arguments)) return ipc.err("Failed to create new tab");
    return ipc.success();
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Format an object pointer as a hex ID string.
fn formatObjectId(alloc: Allocator, obj: anytype) ![]const u8 {
    const ptr_int = @intFromPtr(obj);
    return try std.fmt.allocPrint(alloc, "0x{x}", .{ptr_int});
}

/// Parse a hex ID string back to a pointer value.
fn parseObjectId(id: []const u8) ?usize {
    if (id.len < 3 or !std.mem.startsWith(u8, id, "0x")) {
        return null;
    }
    return std.fmt.parseInt(usize, id[2..], 16) catch null;
}

/// Find a surface by its hex ID.
fn findSurfaceById(surface_id: []const u8) ?*Surface {
    const target_ptr = parseObjectId(surface_id) orelse return null;

    if (surface_registry.get(target_ptr)) |surface| {
        return @ptrCast(@alignCast(surface));
    }

    // Iterate all windows to find the surface
    const window_list = gtk.Window.listToplevels();
    defer window_list.free();

    var node: ?*glib.List = @ptrCast(window_list);
    while (node) |n| : (node = n.f_next) {
        const data = n.f_data orelse continue;
        const widget: *gtk.Widget = @ptrCast(@alignCast(data));
        if (!gobject.ext.isA(widget, Window)) continue;
        const window: *Window = @ptrCast(widget);

        // Check surfaces in this window's tabs
        if (findSurfaceInWindow(window, target_ptr)) |surface| {
            surface_registry.register(surface) catch |err| {
                log.debug("surface registry update failed err={}", .{err});
            };
            return surface;
        }
    }

    return null;
}

fn writeScreenshotAtomically(alloc: Allocator, surface: *Surface, output_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(output_path) orelse "/";
    const base_name = std.fs.path.basename(output_path);
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    const temp_path = try uniqueScreenshotTempPath(alloc, dir_path, base_name);
    defer alloc.free(temp_path);

    const temp_name = std.fs.path.basename(temp_path);
    const temp_path_z = try alloc.dupeZ(u8, temp_path);
    defer alloc.free(temp_path_z);

    var cleanup_temp = true;
    defer if (cleanup_temp) dir.deleteFile(temp_name) catch {};

    if (!surface.screenshotToFile(temp_path_z)) return error.ScreenshotFailed;

    try dir.rename(temp_name, base_name);
    cleanup_temp = false;
}

fn uniqueScreenshotTempPath(alloc: Allocator, dir_path: []const u8, base_name: []const u8) ![]u8 {
    var attempt: u8 = 0;
    while (attempt < 32) : (attempt += 1) {
        const path = try std.fmt.allocPrint(
            alloc,
            "{s}/.{s}.ghostty-screenshot-{x}",
            .{ dir_path, base_name, std.crypto.random.int(u64) },
        );
        errdefer alloc.free(path);

        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return path,
            else => return err,
        };

        alloc.free(path);
    }

    return error.NoSpaceLeft;
}

/// Find a surface in a window by pointer value.
/// Iterates all tabs and their split trees to find non-active surfaces.
fn findSurfaceInWindow(window: *Window, target_ptr: usize) ?*Surface {
    const tab_view = window.getTabView();
    const n = tab_view.getNPages();
    if (n <= 0) return null;

    for (0..@intCast(n)) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;

        var it = tree.iterator();
        while (it.next()) |entry| {
            if (@intFromPtr(entry.view) == target_ptr) {
                return entry.view;
            }
        }
    }

    return null;
}

/// Collect tabs from a window, iterating all tabs and their split trees.
fn collectTabs(window: *Window, tabs: *std.ArrayListUnmanaged(Response.Tab), alloc: Allocator) !void {
    const tab_view = window.getTabView();
    const n = tab_view.getNPages();
    if (n <= 0) return;

    const window_id = try formatObjectId(alloc, window);
    const selected_page = tab_view.getSelectedPage();

    for (0..@intCast(n)) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;

        var surfaces: std.ArrayListUnmanaged(Response.Surface) = .empty;
        var tab_title: []const u8 = "";

        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            const surface_id = try formatObjectId(alloc, surface);
            const title: []const u8 = if (surface.getTitle()) |t| t else "";
            const pwd: []const u8 = if (surface.getPwd()) |p| p else "";

            var grid_rows: u32 = 0;
            var grid_cols: u32 = 0;
            if (surface.core()) |c| {
                const grid = c.size.grid();
                grid_rows = grid.rows;
                grid_cols = grid.columns;
            }

            try surfaces.append(alloc, .{
                .id = surface_id,
                .title = try alloc.dupe(u8, title),
                .focused = surface.getFocused(),
                .pwd = try alloc.dupe(u8, pwd),
                .rows = grid_rows,
                .cols = grid_cols,
            });

            // Use the first surface's title as the tab title
            if (tab_title.len == 0) tab_title = title;
        }

        if (surfaces.items.len > 0) {
            const is_active = if (selected_page) |sp| (sp == page) else (i == 0);
            try tabs.append(alloc, .{
                .id = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ window_id, i }),
                .title = try alloc.dupe(u8, tab_title),
                .active = is_active,
                .surfaces = try surfaces.toOwnedSlice(alloc),
            });
        }
    }
}

/// Parse a mouse button string to MouseButton enum.
fn parseMouseButton(button_str: []const u8) ?input.MouseButton {
    if (std.mem.eql(u8, button_str, "left")) return .left;
    if (std.mem.eql(u8, button_str, "right")) return .right;
    if (std.mem.eql(u8, button_str, "middle")) return .middle;
    if (std.mem.eql(u8, button_str, "four")) return .four;
    if (std.mem.eql(u8, button_str, "five")) return .five;
    if (std.mem.eql(u8, button_str, "six")) return .six;
    if (std.mem.eql(u8, button_str, "seven")) return .seven;
    if (std.mem.eql(u8, button_str, "eight")) return .eight;
    if (std.mem.eql(u8, button_str, "nine")) return .nine;
    if (std.mem.eql(u8, button_str, "ten")) return .ten;
    if (std.mem.eql(u8, button_str, "eleven")) return .eleven;
    return null;
}

/// Send a scroll event to a surface.
pub fn sendScroll(
    app: *Application,
    surface_id: []const u8,
    x: f64,
    y: f64,
    mods_str: ?[]const u8,
) Response {
    _ = app;
    if (mods_str != null) {
        log.debug("scroll mods provided but not yet supported; ignoring", .{});
    }

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Send discrete scroll event (non-precision)
    const scroll_mods: input.ScrollMods = .{
        .precision = false,
        .momentum = .none,
    };

    core.scrollCallback(x, y, scroll_mods) catch {
        return ipc.err("Failed to process scroll event");
    };

    return ipc.success();
}

/// Send a key event to a surface.
pub fn sendKey(
    app: *Application,
    surface_id: []const u8,
    key_str: []const u8,
    action_str: ?[]const u8,
    mods_str: ?[]const u8,
) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Parse key using W3C key code format
    const key = input.Key.fromW3C(key_str) orelse {
        return ipc.err("Invalid key name");
    };

    // Parse action (default to press)
    const action: input.Action = if (action_str) |a| blk: {
        if (std.mem.eql(u8, a, "press")) break :blk .press;
        if (std.mem.eql(u8, a, "release")) break :blk .release;
        if (std.mem.eql(u8, a, "repeat")) break :blk .repeat;
        return ipc.err("Invalid action (use 'press', 'release', or 'repeat')");
    } else .press;

    // Parse modifiers
    const mods = parseMods(mods_str);

    // Physical W3C codes need text as well as a key identity for legacy PTYs.
    // Use the standard US mapping, matching Key.codepoint(); text input with a
    // different keyboard layout can use send-text instead.
    const unshifted = key.codepoint() orelse 0;
    var text: [4]u8 = undefined;
    const codepoint: u21 = if (mods.shift) shiftedCodepoint(unshifted) else unshifted;
    const text_len = if (action != .release and codepoint >= 0x20)
        std.unicode.utf8Encode(codepoint, &text) catch 0
    else
        0;

    // Create key event
    const event: input.KeyEvent = .{
        .action = action,
        .key = key,
        .mods = mods,
        .consumed_mods = .{ .shift = mods.shift and text_len > 0 },
        .composing = false,
        .utf8 = text[0..text_len],
        .unshifted_codepoint = unshifted,
    };

    // Send key event
    _ = core.keyCallback(event) catch {
        return ipc.err("Failed to process key event");
    };

    return ipc.success();
}

fn shiftedCodepoint(codepoint: u21) u21 {
    return switch (codepoint) {
        'a'...'z' => codepoint - 'a' + 'A',
        '0'...'9' => ")!@#$%^&*("[codepoint - '0'],
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '`' => '~',
        '.' => '>',
        '/' => '?',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        else => codepoint,
    };
}

/// Parse modifier string to Mods struct.
fn parseMods(mods_str: ?[]const u8) input.Mods {
    var mods: input.Mods = .{};
    const str = mods_str orelse return mods;

    var iter = std.mem.tokenizeAny(u8, str, ", ");
    while (iter.next()) |mod| {
        const trimmed = std.mem.trim(u8, mod, " ");
        if (std.mem.eql(u8, trimmed, "shift")) mods.shift = true;
        if (std.mem.eql(u8, trimmed, "ctrl")) mods.ctrl = true;
        if (std.mem.eql(u8, trimmed, "alt")) mods.alt = true;
        if (std.mem.eql(u8, trimmed, "super")) mods.super = true;
    }
    return mods;
}
