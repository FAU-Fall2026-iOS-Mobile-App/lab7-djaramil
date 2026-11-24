import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                providerPickerBar

                if !viewModel.hasAPIKey {
                    apiKeyBanner
                }

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if viewModel.messages.isEmpty {
                                emptyState
                            }

                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            if viewModel.isSending {
                                TypingIndicator(status: viewModel.progressText)
                                    .id("typing")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel.progressText) { _, _ in
                        if viewModel.isSending {
                            withAnimation {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.isSending) { _, sending in
                        if sending {
                            withAnimation {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                inputBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 4) {
                        Text("Trussed Chat")
                            .font(.headline)
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.configuration.toolsEnabled ? "wand.and.stars" : "text.bubble")
                            Text(viewModel.configuration.activeModel)
                        }
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearConversation()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.messages.isEmpty && !viewModel.isSending)
                    .accessibilityLabel("Clear conversation")

                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $viewModel.showSettings, onDismiss: {
                viewModel.refreshAPIKeyState()
            }) {
                SettingsView(
                    configuration: viewModel.configuration,
                    onSave: { config in
                        viewModel.saveConfiguration(config)
                    }
                )
            }
        }
    }

    private var providerPickerBar: some View {
        Picker("Provider", selection: $viewModel.selectedProvider) {
            ForEach(LLMProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var apiKeyBanner: some View {
        let provider = viewModel.selectedProvider
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(provider.displayName) API key required")
                    .font(.subheadline.weight(.semibold))
                Text("Add your \(provider.envKeyName) in Settings, your Xcode scheme environment variables, or Config/Secrets.xcconfig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    viewModel.showSettings = true
                }
                .font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Say hello to Trussed AI")
                .font(.subheadline.weight(.medium))
            Text("Using \(viewModel.selectedProvider.displayName) (\(viewModel.configuration.activeModel)).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.configuration.toolsEnabled
                 ? "Live tools on: weather, web search, web pages, date & time. Try \"What's the weather in 27703?\""
                 : "Live tools off (raw LLM mode). Turn them on in Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $viewModel.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .focused($isInputFocused)

            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(sendDisabled)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var sendDisabled: Bool {
        viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.isSending
            || !viewModel.hasAPIKey
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let last = viewModel.messages.last else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - Bubbles

private struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser, !message.toolActivities.isEmpty {
                    ToolActivityPills(activities: message.toolActivities)
                }

                Group {
                    if isUser {
                        Text(message.content)
                    } else {
                        MarkdownText(text: message.content)
                    }
                }
                .textSelection(.enabled)
                .padding(12)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(isUser ? Color.white : Color.primary)
            }
            .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var bubbleBackground: Color {
        isUser ? Color.accentColor : Color(.secondarySystemBackground)
    }
}

/// Compact, subtle pills showing which live tools ran for a reply.
private struct ToolActivityPills: View {
    let activities: [ToolActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(activities) { activity in
                HStack(spacing: 4) {
                    Image(systemName: activity.icon)
                        .imageScale(.small)
                    Text(activity.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(activity.succeeded ? Color.secondary : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }
}

private struct TypingIndicator: View {
    var status: String?
    @State private var phase = 0.0

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0 ..< 3, id: \.self) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(dotOpacity(index: index))
                    }
                }
                if let status, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: status)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func dotOpacity(index: Int) -> Double {
        let base = phase + Double(index) * 0.2
        return 0.3 + 0.7 * abs(sin(base * .pi))
    }
}

#Preview {
    ChatView()
}
