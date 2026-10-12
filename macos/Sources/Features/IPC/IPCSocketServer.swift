import AppKit
import Foundation
import OSLog
import GhosttyKit

private final class IPCWeakSurfaceRef {
    weak var surface: Ghostty.SurfaceView?

    init(_ surface: Ghostty.SurfaceView) {
        self.surface = surface
    }
}

enum IPCSurfaceRegistry {
    private static let lock = NSLock()
    private static var surfaces: [String: IPCWeakSurfaceRef] = [:]

    static func identifier(for surface: Ghostty.SurfaceView) -> String {
        String(format: "0x%lx", UInt(bitPattern: ObjectIdentifier(surface)))
    }

    static func register(_ surface: Ghostty.SurfaceView) {
        lock.lock()
        defer { lock.unlock() }
        surfaces[identifier(for: surface)] = IPCWeakSurfaceRef(surface)
    }

    static func unregister(_ surface: Ghostty.SurfaceView) {
        lock.lock()
        defer { lock.unlock() }
        surfaces.removeValue(forKey: identifier(for: surface))
    }

    static func surface(for identifier: String) -> Ghostty.SurfaceView? {
        lock.lock()
        defer { lock.unlock() }

        guard let ref = surfaces[identifier] else { return nil }
        guard let surface = ref.surface else {
            surfaces.removeValue(forKey: identifier)
            return nil
        }

        return surface
    }
}

private extension String {
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Unix socket server for IPC communication.
///
/// This provides remote control capabilities matching the protocol in `src/apprt/socket.zig`.
/// Clients can send JSON requests to create windows, tabs, etc.
class IPCSocketServer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "IPCSocketServer"
    )

    /// The socket file descriptor
    private var socketFD: Int32 = -1

    /// The path to the socket file
    private var socketPath: String = ""

    /// Whether the server is running
    private(set) var isRunning = false

    /// The dispatch source for accepting connections
    private var acceptSource: DispatchSourceRead?

    /// Reference to the app delegate for accessing ghostty
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    deinit {
        stop()
    }

    /// Start the socket server.
    func start() {
        guard !isRunning else { return }

        do {
            socketPath = try getSocketPath()
            try createSocketDirectory()
            try createSocket()
            isRunning = true
            logger.info("IPC socket server started at \(self.socketPath)")
        } catch {
            logger.error("Failed to start IPC socket server: \(error.localizedDescription)")
        }
    }

    /// Stop the socket server.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        if !socketPath.isEmpty {
            do {
                try removeSocketFileIfPresent(socketPath)
            } catch {
                logger.error("Failed to remove IPC socket path \(self.socketPath): \(error.localizedDescription)")
            }
            socketPath = ""
        }

        isRunning = false
    }

    // MARK: - Socket Path

    /// Get the socket path matching the Zig implementation.
    private func getSocketPath() throws -> String {
        let uid = getuid()

        // Use the OS user directory so agents with a different TMPDIR can
        // discover an already-running app launched by LaunchServices.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { throw IPCError.fileSystem("User temporary directory unavailable") }
        var buffer = [CChar](repeating: 0, count: length)
        let result = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard result > 0, result <= buffer.count else {
            throw IPCError.fileSystem("User temporary directory unavailable")
        }
        let tmpdir = String(cString: buffer)
        let dir = (tmpdir as NSString).appendingPathComponent("ghostty-automator-\(uid)")
        return (dir as NSString).appendingPathComponent("ghostty-automator.sock")
    }

    /// Create the socket directory if it doesn't exist.
    private func createSocketDirectory() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard dir.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw IPCError.fileSystem("Unsafe socket directory")
        }
    }

    // MARK: - Socket Creation

    private func createSocket() throws {
        try removeSocketFileIfPresent(socketPath)

        // Create the socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCError.socketCreationFailed(errno)
        }

        setNoSigPipe(socketFD)

        // Bind to the path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            throw IPCError.bindFailed(errno)
        }

        // Set permissions on socket file
        chmod(socketPath, 0o600)

        // Listen for connections
        guard listen(socketFD, 5) == 0 else {
            throw IPCError.listenFailed(errno)
        }

        // Set non-blocking
        let flags = fcntl(socketFD, F_GETFL)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        // Create dispatch source for accepting connections
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
                self?.socketFD = -1
            }
        }
        acceptSource?.resume()
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            if errno != EWOULDBLOCK && errno != EAGAIN {
                logger.error("Failed to accept connection: \(errno)")
            }
            return
        }

        // Handle the connection in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleClient(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }

        setNoSigPipe(clientFD)

        // Ensure client socket is in blocking mode (it should be, but be explicit)
        let flags = fcntl(clientFD, F_GETFL)
        if flags != -1 && (flags & O_NONBLOCK) != 0 {
            _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
        }

        // Set read/write timeout to prevent indefinite blocking
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard validatePeerIsSameUser(clientFD) else { return }

        do {
            // Read length prefix (4 bytes, little-endian u32)
            let lengthBytes = try readExact(clientFD, count: 4)
            let messageLength = UInt32(lengthBytes[0]) |
                (UInt32(lengthBytes[1]) << 8) |
                (UInt32(lengthBytes[2]) << 16) |
                (UInt32(lengthBytes[3]) << 24)

            guard messageLength <= 16 * 1024 * 1024 else {
                try sendResponseOrThrow(clientFD, response: IPCResponse(ok: false, error: "Request too large"))
                return
            }

            // Read the JSON message
            let messageData = Data(try readExact(clientFD, count: Int(messageLength)))

            // Parse and handle the request
            let response = try handleRequest(data: messageData)
            try sendResponseOrThrow(clientFD, response: response)
        } catch {
            logger.error("IPC socket request failed: \(error.localizedDescription)")
            sendErrorResponse(clientFD, message: "IPC error: \(error.localizedDescription)")
        }
    }

    private func handleRequest(data: Data) throws -> IPCResponse {
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)

            guard request.version == 1 else {
                return IPCResponse(ok: false, error: "Unsupported protocol version")
            }

            switch request.action {
            case .new_window(let payload):
                return handleNewWindow(payload: payload)
            case .new_tab(let payload):
                return handleNewTab(payload: payload)
            case .list_surfaces:
                return handleListSurfaces()
            case .send_text(let payload):
                return handleSendText(payload: payload)
            case .get_screen(let payload):
                return handleGetScreen(payload: payload)
            case .focus_surface(let payload):
                return handleFocusSurface(payload: payload)
            case .close_surface(let payload):
                return handleCloseSurface(payload: payload)
            case .resize_surface(let payload):
                return handleResizeSurface(payload: payload)
            case .screenshot_surface(let payload):
                return handleScreenshotSurface(payload: payload)
            case .send_mouse(let payload):
                return handleSendMouse(payload: payload)
            case .send_scroll(let payload):
                return handleSendScroll(payload: payload)
            case .send_key(let payload):
                return handleSendKey(payload: payload)
            }
        } catch {
            logger.error("Failed to parse IPC request: \(error.localizedDescription)")
            return IPCResponse(ok: false, error: "Invalid request: \(error.localizedDescription)")
        }
    }

    // MARK: - Action Handlers

    private func handleNewWindow(payload: IPCRequest.NewWindowPayload?) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self = self,
                  let appDelegate = self.appDelegate else {
                throw IPCError.appUnavailable
            }

            let launchOptions = try self.parseNewWindowLaunchOptions(payload?.arguments)
            let controller = TerminalController.newWindow(
                appDelegate.ghostty,
                withBaseConfig: launchOptions.config
            )
            controller.titleOverride = launchOptions.titleOverride
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleNewTab(payload: IPCRequest.NewTabPayload?) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self = self,
                  let appDelegate = self.appDelegate else {
                throw IPCError.appUnavailable
            }

            let config = try self.makeExecLaunchConfig(arguments: payload?.arguments)

            // Get the preferred parent window for the new tab
            let parentWindow = TerminalController.preferredParent?.window

            _ = TerminalController.newTab(
                appDelegate.ghostty,
                from: parentWindow,
                withBaseConfig: config
            )
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleListSurfaces() -> IPCResponse {
        let result: Result<[IPCResponse.WindowInfo], IPCError> = performOnMain { [weak self] in
            guard let self = self else { throw IPCError.appUnavailable }

            var windows: [IPCResponse.WindowInfo] = []
            var processedWindows = Set<ObjectIdentifier>()

            // Iterate over all terminal windows
            for window in NSApp.windows {
                // Skip windows we've already processed (via tab groups)
                guard !processedWindows.contains(ObjectIdentifier(window)) else {
                    continue
                }

                guard let controller = window.windowController as? TerminalController else {
                    continue
                }

                let windowId = String(format: "0x%lx", UInt(bitPattern: ObjectIdentifier(window)))
                let isFocused = window.isKeyWindow

                var tabs: [IPCResponse.TabInfo] = []

                // Get tabs from the window's tab group
                if let tabGroup = window.tabGroup {
                    // Mark all windows in this tab group as processed
                    for tabWindow in tabGroup.windows {
                        processedWindows.insert(ObjectIdentifier(tabWindow))
                    }

                    for (tabIndex, tabWindow) in tabGroup.windows.enumerated() {
                        guard let tabController = tabWindow.windowController as? TerminalController else {
                            continue
                        }

                        let tabId = "\(windowId):\(tabIndex)"
                        let isActive = tabWindow == window

                        var surfaces: [IPCResponse.SurfaceInfo] = []

                        // Get surfaces from the tab
                        collectSurfaces(from: tabController.surfaceTree, into: &surfaces)

                        tabs.append(IPCResponse.TabInfo(
                            id: tabId,
                            title: tabWindow.title,
                            active: isActive,
                            surfaces: surfaces
                        ))
                    }
                } else {
                    // Single-tab window
                    processedWindows.insert(ObjectIdentifier(window))
                    let tabId = "\(windowId):0"
                    var surfaces: [IPCResponse.SurfaceInfo] = []

                    collectSurfaces(from: controller.surfaceTree, into: &surfaces)

                    tabs.append(IPCResponse.TabInfo(
                        id: tabId,
                        title: window.title,
                        active: true,
                        surfaces: surfaces
                    ))
                }

                windows.append(IPCResponse.WindowInfo(
                    id: windowId,
                    focused: isFocused,
                    tabs: tabs
                ))
            }

            return windows
        }

        switch result {
        case .success(let windows):
            return IPCResponse(ok: true, data: IPCResponse.ResponseData(windows: windows))
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleSendText(payload: IPCRequest.SendTextPayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            // Send the text to the surface
            guard let surfaceModel = surface.surfaceModel else {
                throw IPCError.surfaceNotFound
            }

            // writeRaw bypasses bracketed paste mode for exact control over PTY input.
            // Use \r to execute commands.
            MainActor.assumeIsolated {
                surfaceModel.writeRaw(payload.text)
            }
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleGetScreen(payload: IPCRequest.GetScreenPayload) -> IPCResponse {
        let result: Result<IPCResponse.ResponseData, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            guard let surfaceC = surface.surface else {
                throw IPCError.surfaceNotFound
            }

            let screenType = payload.screen ?? "viewport"
            let format = payload.format ?? "text"

            if format == "cells" {
                // Get structured cell data as JSON
                let cellsJson: String = MainActor.assumeIsolated {
                    let result = ghostty_surface_get_screen_cells(
                        surfaceC,
                        screenType,
                        UInt(screenType.utf8.count)
                    )

                    if let ptr = result.ptr {
                        let str = String(cString: ptr)
                        ghostty_string_free(result)
                        return str
                    }
                    return "{}"
                }

                // Return the cells JSON as content - the cells format includes cursor and size
                return IPCResponse.ResponseData(
                    content: cellsJson,
                    cursor_x: nil,
                    cursor_y: nil
                )
            } else {
                // Get screen content using the C API (text format)
                let content: String = MainActor.assumeIsolated {
                    let result = ghostty_surface_get_screen_content(
                        surfaceC,
                        screenType,
                        UInt(screenType.utf8.count)
                    )

                    // Convert ghostty_string_s to Swift String
                    if let ptr = result.ptr {
                        let str = String(cString: ptr)
                        // Free the string (it was allocated by Zig)
                        ghostty_string_free(result)
                        return str
                    }
                    return ""
                }

                // Get cursor position
                let cursorPos: UInt32 = MainActor.assumeIsolated {
                    ghostty_surface_get_cursor_position(surfaceC)
                }
                let cursorX = (cursorPos >> 16) & 0xFFFF
                let cursorY = cursorPos & 0xFFFF

                return IPCResponse.ResponseData(
                    content: content,
                    cursor_x: cursorX,
                    cursor_y: cursorY
                )
            }
        }

        switch result {
        case .success(let data):
            return IPCResponse(ok: true, data: data)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleFocusSurface(payload: IPCRequest.FocusSurfacePayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            // Find the window containing this surface and bring it to front
            if let window = surface.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)

                // Focus the specific surface within the window
                if let controller = window.windowController as? TerminalController {
                    controller.focusSurface(surface)
                }
            }
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleCloseSurface(payload: IPCRequest.CloseSurfacePayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            // Find the controller for this surface and close it without confirmation
            guard let window = surface.window,
                  let controller = window.windowController as? BaseTerminalController else {
                throw IPCError.surfaceNotFound
            }

            controller.closeSurface(surface, withConfirmation: false)
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleResizeSurface(payload: IPCRequest.ResizeSurfacePayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            guard let window = surface.window else {
                throw IPCError.surfaceNotFound
            }

            // Get the cell size to calculate the new window size
            let cellSize = surface.cellSize
            guard cellSize.width > 0 && cellSize.height > 0 else {
                throw IPCError.invalidArguments
            }

            // Get current size if we're only changing one dimension
            let currentSize = surface.surfaceSize
            let rows = payload.rows > 0 ? payload.rows : UInt32(currentSize?.rows ?? 24)
            let cols = payload.cols > 0 ? payload.cols : UInt32(currentSize?.columns ?? 80)

            // Calculate the new content size
            let newWidth = CGFloat(cols) * cellSize.width
            let newHeight = CGFloat(rows) * cellSize.height

            // Set the window's content size
            window.setContentSize(NSSize(width: newWidth, height: newHeight))
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleScreenshotSurface(payload: IPCRequest.ScreenshotSurfacePayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Validate output path — require absolute, reject ".." components
            let outputPath = payload.output_path
            guard outputPath.hasPrefix("/") else {
                throw IPCError.invalidArguments
            }
            let hasTraversal = outputPath.split(separator: "/").contains { $0 == ".." }
            guard !hasTraversal else {
                throw IPCError.invalidArguments
            }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            // Capture the surface view as an image
            let bounds = surface.bounds
            guard let bitmapRep = surface.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw IPCError.screenshotFailed
            }

            surface.cacheDisplay(in: bounds, to: bitmapRep)

            // Convert to PNG data
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                throw IPCError.screenshotFailed
            }

            // Write to file - use standardized URL to resolve any remaining path issues
            let url = URL(fileURLWithPath: outputPath).standardized
            try pngData.write(to: url, options: [.atomic])
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleSendMouse(payload: IPCRequest.SendMousePayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            guard let surfaceModel = surface.surfaceModel else {
                throw IPCError.surfaceNotFound
            }

            // Parse modifiers
            var mods: Ghostty.Input.Mods = []
            if let modsStr = payload.mods {
                for mod in modsStr.lowercased().split(separator: ",") {
                    switch mod.trimmingCharacters(in: .whitespaces) {
                    case "shift": mods.insert(.shift)
                    case "ctrl", "control": mods.insert(.ctrl)
                    case "alt", "option": mods.insert(.alt)
                    case "super", "cmd", "command": mods.insert(.super)
                    default: break
                    }
                }
            }

            // Send mouse position first
            let posEvent = Ghostty.Input.MousePosEvent(
                x: payload.x,
                y: payload.y,
                mods: mods
            )
            MainActor.assumeIsolated {
                surfaceModel.sendMousePos(posEvent)
            }

            // If button is specified, send button event
            if let buttonStr = payload.button, let actionStr = payload.button_action {
                let button = try self.parseMouseButton(buttonStr)

                // Parse action
                let action: Ghostty.Input.MouseState
                switch actionStr.lowercased() {
                case "press": action = .press
                case "release": action = .release
                default: throw IPCError.invalidArguments
                }

                let buttonEvent = Ghostty.Input.MouseButtonEvent(
                    action: action,
                    button: button,
                    mods: mods
                )
                MainActor.assumeIsolated {
                    surfaceModel.sendMouseButton(buttonEvent)
                }
            }
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleSendScroll(payload: IPCRequest.SendScrollPayload) -> IPCResponse {
        if payload.mods != nil {
            logger.debug("scroll mods provided but not yet supported; ignoring")
        }
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            guard let surfaceModel = surface.surfaceModel else {
                throw IPCError.surfaceNotFound
            }

            // Send scroll event (no precision/momentum for IPC-triggered scrolls)
            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: payload.x,
                y: payload.y,
                mods: .init(rawValue: 0)
            )
            MainActor.assumeIsolated {
                surfaceModel.sendMouseScroll(scrollEvent)
            }
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    private func handleSendKey(payload: IPCRequest.SendKeyPayload) -> IPCResponse {
        let result: Result<Void, IPCError> = performOnMain { [weak self] in
            guard let self else { throw IPCError.appUnavailable }

            // Find the surface by ID
            guard let surface = self.findSurface(byId: payload.surface_id) else {
                throw IPCError.surfaceNotFound
            }

            guard let surfaceC = surface.surface else {
                throw IPCError.surfaceNotFound
            }

            // Parse action (default to press)
            let actionStr = payload.action ?? "press"
            let action: ghostty_input_action_e
            switch actionStr.lowercased() {
            case "press": action = GHOSTTY_ACTION_PRESS
            case "release": action = GHOSTTY_ACTION_RELEASE
            case "repeat": action = GHOSTTY_ACTION_REPEAT
            default: throw IPCError.invalidArguments
            }

            // Parse modifiers
            var mods = GHOSTTY_MODS_NONE
            if let modsStr = payload.mods {
                for mod in modsStr.lowercased().split(separator: ",") {
                    switch mod.trimmingCharacters(in: .whitespaces) {
                    case "shift": mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
                    case "ctrl", "control": mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                    case "alt", "option": mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue)
                    case "super", "cmd", "command": mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue)
                    default: break
                    }
                }
            }

            // Use the Zig key parsing to convert W3C key name
            var keySuccess = false
            MainActor.assumeIsolated {
                payload.key.withCString { keyPtr in
                    keySuccess = ghostty_surface_send_key_from_string(
                        surfaceC,
                        action,
                        mods,
                        keyPtr
                    )
                }
            }
            guard keySuccess else {
                throw IPCError.invalidArguments
            }
        }

        switch result {
        case .success:
            return IPCResponse(ok: true)
        case .failure(let err):
            return IPCResponse(ok: false, error: err.localizedDescription)
        }
    }

    /// Find a surface by its hex ID (e.g., "0x153872000")
    private func findSurface(byId surfaceId: String) -> Ghostty.SurfaceView? {
        if let surface = IPCSurfaceRegistry.surface(for: surfaceId) {
            return surface
        }

        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController else {
                continue
            }

            // Check surfaces in this window's tree
            for surface in controller.surfaceTree {
                let id = IPCSurfaceRegistry.identifier(for: surface)
                if id == surfaceId {
                    IPCSurfaceRegistry.register(surface)
                    return surface
                }
            }

            // Also check tab group windows
            if let tabGroup = window.tabGroup {
                for tabWindow in tabGroup.windows {
                    guard let tabController = tabWindow.windowController as? TerminalController else {
                        continue
                    }
                    for surface in tabController.surfaceTree {
                        let id = IPCSurfaceRegistry.identifier(for: surface)
                        if id == surfaceId {
                            IPCSurfaceRegistry.register(surface)
                            return surface
                        }
                    }
                }
            }
        }
        return nil
    }

    private func collectSurfaces(from tree: SplitTree<Ghostty.SurfaceView>, into surfaces: inout [IPCResponse.SurfaceInfo]) {
        // SplitTree conforms to Sequence, iterating yields all leaf views
        for surface in tree {
            IPCSurfaceRegistry.register(surface)
            let surfaceId = IPCSurfaceRegistry.identifier(for: surface)
            surfaces.append(IPCResponse.SurfaceInfo(
                id: surfaceId,
                title: surface.title ?? "",
                focused: surface.focused,
                pwd: surface.pwd ?? "",
                rows: UInt32(surface.surfaceSize?.rows ?? 0),
                cols: UInt32(surface.surfaceSize?.columns ?? 0)
            ))
        }
    }

    // MARK: - Response Sending

    private func sendSuccessResponse(_ clientFD: Int32) {
        sendResponse(clientFD, response: IPCResponse(ok: true))
    }

    private func sendErrorResponse(_ clientFD: Int32, message: String) {
        sendResponse(clientFD, response: IPCResponse(ok: false, error: message))
    }

    private func sendResponse(_ clientFD: Int32, response: IPCResponse) {
        do {
            try sendResponseOrThrow(clientFD, response: response)
        } catch {
            logger.error("Failed to send response: \(error.localizedDescription)")
        }
    }

    private func sendResponseOrThrow(_ clientFD: Int32, response: IPCResponse) throws {
        let data = try JSONEncoder().encode(response)

        // Send length prefix (u32, little-endian)
        var length = UInt32(data.count).littleEndian
        try writeAll(clientFD, bytes: &length, count: MemoryLayout<UInt32>.size)

        // Send response data
        var sendError: Error? = nil
        data.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            do {
                try writeAll(clientFD, bytes: baseAddress, count: data.count)
            } catch {
                sendError = error
            }
        }
        if let sendError { throw sendError }
    }

    // MARK: - Low-Level Socket Helpers

    private func setNoSigPipe(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &yes,
            socklen_t(MemoryLayout.size(ofValue: yes))
        )
    }

    private func validatePeerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 {
            logger.error("getpeereid failed: \(errno)")
            return false
        }

        if uid != getuid() {
            logger.error("IPC rejected connection from uid=\(uid)")
            return false
        }

        return true
    }

    private func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        var readError: IPCError? = nil
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                readError = .readFailed(0)
                return
            }

            while totalRead < count {
                let n = recv(fd, base.advanced(by: totalRead), count - totalRead, 0)
                if n == 0 {
                    readError = .connectionClosed
                    return
                }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    readError = .readFailed(errno)
                    return
                }
                totalRead += n
            }
        }
        if let readError { throw readError }

        return buffer
    }

    private func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) throws {
        var totalSent = 0
        while totalSent < count {
            let n = send(fd, bytes.advanced(by: totalSent), count - totalSent, 0)
            if n == 0 { throw IPCError.connectionClosed }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw IPCError.sendFailed(errno)
            }
            totalSent += n
        }
    }

    private func performOnMain<T>(_ body: () throws -> T) -> Result<T, IPCError> {
        if Thread.isMainThread {
            return Result { try body() }.mapError { IPCError.from($0) }
        }

        var result: Result<T, IPCError>!
        DispatchQueue.main.sync {
            result = Result { try body() }.mapError { IPCError.from($0) }
        }
        return result
    }

    private func removeSocketFileIfPresent(_ path: String) throws {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw IPCError.fileSystem("Socket path inspection failed (errno=\(errno))")
        }

        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw IPCError.socketPathOccupied(path)
        }

        guard path.withCString({ unlink($0) }) == 0 else {
            throw IPCError.fileSystem("Socket unlink failed (errno=\(errno))")
        }
    }

    private struct NewWindowLaunchOptions {
        var config = Ghostty.SurfaceConfiguration()
        var titleOverride: String?
    }

    private enum LaunchCommand {
        case shell(String)
        case exec([String])
    }

    private func parseNewWindowLaunchOptions(_ arguments: [String]?) throws -> NewWindowLaunchOptions {
        var result = NewWindowLaunchOptions()
        guard let arguments else { return result }
        guard !arguments.isEmpty else { throw IPCError.invalidArguments }

        var command: LaunchCommand?
        var execMode = false
        var execArguments: [String] = []

        for argument in arguments {
            if execMode {
                execArguments.append(argument)
                continue
            }

            if argument == "-e" {
                execMode = true
                continue
            }

            if let value = argument.strippingPrefix("--command=") {
                command = try parseCommandOverride(value)
                continue
            }

            if let value = argument.strippingPrefix("--working-directory=") {
                result.config.workingDirectory = try parseWorkingDirectoryOverride(value)
                continue
            }

            if let value = argument.strippingPrefix("--title=") {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                result.titleOverride = trimmed.isEmpty ? nil : trimmed
            }
        }

        if !execArguments.isEmpty {
            command = .exec(execArguments)
        } else if execMode {
            throw IPCError.invalidArguments
        }

        switch command {
        case .shell(let value):
            result.config.command = value
        case .exec(let value):
            result.config.initialInput = "exec \(shellQuoteArguments(value))\n"
        case .none:
            break
        }

        return result
    }

    private func makeExecLaunchConfig(arguments: [String]?) throws -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        guard let arguments else { return config }
        guard !arguments.isEmpty else { throw IPCError.invalidArguments }
        config.initialInput = "exec \(shellQuoteArguments(arguments))\n"
        return config
    }

    private func parseCommandOverride(_ value: String) throws -> LaunchCommand {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IPCError.invalidArguments }

        if let direct = trimmed.strippingPrefix("direct:") {
            let arguments = direct
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard !arguments.isEmpty else { throw IPCError.invalidArguments }
            return .exec(arguments)
        }

        if let shell = trimmed.strippingPrefix("shell:") {
            let command = shell.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { throw IPCError.invalidArguments }
            return .shell(command)
        }

        return .shell(trimmed)
    }

    private func parseWorkingDirectoryOverride(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IPCError.invalidArguments }

        switch trimmed {
        case "home":
            return NSHomeDirectory()
        case "inherit":
            return nil
        default:
            return trimmed
        }
    }

    private func parseMouseButton(_ value: String) throws -> Ghostty.Input.MouseButton {
        switch value.lowercased() {
        case "left": return .left
        case "right": return .right
        case "middle": return .middle
        case "four": return .four
        case "five": return .five
        case "six": return .six
        case "seven": return .seven
        case "eight": return .eight
        case "nine": return .nine
        case "ten": return .ten
        case "eleven": return .eleven
        default: throw IPCError.invalidArguments
        }
    }

    private func shellQuoteArguments(_ arguments: [String]) -> String {
        return arguments.map(shellQuote).joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: - Protocol Types

/// IPC request matching the Zig protocol.
struct IPCRequest: Decodable {
    let version: Int
    let action: Action
    let target: String?

    enum Action: Decodable {
        case new_window(NewWindowPayload?)
        case new_tab(NewTabPayload?)
        case list_surfaces
        case send_text(SendTextPayload)
        case get_screen(GetScreenPayload)
        case focus_surface(FocusSurfacePayload)
        case close_surface(CloseSurfacePayload)
        case resize_surface(ResizeSurfacePayload)
        case screenshot_surface(ScreenshotSurfacePayload)
        case send_mouse(SendMousePayload)
        case send_scroll(SendScrollPayload)
        case send_key(SendKeyPayload)

        enum CodingKeys: String, CodingKey {
            case new_window
            case new_tab
            case list_surfaces
            case send_text
            case get_screen
            case focus_surface
            case close_surface
            case resize_surface
            case screenshot_surface
            case send_mouse
            case send_scroll
            case send_key
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.new_window) {
                let payload = try container.decodeIfPresent(NewWindowPayload.self, forKey: .new_window)
                self = .new_window(payload)
            } else if container.contains(.new_tab) {
                let payload = try container.decodeIfPresent(NewTabPayload.self, forKey: .new_tab)
                self = .new_tab(payload)
            } else if container.contains(.list_surfaces) {
                self = .list_surfaces
            } else if container.contains(.send_text) {
                let payload = try container.decode(SendTextPayload.self, forKey: .send_text)
                self = .send_text(payload)
            } else if container.contains(.get_screen) {
                let payload = try container.decode(GetScreenPayload.self, forKey: .get_screen)
                self = .get_screen(payload)
            } else if container.contains(.focus_surface) {
                let payload = try container.decode(FocusSurfacePayload.self, forKey: .focus_surface)
                self = .focus_surface(payload)
            } else if container.contains(.close_surface) {
                let payload = try container.decode(CloseSurfacePayload.self, forKey: .close_surface)
                self = .close_surface(payload)
            } else if container.contains(.resize_surface) {
                let payload = try container.decode(ResizeSurfacePayload.self, forKey: .resize_surface)
                self = .resize_surface(payload)
            } else if container.contains(.screenshot_surface) {
                let payload = try container.decode(ScreenshotSurfacePayload.self, forKey: .screenshot_surface)
                self = .screenshot_surface(payload)
            } else if container.contains(.send_mouse) {
                let payload = try container.decode(SendMousePayload.self, forKey: .send_mouse)
                self = .send_mouse(payload)
            } else if container.contains(.send_scroll) {
                let payload = try container.decode(SendScrollPayload.self, forKey: .send_scroll)
                self = .send_scroll(payload)
            } else if container.contains(.send_key) {
                let payload = try container.decode(SendKeyPayload.self, forKey: .send_key)
                self = .send_key(payload)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown action"
                    )
                )
            }
        }
    }

    struct NewWindowPayload: Decodable {
        let arguments: [String]?
    }

    struct NewTabPayload: Decodable {
        let arguments: [String]?
    }

    struct SendTextPayload: Decodable {
        let surface_id: String
        let text: String
    }

    struct GetScreenPayload: Decodable {
        let surface_id: String
        let screen: String?
        let format: String?  // "text" (default) or "cells"
    }

    struct FocusSurfacePayload: Decodable {
        let surface_id: String
    }

    struct CloseSurfacePayload: Decodable {
        let surface_id: String
    }

    struct ResizeSurfacePayload: Decodable {
        let surface_id: String
        let rows: UInt32
        let cols: UInt32
    }

    struct ScreenshotSurfacePayload: Decodable {
        let surface_id: String
        let output_path: String
    }

    struct SendMousePayload: Decodable {
        let surface_id: String
        let x: Double
        let y: Double
        let button: String?
        let button_action: String?
        let mods: String?
    }

    struct SendScrollPayload: Decodable {
        let surface_id: String
        let x: Double
        let y: Double
        let mods: String?
    }

    struct SendKeyPayload: Decodable {
        let surface_id: String
        let key: String
        let action: String?
        let mods: String?
    }
}

/// IPC response matching the Zig protocol.
struct IPCResponse: Encodable {
    let ok: Bool
    let error: String?
    let data: ResponseData?

    init(ok: Bool, error: String? = nil, data: ResponseData? = nil) {
        self.ok = ok
        self.error = error
        self.data = data
    }

    struct ResponseData: Encodable {
        let id: String?
        let windows: [WindowInfo]?
        let content: String?
        let cursor_x: UInt32?
        let cursor_y: UInt32?

        init(
            id: String? = nil,
            windows: [WindowInfo]? = nil,
            content: String? = nil,
            cursor_x: UInt32? = nil,
            cursor_y: UInt32? = nil
        ) {
            self.id = id
            self.windows = windows
            self.content = content
            self.cursor_x = cursor_x
            self.cursor_y = cursor_y
        }
    }

    struct WindowInfo: Encodable {
        let id: String
        let focused: Bool
        let tabs: [TabInfo]
    }

    struct TabInfo: Encodable {
        let id: String
        let title: String
        let active: Bool
        let surfaces: [SurfaceInfo]
    }

    struct SurfaceInfo: Encodable {
        let id: String
        let title: String
        let focused: Bool
        let pwd: String
        let rows: UInt32
        let cols: UInt32
    }
}

// MARK: - Errors

enum IPCError: LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong
    case socketPathOccupied(String)
    case appUnavailable
    case invalidArguments
    case surfaceNotFound
    case screenshotFailed
    case readFailed(Int32)
    case sendFailed(Int32)
    case connectionClosed
    case fileSystem(String)

    static func from(_ error: Error) -> IPCError {
        if let err = error as? IPCError { return err }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return .fileSystem("Filesystem error (errno=\(nsError.code))")
        }

        return .fileSystem(nsError.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e):
            return "Socket creation failed (errno=\(e))"
        case .bindFailed(let e):
            return "Socket bind failed (errno=\(e))"
        case .listenFailed(let e):
            return "Socket listen failed (errno=\(e))"
        case .pathTooLong:
            return "Socket path too long"
        case .socketPathOccupied(let path):
            return "Socket path is occupied by a non-socket file: \(path)"
        case .appUnavailable:
            return "App not available"
        case .invalidArguments:
            return "Invalid arguments"
        case .surfaceNotFound:
            return "Surface not found"
        case .screenshotFailed:
            return "Screenshot capture failed"
        case .readFailed(let e):
            return "Socket read failed (errno=\(e))"
        case .sendFailed(let e):
            return "Socket send failed (errno=\(e))"
        case .connectionClosed:
            return "Connection closed"
        case .fileSystem(let message):
            return message
        }
    }
}
