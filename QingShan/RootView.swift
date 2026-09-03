import SwiftUI

/// M0：流水线验证空壳。
/// 验收标准（本阶段）：能从 GitHub Actions 产出未签名 IPA 并安装到 iPad 显示此界面。
/// 下一阶段（M0.2）：接入 iSH 三静态库，把这里的占位文案替换为 Alpine `uname -a` 的真实输出。
struct RootView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("青山")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("v0.0.1 · M0 流水线验证")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider().padding(.horizontal, 48)
            Text("如果你能看到这个界面，说明\nWindows → GitHub Actions → IPA → iPad\n整条构建链路已经打通。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
