import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: UsageService!
    private var settings: AppSettings!
    private var navigation: PanelNavigation!
    private var sessionsService: SessionsService!
    private var notchController: NotchController!
    private var hotzone: HoverHotzone!
    private var alertPeek: AlertPeek!
    private var updateService: UpdateService!
    private var updater: Updater!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // sem icone no Dock

        // O painel (Theme.swift) e sempre escuro, independente do Appearance do sistema.
        // Sem isto, o Menu nativo da engrenagem (NSMenu do AppKit) renderiza na aparencia
        // padrao do SO: com o Mac em Light Mode, vira um popup branco colado embaixo de
        // um painel preto. Forca dark app-wide (so este app, nao mexe no SO) pra manter
        // os dois consistentes.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let service = UsageService()
        let settings = AppSettings()
        let navigation = PanelNavigation()
        let sessionsService = SessionsService(settings: settings)
        let updateService = UpdateService()
        let updater = Updater()
        self.service = service
        self.settings = settings
        self.navigation = navigation
        self.sessionsService = sessionsService
        self.updateService = updateService
        self.updater = updater

        let notchController = NotchController(
            service: service, settings: settings, navigation: navigation, sessionsService: sessionsService,
            updateService: updateService, updater: updater,
            onQuit: { [weak self] in self?.quit() },
            onRefresh: { [weak self] in self?.refreshNow() }
        )
        self.notchController = notchController

        let hotzone = HoverHotzone()
        hotzone.onHoverEnter = { [weak self] in
            guard let self else { return }
            self.notchController.hotzoneHoverChanged(true)
            Task { await self.service.refresh() } // gated por TTL, nao bate rede toda hora
        }
        hotzone.onHoverExit = { [weak self] in
            self?.notchController.hotzoneHoverChanged(false)
        }
        hotzone.onClick = { [weak self] in
            self?.notchController.togglePin()
        }
        self.hotzone = hotzone

        self.alertPeek = AlertPeek(
            service: service, settings: settings, notchController: notchController,
            isHovering: { [weak notchController] in notchController?.isHoveringPanel ?? false }
        )

        // Idle no boot: compacto (uso colado no notch) se a flag estiver ligada, senao
        // invisivel como antes desta feature (sem isso o compacto so aparece apos o
        // 1o hover/hide).
        notchController.settleIdle()

        service.start()
        updateService.start()
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    /// Refresh manual (botao do rodape): forca o usage, e as sessoes/gasto tambem se a
    /// pagina Consumo estiver aberta (ela ja para de escanear quando fechada).
    private func refreshNow() {
        Task { await self.service.forceRefresh() }
        if navigation.page == .agents {
            Task { await self.sessionsService.forceRefresh() }
        }
        Task { await self.updateService.checkNow() }
    }
}
