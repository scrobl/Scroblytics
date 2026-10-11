import Foundation

/// Signed write/auth calls against Last.fm — `track.love`/`unlove`,
/// `*.addTags`/`*.removeTag`, and the desktop auth flow
/// (`auth.getToken`/`auth.getSession`) that produces the session key every
/// one of those write calls needs. Stateless functions
/// taking `apiKey`/`secret`/`sessionKey` explicitly rather than a
/// stored-credential client, since a write call's identity (which account,
/// which key) must always come from whatever the caller just loaded from
/// Keychain, never from client state that could go stale.
///
/// Reading (loved status, tags, scrobbles) only ever needs the public API
/// key — mutating anything on Last.fm's side needs a signed request carrying
/// a session key, obtained via the standard desktop auth flow: auth.getToken
/// -> user approves in a browser -> auth.getSession.
enum LastfmWriteClient {
    private static let base = LastfmEndpoint.base
    private static let authBase = "https://www.last.fm/api/auth/"

    private struct TokenResponse: Decodable { let token: String }
    private struct SessionResponse: Decodable {
        struct Session: Decodable { let key: String }
        let session: Session
    }
    private struct ErrorResponse: Decodable { let error: Int; let message: String }

    /// Requests a fresh auth token — step 1 of the desktop auth flow. GET
    /// (only the four true write calls below use POST).
    static func getAuthToken(apiKey: String, secret: String) async throws -> String {
        let response: TokenResponse = try await signedRequest(
            params: ["method": "auth.getToken", "api_key": apiKey], secret: secret, httpMethod: "GET"
        )
        return response.token
    }

    /// The page the user must open and approve in a browser before
    /// `getAuthSession` will succeed.
    static func authURL(apiKey: String, token: String) -> URL {
        var components = URLComponents(string: authBase)!
        components.queryItems = [.init(name: "api_key", value: apiKey), .init(name: "token", value: token)]
        return components.url!
    }

    /// Exchanges an approved token for a permanent session key — step 3 of
    /// the desktop auth flow, called only after the user has approved access
    /// at `authURL` in step 2. GET.
    static func getAuthSession(apiKey: String, secret: String, token: String) async throws -> String {
        let response: SessionResponse = try await signedRequest(
            params: ["method": "auth.getSession", "api_key": apiKey, "token": token], secret: secret, httpMethod: "GET"
        )
        return response.session.key
    }

    /// Loves the exact artist/track pair given on Last.fm.
    static func loveTrack(apiKey: String, secret: String, sessionKey: String, artist: String, track: String) async throws {
        let params: [String: String] = ["method": "track.love", "api_key": apiKey, "sk": sessionKey, "artist": artist, "track": track]
        let _: EmptyResponse = try await signedRequest(params: params, secret: secret, httpMethod: "POST")
    }

    /// Unloves the EXACT artist/track pair given — no autocorrect/redirect,
    /// unlike Last.fm's own website, which is what lets this clear a
    /// phantom/mistitled loved entry the site itself can no longer navigate
    /// to directly.
    static func unloveTrack(apiKey: String, secret: String, sessionKey: String, artist: String, track: String) async throws {
        let params: [String: String] = ["method": "track.unlove", "api_key": apiKey, "sk": sessionKey, "artist": artist, "track": track]
        let _: EmptyResponse = try await signedRequest(params: params, secret: secret, httpMethod: "POST")
    }

    /// Adds up to 10 already-normalized tags in one signed call. Caller is
    /// responsible for chunking longer lists and for trim/lowercase
    /// normalization (`LastfmTagNormalization`) — this just sends exactly
    /// what it's given, capped defensively at Last.fm's documented limit.
    static func addTags(
        apiKey: String, secret: String, sessionKey: String, entity: TopChartsEntity,
        artist: String, album: String?, track: String?, tags: [String]
    ) async throws {
        let capped = Array(tags.prefix(LastfmTagNormalization.maxTagsPerCall))
        guard !capped.isEmpty else { return }
        var params: [String: String] = [
            "api_key": apiKey, "sk": sessionKey, "artist": artist, "tags": capped.joined(separator: ","),
        ]
        switch entity {
        case .artist: params["method"] = "artist.addTags"
        case .album:
            params["method"] = "album.addTags"
            params["album"] = album ?? ""
        case .track:
            params["method"] = "track.addTags"
            params["track"] = track ?? ""
        }
        let _: EmptyResponse = try await signedRequest(params: params, secret: secret, httpMethod: "POST")
    }

    /// Removes a single already-normalized personal tag from an entity.
    static func removeTag(
        apiKey: String, secret: String, sessionKey: String, entity: TopChartsEntity,
        artist: String, album: String?, track: String?, tag: String
    ) async throws {
        var params: [String: String] = ["api_key": apiKey, "sk": sessionKey, "artist": artist, "tag": tag]
        switch entity {
        case .artist: params["method"] = "artist.removeTag"
        case .album:
            params["method"] = "album.removeTag"
            params["album"] = album ?? ""
        case .track:
            params["method"] = "track.removeTag"
            params["track"] = track ?? ""
        }
        let _: EmptyResponse = try await signedRequest(params: params, secret: secret, httpMethod: "POST")
    }

    /// Last.fm's write-method responses are just `{"status": "ok"}` shapes we
    /// don't need any field from — this only exists so `signedRequest`'s
    /// generic decode step has something to decode into without failing on
    /// an empty/irrelevant body.
    private struct EmptyResponse: Decodable {}

    private static func signedRequest<T: Decodable>(
        params: [String: String], secret: String, httpMethod: String
    ) async throws -> T {
        let apiSig = LastfmSigning.sign(params: params, secret: secret)
        var body = params
        body["api_sig"] = apiSig
        body["format"] = "json"
        try ConnectivityGate.check(host: LastfmEndpoint.host)

        let data: Data
        let response: URLResponse
        do {
            if httpMethod == "POST" {
                var request = URLRequest(url: URL(string: base)!)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = formEncode(body).data(using: .utf8)
                (data, response) = try await URLSession.shared.data(for: request)
            } else {
                var components = URLComponents(string: base)!
                components.queryItems = body.map { .init(name: $0.key, value: $0.value) }
                (data, response) = try await URLSession.shared.data(from: components.url!)
            }
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: LastfmEndpoint.host, source: "Last.fm")
            throw LastfmAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw LastfmAPIError.invalidResponse }
        let decoder = JSONDecoder()
        if let apiError = try? decoder.decode(ErrorResponse.self, from: data) {
            throw LastfmAPIError.api(code: apiError.error, message: apiError.message)
        }
        guard (200..<300).contains(http.statusCode) else { throw LastfmAPIError.http(http.statusCode) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LastfmAPIError.decoding(error)
        }
    }

    /// Standard `application/x-www-form-urlencoded` encoding — percent-encodes
    /// values for TRANSPORT only, entirely separate from (and after) the
    /// signature, which is computed over the raw, un-encoded UTF-8 text.
    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
