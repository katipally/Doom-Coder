import Foundation
import Darwin

// MARK: - SocketServer
//
// Listens on a Unix domain socket at ~/.doomcoder/dc.sock.
// Hooks (via `nc -U`) and the doomcoder-mcp binary both connect, write one or
// more newline-delimited JSON events, and close. Each connection is served on
// a background dispatch queue; parsed events are delivered on the main actor
// via the `onEvent` callback (typically AgentStatusManager).
//
// Design notes:
//   • We bind with socket mode 0600 so only the user can read/write.
//   • We deliberately don't use Network.framework — NWListener doesn't support
//     AF_UNIX on macOS 14+ in a clean way and has quirks with permissions.
//   • Max frame size per line: 64 KiB. Larger frames are dropped (logged).
//   • Listener is stoppable and restartable; stale sockets are cleaned up on start.
//   • All OS calls are Darwin libc for clarity and maximum reliability.

@MainActor
final class SocketServer {

    // Callback invoked on main actor for every parsed event.
    var onEvent: ((AgentEvent) -> Void)?

    // Public read-only status, useful for settings UI ("Socket: running").
    private(set) var isRunning = false
    private(set) var socketPath: String = ""
    private(set) var lastError: String?

    @ObservationIgnored nonisolated(unsafe) private var serverFD: Int32 = -1
    @ObservationIgnored nonisolated(unsafe) private var acceptQueue: DispatchQueue?
    @ObservationIgnored nonisolated(unsafe) private var acceptSource: DispatchSourceRead?

    // Concurrent queue for handling connections (small number in practice).
    private let clientQueue = DispatchQueue(
        label: "com.doomcoder.socketserver.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Public API

    // Starts the listener. Returns `true` on success. Safe to call multiple times.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        do {
            let dir  = try SocketServer.ensureSocketDirectory()
            let path = dir.appendingPathComponent("dc.sock").path
            socketPath = path

            // Clean up stale socket from previous run (common after a crash).
            unlink(path)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw SocketError.create(errno: errno)
            }

            // Allow quick restart (though AF_UNIX ignores SO_REUSEADDR, does no harm).
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
            guard path.utf8.count < maxPath else {
                close(fd)
                throw SocketError.pathTooLong(path: path, limit: maxPath)
            }

            _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                    path.withCString { src in
                        strncpy(dst, src, maxPath)
                    }
                }
            }

            let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                    Darwin.bind(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                close(fd)
                throw SocketError.bind(errno: errno, path: path)
            }

            // Owner-only permissions.
            chmod(path, 0o600)

            guard listen(fd, 32) == 0 else {
                close(fd)
                unlink(path)
                throw SocketError.listen(errno: errno)
            }

            // Non-blocking accept loop via DispatchSource.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let queue = DispatchQueue(label: "com.doomcoder.socketserver.accept", qos: .userInitiated)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

            serverFD      = fd
            acceptQueue   = queue
            acceptSource  = src

            src.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    var clientAddr = sockaddr_un()
                    var clientLen  = socklen_t(MemoryLayout<sockaddr_un>.size)
                    let client = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            accept(fd, sockPtr, &clientLen)
                        }
                    }
                    if client < 0 {
                        // EAGAIN/EWOULDBLOCK means no more clients pending.
                        if errno == EAGAIN || errno == EWOULDBLOCK { return }
                        return
                    }
                    self.handleClient(fd: client)
                }
            }

            src.setCancelHandler {
                close(fd)
                unlink(path)
            }

            src.resume()

            isRunning = true
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        acceptSource?.cancel()
        acceptSource = nil
        acceptQueue  = nil
        serverFD     = -1
        isRunning    = false
    }

    // MARK: - Client handling
    //
    // Runs on the clientQueue. Reads until EOF or 64 KiB, parses as many
    // line-delimited JSON events as possible, then hops back to main actor
    // to deliver them.
    private func handleClient(fd: Int32) {
        clientQueue.async { [weak self] in
            defer { close(fd) }
            guard let self else { return }

            var buffer = Data()
            let chunkSize = 4096
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let maxBytes = 64 * 1024

            while buffer.count < maxBytes {
                let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                    read(fd, ptr.baseAddress, chunkSize)
                }
                if n > 0 {
                    buffer.append(chunk, count: n)
                    continue
                }
                if n == 0 { break }                                  // EOF
                if errno == EINTR { continue }                       // signal — retry
                break                                                // other error — bail
            }

            // Ensure buffer ends with newline so any final object parses.
            if !buffer.isEmpty && buffer.last != 0x0A { buffer.append(0x0A) }
            let events = AgentEventCodec.decode(buffer: &buffer)
            guard !events.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                for ev in events { self.onEvent?(ev) }
            }
        }
    }

    // MARK: - Helpers

    static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".doomcoder/dc.sock").path
    }

    static func ensureSocketDirectory() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = home.appendingPathComponent(".doomcoder", isDirectory: true)
        let fm   = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Ensure permissions are tight even on existing dir.
        _ = try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    // MARK: - Errors

    enum SocketError: LocalizedError {
        case create(errno: Int32)
        case bind(errno: Int32, path: String)
        case listen(errno: Int32)
        case pathTooLong(path: String, limit: Int)

        var errorDescription: String? {
            switch self {
            case .create(let e):        return "socket() failed (errno \(e): \(String(cString: strerror(e))))"
            case .bind(let e, let p):   return "bind(\(p)) failed (errno \(e): \(String(cString: strerror(e))))"
            case .listen(let e):        return "listen() failed (errno \(e): \(String(cString: strerror(e))))"
            case .pathTooLong(_, let l): return "Socket path exceeds \(l) bytes"
            }
        }
    }
}
