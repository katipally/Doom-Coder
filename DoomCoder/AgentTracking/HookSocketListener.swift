import Foundation
import Network
import OSLog

// Listens on the Unix-domain socket at AgentSupportDir.socketURL and delivers
// decoded HookEnvelopes to the tracking manager. Frame format matches dc-hook:
// 4-byte big-endian length || UTF-8 JSON bytes.
final class HookSocketListener: @unchecked Sendable {
    static let shared = HookSocketListener()

    private let logger = Logger(subsystem: "com.doomcoder", category: "socket")
    private let queue = DispatchQueue(label: "com.doomcoder.socket", qos: .utility)
    private var onEnvelope: (@Sendable (HookEnvelope) -> Void)?

    private init() {}

    func start(onEnvelope: @escaping @Sendable (HookEnvelope) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onEnvelope = onEnvelope
            AgentSupportDir.ensure()
            let path = AgentSupportDir.socketURL.path
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            self.startRawUnixListener()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopRawUnixListener() }
    }

    // MARK: - Raw POSIX listener (NWListener doesn't cover unix path sockets directly).

    private var rawFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private func startRawUnixListener() {
        let path = AgentSupportDir.socketURL.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                _ = bytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, bytes.count)
                }
            }
        }

        let sz = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in bind(fd, sp, sz) }
        }
        guard bindRC == 0 else {
            logger.error("bind() failed: \(String(cString: strerror(errno)))")
            close(fd); return
        }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            logger.error("listen() failed: \(String(cString: strerror(errno)))")
            close(fd); return
        }

        rawFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(fd, nil, nil)
            if client >= 0 {
                self.handleClient(client)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src
        logger.info("Hook socket listening at \(path, privacy: .public)")
    }

    private func stopRawUnixListener() {
        acceptSource?.cancel()
        acceptSource = nil
        if rawFd >= 0 { close(rawFd); rawFd = -1 }
        try? FileManager.default.removeItem(atPath: AgentSupportDir.socketURL.path)
    }

    private func handleClient(_ fd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { close(fd) }
            var lenBytes = [UInt8](repeating: 0, count: 4)
            guard readExactly(fd, into: &lenBytes, count: 4) else { return }
            let length = (UInt32(lenBytes[0]) << 24) | (UInt32(lenBytes[1]) << 16) |
                         (UInt32(lenBytes[2]) << 8)  |  UInt32(lenBytes[3])
            guard length > 0, length < 1_048_576 else { return }
            var payload = [UInt8](repeating: 0, count: Int(length))
            guard readExactly(fd, into: &payload, count: Int(length)) else { return }
            let data = Data(payload)
            guard let env = HookEnvelope.decode(data) else { return }
            let cb = self?.onEnvelope
            DispatchQueue.main.async { cb?(env) }
        }
    }
}

// MARK: - Low-level IO helpers

private func readExactly(_ fd: Int32, into buf: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
    var total = 0
    while total < count {
        let n = recv(fd, buf.advanced(by: total), count - total, 0)
        if n <= 0 { return false }
        total += n
    }
    return true
}
