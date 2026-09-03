import Foundation

// MARK: - 审批系统（策略判定 + 审批请求；对齐架构方案 §3.5 的 fail-closed 精神）

enum ApprovalPolicy: String, CaseIterable {
    case askAlways = "askAlways"      // 每次都问
    case riskyOnly = "riskyOnly"      // 危险才问（默认）
    case never = "never"              // 从不（完全访问）

    var label: String {
        switch self {
        case .askAlways: return "请求批准"
        case .riskyOnly: return "危险才问"
        case .never: return "完全访问"
        }
    }

    var hint: String {
        switch self {
        case .askAlways: return "执行命令、写文件前，都先征求你的同意。"
        case .riskyOnly: return "日常读操作直接执行，仅对高风险操作要求批准。"
        case .never: return "不打断、不确认，Agent 直接执行所有操作（高风险）。"
        }
    }
}

enum ApprovalDecision: String {
    case allowOnce = "allowOnce"      // 允许一次
    case allowAlways = "allowAlways"  // 始终允许（本会话对该工具）
    case deny = "deny"                // 拒绝
}

/// 审批请求（Agent 循环挂起等待用户决定）
struct ApprovalRequest: Identifiable {
    let id = UUID()
    let toolName: String
    let command: String
    let reason: String
}

enum ApprovalService {
    /// 只读白名单：riskyOnly 策略下直接放行
    private static let safePattern: [String] = [
        "^ls\\b", "^cat\\b", "^head\\b", "^tail\\b", "^pwd$", "^echo\\b", "^date\\b",
        "^uname\\b", "^id\\b", "^whoami\\b", "^df\\b", "^wc\\b", "^grep\\b", "^find\\b",
        "^which\\b", "^env\\b", "^printenv\\b", "^apk info\\b", "^stat\\b", "^file\\b",
        "^du\\b", "^sleep\\b", "^true$", "^false$",
    ]

    /// 危险命令特征（riskyOnly 下需要审批）
    private static let riskyPattern: [String] = [
        "^rm\\b", "^mv\\b", "^chmod\\b", "^chown\\b", "^kill\\b", "^dd\\b",
        "^mkfs", "^shutdown\\b", "^reboot\\b", "^apk (add|del|upgrade)\\b",
        "^pip3? install\\b", "^npm (i|install)\\b", "^wget\\b", "^curl\\b",
        "^git (push|reset|clean)\\b", "\\bsudo\\b", ">\\s*/[^/]", "\\|\\s*sh\\b", "\\|\\s*bash\\b",
    ]

    static func needsApproval(command: String, policy: ApprovalPolicy) -> Bool {
        switch policy {
        case .never: return false
        case .askAlways: return true
        case .riskyOnly:
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if riskyPattern.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
                return true
            }
            // 不在只读白名单里的也算需要审批（fail-closed）
            let isSafe = safePattern.contains { trimmed.range(of: $0, options: [.regularExpression, .anchored]) != nil }
                || safePattern.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil })
            return !isSafe
        }
    }

    static func reason(command: String, policy: ApprovalPolicy) -> String {
        switch policy {
        case .askAlways:
            return "当前审批策略为「请求批准」，执行前需要你的确认。"
        case .riskyOnly:
            return "该命令可能修改系统或访问网络（策略「危险才问」），需要你的确认。"
        case .never:
            return ""
        }
    }
}
