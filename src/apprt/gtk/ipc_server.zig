//! GTK IPC server integration.
//!
//! Client I/O happens on worker threads so the GTK main loop only handles the
//! actual widget interactions via `glib.idleAdd`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const glib = @import("glib");

const socket_client = @import("../socket.zig");
const ipc_handlers = @import("ipc.zig");
const Application = @import("class/application.zig").Application;

const log = std.log.scoped(.gtk_ipc_server);

/// Maximum message size (16 MB for screenshots).
const max_message_size: usize = 16 * 1024 * 1024;

/// Track connection ownership so shutdown can cancel unfinished reads and
/// callbacks before waiting for workers after the GTK main loop has stopped.
const Client = struct {
    fd: posix.socket_t,
    next: ?*Client = null,
    dispatch: ?*ClientDispatch = null,
    phase: enum { reading, dispatching, writing } = .reading,
};

/// Context passed from client thread to main thread via glib.idleAdd.
const ClientDispatch = struct {
    server: *Server,
    client: *Client,
    request: socket_client.Request,
    arena: std.heap.ArenaAllocator,
    source_id: c_uint = 0,

    // Synchronization: thread waits for main thread to produce response.
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    response: ?socket_client.Response = null,
    done: bool = false,
};

/// GTK IPC Server using GLib's event loop.
pub const Server = struct {
    alloc: Allocator,
    socket_fd: posix.socket_t,
    socket_path: []u8,
    socket_inode: u64,
    socket_device: u64,
    owner_lock: std.fs.File,
    app: *Application,
    accept_thread: ?std.Thread = null,
    client_mutex: std.Thread.Mutex = .{},
    client_cond: std.Thread.Condition = .{},
    active_clients: usize = 0,
    clients: ?*Client = null,
    shutting_down: bool = false,

    /// Initialize and start the server.
    pub fn init(alloc: Allocator, app: *Application, instance: ?[]const u8) !*Server {
        const socket_path = try socket_client.getSocketPath(alloc, instance);
        errdefer alloc.free(socket_path);

        // Create socket directory
        const dir_path = std.fs.path.dirname(socket_path) orelse return error.InvalidPath;
        posix.mkdir(dir_path, 0o700) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        try socket_client.validateSocketDirectory(socket_path);
        // Only one application may own a pathname. Keep ownership separate
        // from bootstrap coordination so starting the server cannot deadlock.
        const lock_path = try std.fmt.allocPrintSentinel(alloc, "{s}.owner.lock", .{socket_path}, 0);
        defer alloc.free(lock_path);
        const owner_lock: std.fs.File = .{ .handle = try posix.openZ(lock_path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o600) };
        errdefer owner_lock.close();
        if (!try owner_lock.tryLock(.exclusive)) return error.SocketAlreadyInUse;
        errdefer owner_lock.unlock();
        // Older builds have no ownership lock. Never steal their live socket.
        const target: @import("../ipc.zig").Target = if (instance) |name|
            .{ .class = try alloc.dupeZ(u8, name) }
        else
            .detect;
        defer if (target == .class) alloc.free(target.class);
        if (socket_client.Client.initWithOptions(alloc, target, .{ .quiet = true, .timeout_ms = 100 })) |existing| {
            var live = existing;
            live.deinit();
            return error.SocketAlreadyInUse;
        } else |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused => try socket_client.removeSocketFile(socket_path),
            else => return err,
        }

        // Create socket
        const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(socket_fd);

        // Bind to path
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return error.PathTooLong;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        try posix.bind(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        const identity = try posix.fstatat(std.fs.cwd().fd, socket_path, posix.AT.SYMLINK_NOFOLLOW);
        errdefer socket_client.removeSocketFile(socket_path) catch {};

        // Set socket file permissions to 600
        const path_z = try alloc.dupeZ(u8, socket_path);
        defer alloc.free(path_z);
        if (std.c.chmod(path_z, 0o600) != 0) return error.SocketPermissionsFailed;

        // Listen for connections
        try posix.listen(socket_fd, std.c.SOMAXCONN);

        // Create the server struct
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .socket_fd = socket_fd,
            .socket_path = socket_path,
            .socket_inode = @intCast(identity.ino),
            .socket_device = @intCast(identity.dev),
            .owner_lock = owner_lock,
            .app = app,
        };

        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        log.info("IPC server listening on {s}", .{socket_path});
        return self;
    }

    /// Withdraw the listener and cancel callbacks before draining responses.
    /// Call on the GTK thread after its main loop stops.
    pub fn stop(self: *Server) void {
        self.client_mutex.lock();
        if (self.shutting_down) {
            self.client_mutex.unlock();
            return;
        }
        self.shutting_down = true;
        var next = self.clients;
        while (next) |client| {
            next = client.next;
            switch (client.phase) {
                .reading => posix.shutdown(client.fd, .both) catch {},
                .dispatching => {
                    // GTK callbacks cannot run after its main loop stops.
                    // Remove each queued source before its worker stack dies.
                    const dispatch = client.dispatch.?;
                    _ = glib.Source.remove(dispatch.source_id);
                    client.dispatch = null;
                    dispatch.mutex.lock();
                    dispatch.done = true;
                    dispatch.cond.signal();
                    dispatch.mutex.unlock();
                    posix.shutdown(client.fd, .both) catch {};
                },
                // Let completed requests (including the final close) send
                // their acknowledgement. Response I/O has its own deadline.
                .writing => {},
            }
        }
        self.client_mutex.unlock();

        // Remove our name while the listener is still live. A later owner or
        // replacement file must survive this application's shutdown.
        const identity = posix.fstatat(std.fs.cwd().fd, self.socket_path, posix.AT.SYMLINK_NOFOLLOW) catch null;
        if (identity) |stat| {
            if (stat.ino == self.socket_inode and stat.dev == self.socket_device and
                std.fs.File.Stat.fromPosix(stat).kind == .unix_domain_socket)
                socket_client.removeSocketFile(self.socket_path) catch {};
        }

        // Closing a descriptor from another thread does not wake accept on
        // Linux. Shutdown first releases the accept thread's blocked syscall.
        posix.shutdown(self.socket_fd, .both) catch {};

        if (self.accept_thread) |thread| {
            thread.join();
        }
        posix.close(self.socket_fd);
        self.owner_lock.unlock();
        self.owner_lock.close();
    }

    /// Stop the server, drain completed responses, and free its memory.
    pub fn deinit(self: *Server) void {
        self.stop();

        self.client_mutex.lock();
        while (self.active_clients > 0) {
            self.client_cond.wait(&self.client_mutex);
        }
        self.client_mutex.unlock();

        // Free memory
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);

        log.info("IPC server stopped", .{});
    }

    fn acceptLoop(self: *Server) void {
        while (true) {
            var client_addr: posix.sockaddr.un = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

            const client_fd = posix.accept(
                self.socket_fd,
                @ptrCast(&client_addr),
                &addr_len,
                posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            ) catch |e| {
                self.client_mutex.lock();
                const shutting_down = self.shutting_down;
                self.client_mutex.unlock();
                if (shutting_down) return;

                log.err("accept failed: {}", .{e});
                return;
            };

            const client = self.alloc.create(Client) catch |e| {
                log.err("failed to allocate client: {}", .{e});
                posix.close(client_fd);
                continue;
            };
            self.client_mutex.lock();
            if (self.shutting_down) {
                self.client_mutex.unlock();
                self.alloc.destroy(client);
                posix.close(client_fd);
                return;
            }
            client.* = .{ .fd = client_fd, .next = self.clients };
            self.clients = client;
            self.active_clients += 1;
            self.client_mutex.unlock();

            const thread = std.Thread.spawn(.{}, clientThread, .{ self, client }) catch |e| {
                log.err("failed to spawn client thread: {}", .{e});
                self.clientDone(client);
                continue;
            };
            thread.detach();
        }
    }

    /// Client thread: validates peer, reads request, dispatches to main thread,
    /// sends response. All blocking I/O happens here, not on the GTK main loop.
    fn clientThread(self: *Server, client: *Client) void {
        defer self.clientDone(client);
        const client_fd = client.fd;

        // Validate peer is same user
        if (!self.validatePeer(client_fd)) {
            log.warn("rejected connection from different user", .{});
            return;
        }

        // Read and parse request (blocking, but on this thread)
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const request = self.readRequest(client_fd, alloc) catch |e| {
            self.client_mutex.lock();
            const shutting_down = self.shutting_down;
            self.client_mutex.unlock();
            if (shutting_down) return;
            log.err("failed to read request: {}", .{e});
            self.sendReadError(client_fd, e);
            return;
        };

        // Dispatch handler to GTK main thread and wait for result.
        // IPC handlers access GTK widgets and must run on the main thread.
        var dispatch = ClientDispatch{
            .server = self,
            .client = client,
            .request = request,
            .arena = std.heap.ArenaAllocator.init(self.alloc),
        };
        defer dispatch.arena.deinit();

        self.client_mutex.lock();
        if (self.shutting_down) {
            self.client_mutex.unlock();
            return;
        }
        client.phase = .dispatching;
        client.dispatch = &dispatch;
        dispatch.source_id = glib.idleAdd(mainThreadDispatch, &dispatch);
        self.client_mutex.unlock();

        // Wait for main thread to produce the response
        dispatch.mutex.lock();
        defer dispatch.mutex.unlock();
        while (!dispatch.done) {
            dispatch.cond.wait(&dispatch.mutex);
        }

        // Send response (blocking write, on this thread)
        if (dispatch.response) |response| {
            self.sendResponse(client_fd, dispatch.arena.allocator(), response) catch |e| {
                log.err("failed to send response: {}", .{e});
            };
        }
    }

    /// GLib idle callback: runs on GTK main thread.
    /// Handles the request and signals the waiting client thread.
    fn mainThreadDispatch(user_data: ?*anyopaque) callconv(.c) c_int {
        const dispatch: *ClientDispatch = @ptrCast(@alignCast(user_data));
        const server = dispatch.server;
        server.client_mutex.lock();
        dispatch.client.dispatch = null;
        dispatch.client.phase = .writing;
        server.client_mutex.unlock();
        const alloc = dispatch.arena.allocator();

        const response = dispatch.server.handleRequest(alloc, dispatch.request);

        dispatch.mutex.lock();
        defer dispatch.mutex.unlock();
        dispatch.response = response;
        dispatch.done = true;
        dispatch.cond.signal();

        return 0; // Remove idle source (one-shot)
    }

    /// Handle a request by calling the appropriate handler.
    fn handleRequest(self: *Server, alloc: Allocator, request: socket_client.Request) socket_client.Response {
        return switch (request.action) {
            .list_surfaces => ipc_handlers.listSurfaces(self.app, alloc),
            .send_text => |p| ipc_handlers.sendText(self.app, p.surface_id, p.text),
            .get_screen => |p| ipc_handlers.getScreen(self.app, alloc, p.surface_id, p.screen),
            .focus_surface => |p| ipc_handlers.focusSurface(self.app, p.surface_id),
            .close_surface => |p| ipc_handlers.closeSurface(self.app, p.surface_id),
            .resize_surface => |p| ipc_handlers.resizeSurface(self.app, p.surface_id, p.rows, p.cols),
            .screenshot_surface => |p| ipc_handlers.screenshotSurface(self.app, alloc, p.surface_id, p.output_path),
            .new_window => |p| ipc_handlers.newWindow(self.app, if (p.arguments) |a| a else null),
            .new_tab => |p| ipc_handlers.newTab(self.app, if (p.arguments) |a| a else null),
            .send_mouse => |p| ipc_handlers.sendMouse(self.app, p.surface_id, p.x, p.y, p.button, p.button_action, p.mods),
            .send_scroll => |p| ipc_handlers.sendScroll(self.app, p.surface_id, p.x, p.y, p.mods),
            .send_key => |p| ipc_handlers.sendKey(self.app, p.surface_id, p.key, p.action, p.mods),
        };
    }

    fn validatePeer(self: *Server, client_fd: posix.socket_t) bool {
        _ = self;

        if (comptime builtin.os.tag == .linux) {
            var cred: extern struct {
                pid: i32,
                uid: u32,
                gid: u32,
            } = undefined;

            posix.getsockopt(
                client_fd,
                posix.SOL.SOCKET,
                posix.SO.PEERCRED,
                std.mem.asBytes(&cred),
            ) catch return false;

            return cred.uid == posix.getuid();
        } else if (comptime builtin.os.tag.isDarwin()) {
            // macOS: use getpeereid
            var uid: posix.uid_t = undefined;
            var gid: posix.gid_t = undefined;

            const rc = std.c.getpeereid(client_fd, &uid, &gid);
            if (rc != 0) return false;

            return uid == posix.getuid();
        }

        return true;
    }

    fn readRequest(self: *Server, client_fd: posix.socket_t, alloc: Allocator) !socket_client.Request {
        _ = self;

        // Read length prefix
        var deadline = try FrameIo.init(client_fd, std.time.ns_per_s);
        var len_bytes: [4]u8 = undefined;
        try deadline.readExact(&len_bytes);

        const msg_len = std.mem.readInt(u32, &len_bytes, .little);
        if (msg_len > max_message_size) {
            return error.MessageTooLarge;
        }

        // Read message
        const buf = try alloc.alloc(u8, msg_len);
        try deadline.readExact(buf);

        // Parse JSON
        const request = try std.json.parseFromSliceLeaky(
            socket_client.Request,
            alloc,
            buf,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        try socket_client.validateRequestVersion(request);
        return request;
    }

    fn sendResponse(self: *Server, client_fd: posix.socket_t, alloc: Allocator, response: socket_client.Response) !void {
        _ = self;

        const json = try std.json.Stringify.valueAlloc(alloc, response, .{});
        var deadline = try FrameIo.init(client_fd, 5 * std.time.ns_per_s);

        // Send length prefix
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(json.len), .little);

        try deadline.writeAll(&len_bytes);
        try deadline.writeAll(json);
    }

    fn sendError(self: *Server, client_fd: posix.socket_t, message: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        self.sendResponse(client_fd, arena.allocator(), .{
            .ok = false,
            .@"error" = message,
        }) catch {};
    }

    fn sendReadError(self: *Server, client_fd: posix.socket_t, err: anyerror) void {
        switch (err) {
            error.UnsupportedProtocolVersion => self.sendError(client_fd, "Unsupported protocol version"),
            else => self.sendError(client_fd, "Failed to read request"),
        }
    }

    fn clientDone(self: *Server, client: *Client) void {
        self.client_mutex.lock();
        var link = &self.clients;
        while (link.*) |entry| {
            if (entry == client) break;
            link = &entry.next;
        }
        std.debug.assert(link.* == client);
        link.* = client.next;
        // Closing while ownership is locked prevents shutdown from observing
        // a descriptor number that another thread has already reused.
        posix.close(client.fd);
        self.alloc.destroy(client);
        self.active_clients -= 1;
        if (self.shutting_down and self.active_clients == 0) {
            self.client_cond.signal();
        }
        self.client_mutex.unlock();
    }
};

/// A deadline covers the full frame, including a slow peer's partial I/O.
/// Socket timeouts alone restart with each recv and do not bound a frame.
const FrameIo = struct {
    fd: posix.socket_t,
    timer: std.time.Timer,
    timeout_ns: u64,

    fn init(fd: posix.socket_t, timeout_ns: u64) !FrameIo {
        return .{ .fd = fd, .timer = try std.time.Timer.start(), .timeout_ns = timeout_ns };
    }

    fn wait(self: *FrameIo, events: i16) !void {
        const elapsed = self.timer.read();
        if (elapsed >= self.timeout_ns) return error.FrameTimedOut;
        const remaining_ms = std.math.divCeil(u64, self.timeout_ns - elapsed, std.time.ns_per_ms) catch unreachable;
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(@min(remaining_ms, std.math.maxInt(i32)))) == 0)
            return error.FrameTimedOut;
    }

    fn readExact(self: *FrameIo, buf: []u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            try self.wait(posix.POLL.IN);
            const n = posix.recv(self.fd, buf[off..], 0) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    fn writeAll(self: *FrameIo, buf: []const u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            try self.wait(posix.POLL.OUT);
            const n = posix.send(self.fd, buf[off..], posix.MSG.NOSIGNAL) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }
};

test "GTK IPC partial frames expire while healthy frames still complete" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0, &fds) != 0)
        return error.SocketPairCreationFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    _ = try posix.send(fds[1], "\x01\x00", posix.MSG.NOSIGNAL);
    var stalled = try FrameIo.init(fds[0], 20 * std.time.ns_per_ms);
    var prefix: [4]u8 = undefined;
    try std.testing.expectError(error.FrameTimedOut, stalled.readExact(&prefix));

    _ = try posix.send(fds[1], "ok", posix.MSG.NOSIGNAL);
    var healthy = try FrameIo.init(fds[0], 100 * std.time.ns_per_ms);
    var message: [2]u8 = undefined;
    try healthy.readExact(&message);
    try std.testing.expectEqualStrings("ok", &message);

    try posix.shutdown(fds[1], .both);
    var closed = try FrameIo.init(fds[0], 100 * std.time.ns_per_ms);
    try std.testing.expectError(error.ConnectionClosed, closed.readExact(&prefix));
}
