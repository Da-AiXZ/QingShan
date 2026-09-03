import Foundation

/// 首启装配：把 bundle 内的 fakefs rootfs（folder reference）拷到 App 容器。
/// fakefs 的权限/属主在 meta.db 里，bundle 拷贝不丢权限 —— 这是用 fakefs 的核心好处。
enum FirstRun {
    static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("root", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("meta.db").path)
    }

    /// 拷贝 bundle rootfs → Documents/root（含 data/ 与 meta.db）
    static func install() throws {
        guard let bundled = Bundle.main.url(forResource: "rootfs", withExtension: nil) else {
            throw NSError(domain: "QingShan.FirstRun", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bundle 内未找到 rootfs 资源"])
        }
        let dst = rootURL
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: bundled, to: dst)
        // 确认关键产物存在
        guard FileManager.default.fileExists(atPath: dst.appendingPathComponent("meta.db").path),
              FileManager.default.fileExists(atPath: dst.appendingPathComponent("data").path) else {
            throw NSError(domain: "QingShan.FirstRun", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "rootfs 拷贝后缺少 meta.db/data"])
        }
    }
}
