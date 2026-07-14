import SwiftUI
import AppKit

/// Paleta e constantes visuais do painel. Cor por limite igual ao plugin Python:
/// verde <50, amarelo <80, laranja <95, vermelho >=95.
enum Theme {
    static func color(forPct pct: Int) -> Color {
        switch pct {
        case ..<50: return Color(red: 0.20, green: 0.78, blue: 0.35)   // verde
        case 50..<80: return Color(red: 1.00, green: 0.80, blue: 0.00) // amarelo
        case 80..<95: return Color(red: 1.00, green: 0.58, blue: 0.00) // laranja
        default: return Color(red: 1.00, green: 0.23, blue: 0.19)      // vermelho
        }
    }

    static let panelBackground = Color.black.opacity(0.92)
    static let cardBackground = Color.white.opacity(0.06)
    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
    static let divider = Color.white.opacity(0.08)

    static let cornerRadius: CGFloat = 14
    static let panelWidth: CGFloat = 300

    /// Cor do "dot" de modelo na pagina Agentes (fixa por familia, nao por limiar de uso).
    /// Nenhuma delas pode cair no verde/amarelo/laranja/vermelho de `color(forPct:)`, que
    /// e o unico vocabulario de ESTADO da pagina: identidade de modelo nao e estado.
    static func color(forModel family: AgentModelColor) -> Color {
        switch family {
        case .opus: return Color(red: 0.65, green: 0.45, blue: 1.00)
        case .sonnet: return Color(red: 0.30, green: 0.65, blue: 1.00)
        case .haiku: return Color(red: 0.60, green: 0.60, blue: 0.68) // cinza-azulado neutro, longe do verde de estado
        case .unknown: return tertiaryText
        }
    }
}
