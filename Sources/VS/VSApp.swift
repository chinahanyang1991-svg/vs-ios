import SwiftUI

@main
struct VSApp: App {
    @State private var store = ConfigStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.cyan)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NodeListView()
                .tabItem { Label("节点", systemImage: "antenna.radiowaves.left.and.right") }
            VPNProfileView()
                .tabItem { Label("VPN", systemImage: "lock.shield") }
            SubscriptionListView()
                .tabItem { Label("订阅", systemImage: "tray.and.arrow.down") }
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
    }
}

struct GlassBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.08, blue: 0.16),
                     Color(red: 0.10, green: 0.05, blue: 0.20)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}
