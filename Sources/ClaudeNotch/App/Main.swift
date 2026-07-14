import SwiftUI
import AppKit

/// Ponto de entrada. Antes de subir o app-agente (notch + hotzone), intercepta o modo de
/// verificacao headless `--snapshot`: renderiza o PanelView num PNG e encerra, sem abrir
/// nenhuma janela. Fora desse modo, segue o boot normal do SwiftUI App.
@main
enum Main {
    static func main() {
        // Dump de debug da pagina Consumo (nao abre janela, imprime e sai). Fica ANTES do
        // snapshot: e' so leitura de disco + ccusage, nada de UI.
        if CommandLine.arguments.contains("--debug-agents") {
            _ = AgentsDebugDump.runIfRequested() // chama exit()
            return
        }
        if CommandLine.arguments.contains("--snapshot") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited) // headless: nada aparece na tela
            MainActor.assumeIsolated {
                _ = SnapshotRenderer.runIfRequested() // renderiza e chama exit()
            }
            return
        }
        ClaudeNotchApp.main()
    }
}
