import SwiftUI
import AppKit

extension View {
    /// Mantem o cursor de SETA normal ao passar por cima. No macOS recente um botao de
    /// icone dentro do NSHostingView do painel faz o cursor virar uma forma "estranha"
    /// (mao/apontador) no hover; `onContinuousHover` re-fixa a seta a CADA movimento dentro
    /// da area, sobrepondo o cursor que o botao tentaria por (um `set()` unico no enter
    /// seria revertido no proximo mouse-moved). macOS 13+.
    func arrowCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}
