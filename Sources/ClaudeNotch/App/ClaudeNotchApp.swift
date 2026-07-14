import SwiftUI

struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Sem janela visivel: o app e so agente (LSUIElement) + o painel do notch.
        Settings {
            EmptyView()
        }
    }
}
