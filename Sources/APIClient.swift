import Foundation

public enum AuthAPIClientError: Error {
    case invalidResponse
    case dataTaskError(Error)
    case decodeError(Error)
    case serverError(ServerError)
    case statusCode(Int, Data?)
    case oidcError(OIDCError)
}

enum GrantType: String {
    case authorizationCode = "authorization_code"
    case refreshToken = "refresh_token"
    case anonymous = "urn:authgear:params:oauth:grant-type:anonymous-request"
}

public struct OIDCError: Error, Decodable {
    let error: String
    let errorDescription: String
}

public struct ServerError: Error, Decodable {
    let name: String
    let message: String
    let reason: String
    let info: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case name
        case message
        case reason
        case info
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        message = try values.decode(String.self, forKey: .message)
        reason = try values.decode(String.self, forKey: .reason)
        info = try values.decode([String: Any].self, forKey: .info)
    }
}

enum APIResponse<T: Decodable>: Decodable {
    case result(T)
    case error(ServerError)

    enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.error) {
            self = .error(try container.decode(ServerError.self, forKey: .error))
        } else {
            self = .result(try container.decode(T.self, forKey: .result))
        }
    }

    func toResult() -> Result<T, Error> {
        switch self {
        case let .result(value):
            return .success(value)
        case let .error(error):
            return .failure(AuthAPIClientError.serverError(error))
        }
    }
}

struct OIDCTokenResponse: Decodable {
    let idToken: String?
    let tokenType: String
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
}

struct ChallengeBody: Encodable {
    let purpose: String
}

struct ChallengeResponse: Decodable {
    let token: String
    let expireAt: String
}

struct AppSessionTokenBody: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct AppSessionTokenResponse: Decodable {
    let appSessionToken: String
    let expireAt: String
}

protocol AuthAPIClient: AnyObject {
    var endpoint: URL { get }
    func fetchOIDCConfiguration(handler: @escaping (Result<OIDCConfiguration, Error>) -> Void)
    func requestOIDCToken(
        grantType: GrantType,
        clientId: String,
        redirectURI: String?,
        code: String?,
        codeVerifier: String?,
        refreshToken: String?,
        jwt: String?,
        handler: @escaping (Result<OIDCTokenResponse, Error>) -> Void
    )
    func requestOIDCUserInfo(
        accessToken: String,
        handler: @escaping (Result<UserInfo, Error>) -> Void
    )
    func requestOIDCRevocation(
        refreshToken: String,
        handler: @escaping (Result<Void, Error>) -> Void
    )
    func requestOAuthChallenge(
        purpose: String,
        handler: @escaping (Result<ChallengeResponse, Error>) -> Void
    )
    func requestAppSessionToken(
        refreshToken: String,
        handler: @escaping (Result<AppSessionTokenResponse, Error>) -> Void
    )
    func requestWeChatAuthCallback(
        code: String,
        state: String,
        handler: @escaping (Result<Void, Error>) -> Void
    )
}

extension AuthAPIClient {
    private func withSemaphore<T>(
        asynTask: (@escaping (Result<T, Error>) -> Void) -> Void
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)

        var returnValue: Result<T, Error>?
        asynTask { result in
            returnValue = result
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .distantFuture)
        return try returnValue!.get()
    }

    func syncFetchOIDCConfiguration() throws -> OIDCConfiguration {
        try withSemaphore { handler in
            self.fetchOIDCConfiguration(handler: handler)
        }
    }

    func syncRequestOIDCToken(
        grantType: GrantType,
        clientId: String,
        redirectURI: String?,
        code: String?,
        codeVerifier: String?,
        refreshToken: String?,
        jwt: String?
    ) throws -> OIDCTokenResponse {
        try withSemaphore { handler in
            self.requestOIDCToken(
                grantType: grantType,
                clientId: clientId,
                redirectURI: redirectURI,
                code: code,
                codeVerifier: codeVerifier,
                refreshToken: refreshToken,
                jwt: jwt,
                handler: handler
            )
        }
    }

    func syncRequestOIDCUserInfo(
        accessToken: String
    ) throws -> UserInfo {
        try withSemaphore { handler in
            self.requestOIDCUserInfo(
                accessToken: accessToken,
                handler: handler
            )
        }
    }

    func syncRequestOIDCRevocation(
        refreshToken: String
    ) throws {
        try withSemaphore { handler in
            self.requestOIDCRevocation(
                refreshToken: refreshToken,
                handler: handler
            )
        }
    }

    func syncRequestOAuthChallenge(
        purpose: String
    ) throws -> ChallengeResponse {
        try withSemaphore { handler in
            self.requestOAuthChallenge(
                purpose: purpose,
                handler: handler
            )
        }
    }

    func syncRequestAppSessionToken(
        refreshToken: String
    ) throws -> AppSessionTokenResponse {
        try withSemaphore { handler in
            self.requestAppSessionToken(
                refreshToken: refreshToken,
                handler: handler
            )
        }
    }

    func syncRequestWeChatAuthCallback(code: String, state: String) throws {
        try withSemaphore { handler in
            self.requestWeChatAuthCallback(
                code: code, state: state,
                handler: handler
            )
        }
    }
}

protocol AuthAPIClientDelegate: AnyObject {
    func getAccessToken() -> String?
    func shouldRefreshAccessToken() -> Bool
    func refreshAccessToken(handler: VoidCompletionHandler?)
}

class DefaultAuthAPIClient: AuthAPIClient {
    public let endpoint: URL

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    private let defaultSession = URLSession(configuration: .default)
    private var oidcConfiguration: OIDCConfiguration?

    weak var delegate: AuthAPIClientDelegate?

    private func buildFetchOIDCConfigurationRequest() -> URLRequest {
        URLRequest(url: endpoint.appendingPathComponent("/.well-known/openid-configuration"))
    }

    func fetchOIDCConfiguration(handler: @escaping (Result<OIDCConfiguration, Error>) -> Void) {
        if let configuration = oidcConfiguration {
            return handler(.success(configuration))
        }

        let request = buildFetchOIDCConfigurationRequest()

        fetch(request: request) { [weak self] (result: Result<OIDCConfiguration, Error>) in
            self?.oidcConfiguration = try? result.get()
            return handler(result)
        }
    }

    func fetch(
        request: URLRequest,
        handler: @escaping (Result<(Data?, HTTPURLResponse), Error>) -> Void
    ) {
        let dataTaslk = defaultSession.dataTask(with: request) { data, response, error in

            guard let response = response as? HTTPURLResponse else {
                return handler(.failure(AuthAPIClientError.invalidResponse))
            }

            if response.statusCode < 200 || response.statusCode >= 300 {
                if let data = data {
                    let decorder = JSONDecoder()
                    decorder.keyDecodingStrategy = .convertFromSnakeCase
                    if let error = try? decorder.decode(OIDCError.self, from: data) {
                        return handler(.failure(AuthAPIClientError.oidcError(error)))
                    }
                }
                return handler(.failure(AuthAPIClientError.statusCode(response.statusCode, data)))
            }

            if let error = error {
                return handler(.failure(AuthAPIClientError.dataTaskError(error)))
            }

            return handler(.success((data, response)))
        }

        dataTaslk.resume()
    }

    func fetch<T: Decodable>(
        request: URLRequest,
        keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .convertFromSnakeCase,
        handler: @escaping (Result<T, Error>) -> Void
    ) {
        fetch(request: request) { result in
            handler(result.flatMap { (data, _) -> Result<T, Error> in
                do {
                    let decorder = JSONDecoder()
                    decorder.keyDecodingStrategy = keyDecodingStrategy
                    let response = try decorder.decode(T.self, from: data!)
                    return .success(response)
                } catch {
                    return .failure(AuthAPIClientError.decodeError(error))
                }
            })
        }
    }

    func refreshAccessTokenIfNeeded(handler: @escaping (Result<Void, Error>) -> Void) {
        if let delegate = self.delegate,
           delegate.shouldRefreshAccessToken() {
            delegate.refreshAccessToken { result in
                switch result {
                case .success:
                    return handler(.success(()))
                case let .failure(error):
                    return handler(.failure(error))
                }
            }
        }
        return handler(.success(()))
    }

    func fetchWithRefreshToken(
        request: URLRequest,
        handler: @escaping (Result<(Data?, HTTPURLResponse), Error>) -> Void
    ) {
        refreshAccessTokenIfNeeded { [weak self] result in
            switch result {
            case .success:
                var request = request
                if let accessToken = self?.delegate?.getAccessToken() {
                    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
                }

                self?.fetch(request: request, handler: handler)
            case let .failure(error):
                return handler(.failure(error))
            }
        }
    }

    func requestOIDCToken(
        grantType: GrantType,
        clientId: String,
        redirectURI: String? = nil,
        code: String? = nil,
        codeVerifier: String? = nil,
        refreshToken: String? = nil,
        jwt: String? = nil,
        handler: @escaping (Result<OIDCTokenResponse, Error>) -> Void
    ) {
        fetchOIDCConfiguration { [weak self] result in
            switch result {
            case let .success(config):
                var queryParams = [String: String]()
                queryParams["client_id"] = clientId
                queryParams["grant_type"] = grantType.rawValue

                if let code = code {
                    queryParams["code"] = code
                }

                if let redirectURI = redirectURI {
                    queryParams["redirect_uri"] = redirectURI
                }

                if let codeVerifier = codeVerifier {
                    queryParams["code_verifier"] = codeVerifier
                }

                if let refreshToken = refreshToken {
                    queryParams["refresh_token"] = refreshToken
                }

                if let jwt = jwt {
                    queryParams["jwt"] = jwt
                }

                var urlComponents = URLComponents()
                urlComponents.queryParams = queryParams

                let body = urlComponents.query?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.data(using: .utf8)

                var urlRequest = URLRequest(url: config.tokenEndpoint)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue(
                    "application/x-www-form-urlencoded",
                    forHTTPHeaderField: "content-type"
                )
                urlRequest.httpBody = body

                self?.fetch(request: urlRequest, handler: handler)

            case let .failure(error):
                return handler(.failure(error))
            }
        }
    }

    func requestOIDCUserInfo(
        accessToken: String,
        handler: @escaping (Result<UserInfo, Error>) -> Void
    ) {
        fetchOIDCConfiguration { [weak self] result in
            switch result {
            case let .success(config):
                var urlRequest = URLRequest(url: config.userinfoEndpoint)
                urlRequest.setValue(
                    "Bearer \(accessToken)",
                    forHTTPHeaderField: "authorization"
                )
                self?.fetch(request: urlRequest, keyDecodingStrategy: .useDefaultKeys, handler: handler)

            case let .failure(error):
                return handler(.failure(error))
            }
        }
    }

    func requestOIDCRevocation(
        refreshToken: String,
        handler: @escaping (Result<Void, Error>) -> Void
    ) {
        fetchOIDCConfiguration { [weak self] result in
            switch result {
            case let .success(config):

                var urlComponents = URLComponents()
                urlComponents.queryParams = ["token": refreshToken]

                let body = urlComponents.query?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.data(using: .utf8)

                var urlRequest = URLRequest(url: config.revocationEndpoint)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue(
                    "application/x-www-form-urlencoded",
                    forHTTPHeaderField: "content-type"
                )
                urlRequest.httpBody = body

                self?.fetch(request: urlRequest, handler: { result in
                    handler(result.map { _ in () })
                })
            case let .failure(error):
                return handler(.failure(error))
            }
        }
    }

    func requestOAuthChallenge(
        purpose: String,
        handler: @escaping (Result<ChallengeResponse, Error>) -> Void
    ) {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("/oauth2/challenge"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try? JSONEncoder().encode(ChallengeBody(purpose: purpose))

        fetch(request: urlRequest, handler: { (result: Result<APIResponse<ChallengeResponse>, Error>) in
            handler(result.flatMap { $0.toResult() })
        })
    }

    func requestAppSessionToken(
        refreshToken: String,
        handler: @escaping (Result<AppSessionTokenResponse, Error>) -> Void
    ) {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("/oauth2/app_session_token"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try? JSONEncoder().encode(AppSessionTokenBody(refreshToken: refreshToken))

        fetch(request: urlRequest, handler: { (result: Result<APIResponse<AppSessionTokenResponse>, Error>) in
            handler(result.flatMap { $0.toResult() })
        })
    }

    func requestWeChatAuthCallback(code: String, state: String, handler: @escaping (Result<Void, Error>) -> Void) {
        let queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "x_platform", value: "ios")
        ]
        var urlComponents = URLComponents()
        urlComponents.queryItems = queryItems

        let u = endpoint.appendingPathComponent("/sso/wechat/callback")
        var urlRequest = URLRequest(url: u)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "content-type"
        )
        urlRequest.httpBody = urlComponents.query?.data(using: .utf8)
        fetch(request: urlRequest, handler: { result in
            handler(result.map { _ in () })
        })
    }
}
