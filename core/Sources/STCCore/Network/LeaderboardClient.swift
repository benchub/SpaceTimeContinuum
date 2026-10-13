import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends HTTP requests. Abstracted so tests can substitute canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LeaderboardClient.ClientError.invalidResponse }
        return (data, http)
    }
}

/// Client for the protocol described in docs/protocol.md.
public struct LeaderboardClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://spacetime.silentmedia.com")!
    public static let protocolVersion = "1"
    public static let maxSamplesPerRequest = 1440

    public enum ClientError: Error, Equatable {
        case invalidResponse
        case http(status: Int, message: String?, retryAfter: TimeInterval?)
    }

    public struct UploadResult: Equatable, Sendable {
        public var accepted: [Int64]
        public var rejected: [Int64: String]
    }

    public struct NameCheck: Equatable, Sendable {
        public var name: String
        public var available: Bool
        public var reason: String?
    }

    public enum NameClaim: Equatable, Sendable {
        case success(name: String)
        case unavailable(name: String)
        case error(message: String)
    }

    public enum UnitsFetch: Equatable, Sendable {
        case notModified
        case updated(data: Data, etag: String?)
    }

    public var baseURL: URL
    public var transport: HTTPTransport
    public var userAgent: String

    public init(baseURL: URL = defaultBaseURL, transport: HTTPTransport = URLSessionTransport(), userAgent: String) {
        self.baseURL = baseURL
        self.transport = transport
        self.userAgent = userAgent
    }

    // MARK: Endpoints

    public func upload(guid: String, token: String, samples: [MinuteRollup], utcOffsetSeconds: Int) async throws -> UploadResult {
        precondition(samples.count <= Self.maxSamplesPerRequest)
        struct Body: Encodable {
            var utc_offset_s: Int
            var samples: [Sample]
        }
        struct Sample: Encodable {
            var minute_start: Int64
            var screen_on_s, unlocked_s, attentive_s, key_active_s, key_presses: Int
            var key_distance_m: Double
            var pointer_active_s: Int
            var pointer_distance_m: Double
            var any_active_s: Int
        }
        let body = Body(utc_offset_s: utcOffsetSeconds, samples: samples.map {
            let a = $0.activity
            return Sample(
                minute_start: $0.minuteStart, screen_on_s: a.screenOnSeconds, unlocked_s: a.unlockedSeconds,
                attentive_s: a.attentiveSeconds, key_active_s: a.keyActiveSeconds, key_presses: a.keyPresses,
                key_distance_m: a.keyDistanceMeters, pointer_active_s: a.pointerActiveSeconds,
                pointer_distance_m: a.pointerDistanceMeters, any_active_s: a.anyActiveSeconds
            )
        })
        var req = request("sample/\(guid)", method: "POST", token: token)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(req)
        guard response.statusCode == 200 else { throw Self.error(response, data) }

        struct Response: Decodable {
            struct Rejection: Decodable { var minute_start: Int64; var reason: String? }
            var accepted: [Int64]?
            var rejected: [Rejection]?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw ClientError.invalidResponse }
        var rejected: [Int64: String] = [:]
        for x in r.rejected ?? [] { rejected[x.minute_start] = x.reason ?? "rejected" }
        return UploadResult(accepted: r.accepted ?? [], rejected: rejected)
    }

    public func checkName(guid: String, name: String) async throws -> NameCheck {
        let (data, response) = try await transport.send(request("check/\(guid)/\(Self.encode(name))", method: "GET"))
        guard response.statusCode == 200 else { throw Self.error(response, data) }
        struct Response: Decodable { var name: String?; var available: Bool; var reason: String? }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw ClientError.invalidResponse }
        return NameCheck(name: r.name ?? name, available: r.available, reason: r.reason)
    }

    public func claimName(guid: String, token: String, name: String) async -> NameClaim {
        do {
            let (data, response) = try await transport.send(request("name/\(guid)/\(Self.encode(name))", method: "POST", token: token))
            struct Response: Decodable { var status: String?; var name: String?; var message: String? }
            let r = try? JSONDecoder().decode(Response.self, from: data)
            switch (response.statusCode, r?.status) {
            case (200, "success"): return .success(name: r?.name ?? name)
            case (_, "unavailable"), (409, _): return .unavailable(name: r?.name ?? name)
            default: return .error(message: r?.message ?? "Server responded with HTTP \(response.statusCode)")
            }
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    public func fetchUnits(etag: String?) async throws -> UnitsFetch {
        var req = request("units", method: "GET")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await transport.send(req)
        switch response.statusCode {
        case 304: return .notModified
        case 200: return .updated(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
        default: throw Self.error(response, data)
        }
    }

    // MARK: Helpers

    func request(_ path: String, method: String, token: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(Self.protocolVersion, forHTTPHeaderField: "X-STC-Protocol")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        if let token { req.setValue(token, forHTTPHeaderField: "X-STC-Token") }
        return req
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func error(_ response: HTTPURLResponse, _ data: Data) -> ClientError {
        struct Envelope: Decodable { var message: String? }
        let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.message
        let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return .http(status: response.statusCode, message: message, retryAfter: retry)
    }
}

/// Leaderboard name rules from the protocol: 3–24 chars of letters, digits, space, `_`, `-`, `.`,
/// starting and ending with a letter or digit.
public enum LeaderboardName {
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isValid(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9 _.\-]{1,22})[A-Za-z0-9]$"#, options: .regularExpression) != nil
    }
}
