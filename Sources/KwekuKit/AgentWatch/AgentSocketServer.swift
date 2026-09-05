import Foundation

/// Minimal Unix-domain-socket line server (BSD sockets + GCD, zero deps).
/// Hooks connect and write newline-delimited JSON; each complete line is
/// delivered on the main queue.
final class AgentSocketServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    private let queue = DispatchQueue(label: "com.kweku.agentwatch")
    private var onLine: ((String) -> Void)?

    /// Start listening at `path`. Replaces any stale socket file.
    @discardableResult
    func start(path: String, onLine: @escaping (String) -> Void) -> Bool {
        self.onLine = onLine
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.withCString { cstr -> Bool in
            let len = strlen(cstr)
            guard len < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    _ = strcpy(dst, cstr)
                }
            }
            return true
        }
        guard ok else { close(fd); return false }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else { close(fd); return false }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
        return true
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            for (fd, entry) in connections { entry.source.cancel(); close(fd) }
            connections.removeAll()
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
        }
    }

    deinit { stop() }

    // MARK: - Internals (all on `queue`)

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { break }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readPending(fd) }
            connections[fd] = (source, Data())
            source.resume()
        }
    }

    private func readPending(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                connections[fd]?.buffer.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                drainLines(fd)
                closeConnection(fd)
                return
            } else {
                break // EAGAIN
            }
        }
        drainLines(fd)
    }

    private func drainLines(_ fd: Int32) {
        guard var buffer = connections[fd]?.buffer else { return }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: Data(lineData), encoding: .utf8),
               !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let handler = onLine
                DispatchQueue.main.async { handler?(line) }
            }
        }
        connections[fd]?.buffer = buffer
    }

    private func closeConnection(_ fd: Int32) {
        connections[fd]?.source.cancel()
        connections[fd] = nil
        close(fd)
    }
}
