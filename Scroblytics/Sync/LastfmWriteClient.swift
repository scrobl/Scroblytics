import Foundation

/// Signed write/auth calls against Last.fm — `track.love`/`unlove`,
/// `*.addTags`/`*.removeTag`, `track.scrobble`, and the desktop auth flow
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

    // MARK: Scrobbling

    /// One play to submit: when it started (seconds since 1970, UTC), and what it was.
    struct ScrobbleSubmission: Sendable, Equatable {
        let artist: String
        let track: String
        let album: String?
        let timestamp: Int
    }

    /// What Last.fm did with one submitted play. `ignoredCode` is Last.fm's own: 1 artist ignored, 2 track ignored, 3 timestamp too
    /// old, 4 too new, 5 daily limit reached; nil when the play was accepted.
    struct ScrobbleOutcome: Sendable, Equatable {
        let accepted: Bool
        let ignoredCode: Int?
        let message: String
    }

    /// Last.fm takes at most this many plays in one `track.scrobble` call.
    static let maxScrobblesPerCall = 50

    /// The form fields of one `track.scrobble` call: the plays as numbered fields (`artist[0]`, `track[0]`, `timestamp[0]`, and
    /// `album[0]` when there is one). The signature is computed over exactly these (plus `api_sig`'s own exclusions), by `signedData`.
    static func scrobbleParameters(apiKey: String, sessionKey: String, plays: [ScrobbleSubmission]) -> [String: String] {
        var params: [String: String] = ["method": "track.scrobble", "api_key": apiKey, "sk": sessionKey]
        for (i, play) in plays.enumerated() {
            params["artist[\(i)]"] = play.artist
            params["track[\(i)]"] = play.track
            params["timestamp[\(i)]"] = String(play.timestamp)
            if let album = play.album, !album.isEmpty { params["album[\(i)]"] = album }
        }
        return params
    }

    /// Reads Last.fm's answer to a scrobble call into one outcome per submitted play, in order. Last.fm answers with a single object, not
    /// a list, when only one play was sent, and its codes may be numbers or text, so this reads the JSON loosely. A count that doesn't
    /// match what was sent is an error, never a guess about which plays were taken.
    static func parseScrobbleResponse(_ data: Data, expected: Int) throws -> [ScrobbleOutcome] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scrobbles = root["scrobbles"] as? [String: Any] else { throw LastfmAPIError.malformedField("scrobbles") }
        let rawItems: [[String: Any]]
        switch scrobbles["scrobble"] {
        case let list as [[String: Any]]: rawItems = list
        case let one as [String: Any]: rawItems = [one]
        default: rawItems = []
        }
        guard rawItems.count == expected else { throw LastfmAPIError.malformedField("scrobble count \(rawItems.count), expected \(expected)") }
        return rawItems.map { item in
            let message = item["ignoredMessage"] as? [String: Any]
            let code: Int
            switch message?["code"] {
            case let n as Int: code = n
            case let text as String: code = Int(text) ?? 0
            default: code = 0
            }
            let text = (message?["#text"] as? String) ?? ""
            return ScrobbleOutcome(accepted: code == 0, ignoredCode: code == 0 ? nil : code, message: text)
        }
    }

    /// Submits up to 50 plays in one signed POST and returns what Last.fm did with each. A play Last.fm ignores is NOT an error: it comes
    /// back as an outcome with a code. A thrown error means the call as a whole failed (and, after a dropped connection, that it is
    /// not known whether Last.fm took the plays).
    static func scrobble(apiKey: String, secret: String, sessionKey: String, plays: [ScrobbleSubmission]) async throws -> [ScrobbleOutcome] {
        guard !plays.isEmpty else { return [] }
        precondition(plays.count <= maxScrobblesPerCall, "Last.fm takes at most \(maxScrobblesPerCall) scrobbles per call")
        let data = try await signedData(params: scrobbleParameters(apiKey: apiKey, sessionKey: sessionKey, plays: plays), secret: secret, httpMethod: "POST")
        return try parseScrobbleResponse(data, expected: plays.count)
    }

    /// Last.fm's write-method responses are just `{"status": "ok"}` shapes we
    /// don't need any field from — this only exists so `signedRequest`'s
    /// generic decode step has something to decode into without failing on
    /// an empty/irrelevant body.
    private struct EmptyResponse: Decodable {}

    private static func signedRequest<T: Decodable>(
        params: [String: String], secret: String, httpMethod: String
    ) async throws -> T {
        let data = try await signedData(params: params, secret: secret, httpMethod: httpMethod)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LastfmAPIError.decoding(error)
        }
    }

    /// Signs and sends one call, and returns the body of a successful answer; Last.fm's error answers and HTTP failures throw.
    private static func signedData(params: [String: String], secret: String, httpMethod: String) async throws -> Data {
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
        return data
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
