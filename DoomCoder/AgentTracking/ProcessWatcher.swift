import Foundation

// kqueue-based process-exit watcher. Fires `onExit` exactly once
// when the watched PID exits (via EVFILT_PROC / NOTE_EXIT).
final class ProcessWatcher: @unchecked Sendable {
    private let pid: pid_t
    private let onExit: @Sendable () -> Void
    private var thread: Thread?
    private let cancelFd: [Int32]   // cancelFd[0]=read, cancelFd[1]=write

    init(pid: pid_t, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.onExit = onExit
        var fds: [Int32] = [0, 0]
        pipe(&fds)
        self.cancelFd = fds
        start()
    }

    deinit { cancel() }

    func cancel() {
        var b: UInt8 = 1
        write(cancelFd[1], &b, 1)
    }

    private func start() {
        let pid = self.pid
        let cb  = onExit
        let rfd = cancelFd[0]
        let wfd = cancelFd[1]

        let t = Thread {
            let kq = kqueue()
            guard kq >= 0 else { close(rfd); close(wfd); return }
            defer { close(kq); close(rfd); close(wfd) }

            // Register EVFILT_PROC for NOTE_EXIT on the target PID.
            var procEv = kevent(
                ident:  UInt(bitPattern: Int(pid)),
                filter: Int16(EVFILT_PROC),
                flags:  UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data:   0,
                udata:  nil)
            kevent(kq, &procEv, 1, nil, 0, nil)

            // Also watch the cancel pipe read-end so we can wake up early.
            var pipeEv = kevent(
                ident:  UInt(rfd),
                filter: Int16(EVFILT_READ),
                flags:  UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: 0,
                data:   0,
                udata:  nil)
            kevent(kq, &pipeEv, 1, nil, 0, nil)

            var event = kevent()
            let n = kevent(kq, nil, 0, &event, 1, nil)
            if n > 0 && event.filter == Int16(EVFILT_PROC) {
                cb()
            }
        }
        t.name = "dc.ProcessWatcher.\(pid)"
        t.start()
        thread = t
    }
}
