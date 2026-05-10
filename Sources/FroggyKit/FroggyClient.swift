import Darwin
import Foundation

// MARK: - Wire types

public struct FroggyRequest: Codable, Sendable {
    public var cmd: String
    public var prompt: String?
    public var maxTokens: Int?
    public var maxChars: Int?
    public var useContext: Bool?
    public var path: String?
    public var accessor: String?

    public init(
        cmd: String, prompt: String? = nil, maxTokens: Int? = nil,
        maxChars: Int? = nil, useContext: Bool? = nil,
        path: String? = nil, accessor: String? = nil
    ) {
        self.cmd       = cmd
        self.prompt    = prompt
        self.maxTokens = maxTokens
        self.maxChars  = maxChars
        self.useContext = useContext
        self.path      = path
        self.accessor  = accessor
    }
}

public struct FroggyResponse: Codable, Sendable {
    public var ok: Bool?
    public var error: String?
    public var text: String?
    public var context: String?
    public var listening: Bool?
    public var sessionURL: String?
    public var audioOutputDevice: String?
    public var audioInputDevice: String?
    public var modelLoaded: Bool?
    public var modelPath: String?
    public var memoryPressure: Int?
    public var snapshots: Int?
    public var kvCacheBits: Int?
    public var pressureLevel: String?
    public var tier1Frozen: [Int32]?
    public var tier2Frozen: [Int32]?
    public var secondsInLevel: Int?
    public var `final`: Bool?
}

public enum FroggyClientError: Error, CustomStringConvertible, LocalizedError {
    case socketCreation
    case connection(Int32)
    case daemonNotRunning
    case daemon(String)

    public var description: String {
        switch self {
        case .socketCreation:    return "не удалось создать сокет"
        case .connection(let e): return "не удалось подключиться к daemon: errno=\(e)"
        case .daemonNotRunning:  return "Froggy daemon не запущен (проверь: launchctl list | grep froggy)"
        case .daemon(let msg):   return msg
        }
    }

    public var errorDescription: String? { description }
}

/// Unix socket IPC client for the Froggy daemon.
/// One connection per request — daemon closes the connection after the final response chunk.
public struct FroggyClient: Sendable {
    public let socketPath: String
    public let maxTokens: Int

    public init() {
        let env = ProcessInfo.processInfo.environment
        socketPath = env["FROGGY_IPC_SOCKET"]
            ?? "\(NSHomeDirectory())/Library/Application Support/Froggy/froggy.sock"
        maxTokens = Int(env["FROGGY_SRE_MAX_TOKENS"] ?? "1024") ?? 1024
    }

    // MARK: - Async API (Swift concurrency consumers)

    /// Generates text via the local Froggy LLM. Wraps the blocking `call` in a detached task.
    public func generate(prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let result = try self.call(
                        FroggyRequest(cmd: "generate", prompt: prompt,
                                      maxTokens: self.maxTokens, useContext: false)
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync API (blocking, for synchronous consumers)

    /// Sends a request and collects all response chunks until `final: true`.
    public func send(_ request: FroggyRequest, timeoutSeconds: Double = 30) throws -> [FroggyResponse] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FroggyClientError.socketCreation }
        defer { Darwin.close(fd) }

        let secs  = Int(timeoutSeconds)
        let usecs = Int32((timeoutSeconds - Double(secs)) * 1_000_000)
        var tv    = timeval(tv_sec: secs, tv_usec: usecs)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cStr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    _ = strlcpy(dst, cStr, maxLen)
                }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw (errno == ENOENT || errno == ECONNREFUSED)
                ? FroggyClientError.daemonNotRunning
                : FroggyClientError.connection(errno)
        }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }

        var buffer    = Data()
        var responses = [FroggyResponse]()
        let chunk     = Data(count: 4096)
        while true {
            var mutable = chunk
            let n = mutable.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress, 4096, 0)
            }
            if n <= 0 { break }
            buffer.append(mutable.prefix(n))
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let r = try? JSONDecoder().decode(FroggyResponse.self, from: line) {
                    responses.append(r)
                    if r.final == true { return responses }
                }
            }
        }
        return responses
    }

    /// Convenience: sends a request, joins `text` chunks, throws on `ok: false`.
    public func call(_ request: FroggyRequest, timeout: Double = 30) throws -> String {
        let responses = try send(request, timeoutSeconds: timeout)
        if let err = responses.first(where: { $0.ok == false })?.error {
            throw FroggyClientError.daemon(err)
        }
        return responses.compactMap(\.text).joined()
    }
}
