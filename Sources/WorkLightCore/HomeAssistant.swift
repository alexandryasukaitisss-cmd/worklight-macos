import Foundation
import Security

public struct BearerToken: Sendable, Equatable {
    public let value: String

    public init(data: Data) throws {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else {
            throw LampError.credential
        }
        try self.init(string: text)
    }

    public init(string: String) throws {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{00A0}\u{FEFF}"))
        guard (16...4096).contains(trimmed.utf8.count), trimmed.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 126].contains($0)
        }) else {
            throw LampError.credential
        }
        self.value = trimmed
    }
}

public protocol TokenStore: Sendable {
    func loadToken() throws -> BearerToken
    func saveToken(_ raw: String) throws
    func deleteToken() throws
    func hasToken() -> Bool
}

public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public let fallbackFileURL: URL?

    public init(
        service: String = "io.github.worklight.WorkLight",
        account: String = "home-assistant-token",
        fallbackFileURL: URL? = KeychainTokenStore.defaultFallbackURL()
    ) {
        self.service = service
        self.account = account
        self.fallbackFileURL = fallbackFileURL
    }

    public static func defaultFallbackURL() -> URL {
        if let envPath = ProcessInfo.processInfo.environment["WORKLIGHT_HA_TOKEN_FILE"], !envPath.isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/worklight/token")
    }

    public func loadToken() throws -> BearerToken {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try BearerToken(data: data)
        }
        if let fallbackFileURL, let data = try? Data(contentsOf: fallbackFileURL) {
            return try BearerToken(data: data)
        }
        throw LampError.credential
    }

    public func saveToken(_ raw: String) throws {
        let token = try BearerToken(string: raw)
        let data = Data(token.value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw LampError.credential }
        } else if updateStatus != errSecSuccess {
            throw LampError.credential
        }
    }

    public func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LampError.credential
        }
    }

    public func hasToken() -> Bool {
        (try? loadToken()) != nil
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public protocol LightTransportClient: Sendable {
    func read(endpoint: HomeAssistantEndpoint) async throws -> LampReport
    func apply(_ output: LampOutput, endpoint: HomeAssistantEndpoint) async throws -> LampReport
}

public struct HomeAssistantLight: LightTransportClient, Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public struct LightCommand: Encodable {
        public let entityID: String
        public var brightness: Int?
        public var rgb: [Int]?
        public var kelvin: Int?
        public var effect: String?

        public init(entityID: String, output: LampOutput, useMiotEffects: Bool) {
            self.entityID = entityID
            self.brightness = output.brightness
            switch output {
            case .off:
                break
            case let .color(value, _):
                rgb = value.channels
                if useMiotEffects { effect = "Color" }
            case let .white(value, _):
                kelvin = value
                if useMiotEffects { effect = "Day" }
            }
        }

        enum CodingKeys: String, CodingKey {
            case entityID = "entity_id"
            case brightness = "brightness_pct"
            case rgb = "rgb_color"
            case kelvin = "color_temp_kelvin"
            case effect
        }
    }

    public let credential: @Sendable () throws -> BearerToken
    public let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        credential: @escaping @Sendable () throws -> BearerToken = { try KeychainTokenStore().loadToken() },
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.credential = credential
        self.transport = transport ?? { try await Self.session.data(for: $0) }
    }

    public func read(endpoint: HomeAssistantEndpoint) async throws -> LampReport {
        guard let baseURL = endpoint.normalizedBaseURL,
              let entityID = endpoint.normalizedEntityID else {
            throw LampError.notConfigured
        }
        let report: LampReport = try await request(baseURL: baseURL, path: "api/states/\(entityID)")
        guard valid(report, expectedEntityID: entityID) else { throw LampError.response }
        if report.state == "unavailable" || report.state == "unknown" { throw LampError.unavailable }
        return report
    }

    public func apply(_ output: LampOutput, endpoint: HomeAssistantEndpoint) async throws -> LampReport {
        guard output.isValid else { throw LampError.invalidPreset }
        guard let baseURL = endpoint.normalizedBaseURL,
              let entityID = endpoint.normalizedEntityID else {
            throw LampError.notConfigured
        }
        let command = try JSONEncoder().encode(
            LightCommand(entityID: entityID, output: output, useMiotEffects: endpoint.useMiotEffects)
        )
        let action = output == .off ? "turn_off" : "turn_on"
        let changes: [LampReport] = try await request(
            baseURL: baseURL,
            path: "api/services/light/\(action)",
            body: command
        )
        if let report = changes.last(where: { valid($0, expectedEntityID: entityID) }),
           report.acknowledges(output, miotEffects: endpoint.useMiotEffects) {
            return report
        }
        let report = try await read(endpoint: endpoint)
        guard report.output?.matches(output) == true else { throw LampError.unconfirmed }
        return report
    }

    private func valid(_ report: LampReport, expectedEntityID: String) -> Bool {
        guard report.entityID == expectedEntityID,
              ["on", "off", "unavailable", "unknown"].contains(report.state),
              (20...40).contains(report.revision.utf8.count) else {
            return false
        }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(report.revision)) != nil
            || (try? Date.ISO8601FormatStyle().parse(report.revision)) != nil
    }

    private func request<T: Decodable>(baseURL: URL, path: String, body: Data? = nil) async throws -> T {
        let token = try credential()
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do {
            result = try await transport(request)
        } catch {
            throw LampError.connection
        }
        guard let response = result.1 as? HTTPURLResponse, response.url == url else {
            throw LampError.response
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw LampError.denied }
        if response.statusCode == 404 { throw LampError.unavailable }
        guard response.statusCode == 200, result.0.count <= 131_072 else {
            throw LampError.response
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: result.0) else {
            throw LampError.response
        }
        return decoded
    }
}
