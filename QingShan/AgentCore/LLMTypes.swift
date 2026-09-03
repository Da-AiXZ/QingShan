import Foundation
import Security

// MARK: - LLM 消息与流事件类型（对齐 dsh packages/llm 的语义，见「dsh语义对照笔记.md」第三节）

/// OpenAI 兼容的历史消息（内部 LLM 历史格式，与 UI ChatMessage 分离）
struct LLMMessage: Codable {
    enum Role: String, Codable { case system, user, assistant, tool }
    var role: Role
    var content: String?
    /// assistant 消息携带的工具调用（原生 function calling）
    var toolCalls: [LLMToolCall]?
    /// tool 角色消息对应的调用 id
    var toolCallId: String?
}

struct LLMToolCall: Codable, Equatable {
    var id: String
    var name: String
    /// JSON 字符串形式的参数（模型增量拼接的产物）
    var arguments: String
}

struct LLMToolDef {
    var name: String
    var description: String
    /// JSON Schema 对象（透传给 API 的 tools[].function.parameters）
    var parameters: [String: Any]

    var wireJSON: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}

/// 流事件（对齐 dsh translate.ts：reasoning/content/tool_calls 三类增量 + finish）
enum LLMStreamEvent {
    case reasoningDelta(String)
    case textDelta(String)
    /// 一步完成：累积的全文 + 模型发起的工具调用（空 = 纯文本回复）
    case done(text: String, toolCalls: [LLMToolCall], finishReason: String, promptTokens: Int, completionTokens: Int)
}

// MARK: - LLM 适配器协议（M3 起：流式 + 原生 function calling）

protocol LLMAdapter {
    var name: String { get }
    func stream(messages: [LLMMessage], tools: [LLMToolDef]) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

// MARK: - Keychain（API Key 只进钥匙串，不进 UserDefaults/日志）

enum Keychain {
    private static let service = "com.qingshan.juyang.llm"

    static func save(key: String, data: String) {
        let data = Data(data.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 模型服务设置（BYOK）

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let udBaseKey = "llm.baseURL"
    private static let udModelKey = "llm.model"
    private static let kcAPIKey = "llm.apiKey"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.udBaseKey) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.udModelKey) }
    }
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty { Keychain.delete(key: Self.kcAPIKey) }
            else { Keychain.save(key: Self.kcAPIKey, data: apiKey) }
        }
    }

    private init() {
        let ud = UserDefaults.standard
        baseURL = ud.string(forKey: Self.udBaseKey) ?? "https://api.deepseek.com/v1"
        model = ud.string(forKey: Self.udModelKey) ?? "deepseek-chat"
        apiKey = Keychain.load(key: Self.kcAPIKey) ?? ""
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}
