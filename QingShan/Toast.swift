import SwiftUI

// MARK: - Toast：顶部居中悬浮提示，自动淡出（用户指定的通知形态）

struct Toast: Identifiable, Equatable {
    enum Kind { case info, warn, error, success }
    let id = UUID()
    let text: String
    let kind: Kind
    let createdAt = Date()
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var toasts: [Toast] = []

    func show(_ text: String, kind: Toast.Kind = .info, duration: TimeInterval = 3.5) {
        let t = Toast(text: text, kind: kind)
        toasts.append(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            withAnimation(.easeIn(duration: 0.5)) {
                self?.toasts.removeAll { $0.id == t.id }
            }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.toasts) { t in
                HStack(spacing: 8) {
                    Image(systemName: icon(t.kind))
                    Text(t.text).font(.footnote).lineLimit(3)
                }
                .foregroundStyle(Color.white)
                .padding(.vertical, 9).padding(.horizontal, 14)
                .background(bg(t.kind))
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.25), radius: 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func icon(_ k: Toast.Kind) -> String {
        switch k {
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.seal.fill"
        }
    }

    private func bg(_ k: Toast.Kind) -> Color {
        switch k {
        case .info: return Color(hex: 0x3A3A38).opacity(0.94)
        case .warn: return Color(hex: 0xB57308).opacity(0.96)
        case .error: return Color(hex: 0xB3403A).opacity(0.96)
        case .success: return Color(hex: 0x2F7D4F).opacity(0.96)
        }
    }
}
