import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draftText: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var configuration: TrussedAPIConfiguration
    @Published var showSettings = false
    /// Live status shown while the agent is working (e.g. "Checking weather for 27703…").
    @Published var progressText: String?

    private let client = TrussedAPIClient()

    private enum StorageKey {
        static let endpoint = "trussed.endpointURL"
        static let provider = "trussed.selectedProvider"
        static let toolsEnabled = "trussed.toolsEnabled"
        static func model(for provider: LLMProvider) -> String {
            "trussed.model.\(provider.rawValue)"
        }
    }

    init() {
        configuration = Self.loadConfiguration()
    }

    var selectedProvider: LLMProvider {
        get { configuration.selectedProvider }
        set {
            guard configuration.selectedProvider != newValue else { return }
            configuration.selectedProvider = newValue
            errorMessage = nil
            UserDefaults.standard.set(newValue.rawValue, forKey: StorageKey.provider)
        }
    }

    var hasAPIKey: Bool {
        APIKeyResolver.hasConfiguredKey(for: configuration.selectedProvider)
    }

    func refreshAPIKeyState() {
        objectWillChange.send()
    }

    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        errorMessage = nil
        draftText = ""

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        isSending = true
        progressText = configuration.toolsEnabled ? "Thinking…" : nil
        defer {
            isSending = false
            progressText = nil
        }

        do {
            if configuration.toolsEnabled {
                let reply = try await client.runAgent(
                    history: messages,
                    configuration: configuration,
                    onProgress: { [weak self] status in
                        self?.progressText = status
                    }
                )
                messages.append(ChatMessage(role: .assistant, content: reply.text, toolActivities: reply.activities))
            } else {
                let reply = try await client.sendChat(messages: messages, configuration: configuration)
                messages.append(ChatMessage(role: .assistant, content: reply))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearConversation() {
        messages.removeAll()
        errorMessage = nil
    }

    func saveConfiguration(_ config: TrussedAPIConfiguration) {
        configuration = config
        let defaults = UserDefaults.standard
        defaults.set(config.endpointURL.absoluteString, forKey: StorageKey.endpoint)
        defaults.set(config.selectedProvider.rawValue, forKey: StorageKey.provider)
        defaults.set(config.toolsEnabled, forKey: StorageKey.toolsEnabled)
        for provider in LLMProvider.allCases {
            defaults.set(config.model(for: provider), forKey: StorageKey.model(for: provider))
        }
        objectWillChange.send()
    }

    private static func loadConfiguration() -> TrussedAPIConfiguration {
        let defaults = UserDefaults.standard
        var config = TrussedAPIConfiguration.default

        if let urlString = defaults.string(forKey: StorageKey.endpoint),
           let url = URL(string: urlString) {
            config.endpointURL = url
        }
        if let rawProvider = defaults.string(forKey: StorageKey.provider),
           let provider = LLMProvider(rawValue: rawProvider) {
            config.selectedProvider = provider
        }
        if defaults.object(forKey: StorageKey.toolsEnabled) != nil {
            config.toolsEnabled = defaults.bool(forKey: StorageKey.toolsEnabled)
        }
        for provider in LLMProvider.allCases {
            if let savedModel = defaults.string(forKey: StorageKey.model(for: provider)),
               !savedModel.isEmpty {
                config.models[provider] = savedModel
            }
        }
        return config
    }
}
