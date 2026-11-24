import Foundation

/// Result of running one tool: the text fed back to the model plus a UI activity pill.
struct ToolExecutionResult: Sendable {
    let output: String
    let activity: ToolActivity
}

/// Built-in live tools the model can call. No extra API keys needed.
enum AgentTools {

    // MARK: - System prompt

    static func systemPrompt(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        let stamp = formatter.string(from: now)
        let tz = TimeZone.current.identifier

        return """
        You are Trussed Chat, a helpful, accurate AI assistant running in an iOS app.
        Current local date/time: \(stamp) (time zone: \(tz)).

        You have LIVE TOOLS that reach the internet. Never say you lack internet access or real-time data.
        - get_weather: current conditions + 3-day forecast for a US ZIP code or place name.
        - web_search: search the web for news, facts, prices, people, events, or anything that may have changed recently.
        - fetch_webpage: read the text of a specific URL (e.g. a search result) for details.
        - get_current_datetime: exact current local date and time.

        Rules:
        - Whenever the user asks about weather, news, current events, recent facts, dates/times, or a web page, call the right tool first instead of guessing.
        - You may chain tools (e.g. web_search, then fetch_webpage on the best result) before answering.
        - Ground your answer in tool results, mention the source site briefly, and include useful links in Markdown.
        - Be concise and well formatted: short paragraphs, **bold** key facts, bullet lists where helpful.
        """
    }

    // MARK: - Tool definitions (OpenAI function-calling format)

    static var definitions: [[String: Any]] {
        [
            function(
                name: "get_weather",
                description: "Get current weather conditions and a 3-day forecast for a location. Accepts a 5-digit US ZIP code (e.g. 27703) or a city/place name (e.g. 'Boca Raton, FL').",
                properties: ["location": ["type": "string", "description": "US ZIP code or city/place name"]],
                required: ["location"]
            ),
            function(
                name: "web_search",
                description: "Search the web (DuckDuckGo) for current information, news, facts, or links. Returns the top results with titles, URLs and snippets.",
                properties: ["query": ["type": "string", "description": "The search query"]],
                required: ["query"]
            ),
            function(
                name: "fetch_webpage",
                description: "Fetch a web page by URL and return its readable text (truncated to about 4000 characters). Use after web_search to read a result.",
                properties: ["url": ["type": "string", "description": "Full http(s) URL to read"]],
                required: ["url"]
            ),
            function(
                name: "get_current_datetime",
                description: "Get the user's current local date, time, day of week and time zone.",
                properties: [:],
                required: []
            )
        ]
    }

    private static func function(name: String, description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - Labels

    static func progressLabel(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "get_weather":
            return "Checking weather for \(string(arguments["location"]) ?? "location")…"
        case "web_search":
            return "Searching the web for \"\(string(arguments["query"]) ?? "")\"…"
        case "fetch_webpage":
            return "Reading \(host(of: string(arguments["url"]) ?? "") ?? "web page")…"
        case "get_current_datetime":
            return "Checking the current date and time…"
        default:
            return "Running \(name)…"
        }
    }

    private static func icon(for name: String) -> String {
        switch name {
        case "get_weather": return "cloud.sun.fill"
        case "web_search": return "magnifyingglass"
        case "fetch_webpage": return "doc.text.magnifyingglass"
        case "get_current_datetime": return "clock.fill"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private static func doneLabel(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "get_weather": return "Checked weather for \(string(arguments["location"]) ?? "location")"
        case "web_search": return "Searched \"\(string(arguments["query"]) ?? "")\""
        case "fetch_webpage": return "Read \(host(of: string(arguments["url"]) ?? "") ?? "web page")"
        case "get_current_datetime": return "Checked date & time"
        default: return "Ran \(name)"
        }
    }

    // MARK: - Dispatch

    static func parseArguments(_ json: String) -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func execute(name: String, argumentsJSON: String) async -> ToolExecutionResult {
        let args = parseArguments(argumentsJSON)
        var ok = true
        let output: String
        do {
            switch name {
            case "get_weather":
                guard let loc = string(args["location"]), !loc.isEmpty else { throw ToolError("Missing 'location' argument.") }
                output = try await weather(location: loc)
            case "web_search":
                guard let q = string(args["query"]), !q.isEmpty else { throw ToolError("Missing 'query' argument.") }
                output = try await webSearch(query: q)
            case "fetch_webpage":
                guard let u = string(args["url"]), !u.isEmpty else { throw ToolError("Missing 'url' argument.") }
                output = try await fetchWebpage(urlString: u)
            case "get_current_datetime":
                output = currentDateTime()
            default:
                throw ToolError("Unknown tool '\(name)'.")
            }
        } catch {
            ok = false
            output = "Tool error: \(error.localizedDescription)"
        }
        let activity = ToolActivity(
            toolName: name,
            icon: ok ? icon(for: name) : "exclamationmark.triangle.fill",
            label: ok ? doneLabel(name: name, arguments: args) : doneLabel(name: name, arguments: args) + " (failed)",
            succeeded: ok
        )
        return ToolExecutionResult(output: output, activity: activity)
    }

    // MARK: - get_current_datetime

    static func currentDateTime(now: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "EEEE, MMMM d, yyyy"
        let date = f.string(from: now)
        f.dateFormat = "h:mm:ss a"
        let time = f.string(from: now)
        f.dateFormat = "EEEE"
        let weekday = f.string(from: now)
        let tz = TimeZone.current
        let abbr = tz.abbreviation(for: now) ?? ""
        let iso = ISO8601DateFormatter()
        iso.timeZone = tz
        return """
        Date: \(date)
        Time: \(time) \(abbr)
        Day of week: \(weekday)
        Time zone: \(tz.identifier) (\(abbr))
        ISO 8601: \(iso.string(from: now))
        """
    }

    // MARK: - get_weather

    private struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    static func weather(location: String) async throws -> String {
        let place = try await geocode(location)
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m,surface_pressure"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "precipitation_unit", value: "inch"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "3")
        ]
        let json = try await getJSON(comps.url!)
        guard let current = json["current"] as? [String: Any] else { throw ToolError("Weather service returned no current data.") }

        let temp = number(current["temperature_2m"])
        let feels = number(current["apparent_temperature"])
        let humidity = number(current["relative_humidity_2m"])
        let precip = number(current["precipitation"])
        let code = Int(number(current["weather_code"]) ?? -1)
        let wind = number(current["wind_speed_10m"])
        let windDir = number(current["wind_direction_10m"])
        let pressure = number(current["surface_pressure"])
        let observed = current["time"] as? String ?? ""
        let tzName = json["timezone"] as? String ?? ""

        var lines: [String] = []
        lines.append("Location: \(place.name) (lat \(fmt(place.latitude, 4)), lon \(fmt(place.longitude, 4)))")
        lines.append("Observed: \(observed) local time (\(tzName))")
        lines.append("Conditions: \(weatherDescription(code))")
        if let t = temp { lines.append("Temperature: \(fmt(t, 1))°F" + (feels.map { " (feels like \(fmt($0, 1))°F)" } ?? "")) }
        if let h = humidity { lines.append("Humidity: \(Int(h))%") }
        if let w = wind { lines.append("Wind: \(fmt(w, 1)) mph" + (windDir.map { " from the \(compass($0)) (\(Int($0))°)" } ?? "")) }
        if let p = precip { lines.append("Precipitation (current): \(fmt(p, 2)) in") }
        if let p = pressure { lines.append("Surface pressure: \(fmt(p, 1)) hPa (\(fmt(p * 0.0295299830714, 2)) inHg)") }

        if let daily = json["daily"] as? [String: Any],
           let days = daily["time"] as? [String] {
            let codes = daily["weather_code"] as? [Any] ?? []
            let maxs = daily["temperature_2m_max"] as? [Any] ?? []
            let mins = daily["temperature_2m_min"] as? [Any] ?? []
            let pops = daily["precipitation_probability_max"] as? [Any] ?? []
            lines.append("")
            lines.append("3-day forecast:")
            for (i, day) in days.enumerated() {
                let c = i < codes.count ? Int(number(codes[i]) ?? -1) : -1
                let hi = i < maxs.count ? number(maxs[i]) : nil
                let lo = i < mins.count ? number(mins[i]) : nil
                let pop = i < pops.count ? number(pops[i]) : nil
                var s = "- \(dayLabel(day)): \(weatherDescription(c))"
                if let hi, let lo { s += ", high \(Int(hi.rounded()))°F / low \(Int(lo.rounded()))°F" }
                if let pop { s += ", \(Int(pop))% chance of precipitation" }
                lines.append(s)
            }
        }
        lines.append("")
        lines.append("Source: Open-Meteo (open-meteo.com)")
        return lines.joined(separator: "\n")
    }

    private static func geocode(_ location: String) async throws -> Place {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        // 5-digit US ZIP (optionally ZIP+4)
        let zip = String(trimmed.prefix(5))
        if zip.count == 5, zip.allSatisfy(\.isNumber),
           trimmed.count == 5 || (trimmed.count == 10 && trimmed.dropFirst(5).first == "-") {
            let json = try await getJSON(URL(string: "https://api.zippopotam.us/us/\(zip)")!)
            guard let places = json["places"] as? [[String: Any]], let p = places.first,
                  let lat = number(p["latitude"]), let lon = number(p["longitude"]) else {
                throw ToolError("Unknown US ZIP code \(zip).")
            }
            let city = p["place name"] as? String ?? ""
            let state = p["state abbreviation"] as? String ?? ""
            return Place(name: "\(city), \(state) \(zip)", latitude: lat, longitude: lon)
        }

        // City / place name via Open-Meteo geocoding. Try full text, then the part before a comma.
        var candidates = [trimmed]
        if let first = trimmed.split(separator: ",").first {
            let head = first.trimmingCharacters(in: .whitespaces)
            if head != trimmed { candidates.append(head) }
        }
        for name in candidates {
            var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            comps.queryItems = [
                .init(name: "name", value: name),
                .init(name: "count", value: "1"),
                .init(name: "language", value: "en"),
                .init(name: "format", value: "json")
            ]
            let json = try await getJSON(comps.url!)
            if let results = json["results"] as? [[String: Any]], let r = results.first,
               let lat = number(r["latitude"]), let lon = number(r["longitude"]) {
                let parts = [r["name"] as? String, r["admin1"] as? String, r["country"] as? String].compactMap { $0 }
                return Place(name: parts.joined(separator: ", "), latitude: lat, longitude: lon)
            }
        }
        throw ToolError("Could not find a location named \"\(trimmed)\".")
    }

    static func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45: return "Fog"
        case 48: return "Depositing rime fog"
        case 51: return "Light drizzle"
        case 53: return "Moderate drizzle"
        case 55: return "Dense drizzle"
        case 56: return "Light freezing drizzle"
        case 57: return "Dense freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Moderate rain"
        case 65: return "Heavy rain"
        case 66: return "Light freezing rain"
        case 67: return "Heavy freezing rain"
        case 71: return "Light snow"
        case 73: return "Moderate snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light rain showers"
        case 81: return "Moderate rain showers"
        case 82: return "Violent rain showers"
        case 85: return "Light snow showers"
        case 86: return "Heavy snow showers"
        case 95: return "Thunderstorm"
        case 96: return "Thunderstorm with light hail"
        case 99: return "Thunderstorm with heavy hail"
        default: return "Unknown conditions"
        }
    }

    private static func compass(_ degrees: Double) -> String {
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let idx = Int((degrees.truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return dirs[(idx + 16) % 16]
    }

    private static func dayLabel(_ isoDay: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: isoDay) else { return isoDay }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "EEE MMM d"
        return out.string(from: d)
    }

    // MARK: - web_search

    struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static func webSearch(query: String) async throws -> String {
        var results: [SearchResult] = []
        var source = "DuckDuckGo"

        if let html = try? await duckDuckGoHTML(query: query) {
            results = parseDuckDuckGoResults(html)
        }
        if results.isEmpty, let instant = try? await duckDuckGoInstant(query: query) {
            results = instant
            source = "DuckDuckGo Instant Answer"
        }
        if results.isEmpty, let wiki = try? await wikipediaSearch(query: query) {
            results = wiki
            source = "Wikipedia"
        }
        guard !results.isEmpty else { throw ToolError("No search results found for \"\(query)\".") }

        var out = "Top web results for \"\(query)\" (via \(source)):\n"
        for (i, r) in results.prefix(5).enumerated() {
            out += "\n\(i + 1). \(r.title)\n   URL: \(r.url)\n"
            if !r.snippet.isEmpty { out += "   \(r.snippet)\n" }
        }
        out += "\nTip: call fetch_webpage on a URL above for full details."
        return out
    }

    private static func duckDuckGoHTML(query: String) async throws -> String {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [.init(name: "q", value: query)]
        var request = URLRequest(url: comps.url!, timeoutInterval: 15)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw ToolError("DuckDuckGo search unavailable.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseDuckDuckGoResults(_ html: String) -> [SearchResult] {
        // Each organic result: <a ... class="result__a" href="...">Title</a> ... <a class="result__snippet" ...>Snippet</a>
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        var results: [SearchResult] = []
        var seen = Set<String>()
        for block in blocks {
            guard let href = firstMatch(in: block, pattern: "href=\"([^\"]+)\""),
                  let titleHTML = firstMatch(in: block, pattern: ">(.*?)</a>") else { continue }
            let url = resolveDuckDuckGoURL(decodeEntities(href))
            // Skip ads / tracking redirects
            if url.contains("duckduckgo.com/y.js") || url.contains("ad_domain=") { continue }
            guard url.hasPrefix("http"), !seen.contains(url) else { continue }
            seen.insert(url)

            var snippet = ""
            if let snipHTML = firstMatch(in: block, pattern: "class=\"result__snippet\"[^>]*>(.*?)</(?:a|div|td)>") {
                snippet = cleanInline(snipHTML)
            }
            results.append(SearchResult(title: cleanInline(titleHTML), url: url, snippet: snippet))
            if results.count >= 5 { break }
        }
        return results
    }

    private static func resolveDuckDuckGoURL(_ raw: String) -> String {
        var link = raw
        if link.hasPrefix("//") { link = "https:" + link }
        if let comps = URLComponents(string: link),
           let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
           !target.isEmpty {
            return target
        }
        return link
    }

    private static func duckDuckGoInstant(query: String) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "format", value: "json"),
            .init(name: "no_html", value: "1"),
            .init(name: "skip_disambig", value: "1")
        ]
        let json = try await getJSON(comps.url!)
        var results: [SearchResult] = []
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
            let url = (json["AbstractURL"] as? String) ?? ""
            let heading = (json["Heading"] as? String) ?? query
            results.append(SearchResult(title: heading, url: url, snippet: abstract))
        }
        if let answer = json["Answer"] as? String, !answer.isEmpty {
            results.append(SearchResult(title: "Instant answer", url: "https://duckduckgo.com/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")", snippet: answer))
        }
        func collect(_ topics: [[String: Any]]) {
            for t in topics {
                if let nested = t["Topics"] as? [[String: Any]] { collect(nested); continue }
                if let text = t["Text"] as? String, let url = t["FirstURL"] as? String, !text.isEmpty {
                    results.append(SearchResult(title: String(text.prefix(80)), url: url, snippet: text))
                }
            }
        }
        collect(json["RelatedTopics"] as? [[String: Any]] ?? [])
        return Array(results.prefix(5))
    }

    private static func wikipediaSearch(query: String) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            .init(name: "action", value: "opensearch"),
            .init(name: "search", value: query),
            .init(name: "limit", value: "5"),
            .init(name: "namespace", value: "0"),
            .init(name: "format", value: "json")
        ]
        var request = URLRequest(url: comps.url!, timeoutInterval: 15)
        request.setValue("TrussedChat/1.0 (iOS student project)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any], arr.count >= 4,
              let titles = arr[1] as? [String], let urls = arr[3] as? [String] else { return [] }
        let descs = arr[2] as? [String] ?? []
        return zip(titles, urls).enumerated().map { i, pair in
            SearchResult(title: pair.0, url: pair.1, snippet: i < descs.count ? descs[i] : "")
        }
    }

    // MARK: - fetch_webpage

    static func fetchWebpage(urlString: String) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            throw ToolError("Invalid URL. Only http:// or https:// URLs are supported.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw ToolError("The page returned HTTP \(http.statusCode).")
        }
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        var title = ""
        var text: String
        if mime.contains("html") || raw.range(of: "<html", options: .caseInsensitive) != nil {
            if let t = firstMatch(in: raw, pattern: "<title[^>]*>(.*?)</title>") { title = cleanInline(t) }
            let mainHTML = firstMatch(in: raw, pattern: "<main\\b[^>]*>(.*)</main>")
                ?? firstMatch(in: raw, pattern: "<article\\b[^>]*>(.*)</article>")
            text = htmlToText(mainHTML ?? raw)
        } else {
            text = collapseWhitespace(raw)
        }
        let limit = 4000
        let truncated = text.count > limit
        if truncated { text = String(text.prefix(limit)) + "… [truncated]" }
        var out = "URL: \(url.absoluteString)\n"
        if !title.isEmpty { out += "Title: \(title)\n" }
        out += "\n" + (text.isEmpty ? "(No readable text found on this page.)" : text)
        return out
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        for pattern in [
            "<script\\b[^>]*>[\\s\\S]*?</script>",
            "<style\\b[^>]*>[\\s\\S]*?</style>",
            "<noscript\\b[^>]*>[\\s\\S]*?</noscript>",
            "<svg\\b[^>]*>[\\s\\S]*?</svg>",
            "<head\\b[^>]*>[\\s\\S]*?</head>",
            "<nav\\b[^>]*>[\\s\\S]*?</nav>",
            "<footer\\b[^>]*>[\\s\\S]*?</footer>",
            "<aside\\b[^>]*>[\\s\\S]*?</aside>",
            "<form\\b[^>]*>[\\s\\S]*?</form>",
            "<!--[\\s\\S]*?-->"
        ] {
            s = replace(s, pattern: pattern, with: " ")
        }
        s = replace(s, pattern: "<(br|/p|/div|/li|/h[1-6]|/tr)\\b[^>]*>", with: "\n")
        s = replace(s, pattern: "<[^>]+>", with: " ")
        s = decodeEntities(s)
        return collapseWhitespace(s)
    }

    // MARK: - Helpers

    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("TrussedChat/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            if http.statusCode == 404 { return [:] }
            throw ToolError("\(url.host ?? "Service") returned HTTP \(http.statusCode).")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("Unexpected response from \(url.host ?? "service").")
        }
        return obj
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func host(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func cleanInline(_ html: String) -> String {
        collapseWhitespace(decodeEntities(replace(html, pattern: "<[^>]+>", with: "")))
    }

    static func collapseWhitespace(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r", with: "\n")
        s = replace(s, pattern: "[ \\t\\u00A0]+", with: " ")
        s = replace(s, pattern: " *\\n[ \\n]*", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
            "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
            "middot": "·", "bull": "•", "laquo": "«", "raquo": "»"
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let entity = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if entity.hasPrefix("#") {
                let body = entity.dropFirst()
                let value: UInt32?
                if body.hasPrefix("x") || body.hasPrefix("X") {
                    value = UInt32(body.dropFirst(), radix: 16)
                } else {
                    value = UInt32(body, radix: 10)
                }
                if let v = value, let scalar = Unicode.Scalar(v) { replacement = String(Character(scalar)) }
            } else {
                replacement = named[entity.lowercased()]
            }
            result += replacement ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
