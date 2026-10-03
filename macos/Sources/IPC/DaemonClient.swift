import Foundation
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "DaemonClient")

/// What `daemon.status` reports about the running daemon. Only `version`
/// is required, so an older daemon still decodes and can be detected (and
/// restarted) by its version instead of failing every refresh.
struct DaemonInfo: Decodable {
    struct Proxy: Decodable {
        let state: String
        let error: String?
    }

    let version: String
    let tld: String
    let httpPort: Int
    let httpsPort: Int
    let dnsPort: Int
    let proxy: Proxy
    let caRoot: String
    let logDir: String

    private enum CodingKeys: String, CodingKey {
        case version, tld, httpPort, httpsPort, dnsPort, proxy, caRoot, logDir
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let home = NSHomeDirectory()
        version = try c.decode(String.self, forKey: .version)
        tld = try c.decodeIfPresent(String.self, forKey: .tld) ?? "test"
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort) ?? 47080
        httpsPort = try c.decodeIfPresent(Int.self, forKey: .httpsPort) ?? 47443
        dnsPort = try c.decodeIfPresent(Int.self, forKey: .dnsPort) ?? 5553
        proxy = try c.decodeIfPresent(Proxy.self, forKey: .proxy) ?? Proxy(state: "running", error: nil)
        caRoot = try c.decodeIfPresent(String.self, forKey: .caRoot)
            ?? home + "/Library/Application Support/LocalPort/caddy/pki/authorities/local/root.crt"
        logDir = try c.decodeIfPresent(String.self, forKey: .logDir) ?? home + "/Library/Logs/LocalPort"
    }
}

/// The process serving a route.
struct RouteOwner: Decodable {
    let pid: Int
    /// Executable name, e.g. "node".
    let process: String?
    /// How the daemon attributed it: "claim", "tag" or "cwd".
    let source: String
}

/// A listening port no project claims that looks like a dev server.
struct UnclaimedPort: Decodable {
    let port: Int
    let upstream: String
    let pid: Int
    let process: String?
    let cwd: String?
}

/// What `project.status` reports: registered projects, all live routes, and
/// unclaimed listeners.
struct DaemonProjectStatus: Decodable {
    struct ProjectInfo: Decodable {
        let name: String
        let directory: String
        let hostname: String
        let port: Int?
        let claim: Bool?
        let upstream: String?
        let owner: RouteOwner?
    }

    struct Route: Decodable {
        let hostname: String
        let upstream: String
        let owner: RouteOwner?
    }

    let projects: [ProjectInfo]
    let routes: [Route]
    let unclaimed: [UnclaimedPort]?
}

/// JSON-RPC 2.0 client that communicates with the LocalPort daemon over a Unix socket.
/// Uses simple synchronous I/O — each call writes a request and reads the response.
/// Thread-safe, but blocking: call it from a background queue, never the main thread.
final class DaemonClient {
    let socketPath: String
    private var fd: Int32 = -1
    private var requestID: Int = 0
    private let lock = NSLock()

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? DaemonClient.defaultSocketPath()
    }

    static func defaultSocketPath() -> String {
        "/tmp/localport-\(getuid()).sock"
    }

    // MARK: - Connection

    func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        closeLocked()
        fd = try Self.openSocket(path: socketPath)
        logger.info("Connected to daemon at \(self.socketPath)")
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    /// Whether a daemon is accepting connections at `path`, without
    /// disturbing this client's connection.
    static func isReachable(path: String = defaultSocketPath()) -> Bool {
        guard let sock = try? openSocket(path: path) else { return false }
        close(sock)
        return true
    }

    private func closeLocked() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private static func openSocket(path: String) throws -> Int32 {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw DaemonError.connectionFailed("Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
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
            let message = String(cString: strerror(errno))
            close(sock)
            throw DaemonError.connectionFailed("Failed to connect: \(message)")
        }

        // Writing to a socket the daemon has closed must fail with EPIPE,
        // not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // 5 second read/write timeouts
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        return sock
    }

    // MARK: - JSON-RPC Calls

    /// Send a JSON-RPC request and wait for the response. Any I/O failure
    /// drops the connection so the next call starts from a clean state.
    func callSync(method: String, params: [String: Any] = [:]) throws -> Any {
        lock.lock()
        defer { lock.unlock() }

        guard fd >= 0 else {
            throw DaemonError.connectionFailed("Not connected")
        }

        requestID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]

        var message = try JSONSerialization.data(withJSONObject: request)
        message.append(0x0A) // newline delimiter

        do {
            try writeAllLocked(message)
            let line = try readLineLocked()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw DaemonError.rpcError("Invalid JSON response")
            }
            if let error = json["error"] as? [String: Any] {
                throw DaemonError.rpcError(error["message"] as? String ?? "Unknown error")
            }
            return json["result"] ?? NSNull()
        } catch let error as DaemonError {
            if case .rpcError = error {} else { closeLocked() }
            throw error
        }
    }

    private func writeAllLocked(_ data: Data) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw DaemonError.connectionFailed("Write failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    private func readLineLocked() throws -> Data {
        var readBuffer = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                return readBuffer[readBuffer.startIndex..<newlineIndex]
            }
            let bytesRead = Darwin.read(fd, &buf, buf.count)
            if bytesRead > 0 {
                readBuffer.append(contentsOf: buf[0..<bytesRead])
            } else if bytesRead == 0 {
                throw DaemonError.connectionFailed("Connection closed")
            } else if errno == EINTR {
                continue
            } else {
                throw DaemonError.timeout
            }
        }
    }

    private func call<T: Decodable>(_ method: String, params: [String: Any] = [:], as type: T.Type) throws -> T {
        let result = try callSync(method: method, params: params)
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Specific RPC Methods

    func daemonStatus() throws -> DaemonInfo {
        try call("daemon.status", as: DaemonInfo.self)
    }

    func projectStatus() throws -> DaemonProjectStatus {
        try call("project.status", as: DaemonProjectStatus.self)
    }

    /// Register a project. `hostname`/`port` are the user's overrides from
    /// Project Settings; when nil the daemon uses `.localport.toml` or defaults.
    /// `claim` routes `port` to this project whichever process listens on it.
    func registerProject(directory: String, hostname: String?, port: Int?, claim: Bool) throws -> DaemonProjectStatus.ProjectInfo {
        var params: [String: Any] = ["directory": directory]
        if let hostname { params["hostname"] = hostname }
        if let port {
            params["port"] = port
            params["claim"] = claim
        }
        return try call("project.init", params: params, as: DaemonProjectStatus.ProjectInfo.self)
    }

    func removeProject(directory: String) throws {
        _ = try callSync(method: "project.remove", params: ["directory": directory])
    }

    func shutdown() throws {
        _ = try callSync(method: "daemon.shutdown")
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
        case .rpcError(let msg): return msg
        case .timeout: return "Request timed out"
        }
    }
}
