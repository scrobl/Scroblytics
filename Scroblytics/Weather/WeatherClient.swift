import Foundation

/// Where the weather comes from. Open-Meteo is free for apps like this one (no account, no key) and asks that its data be credited.
/// Everything sent is a rounded coordinate and a range of dates (or, when searching for a place, the name that was typed): never
/// anything about what was listened to.
enum WeatherAttribution {
    static let text = "Weather data by Open-Meteo.com"
    static let url = URL(string: "https://open-meteo.com/")!
    static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
}

enum WeatherError: Error, LocalizedError, Equatable {
    case offline
    case rateLimited
    case http(Int)
    case rejected(String)
    case unreadable
    case network

    var errorDescription: String? {
        switch self {
        case .offline: "Offline mode is on."
        case .rateLimited: "The weather service is limiting requests right now. It will try again later."
        case .http(let code): "The weather service answered with an error (\(code))."
        case .rejected(let reason): "The weather service refused the request: \(reason)"
        case .unreadable: "The weather service sent an answer the app couldn’t read."
        case .network: "Couldn’t reach the weather service. Check your internet connection."
        }
    }
}

/// One matching place from a search by name.
struct GeocodeResult: Equatable, Sendable, Identifiable {
    let name: String
    let region: String?
    let country: String?
    let latitude: Double
    let longitude: Double
    let population: Int?

    var id: String { "\(latitude),\(longitude),\(name)" }

    /// "Oslo, Oslo, Norway": the place, its region and its country, without repeating a part.
    var label: String {
        var parts = [name]
        for part in [region, country] { if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) } }
        return parts.joined(separator: ", ")
    }

    var place: WeatherPlace { WeatherPlace(name: label, latitude: latitude, longitude: longitude) }
}

/// A request to Open-Meteo. Built in one place so a check can look at exactly what would be sent.
struct WeatherClient: Sendable {
    struct Endpoints: Sendable {
        var archive = URL(string: "https://archive-api.open-meteo.com/v1/archive")!
        var recent = URL(string: "https://api.open-meteo.com/v1/forecast")!
        var geocoding = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
    }

    static let hourlyVariables = "temperature_2m,precipitation,rain,snowfall,weather_code"

    var endpoints = Endpoints()
    var session: URLSession = WeatherClient.makeSession()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    // MARK: Requests

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func dayString(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The request for the archive (settled historical data) over whole UTC days, `from` through `to` inclusive.
    func archiveRequest(place: WeatherPlace, from: Date, to: Date) -> URLRequest {
        request(endpoints.archive, [
            "latitude": String(format: "%.1f", place.latitude), "longitude": String(format: "%.1f", place.longitude),
            "start_date": Self.dayString(from), "end_date": Self.dayString(to),
            "hourly": Self.hourlyVariables, "timezone": "GMT",
        ])
    }

    /// The request for the last few days, which the archive doesn't have yet.
    func recentRequest(place: WeatherPlace, pastDays: Int) -> URLRequest {
        request(endpoints.recent, [
            "latitude": String(format: "%.1f", place.latitude), "longitude": String(format: "%.1f", place.longitude),
            "past_days": String(max(1, min(92, pastDays))), "forecast_days": "1",
            "hourly": Self.hourlyVariables, "timezone": "GMT",
        ])
    }

    func searchRequest(name: String) -> URLRequest {
        request(endpoints.geocoding, ["name": name, "count": "8", "language": "en", "format": "json"])
    }

    private func request(_ base: URL, _ query: [String: String]) -> URLRequest {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("Scroblytics/\(AppVersion.running)", forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: Sending

    /// Sends a request, always starting with the Offline-mode gate, and reports how it went. Failures to connect are never an answer.
    func send(_ request: URLRequest) async throws -> Data {
        let host = request.url?.host
        do { try ConnectivityGate.check(host: host) } catch { throw WeatherError.offline }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            ConnectivityHub.reportSuccess()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ConnectivityHub.report(error, host: host, source: "Weather")
            throw WeatherError.network
        }
        guard let http = response as? HTTPURLResponse else { throw WeatherError.unreadable }
        switch http.statusCode {
        case 200: return data
        case 429: throw WeatherError.rateLimited
        case 400:
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.reason
            throw WeatherError.rejected(reason ?? "bad request")
        default: throw WeatherError.http(http.statusCode)
        }
    }

    private struct ErrorBody: Decodable { let reason: String? }

    func search(name: String) async throws -> [GeocodeResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        return try Self.parseSearch(try await send(searchRequest(name: trimmed)))
    }

    /// Hours for whole UTC days from the archive.
    func fetchArchive(place: WeatherPlace, from: Date, to: Date) async throws -> [(hour: Int, sample: WeatherSample)] {
        try Self.parseHourly(try await send(archiveRequest(place: place, from: from, to: to)))
    }

    /// Hours for the last `pastDays` days (and the rest of today, which the caller leaves out).
    func fetchRecent(place: WeatherPlace, pastDays: Int) async throws -> [(hour: Int, sample: WeatherSample)] {
        try Self.parseHourly(try await send(recentRequest(place: place, pastDays: pastDays)))
    }

    // MARK: Reading answers

    private struct SearchBody: Decodable {
        struct Item: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
            let population: Int?
        }
        let results: [Item]?
    }

    static func parseSearch(_ data: Data) throws -> [GeocodeResult] {
        guard let body = try? JSONDecoder().decode(SearchBody.self, from: data) else { throw WeatherError.unreadable }
        return (body.results ?? []).filter { WeatherPlace.isValid(latitude: $0.latitude, longitude: $0.longitude) }
            .map { GeocodeResult(name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude, population: $0.population) }
    }

    private struct HourlyBody: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]?
            let precipitation: [Double?]?
            let rain: [Double?]?
            let snowfall: [Double?]?
            let weather_code: [Double?]?
        }
        let hourly: Hourly
    }

    /// The hours in an answer (times are UTC because every request asks for GMT). A value the service has no number for stays nil.
    static func parseHourly(_ data: Data) throws -> [(hour: Int, sample: WeatherSample)] {
        guard let body = try? JSONDecoder().decode(HourlyBody.self, from: data) else { throw WeatherError.unreadable }
        let h = body.hourly
        var out: [(hour: Int, sample: WeatherSample)] = []
        out.reserveCapacity(h.time.count)
        func value(_ array: [Double?]?, _ i: Int) -> Double? { array.flatMap { i < $0.count ? $0[i] : nil } }
        for (i, text) in h.time.enumerated() {
            guard let hour = hourNumber(text) else { throw WeatherError.unreadable }
            out.append((hour, WeatherSample(
                temperature: value(h.temperature_2m, i), precipitation: value(h.precipitation, i), rain: value(h.rain, i),
                snowfall: value(h.snowfall, i), code: value(h.weather_code, i).map { Int($0.rounded()) }
            )))
        }
        return out
    }

    /// "2024-03-05T14:00" (UTC) as hours since 1970, with plain integer arithmetic (an archive year is 8,784 of these).
    static func hourNumber(_ text: String) -> Int? {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" })
        guard parts.count >= 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), let hour = Int(parts[3]),
              (1...12).contains(m), (1...31).contains(d), (0...23).contains(hour) else { return nil }
        // Days from 1970-01-01 to y-m-d (the proleptic Gregorian calendar).
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return days * 24 + hour
    }
}
