import Foundation
import Darwin

// MARK: - SocketServer
//
// Listens on a Unix domain socket at ~/.doomcoder/dc.sock.
// Hooks (via `nc -U`) and the doomcoder-mcp binary both connect, write one or
// more newline-delimited JSON events, and close.
//
// Concurrency model (v1.4.1 — fixes accept-queue crash):
//   • SocketServer is @MainActor and exposes UI-facing state only
//     (`isRunning`, `socketPath`, `lastError`, `onEvent`).
//   • ALL socket I/O lives in `SocketCore`, a plain nonisolated class that
//     owns the file descriptor, the DispatchSource, and the accept loop.
//     It never touches @MainActor state.
//   • SocketCore forwards decoded events through a `@Sendable` closure
//     captured at start time. That closure hops to MainActor internally
//     and calls `onEvent`.
//   • This is what fixes the crash on `com.doomcoder.socketserver.accept`:
//     previously the accept handler captured `self` (@MainActor) and passed
//     it across actor boundaries, which traps under Swift 6 concurrency.

@MainActor
final class SocketServer {

    // Callback invoked on main actor for every parsed event.
    var onEvent: ((AgentEvent) -> Void)?

    // Public read-only status.
    private(set) var isRunning = false
    private(set) var socketPath: String = ""
    private(set) var lastError: String?

    // The actual I/O engine. nil until start() succeeds.
    private var core: SocketCore?

    // MARK: - Public API

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        do {
            let dir  = try SocketServer.ensureSocketDirectory()
            let path = dir.appendingPathComponent("dc.sock").path

            // Forwarder: called on clientQueue with a batch of events.
            // Hops to MainActor and delivers via onEvent.
            let forward: @Sendable ([AgentEvent]) -> Void = { [weak self] events in
                Task { @MainActor [weak self] in
                    guard let self, let cb = self.onEvent else { return }
                    for ev in events { cb(ev) }
                }
            }

            let core = try SocketCore.start(atPath: path, forward: forward)
            self.core       = core
            self.socketPath = path
            self.isRunning  = true
            self.lastError  = nil
            return true
        } catch {
            self.lastError = String(describing: error)
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        core?.shutdown()
        core = nil
        isRunning = false
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
            case .create(let e):         return "socket() failed (errno \(e): \(String(cString: strerror(e))))"
            case .bind(let e, let p):    return "bind(\(p)) failed (errno \(e): \(String(cString: strerror(e))))"
            case .listen(let e):         return "listen() failed (errno \(e): \(String(cString: strerror(e))))"
            case .pathTooLong(_, let l): return "Socket path exceeds \(l) bytes"
            }
        }
    }
}

// MARK: - SocketCore (nonisolated I/O engine)
//
// Holds the FD + DispatchSource. Runs entirely off the main actor.
// All state is accessed only from the accept serial queue or the concurrent
// client queue. No @MainActor type is ever captured or referenced here —
// the only bridge to the UI is the @Sendable `forward` closure.

private final class SocketCore: @unchecked Sendable {

    private let fd: Int32
    private let path: String
    private let acceptQueue: DispatchQueue
    private let source: DispatchSourceRead
    private let forward: @Sendable ([AgentEvent]) -> Void

    private static let clientQueue = DispatchQueue(
        label: "com.doomcoder.socketserver.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init(fd: Int32, path: String, queue: DispatchQueue, source: DispatchSourceRead, forward: @Sendable @escaping ([AgentEvent]) -> Void) {
        self.fd = fd
        self.path = path
        self.acceptQueue = queue
        self.source = source
        self.forward = forward
    }

    static func start(atPath path: String,
                      forward: @Sendable @escaping ([AgentEvent]) -> Void) throws -> SocketCore {

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketServer.SocketError.create(errno: errno)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPath else {
            close(fd)
            throw SocketServer.SocketError.pathTooLong(path: path, limit: maxPath)
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
            let e = errno
            close(fd)
            throw SocketServer.SocketError.bind(errno: e, path: path)
        }

        chmod(path, 0o600)

        guard listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServer.SocketError.listen(errno: e)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let queue  = DispatchQueue(label: "com.doomcoder.socketserver.accept", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

        let core = SocketCore(fd: fd, path: path, queue: queue, source: source, forward: forward)

        // IMPORTANT: capture only Sendable values (fd, forward) — never `self`.
        let capturedFD = fd
        let capturedForward = forward

        source.setEventHandler {
            while true {
                var clientAddr = sockaddr_un()
                var clientLen  = socklen_t(MemoryLayout<sockaddr_un>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(capturedFD, sockPtr, &clientLen)
                    }
                }
                if client < 0 {
                    // No more clients pending, or unexpected error — bail this cycle.
                    return
                }
                SocketCore.handleClient(fd: client, forward: capturedForward)
            }
        }

        source.setCancelHandler {
            close(capturedFD)
            unlink(path)
        }

        source.resume()
        return core
    }

    func shutdown() {
        source.cancel()
    }

    // Fully nonisolated, runs on the concurrent client queue. Reads the
    // client socket until EOF / error / size cap, decodes line-delimited
    // JSON, and forwards via the Sendable callback. Never touches self.
    private static func handleClient(fd: Int32,
                                     forward: @Sendable @escaping ([AgentEvent]) -> Void) {
        clientQueue.async {
            defer { close(fd) }

            var buffer = Data()
            let chunkSize = 4096
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let maxBytes = 64 * 1024

            while buffer.count < maxBytes {
                let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return read(fd, base, chunkSize)
                }
                if n > 0 {
                    buffer.append(chunk, count: n)
                    continue
                }
                if n == 0 { break }                     // EOF
                if errno == EINTR { continue }          // signal — retry
                break                                   // other error — bail
            }

            if buffer.count > maxBytes { buffer = buffer.prefix(maxBytes) }
            if !buffer.isEmpty && buffer.last != 0x0A { buffer.append(0x0A) }

            let events = AgentEventCodec.decode(buffer: &buffer)
            guard !events.isEmpty else { return }
            forward(events)
        }
    }
}
