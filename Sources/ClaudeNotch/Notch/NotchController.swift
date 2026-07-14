import AppKit
import SwiftUI
import DynamicNotchKit
import Combine

/// Estado do "pin" (clique fixa aberto), observavel pelo PanelView pro icone refletir
/// se esta fixado. Separado do NotchController pra poder ser capturado pela closure de
/// conteudo do DynamicNotch antes do NotchController terminar de se inicializar.
final class PinState: ObservableObject {
    @Published private(set) var pinned = false
    fileprivate var onToggleRequested: (() -> Void)?

    fileprivate func set(_ value: Bool) {
        pinned = value
    }

    /// Chamado pelo botao de pin no PanelView (conteudo visivel, nao pela hotzone que
    /// fica ocluida assim que o painel expande).
    func requestToggle() {
        onToggleRequested?()
    }
}

/// Sinaliza pra CompactNotchUsageView SUMIR o numero na hora que o painel comeca a abrir,
/// antes da transicao do DynamicNotchKit (que "espreme" o compacto horizontalmente e faz
/// o numero dar um flash glitchado durante a abertura). Volta a mostrar ao recolher.
final class NotchOpenState: ObservableObject {
    @Published fileprivate(set) var isOpen = false
    init(isOpen: Bool = false) { self.isOpen = isOpen }
}

/// Embrulha o DynamicNotchKit com o PanelView. Controla expand/hide e o "pin" (clique
/// fixa aberto; outro clique solta).
@MainActor
final class NotchController {
    private let notch: DynamicNotch<PanelView, EmptyView, CompactNotchUsageView>
    private let pinState = PinState()
    private let openState = NotchOpenState()
    private let navigation: PanelNavigation
    private let settings: AppSettings
    var pinned: Bool { pinState.pinned }

    /// Hover real sobre o conteudo visivel do painel (DynamicNotchKit propria, via onHover
    /// no SwiftUI). Ao contrario do hover da HoverHotzone, nao fica corrompido quando o painel
    /// expandido (nivel .screenSaver) oclui a janela da hotzone (nivel .statusBar).
    var isHoveringPanel: Bool { notch.isHovering }

    /// Serializa expand/hide: cada chamada espera a anterior terminar antes de comecar,
    /// pra nunca cancelar o closePanelTask do DynamicNotchKit no meio de um hide() ainda
    /// suspenso (isso deixaria a continuation dele presa pra sempre).
    private var currentTask: Task<Void, Never>?

    /// Enquanto o idle compacto fica ligado (`showNotchUsage`, default), a janela do
    /// DynamicNotch nunca mais e desalocada (fica em `.compact` em vez de `.hidden`) --
    /// e ela e MAIOR que a HotzonePanel e fica num nivel acima (`.screenSaver` >
    /// `.statusBar`), entao oclui a hotzone permanentemente. A HotzonePanel so continua
    /// funcionando pro 1o hover quando a janela ainda nao existe (`showNotchUsage`
    /// desligado, idle = invisivel de verdade). Com o idle compacto sempre vivo, o hover
    /// real tem que vir do proprio `notch.isHovering` (a mesma janela que esta por cima
    /// e portanto recebe o evento de verdade).
    private var hoverCancellable: AnyCancellable?

    /// Hover bruto de cada fonte. Unificadas por OR em `effectiveHovering`: uma fonte
    /// "apagando" (false) so porque a outra janela passou a ocluir ela nao pode nunca,
    /// sozinha, gerar uma transicao espuria pro HoverIntentMachine (ver comentario acima
    /// sobre a hotzone ficar ocluida quando o idle compacto esta ligado).
    private var hotzoneHovering = false
    private var panelHovering = false
    private var effectiveHovering: Bool { hotzoneHovering || panelHovering }

    /// Maquina de histerese (dwell de abertura + carencia de fechamento, ver
    /// HoverIntentMachine.swift) que decide QUANDO expand()/hide() rodam de verdade a
    /// partir do hover bruto das 2 fontes. Fonte UNICA de verdade pra evitar o loop de
    /// expand/hide (flicker) quando o hover oscila na fronteira compacto<->expandido.
    private lazy var hoverIntent = HoverIntentMachine(
        scheduler: MainQueueHoverScheduler(),
        isPinned: { [weak self] in self?.pinned ?? false },
        onExpand: { [weak self] in self?.expand() },
        onHide: { [weak self] in self?.hide() }
    )

    init(
        service: UsageService, settings: AppSettings, navigation: PanelNavigation,
        sessionsService: SessionsService, updateService: UpdateService, updater: Updater,
        onQuit: @escaping () -> Void,
        onRefresh: @escaping () -> Void = {}
    ) {
        self.navigation = navigation
        self.settings = settings
        let pinState = self.pinState
        let openState = self.openState
        notch = DynamicNotch(
            hoverBehavior: .all, style: .auto,
            expanded: {
                PanelView(
                    service: service, settings: settings, pinState: pinState,
                    navigation: navigation, sessionsService: sessionsService,
                    updateService: updateService, updater: updater,
                    onTogglePin: { pinState.requestToggle() }, onQuit: onQuit,
                    onRefresh: onRefresh
                )
            },
            compactLeading: { EmptyView() },
            compactTrailing: {
                CompactNotchUsageView(service: service, openState: openState, onTap: { pinState.requestToggle() })
            }
        )
        pinState.onToggleRequested = { [weak self] in self?.togglePin() }

        // `DynamicNotch.state` e interno ao pacote (nao acessivel daqui), mas nao
        // precisa: a lib so publica `isHovering` quando `state != .hidden` (guard dela
        // mesma em `updateHoverState`), entao chamar expand()/hide() aqui e sempre
        // seguro e idempotente (ambos ja tem guard de estado por dentro).
        let notch = self.notch
        hoverCancellable = notch.$isHovering
            .dropFirst() // valor inicial (false) e' redundante com o settleIdle() do AppDelegate
            .removeDuplicates()
            .sink { [weak self] hovering in
                guard let self else { return }
                self.panelHovering = hovering
                self.hoverIntent.hoverChanged(self.effectiveHovering)
            }
    }

    /// Hover bruto vindo da HoverHotzone (janela separada, so recebe eventos reais
    /// quando nao esta ocluida pelo idle compacto). Alimenta a MESMA maquina de
    /// histerese que o hover do proprio DynamicNotch (ver `effectiveHovering`).
    func hotzoneHoverChanged(_ hovering: Bool) {
        hotzoneHovering = hovering
        hoverIntent.hoverChanged(effectiveHovering)
    }

    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = currentTask
        currentTask = Task {
            await previous?.value
            await operation()
        }
    }

    func expand() {
        openState.isOpen = true // some o numero do compacto ja, antes da transicao (fim do flash)
        guard let screen = NSScreen.withPhysicalNotch() else { return }
        enqueue { [notch] in await notch.expand(on: screen) }
    }

    /// Recolhe, exceto se estiver fixado (pin).
    func hide() {
        guard !pinned else { return }
        enqueue { [weak self] in await self?.collapseToIdle() }
    }

    /// Recolhe incondicionalmente (usado pelo AlertPeek e pelo toggle de pin).
    func forceHide() {
        enqueue { [weak self] in await self?.collapseToIdle() }
    }

    /// Mostra o idle certo no boot do app: compacto (uso colado no notch) se
    /// `settings.showNotchUsage` estiver ligado, senao invisivel (como era antes desta
    /// feature). Sem isso, o compacto so apareceria depois do 1o ciclo hover/hide.
    func settleIdle() {
        enqueue { [weak self] in await self?.collapseToIdle() }
    }

    /// O "idle" pos-hover: recolhe pro estado compacto (uso sempre-visivel) quando a
    /// flag esta ligada, ou esconde de vez quando desligada (era o unico idle antes da
    /// feature D). Espera o hover REAL soltar antes de colapsar (mesma checagem que o
    /// `_hide()` interno do DynamicNotchKit faz pro `hoverBehavior .keepVisible`), senao
    /// o painel expandido fecharia debaixo do mouse enquanto o usuario ainda navega nele.
    private func collapseToIdle() async {
        while notch.hoverBehavior.contains(.keepVisible), notch.isHovering {
            try? await Task.sleep(for: .seconds(0.1))
        }
        openState.isOpen = false // recolhendo: o compacto volta a mostrar o numero
        if settings.showNotchUsage, let screen = NSScreen.withPhysicalNotch() {
            await notch.compact(on: screen)
        } else {
            await notch.hide()
        }
        navigation.page = .usage
    }

    /// Clique/tap no badge ou no pin: abre na hora (bypassa o dwell do hover-intent via
    /// `click()`, que tambem sincroniza o estado interno da maquina pra `.open`).
    func togglePin() {
        pinState.set(!pinState.pinned)
        if pinState.pinned {
            hoverIntent.click()
        } else {
            forceHide()
        }
    }
}
