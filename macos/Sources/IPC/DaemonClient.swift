import Foundation
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "DaemonClient")

/// JSON-RPC 2.0 client that communicates with the DevSpace daemon over a Unix socket.
final class DaemonClient {
    private let socketPath: String
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var requestID: Int = 0
    private var pendingCallbacks: [Int: (Result<Any, Error>) -> Void] = [:]
    private var readBuffer = Data()
    private let queue = DispatchQueue(label: "com.devspace.daemon-client", qos: .userInitiated)

    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var isConnected = false

    init(socketPath: String = "/tmp/devspace.sock") {
        self.socketPath = socketPath
    }

    // MARK: - Connection

    func connect() throws {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        let path = socketPath as CFString

        CFStreamCreatePairWithSocketToHost(nil, path, 0, &readStream, &writeStream)

        // For Unix socket, we use a different approach
        let socket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw DaemonError.connectionFailed("Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(socket)
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
                Foundation.connect(socket, sockAddr, addrLen)
            }
        }

        guard result == 0 else {
            close(socket)
            throw DaemonError.connectionFailed("Failed to connect: \(String(cString: strerror(errno)))")
        }

        // Create streams from the connected socket
        CFStreamCreatePairWithSocket(nil, Int32(socket), &readStream, &writeStream)

        guard let input = readStream?.takeRetainedValue() as InputStream?,
              let output = writeStream?.takeRetainedValue() as OutputStream? else {
            close(socket)
            throw DaemonError.connectionFailed("Failed to create streams")
        }

        // Ensure streams close the socket when done
        input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket as String))
        output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket as String))

        self.inputStream = input
        self.outputStream = output

        input.open()
        output.open()

        isConnected = true
        logger.info("Connected to daemon at \(self.socketPath)")

        // Start reading
        startReading()
    }

    func disconnect() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        isConnected = false
        logger.info("Disconnected from daemon")
    }

    // MARK: - JSON-RPC Calls

    func call(method: String, params: [String: Any] = [:], completion: @escaping (Result<Any, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.requestID += 1
            let id = self.requestID

            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            ]

            self.pendingCallbacks[id] = completion

            do {
                let data = try JSONSerialization.data(withJSONObject: request)
                self.send(data)
            } catch {
                self.pendingCallbacks.removeValue(forKey: id)
                completion(.failure(error))
            }
        }
    }

    /// Synchronous convenience for simple calls
    func callSync(method: String, params: [String: Any] = [:]) throws -> Any {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Any, Error> = .failure(DaemonError.timeout)

        call(method: method, params: params) { r in
            result = r
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 5)
        if timeout == .timedOut {
            throw DaemonError.timeout
        }

        return try result.get()
    }

    // MARK: - Specific RPC Methods

    func registerProject(directory: String) throws -> [String: Any] {
        let result = try callSync(method: "project.register", params: ["dir": directory])
        return result as? [String: Any] ?? [:]
    }

    func startProject(id: String) throws -> [String: Any] {
        let result = try callSync(method: "project.start", params: ["id": id])
        return result as? [String: Any] ?? [:]
    }

    func stopProject(id: String) throws {
        _ = try callSync(method: "project.stop", params: ["id": id])
    }

    func getProxyStatus() throws -> [[String: Any]] {
        let result = try callSync(method: "proxy.status")
        guard let dict = result as? [String: Any],
              let routes = dict["routes"] as? [[String: Any]] else { return [] }
        return routes
    }

    // MARK: - I/O

    private func send(_ data: Data) {
        guard let output = outputStream else { return }

        // Send as newline-delimited JSON
        var message = data
        message.append(0x0A) // newline

        message.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            output.write(base, maxLength: message.count)
        }
    }

    private func startReading() {
        queue.async { [weak self] in
            guard let self = self, let input = self.inputStream else { return }

            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while input.hasBytesAvailable || self.isConnected {
                let bytesRead = input.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    self.readBuffer.append(contentsOf: buffer[0..<bytesRead])
                    self.processReadBuffer()
                } else if bytesRead < 0 {
                    logger.error("Read error: \(input.streamError?.localizedDescription ?? "unknown")")
                    break
                } else {
                    // No bytes available, sleep briefly
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
    }

    private func processReadBuffer() {
        // Split by newlines (newline-delimited JSON)
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let messageData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer = Data(readBuffer[readBuffer.index(after: newlineIndex)...])

            guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                continue
            }

            handleMessage(json)
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        if let id = json["id"] as? Int {
            // Response to a request
            let callback = pendingCallbacks.removeValue(forKey: id)
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                callback?(.failure(DaemonError.rpcError(message)))
            } else {
                callback?(.success(json["result"] ?? NSNull()))
            }
        } else if let method = json["method"] as? String {
            // Server-initiated event (notification)
            let params = json["params"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(method, params)
            }
        }
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
