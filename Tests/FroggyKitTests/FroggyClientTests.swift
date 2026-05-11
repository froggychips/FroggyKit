import Testing
import Foundation
import Darwin
@testable import FroggyKit

// MARK: - Mock Unix-socket server

/// Minimal AF_UNIX SOCK_STREAM server for client tests.
/// Accepts a single connection, replies with the pre-arranged response lines
/// (each followed by `\n` to match the daemon's JSON-line wire format),
/// then closes the connection. Bind path is removed on `stop()`.
final class MockSocketServer: @unchecked Sendable {
    let socketPath: String
    private let responseLines: [String]
    /// If `>0`, after recv() the server waits this many seconds before
    /// sending its first response line — used to exercise client timeouts.
    private let preReplyDelay: TimeInterval
    /// If true, accept the connection but never send anything (closes only on stop).
    private let dropAfterAccept: Bool
    private var listenFd: Int32 = -1
    private var thread: Thread?

    init(
        socketPath: String,
        responseLines: [String],
        preReplyDelay: TimeInterval = 0,
        dropAfterAccept: Bool = false
    ) {
        self.socketPath = socketPath
        self.responseLines = responseLines
        self.preReplyDelay = preReplyDelay
        self.dropAfterAccept = dropAfterAccept
    }

    func start() throws {
        listenFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFd < 0 { throw POSIXError(.EACCES) }

        // Ensure stale socket is gone.
        unlink(socketPath)

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
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            Darwin.close(listenFd)
            listenFd = -1
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        if Darwin.listen(listenFd, 4) != 0 {
            Darwin.close(listenFd)
            listenFd = -1
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }

        let fd = listenFd
        let lines = responseLines
        let delay = preReplyDelay
        let drop = dropAfterAccept
        let thread = Thread {
            while !Thread.current.isCancelled {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }

                // Drain the request line — we don't validate it, just read so the
                // client's send() returns.
                var buf = [UInt8](repeating: 0, count: 4096)
                _ = buf.withUnsafeMutableBufferPointer { bp in
                    Darwin.recv(client, bp.baseAddress, bp.count, 0)
                }

                if drop {
                    // Hold connection open without responding. Client will hit
                    // SO_RCVTIMEO and throw .timeout, then call Darwin.close().
                    // We sleep briefly to keep this thread alive past the test.
                    Thread.sleep(forTimeInterval: 2.0)
                    Darwin.close(client)
                    continue
                }

                if delay > 0 { Thread.sleep(forTimeInterval: delay) }

                for line in lines {
                    let payload = line + "\n"
                    _ = payload.withCString { p in
                        Darwin.send(client, p, strlen(p), 0)
                    }
                }
                Darwin.close(client)
            }
        }
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.cancel()
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
        unlink(socketPath)
    }
}

// MARK: - Helpers

private func tempSocketPath() -> String {
    let dir = NSTemporaryDirectory()
    return "\(dir)froggy-test-\(UUID().uuidString.prefix(8)).sock"
}

private func encodeJSONLine(_ res: FroggyResponse) throws -> String {
    let data = try JSONEncoder().encode(res)
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Happy path

@Test func client_send_collectsAllChunks_untilFinal() async throws {
    let path = tempSocketPath()
    var chunk1 = FroggyResponse(); chunk1.ok = true; chunk1.text = "hel";  chunk1.final = false
    var chunk2 = FroggyResponse(); chunk2.ok = true; chunk2.text = "lo!";  chunk2.final = false
    var done   = FroggyResponse(); done.ok = true;   done.final = true

    let server = MockSocketServer(
        socketPath: path,
        responseLines: [
            try encodeJSONLine(chunk1),
            try encodeJSONLine(chunk2),
            try encodeJSONLine(done)
        ]
    )
    try server.start()
    defer { server.stop() }

    let client    = FroggyClient(socketPath: path)
    let responses = try client.send(FroggyRequest(cmd: "generate", prompt: "p"))
    #expect(responses.count == 3)
    #expect(responses.last?.final == true)

    let joined = responses.compactMap(\.text).joined()
    #expect(joined == "hello!")
}

@Test func client_call_joinsTextChunks() async throws {
    let path = tempSocketPath()
    var c1 = FroggyResponse(); c1.text = "foo"; c1.final = false
    var c2 = FroggyResponse(); c2.text = "bar"; c2.final = true

    let server = MockSocketServer(socketPath: path, responseLines: [try encodeJSONLine(c1), try encodeJSONLine(c2)])
    try server.start()
    defer { server.stop() }

    let client = FroggyClient(socketPath: path)
    let result = try client.call(FroggyRequest(cmd: "generate", prompt: "p"))
    #expect(result == "foobar")
}

@Test func client_call_throwsDaemonErrorString_whenOkFalse() async throws {
    let path = tempSocketPath()
    var fail = FroggyResponse(); fail.ok = false; fail.error = "model not loaded"; fail.final = true
    let server = MockSocketServer(socketPath: path, responseLines: [try encodeJSONLine(fail)])
    try server.start()
    defer { server.stop() }

    let client = FroggyClient(socketPath: path)
    do {
        _ = try client.call(FroggyRequest(cmd: "generate", prompt: "p"))
        Issue.record("expected throw")
    } catch FroggyClientError.daemon(let msg) {
        #expect(msg == "model not loaded")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - daemonNotRunning + retry

@Test func client_throwsDaemonNotRunning_whenSocketMissing() async throws {
    // No server, no socket file → connect() returns ENOENT.
    let path = "/tmp/froggy-test-nonexistent-\(UUID().uuidString.prefix(8)).sock"
    let client = FroggyClient(socketPath: path)
    do {
        _ = try client.send(FroggyRequest(cmd: "status"), timeoutSeconds: 2)
        Issue.record("expected throw")
    } catch FroggyClientError.daemonNotRunning {
        // expected after the retry path also fails — both attempts hit ENOENT.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Timeout via SO_RCVTIMEO

@Test func client_timeout_whenServerDoesNotRespond() async throws {
    let path = tempSocketPath()
    let server = MockSocketServer(socketPath: path, responseLines: [], dropAfterAccept: true)
    try server.start()
    defer { server.stop() }

    let client = FroggyClient(socketPath: path)
    do {
        _ = try client.send(FroggyRequest(cmd: "generate", prompt: "p"), timeoutSeconds: 0.5)
        Issue.record("expected timeout throw")
    } catch FroggyClientError.timeout {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - generate() async wrapper

@Test func client_generate_returnsJoinedTextOnSuccess() async throws {
    let path = tempSocketPath()
    var c1 = FroggyResponse(); c1.ok = true; c1.text = "answer";  c1.final = true

    let server = MockSocketServer(socketPath: path, responseLines: [try encodeJSONLine(c1)])
    try server.start()
    defer { server.stop() }

    let client = FroggyClient(socketPath: path, maxTokens: 64)
    let result = try await client.generate(prompt: "ping")
    #expect(result == "answer")
}
