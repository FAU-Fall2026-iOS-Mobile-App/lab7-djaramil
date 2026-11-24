import Foundation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// One live tool the assistant ran while producing a reply (shown as a pill above the bubble).
struct ToolActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    let icon: String
    let label: String
    let succeeded: Bool

    init(id: UUID = UUID(), toolName: String, icon: String, label: String, succeeded: Bool = true) {
        self.id = id
        self.toolName = toolName
        self.icon = icon
        self.label = label
        self.succeeded = succeeded
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date
    var toolActivities: [ToolActivity]

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = .now,
        toolActivities: [ToolActivity] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.toolActivities = toolActivities
    }
}

extension ChatMessage {
    /// Plain OpenAI-format payload for conversation history (user / assistant text turns).
    var apiPayload: [String: Any] {
        ["role": role.rawValue, "content": content]
    }
}
