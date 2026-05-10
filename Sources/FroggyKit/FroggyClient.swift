import Foundation

/// Unix socket IPC client for the Froggy daemon.
/// One connection per request — daemon closes after each response.
public struct FroggyClient: Sendable {
    public let socketPath: String
    public let maxTokens: Int

    public init() {
        let env = ProcessInfo.processInfo.environment
        socketPath = env["FROGGY_IPC_SOCKET"]
            ?? "\(NSHomeDirectory())/Library/Application Support/Froggy/froggy.sock"
        maxTokens = Int(env["FROGGY_SRE_MAX_TOKENS"] ?? "1024") ?? 1024
    }

    public func generate(prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    continuation.resume(returning: try self.generateSync(prompt: prompt))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking implementation (runs on detached task)

    private func generateSync(prompt: String) throws -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FroggyClientError.socketCreation }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 30, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, byte) in pathBytes.enumerated() {
                buf.storeBytes(of: byte, toByteOffset: i, as: UInt8.self)
            }
            buf.storeBytes(of: 0, toByteOffset: pathBytes.count, as: UInt8.self)
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw (errno == ENOENT || errno == ECONNREFUSED)
                ? FroggyClientError.daemonNotRunning
                : FroggyClientError.connection(errno)
        }

        var payload = try JSONSerialization.data(withJSONObject: [
            "cmd": "generate",
            "prompt": prompt,
            "maxTokens": maxTokens,
            "useContext": false
        ])
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }

        return try readResponse(fd: fd)
    }

    private func readResponse(fd: Int32) throws -> String {
        var buffer = Data()
        var result = ""
        let chunk  = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { chunk.deallocate() }

        outer: while true {
            let n = Darwin.recv(fd, chunk, 4096, 0)
            if n <= 0 { break }
            buffer.append(Data(bytes: chunk, count: n))

            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)

                guard let resp = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }

                if let ok = resp["ok"] as? Bool, !ok, let err = resp["error"] as? String {
                    throw FroggyClientError.daemon(err)
                }
                if let text = resp["text"] as? String { result += text }
                if resp["final"] as? Bool == true { break outer }
            }
        }
        return result
    }
}

public enum FroggyClientError: Error {
    case socketCreation
    case connection(Int32)
    case daemonNotRunning
    case daemon(String)
}
