import SwiftUI

@main
@MainActor
struct JARVISApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            switch state.phase {
            case .restoring:
                ProgressView()
            case .signedOut:
                OnboardingView()
            case .signedIn:
                ConversationsView()
            }
        }
        .toastOverlay()
        .task { await state.restore() }
    }
}

// MARK: - Toasts

struct ToastOverlay: ViewModifier {
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text = state.toast {
                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.3), value: state.toast)
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}
