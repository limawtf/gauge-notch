import AppKit

/// Janela transparente e nonactivating sobre o retangulo do notch, so pra detectar
/// mouse-enter/exit (e clique) e repassar pro NotchController. Repassa os eventos
/// BRUTOS na hora, sem debounce proprio: quem decide COM QUE ATRASO abrir/fechar de
/// verdade e' o HoverIntentMachine do NotchController (fonte unica de histerese,
/// compartilhada com o hover do proprio DynamicNotch). Mantem esta classe fina, so
/// glue com AppKit.
@MainActor
final class HoverHotzone {
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?
    var onClick: (() -> Void)?

    private(set) var isHovering = false

    private var panel: NSPanel?

    init() {
        setupPanel()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    private func setupPanel() {
        guard let screen = NSScreen.withPhysicalNotch() else { return }
        let rect = screen.hotzoneRect

        let panel = HotzonePanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let trackingView = HotzoneTrackingView(frame: NSRect(origin: .zero, size: rect.size))
        trackingView.hotzone = self
        panel.contentView = trackingView

        panel.setFrame(rect, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    @objc private func screenParametersChanged() {
        guard let screen = NSScreen.withPhysicalNotch(), let panel else { return }
        panel.setFrame(screen.hotzoneRect, display: true)
    }

    fileprivate func handleMouseEntered() {
        isHovering = true
        onHoverEnter?()
    }

    fileprivate func handleMouseExited() {
        isHovering = false
        onHoverExit?()
    }

    fileprivate func handleClick() {
        onClick?()
    }
}

/// Panel que nunca vira key window (nao rouba foco de app nenhum).
private final class HotzonePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class HotzoneTrackingView: NSView {
    weak var hotzone: HoverHotzone?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hotzone?.handleMouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        hotzone?.handleMouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        hotzone?.handleClick()
    }
}
