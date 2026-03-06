import Foundation
import Network
import Security
import EventKit
import Contacts

// MARK: - Global Stores

let eventStore = EKEventStore()
let contactStore = CNContactStore()

// MARK: - Configuration

struct ServerConfig {
    let port: UInt16
    let p12Path: String
    let p12Passphrase: String
    let apiToken: String
}

func loadConfig() -> ServerConfig {
    // Load from .env file in working directory
    var env: [String: String] = [:]
    let envPath = FileManager.default.currentDirectoryPath + "/.env"
    if let contents = try? String(contentsOfFile: envPath, encoding: .utf8) {
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }
    }

    // Defaults from .env, overridable via CLI args
    var port: UInt16 = UInt16(env["PORT"] ?? "4000") ?? 4000
    var p12Path = env["P12_PATH"] ?? ""
    var p12Pass = env["P12_PASSPHRASE"] ?? ""
    var token = env["MAC_API_TOKEN"] ?? ""

    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--port": if let v = args.next(), let p = UInt16(v) { port = p }
        case "--cert": p12Path = args.next() ?? p12Path
        case "--pass": p12Pass = args.next() ?? p12Pass
        case "--token": token = args.next() ?? token
        default: break
        }
    }

    return ServerConfig(port: port, p12Path: p12Path, p12Passphrase: p12Pass, apiToken: token)
}

// MARK: - TCC Access

func requestAllAccess() {
    // Calendar events
    let calSem = DispatchSemaphore(value: 0)
    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToEvents { granted, _ in calSem.signal() }
    } else {
        eventStore.requestAccess(to: .event) { _, _ in calSem.signal() }
    }
    calSem.wait()

    // Reminders
    let remSem = DispatchSemaphore(value: 0)
    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToReminders { granted, _ in remSem.signal() }
    } else {
        eventStore.requestAccess(to: .reminder) { _, _ in remSem.signal() }
    }
    remSem.wait()

    // Contacts
    let conSem = DispatchSemaphore(value: 0)
    contactStore.requestAccess(for: .contacts) { _, _ in conSem.signal() }
    conSem.wait()
}

// Interactive grant mode: triggers TCC dialogs when run from terminal
func grantAccess() {
    print("=== Mac Services API - TCC Permission Grant ===\n")

    print("Requesting Calendar access...")
    let calSem = DispatchSemaphore(value: 0)
    var calGranted = false
    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToEvents { success, error in
            calGranted = success
            if let error = error { print("  Error: \(error.localizedDescription)") }
            calSem.signal()
        }
    } else {
        eventStore.requestAccess(to: .event) { success, error in
            calGranted = success
            if let error = error { print("  Error: \(error.localizedDescription)") }
            calSem.signal()
        }
    }
    calSem.wait()
    print("  Calendars: \(calGranted ? "GRANTED" : "DENIED")\n")

    print("Requesting Reminders access...")
    let remSem = DispatchSemaphore(value: 0)
    var remGranted = false
    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToReminders { success, error in
            remGranted = success
            if let error = error { print("  Error: \(error.localizedDescription)") }
            remSem.signal()
        }
    } else {
        eventStore.requestAccess(to: .reminder) { success, error in
            remGranted = success
            if let error = error { print("  Error: \(error.localizedDescription)") }
            remSem.signal()
        }
    }
    remSem.wait()
    print("  Reminders: \(remGranted ? "GRANTED" : "DENIED")\n")

    print("Requesting Contacts access...")
    let conSem = DispatchSemaphore(value: 0)
    var conGranted = false
    contactStore.requestAccess(for: .contacts) { success, error in
        conGranted = success
        if let error = error { print("  Error: \(error.localizedDescription)") }
        conSem.signal()
    }
    conSem.wait()
    print("  Contacts: \(conGranted ? "GRANTED" : "DENIED")\n")

    if calGranted && remGranted && conGranted {
        print("All access granted! You can now run the server via LaunchAgent.")
    } else {
        print("Some access was denied. Check System Settings > Privacy & Security.")
    }
}

// MARK: - TLS

func createTLSOptions(p12Path: String, passphrase: String) -> NWProtocolTLS.Options? {
    guard let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
        fputs("[TLS] Cannot read .p12 file at \(p12Path)\n", stderr)
        return nil
    }

    let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
    var items: CFArray?
    let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

    guard status == errSecSuccess,
          let itemArray = items as? [[String: Any]],
          let firstItem = itemArray.first,
          let identity = firstItem[kSecImportItemIdentity as String] else {
        fputs("[TLS] SecPKCS12Import failed with status \(status)\n", stderr)
        return nil
    }

    let secIdentity = identity as! SecIdentity
    let tlsOptions = NWProtocolTLS.Options()

    guard let secIdentityRef = sec_identity_create(secIdentity) else {
        fputs("[TLS] Failed to create sec_identity\n", stderr)
        return nil
    }

    sec_protocol_options_set_local_identity(
        tlsOptions.securityProtocolOptions,
        secIdentityRef
    )
    sec_protocol_options_set_min_tls_protocol_version(
        tlsOptions.securityProtocolOptions,
        .TLSv12
    )

    return tlsOptions
}

// MARK: - HTTP Types

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    var pathOnly: String {
        if let idx = path.firstIndex(of: "?") {
            return String(path[..<idx])
        }
        return path
    }

    var pathComponents: [String] {
        pathOnly.split(separator: "/").map { String($0) }
    }

    var queryParams: [String: String] {
        guard let idx = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: idx)...])
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return params
    }

    func jsonBody() -> [String: Any]? {
        guard let body = body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

struct HTTPResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    init(statusCode: Int = 200) {
        self.statusCode = statusCode
        self.headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Connection": "close",
            "Access-Control-Allow-Origin": "*",
        ]
        self.body = Data()
    }

    func serialize() -> Data {
        let statusText: String = {
            switch statusCode {
            case 200: return "OK"
            case 201: return "Created"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 404: return "Not Found"
            case 500: return "Internal Server Error"
            default: return "Unknown"
            }
        }()
        var result = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        for (key, value) in allHeaders {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"
        var data = result.data(using: .utf8)!
        data.append(body)
        return data
    }
}

// MARK: - Response Helpers

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
    var resp = HTTPResponse(statusCode: status)
    if let data = try? jsonEncoder.encode(value) {
        resp.body = data
    }
    return resp
}

struct ErrorBody: Codable { let error: String }
struct SuccessBody: Codable { let success: Bool; let message: String }

func jsonError(_ message: String, status: Int = 500) -> HTTPResponse {
    return jsonResponse(ErrorBody(error: message), status: status)
}

func jsonSuccess(_ message: String) -> HTTPResponse {
    return jsonResponse(SuccessBody(success: true, message: message))
}

// MARK: - Shared Date Parsing

func parseDateString(_ dateStr: String) -> DateComponents? {
    // Date-only: YYYY-MM-DD
    if !dateStr.contains("T") {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    // Datetime: treat as LOCAL time (strip Z suffix if present)
    var cleanStr = dateStr
    if cleanStr.hasSuffix("Z") { cleanStr = String(cleanStr.dropLast()) }

    let formatter = DateFormatter()
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = formatter.date(from: cleanStr) {
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
    if let date = formatter.date(from: cleanStr) {
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    return nil
}

// MARK: - HTTP Request Parser

func parseHTTPRequest(from data: Data) -> HTTPRequest? {
    guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
        return nil
    }
    let headerData = data[data.startIndex..<separatorRange.lowerBound]
    let bodyData = data[separatorRange.upperBound..<data.endIndex]

    guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let requestParts = requestLine.split(separator: " ", maxSplits: 2)
    guard requestParts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        if let colonIdx = line.firstIndex(of: ":") {
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
    }

    return HTTPRequest(
        method: String(requestParts[0]),
        path: String(requestParts[1]),
        headers: headers,
        body: bodyData.isEmpty ? nil : Data(bodyData)
    )
}

// MARK: - HTTP Server

final class HTTPServer {
    let listener: NWListener
    let handler: (HTTPRequest) -> HTTPResponse
    let queue = DispatchQueue(label: "com.example.mac-services-api.server")

    init(port: UInt16, tlsOptions: NWProtocolTLS.Options?, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 30
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = self.listener.port {
                print("[SERVER] Listening on port \(port)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveRequest(on: connection, accumulated: Data())
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { connection.cancel(); return }

            var buffer = accumulated
            if let data = data { buffer.append(data) }

            // Check if we have complete headers + full body
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    let contentLength = self.extractContentLength(from: headerStr)
                    let bodyReceived = buffer[headerEnd.upperBound...].count
                    if bodyReceived >= contentLength {
                        self.processRequest(buffer, on: connection)
                        return
                    }
                }
            }

            if isComplete {
                if !buffer.isEmpty { self.processRequest(buffer, on: connection) }
                else { connection.cancel() }
                return
            }

            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func extractContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func processRequest(_ data: Data, on connection: NWConnection) {
        guard let request = parseHTTPRequest(from: data) else {
            sendResponse(jsonError("Bad Request", status: 400), on: connection)
            return
        }
        let response = handler(request)
        sendResponse(response, on: connection)
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
