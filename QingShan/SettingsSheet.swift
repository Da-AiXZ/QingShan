import SwiftUI

/// 设置弹层（BYOK：模型服务三件套；Key 只进本机 Keychain）
struct SettingsSheet: View {
    let onClose: () -> Void
    @StateObject private var st = SettingsStore.shared
    @State private var keyDraft: String = ""
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部
            HStack {
                Text("设置").font(.system(size: 16, weight: .semibold))
                Text("BYOK · Key 仅存本机 Keychain").font(.caption).foregroundStyle(Color.secondary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        Text("模型服务").font(.footnote).foregroundStyle(Color.secondary)
                        settingRow("服务地址（baseURL）") {
                            TextField("https://api.deepseek.com/v1", text: $st.baseURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        settingRow("模型名") {
                            TextField("deepseek-chat", text: $st.model)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        settingRow("API Key") {
                            SecureField("sk-…", text: $keyDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        HStack {
                            Button("保存 Key 到钥匙串") {
                                st.apiKey = keyDraft.trimmingCharacters(in: .whitespaces)
                                saved = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                            if st.hasKey {
                                Text("已存 ✓").font(.footnote).foregroundStyle(Color.green)
                            }
                            if saved {
                                Text("已保存").font(.footnote).foregroundStyle(Color.green)
                            }
                            Spacer()
                            if st.hasKey {
                                Button("清除 Key", role: .destructive) {
                                    st.apiKey = ""
                                    keyDraft = ""
                                }
                                .font(.footnote)
                                .buttonStyle(.plain)
                            }
                        }
                        Text("获取 Key：platform.deepseek.com · 充值或新户额度均可。Key 永不进入对话记录或日志。")
                            .font(.caption2).foregroundStyle(Color.secondary)
                    }

                    Divider()

                    Group {
                        Text("使用说明").font(.footnote).foregroundStyle(Color.secondary)
                        Text("""
                        · 未填 Key 时 Agent 使用脚本化假大脑（M2 基线，无真智能）\n· 填入 Key 后对话走 DeepSeek 真模型，可调用 run_command 工具操作 Linux 沙箱\n· 模型上下文接近上限时会自动压缩成交接摘要，对话不断线
                        """)
                        .font(.caption).foregroundStyle(Color.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 460)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 24)
        .onAppear { keyDraft = st.apiKey }
    }

    private func settingRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote)
            field()
                .padding(8)
                .background(Color(hex: 0xF4F3EE))
                .cornerRadius(8)
        }
    }
}
