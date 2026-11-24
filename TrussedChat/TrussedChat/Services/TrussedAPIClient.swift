import Foundation

enum LLMProvider: String, CaseIterable, Identifiable {
    case faullm
    case chatgpt
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .faullm: return "FAU LLM"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    var defaultModel: String {
        switch self {
        case .faullm: return "gemma4-vibe"
        case .chatgpt: return "gpt-5.6-luna"
        case .gemini: return "gemini-3.8-flash"
        }
    }

    var envKeyName: String {
        switch self {
        case .faullm: return "FAULLM_API_KEY"
        case .chatgpt: return "CHATGPT_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }
}

enum TrussedAPIError: LocalizedError {
    case missingAPIKey(LLMProvider)
    case invalidURL
    case invalidResponse
    case httpError(status: Int, body: String)
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider.displayName)."
        case .invalidURL:
            return "The endpoint URL is invalid."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .httpError(let status, let body):
            return httpMessage(status: status, body: body)
        case .decodingFailed(let underlying):
            return "Could not parse the response: \(underlying.localizedDescription)"
        }
    }

    private func httpMessage(status: Int, body: String) -> String {
        let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = snippet.count > 400 ? String(snippet.prefix(400)) + "…" : snippet
        var tip = ""
        switch status {
        case 401, 403:
            tip = " Tip: Check your API key and model name in Settings."
        case 404:
            tip = " Tip: Verify the endpoint URL and model name in Settings."
        default:
            break
        }
        if clipped.isEmpty {
            return "HTTP \(status).\(tip)"
        }
        return "HTTP \(status): \(clipped)\(tip)"
    }
}

struct TrussedAPIConfiguration: Equatable {
    var endpointURL: URL
    var selectedProvider: LLMProvider
    var models: [LLMProvider: String]
    /// When true the app runs the agent loop with live tools; when false it sends raw chat.
    var toolsEnabled: Bool = true

    static let defaultEndpoint = URL(string: "https://trussed.eng.fau.edu/provider/generic/chat/completions")!

    var activeModel: String {
        let custom = models[selectedProvider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? selectedProvider.defaultModel : custom
    }

    func model(for provider: LLMProvider) -> String {
        let custom = models[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? provider.defaultModel : custom
    }

    static var `default`: TrussedAPIConfiguration {
        var defaults: [LLMProvider: String] = [:]
        for p in LLMProvider.allCases {
            defaults[p] = p.defaultModel
        }
        return TrussedAPIConfiguration(
            endpointURL: defaultEndpoint,
            selectedProvider: .faullm,
            models: defaults
        )
    }
}

enum APIKeyResolver {
    /// Priority: Keychain/Settings → Xcode scheme env var → Info.plist (Config/Secrets.xcconfig)
    static func resolvedAPIKey(for provider: LLMProvider) -> String? {
        if let saved = KeychainStore.loadAPIKey(for: provider), !saved.isEmpty {
            return saved
        }
        if let env = envValue(for: provider.envKeyName) {
            return env
        }
        if let plist = plistValue(for: provider.envKeyName) {
            return plist
        }
        if provider == .faullm {
            if let legacyEnv = envValue(for: "TRUSSED_API_KEY") {
                return legacyEnv
            }
            if let legacyPlist = plistValue(for: "TRUSSED_API_KEY") {
                return legacyPlist
            }
        }
        return nil
    }

    static func hasConfiguredKey(for provider: LLMProvider) -> Bool {
        resolvedAPIKey(for: provider) != nil
    }

    static func envValue(for name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func plistValue(for name: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: name) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "$(\(name))" {
            return nil
        }
        return trimmed
    }
}

/// One assistant turn from the API: optional text plus any requested tool calls.
struct AssistantTurn {
    struct ToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    let content: String?
    let toolCalls: [ToolCall]
    /// The exact `tool_calls` JSON returned by the server. Echoed back verbatim on the next
    /// request because some providers (e.g. Gemini) embed signatures in ids/extra fields.
    let rawToolCalls: [[String: Any]]
}

/// Final output of the agent loop.
struct AgentReply {
    let text: String
    let activities: [ToolActivity]
}

struct TrussedAPIClient {
    static let maxToolIterations = 5

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Simple (raw LLM) chat

    func sendChat(
        messages: [ChatMessage],
        configuration: TrussedAPIConfiguration
    ) async throws -> String {
        let turn = try await complete(
            messages: messages.map { $0.apiPayload },
            tools: nil,
            toolChoice: nil,
            configuration: configuration
        )
        guard let content = turn.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw TrussedAPIError.invalidResponse
        }
        return content
    }

    // MARK: - Agent loop with tool calling

    /// Runs the model with live tools. The model may request tools up to `maxToolIterations`
    /// times; each result is appended as a `role: "tool"` message before calling the model again.
    func runAgent(
        history: [ChatMessage],
        configuration: TrussedAPIConfiguration,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> AgentReply {
        var messages: [[String: Any]] = [["role": "system", "content": AgentTools.systemPrompt()]]
        messages += history.filter { $0.role == .user || $0.role == .assistant }.map { $0.apiPayload }

        var activities: [ToolActivity] = []
        var toolsSupported = true

        for iteration in 0 ... Self.maxToolIterations {
            let allowTools = toolsSupported && iteration < Self.maxToolIterations
            let turn: AssistantTurn
            do {
                turn = try await complete(
                    messages: messages,
                    tools: toolsSupported ? AgentTools.definitions : nil,
                    // After the last allowed iteration force a plain-text answer.
                    toolChoice: toolsSupported ? (allowTools ? "auto" : "none") : nil,
                    configuration: configuration
                )
            } catch TrussedAPIError.httpError(let status, let body)
                where iteration == 0 && toolsSupported && [400, 404, 422].contains(status)
                    && body.lowercased().contains("tool") {
                // Model/provider rejected the `tools` parameter: fall back to plain chat.
                toolsSupported = false
                turn = try await complete(messages: messages, tools: nil, toolChoice: nil, configuration: configuration)
            }

            if allowTools, !turn.toolCalls.isEmpty {
                var assistant: [String: Any] = ["role": "assistant", "tool_calls": turn.rawToolCalls]
                // Many providers return content: null alongside tool_calls; send NSNull back in that case.
                assistant["content"] = turn.content ?? NSNull()
                messages.append(assistant)

                for call in turn.toolCalls {
                    let args = AgentTools.parseArguments(call.arguments)
                    await onProgress(AgentTools.progressLabel(name: call.name, arguments: args))
                    let result = await AgentTools.execute(name: call.name, argumentsJSON: call.arguments)
                    activities.append(result.activity)
                    messages.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "name": call.name,
                        "content": result.output
                    ])
                }
                await onProgress("Thinking…")
                continue
            }

            let text = turn.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                throw TrussedAPIError.invalidResponse
            }
            return AgentReply(text: text, activities: activities)
        }
        throw TrussedAPIError.invalidResponse
    }

    // MARK: - Low-level request

    func complete(
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        toolChoice: String?,
        configuration: TrussedAPIConfiguration
    ) async throws -> AssistantTurn {
        let provider = configuration.selectedProvider
        guard let apiKey = APIKeyResolver.resolvedAPIKey(for: provider) else {
            throw TrussedAPIError.missingAPIKey(provider)
        }

        var request = URLRequest(url: configuration.endpointURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": configuration.activeModel,
            "messages": messages
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            if let toolChoice { body["tool_choice"] = toolChoice }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TrussedAPIError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TrussedAPIError.httpError(status: http.statusCode, body: bodyText)
        }
        return try Self.parseTurn(data)
    }

    /// Parses an OpenAI-compatible chat completion. `content` is optional because providers
    /// return `content: null` when they respond with `tool_calls`.
    static func parseTurn(_ data: Data) throws -> AssistantTurn {
        let root: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TrussedAPIError.invalidResponse
            }
            root = obj
        } catch let error as TrussedAPIError {
            throw error
        } catch {
            throw TrussedAPIError.decodingFailed(underlying: error)
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw TrussedAPIError.invalidResponse
        }

        let content: String?
        if let s = message["content"] as? String {
            content = s
        } else if let parts = message["content"] as? [[String: Any]] {
            // Some providers return content as an array of parts.
            content = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            content = nil
        }

        var calls: [AssistantTurn.ToolCall] = []
        var raw: [[String: Any]] = []
        for var item in (message["tool_calls"] as? [[String: Any]]) ?? [] {
            guard var function = item["function"] as? [String: Any],
                  let name = function["name"] as? String, !name.isEmpty else { continue }
            // Arguments are normally a JSON string, but tolerate an object.
            var argString = "{}"
            if let s = function["arguments"] as? String {
                argString = s.isEmpty ? "{}" : s
            } else if let obj = function["arguments"],
                      JSONSerialization.isValidJSONObject(obj),
                      let d = try? JSONSerialization.data(withJSONObject: obj) {
                argString = String(decoding: d, as: UTF8.self)
            }
            function["arguments"] = argString
            item["function"] = function
            if item["type"] == nil { item["type"] = "function" }
            let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(UUID().uuidString.prefix(12))"
            item["id"] = id
            raw.append(item)
            calls.append(.init(id: id, name: name, arguments: argString))
        }
        return AssistantTurn(content: content, toolCalls: calls, rawToolCalls: raw)
    }
}
