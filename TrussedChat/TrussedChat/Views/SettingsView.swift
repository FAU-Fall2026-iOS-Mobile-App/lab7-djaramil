import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var endpointString: String
    @State private var selectedProvider: LLMProvider
    @State private var models: [LLMProvider: String]
    @State private var apiKeys: [LLMProvider: String]
    @State private var toolsEnabled: Bool

    let onSave: (TrussedAPIConfiguration) -> Void

    init(configuration: TrussedAPIConfiguration, onSave: @escaping (TrussedAPIConfiguration) -> Void) {
        _endpointString = State(initialValue: configuration.endpointURL.absoluteString)
        _selectedProvider = State(initialValue: configuration.selectedProvider)
        _toolsEnabled = State(initialValue: configuration.toolsEnabled)

        var initialModels: [LLMProvider: String] = [:]
        var initialKeys: [LLMProvider: String] = [:]
        for provider in LLMProvider.allCases {
            initialModels[provider] = configuration.model(for: provider)
            initialKeys[provider] = KeychainStore.loadAPIKey(for: provider) ?? ""
        }
        _models = State(initialValue: initialModels)
        _apiKeys = State(initialValue: initialKeys)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $toolsEnabled) {
                        Label("Enable Live Tools", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("Assistant")
                } footer: {
                    Text(toolsEnabled
                         ? "The model can check weather, search the web, read web pages, and get the current date/time before answering."
                         : "Raw LLM mode: messages go straight to the model with no tools or system prompt.")
                }

                ForEach(LLMProvider.allCases) { provider in
                    Section {
                        TextField("Model", text: modelBinding(for: provider))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        SecureField("\(provider.envKeyName)", text: keyBinding(for: provider))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if !(apiKeys[provider]?.isEmpty ?? true) {
                            Button("Clear \(provider.displayName) key", role: .destructive) {
                                KeychainStore.deleteAPIKey(for: provider)
                                apiKeys[provider] = ""
                            }
                        }
                    } header: {
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            Text(keySourceLabel(for: provider))
                                .font(.caption2)
                                .foregroundStyle(APIKeyResolver.hasConfiguredKey(for: provider) || !(apiKeys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? .green : .orange)
                        }
                    }
                }

                Section {
                    TextField("Endpoint URL", text: $endpointString, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Trussed Endpoint")
                } footer: {
                    Text("Keys can be saved here, in Xcode Scheme environment variables (FAULLM_API_KEY, CHATGPT_API_KEY, GEMINI_API_KEY), or in Config/Secrets.xcconfig.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        applyConfiguration()
                        dismiss()
                    }
                }
            }
        }
    }

    private func modelBinding(for provider: LLMProvider) -> Binding<String> {
        Binding(
            get: { models[provider] ?? provider.defaultModel },
            set: { models[provider] = $0 }
        )
    }

    private func keyBinding(for provider: LLMProvider) -> Binding<String> {
        Binding(
            get: { apiKeys[provider] ?? "" },
            set: { apiKeys[provider] = $0 }
        )
    }

    private func keySourceLabel(for provider: LLMProvider) -> String {
        if !(apiKeys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return "Saved in app"
        }
        if APIKeyResolver.envValue(for: provider.envKeyName) != nil {
            return "From env var"
        }
        if APIKeyResolver.plistValue(for: provider.envKeyName) != nil {
            return "From Secrets.xcconfig"
        }
        return "Not set"
    }

    private func applyConfiguration() {
        var finalModels: [LLMProvider: String] = [:]
        for provider in LLMProvider.allCases {
            let trimmedKey = (apiKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                KeychainStore.saveAPIKey(trimmedKey, for: provider)
            }
            let trimmedModel = (models[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            finalModels[provider] = trimmedModel.isEmpty ? provider.defaultModel : trimmedModel
        }

        let urlString = endpointString.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: urlString) ?? TrussedAPIConfiguration.defaultEndpoint

        onSave(TrussedAPIConfiguration(
            endpointURL: url,
            selectedProvider: selectedProvider,
            models: finalModels,
            toolsEnabled: toolsEnabled
        ))
    }
}

#Preview {
    SettingsView(configuration: .default, onSave: { _ in })
}
