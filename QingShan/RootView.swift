import SwiftUI

/// M0.2：iSH 接入验证。
/// 流程：首启拷 rootfs → qc_boot() 拉起内核 → PID1 执行 uname -a → console 输出上屏。
/// 验收标准：屏幕出现 `Linux ... aarch64 Linux` 一行（Alpine 真实 uname）。
struct RootView: View {
    enum Phase: Equatable {
        case installing
        case booting
        case done
        case failed(String)
    }

    @State private var phase: Phase = .installing
    @State private var console: String = ""
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch phase {
            case .installing:
                Label("正在装配 Alpine rootfs（仅首次）…", systemImage: "externaldrive.badge.timemachine")
                    .font(.footnote).foregroundStyle(.secondary)
            case .booting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("内核启动中…").font(.footnote).foregroundStyle(.secondary)
                }
            case .done:
                Label("Linux 已启动", systemImage: "checkmark.seal.fill")
                    .font(.footnote).foregroundStyle(Color.green)
            case .failed(let msg):
                Label("失败：\(msg)", systemImage: "xmark.octagon.fill")
                    .font(.footnote).foregroundStyle(Color.red)
            }

            // console 输出（等宽、暗底，模拟终端）
            ScrollView {
                Text(console.isEmpty ? "（等待 console 输出…）" : console)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(console.isEmpty ? Color.secondary : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .task { await run() }
        .onReceive(NotificationCenter.default.publisher(for: .QCConsoleOutput)) { _ in
            console = qcConsoleBuffer()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("青山").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("M0.2 · iSH 接入验证").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func run() async {
        // 1. 首启装配
        if !FirstRun.isInstalled {
            do { try FirstRun.install() } catch {
                phase = .failed("rootfs 装配失败：\((error as NSError).localizedDescription)")
                return
            }
        }
        phase = .booting

        // 2. 拉内核（重量级，放后台线程）
        let out: String? = await Task.detached(priority: .userInitiated) {
            var err: NSString?
            let rc = qc_boot(FirstRun.rootURL.path, &err)
            return rc == 0 ? nil : (err as String?) ?? "boot rc=\(rc)"
        }.value

        if let out {
            phase = .failed(out)
            return
        }

        // 3. PID1 的 uname 输出走 console；轮询刷新 + 完成检测
        phase = .done
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            console = qcConsoleBuffer()
        }
        // PID1 退出后停表（防泄漏）
        _ = NotificationCenter.default.addObserver(forName: .QCProcessExited,
                                                   object: nil, queue: .main) { _ in
            timer?.invalidate()
            console = qcConsoleBuffer()
        }
    }
}
