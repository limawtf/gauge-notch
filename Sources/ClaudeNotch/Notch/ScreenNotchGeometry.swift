import AppKit

/// Geometria do notch calculada a partir da propria tela (DynamicNotchKit expoe algo
/// parecido mas so internamente ao pacote dele; a hotzone precisa da sua propria copia).
extension NSScreen {
    var hasPhysicalNotch: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// Tela fisica com o notch de verdade, se existir alguma no setup atual. Usado por
    /// HoverHotzone e NotchController pra sempre concordarem em qual tela mostrar o painel,
    /// independente de qual tela tem o foco do teclado (NSScreen.main).
    static func withPhysicalNotch() -> NSScreen? {
        NSScreen.screens.first(where: \.hasPhysicalNotch) ?? NSScreen.main ?? NSScreen.screens.first
    }

    var notchRect: NSRect? {
        guard
            let leftWidth = auxiliaryTopLeftArea?.width,
            let rightWidth = auxiliaryTopRightArea?.width
        else { return nil }

        let notchHeight = safeAreaInsets.top
        let notchWidth = frame.width - leftWidth - rightWidth
        return NSRect(
            x: frame.midX - (notchWidth / 2),
            y: frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }

    var menuBarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    /// Retangulo da hotzone: o notch fisico (com uma folga lateral pra facilitar o hover),
    /// ou a regiao central da menu bar em Macs sem notch.
    var hotzoneRect: NSRect {
        if let notchRect {
            return notchRect.insetBy(dx: -20, dy: 0)
        }
        let width: CGFloat = 220
        let height = max(menuBarHeight, 24)
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }
}
