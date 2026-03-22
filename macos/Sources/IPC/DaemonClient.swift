import Foundation
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "DaemonClient")

/// JSON-RPC 2.0 client that communicates with the LocalPort daemon over a Unix socket.
/// Uses simple synchronous I/O — each call writes a request and reads the response.
final class DaemonClient {
    private let socketPath: String
    private var fd: Int32 = -1
    private var requestID: Int = 0
    private let lock = NSLock()

    private(set) var isConnected = false

    init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? DaemonClient.defaultSocketPath()
    }

    private static func defaultSocketPath() -> String {
        let uid = getuid()
        return "/tmp/localport-\(uid).sock"
    }

    // MARK: - Connection

    func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        // Close existing connection
        if fd >= 0 {
            close(fd)
            fd = -1
            isConnected = false
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw DaemonError.connectionFailed("Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            throw DaemonError.connectionFailed("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Foundation.connect(sock, sockAddr, addrLen)
            }
        }

        guard result == 0 else {
            close(sock)
            throw DaemonError.connectionFailed("Failed to connect: \(String(cString: strerror(errno)))")
        }

        // Set read timeout (5 seconds)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        self.fd = sock
        self.isConnected = true
        logger.info("Connected to daemon at \(self.socketPath)")
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        isConnected = false
    }

    // MARK: - JSON-RPC Calls

    /// Send a JSON-RPC request and wait for the response. Thread-safe.
    func callSync(method: String, params: [String: Any] = [:]) throws -> Any {
        lock.lock()
        defer { lock.unlock() }

        guard fd >= 0 else {
            throw DaemonError.connectionFailed("Not connected")
        }

        requestID += 1
        let id = requestID

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        var message = data
        message.append(0x0A) // newline delimiter

        // Write
        let written = message.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.write(fd, base, message.count)
        }

        if written < 0 {
            isConnected = false
            throw DaemonError.connectionFailed("Write failed: \(String(cString: strerror(errno)))")
        }

        // Read until we get a complete newline-delimited response
        var readBuffer = Data()
        var buf = [UInt8](repeating: 0, count: 4096)

        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let messageData = readBuffer[readBuffer.startIndex..<newlineIndex]
                guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    throw DaemonError.rpcError("Invalid JSON response")
                }

                if let error = json["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "Unknown error"
                    throw DaemonError.rpcError(msg)
                }

                return json["result"] ?? NSNull()
            }

            let bytesRead = Darwin.read(fd, &buf, buf.count)
            if bytesRead > 0 {
                readBuffer.append(contentsOf: buf[0..<bytesRead])
            } else if bytesRead == 0 {
                isConnected = false
                throw DaemonError.connectionFailed("Connection closed")
            } else {
                isConnected = false
                throw DaemonError.timeout
            }
        }
    }

    // MARK: - Specific RPC Methods

    func registerProject(directory: String) throws -> [String: Any] {
        let result = try callSync(method: "project.register", params: ["dir": directory])
        return result as? [String: Any] ?? [:]
    }

    func getProxyStatus() throws -> [[String: Any]] {
        let result = try callSync(method: "project.status")
        guard let dict = result as? [String: Any],
              let routes = dict["routes"] as? [[String: Any]] else { return [] }
        return routes
    }
}

// MARK: - Errors

enum DaemonError: Error, LocalizedError {
    case connectionFailed(String)
    case rpcError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .rpcError(let msg): return "RPC error: \(msg)"
        case .timeout: return "Request timed out"
        }
    }
}
