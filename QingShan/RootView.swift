import SwiftUI

/// M0.2：iSH 接入验证（OpenMinis 生产版 ISHKernel 驱动）。
/// 流程：首启解包 rootfs.tar → ISHKernel.boot → 执行 `uname -a` → 输出上屏。
struct RootView: View {
    enum Phase: Equatable {
        case installing
        case booting
        case running
        case done
        case failed(String)
    }

    @State private var phase: Phase = .installing
    @State private var console: String = ""
    @State private var unameResult: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch phase {
            case .installing:
                Label("正在装配 Alpine rootfs（仅首次）…", systemImage: "externaldrive.badge.timemachine")
                    .font(.footnote).foregroundStyle(Color.secondary)
            case .booting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("内核启动中…").font(.footnote).foregroundStyle(Color.secondary)
                }
            case .running, .done:
                Label(phase == .done ? "Linux 已启动" : "执行验收命令中…",
                      systemImage: phase == .done ? "checkmark.seal.fill" : "gearshape.2")
                    .font(.footnote).foregroundStyle(Color.green)
            case .failed(let msg):
                Label("失败：\(msg)", systemImage: "xmark.octagon.fill")
                    .font(.footnote).foregroundStyle(Color.red)
            }

            ScrollView {
                Text(displayText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(displayText.isEmpty ? Color.secondary : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .task { await run() }
    }

    private var displayText: String {
        if !unameResult.isEmpty { return unameResult }
        return console
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("青山").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("M0.2 · iSH 接入验证").font(.subheadline).foregroundStyle(Color.secondary)
        }
    }

    private func run() async {
        // 1. 首启装配（解包 rootfs.tar）
        if !FirstRun.isInstalled {
            do { try FirstRun.install() } catch {
                phase = .failed("rootfs 装配失败：\((error as NSError).localizedDescription)")
                return
            }
        }

        // 2. 实时收内核输出
        ISHKernel.shared.outputCallback = { [weak self] data in
            guard let self, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.console += s
                if self.console.count > 64_000 {
                    self.console = String(self.console.suffix(32_000))
                }
            }
        }

        phase = .booting

        // 3. 拉内核（重量级，后台线程；bootWithRootPath 自带完整初始化与崩溃信号处理）
        let bootErr: String? = await Task.detached(priority: .userInitiated) { [weak self] () -> String? in
            guard let self else { return "self gone" }
            let rc = self.bootKernel()
            return rc == 0 ? nil : "boot rc=\(rc)"
        }.value

        if let bootErr {
            phase = .failed(bootErr)
            return
        }
        phase = .running

        // 4. 执行验收命令（executeCommandAndWait 自带完成检测与超时）
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String?) in
            var out: NSString?
            var err: NSError?
            ISHKernel.shared.executeCommandAndWait(
                "uname -a; echo; echo '青山 M0.2 · Alpine/AArch64 已启动'; id; cat /etc/alpine-release",
                timeout: 20,
                completion: { o, e in out = o; err = e as NSError? }
            )
            return (out as String? ?? "", err?.localizedDescription)
        }.value

        if let err = result.1, !err.isEmpty {
            phase = .failed("验收命令失败：\(err)")
            return
        }
        unameResult = result.0
        phase = .done
    }

    /// ISHKernel.boot 在 ObjC 里是非阻塞设计：需要按它自己的就绪语义等待。
    /// 这里用轮询 isBooted 兜底（boot 线程由 ISHKernel 内部管理）。
    private nonisolated func bootKernel() -> Int {
        let rc = ISHKernel.shared.boot(withRootPath: FirstRun.rootURL.path)
        if rc != 0 { return rc }
        // 等待内核完全就绪（最多 30s）
        for _ in 0..<300 {
            if ISHKernel.shared.isBooted { return 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return -99
    }
}
