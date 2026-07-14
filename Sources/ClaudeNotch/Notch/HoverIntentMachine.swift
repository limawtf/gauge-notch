import Foundation

/// Agenda uma acao pra rodar depois de um atraso. Abstrai DispatchQueue.main.asyncAfter
/// pra HoverIntentMachine poder ser testada sem window server nem tempo real: em teste,
/// quem injeta o scheduler decide QUANDO (ou se) a acao agendada dispara de verdade.
@MainActor
protocol HoverIntentScheduler {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void)
}

/// Scheduler de producao: agenda de verdade na main queue.
struct MainQueueHoverScheduler: HoverIntentScheduler {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
}

/// Maquina de estado PURA (sem AppKit/Combine/DispatchQueue direto) que decide QUANDO
/// abrir/fechar o notch a partir de eventos brutos de hover, com histerese. Extraida pra
/// unidade separada pra poder ser testada sem window server: quem usa isto injeta um
/// `HoverIntentScheduler` (real ou fake) e recebe `onExpand`/`onHide` como callbacks.
///
/// - Abrir exige hover CONTINUO por `openDelay` (default 1.5s). Qualquer exit no meio
///   cancela o open pendente (sem flash de abertura por um passar-de-mouse rapido).
/// - Fechar exige um-hover SUSTENTADO por `closeGrace` (default 0.3s). Um re-entrar
///   dentro da carencia cancela o fechamento (absorve o "flicker" na fronteira
///   compacto<->expandido, onde o isHovering do DynamicNotchKit oscila rapido).
/// - `click()` bypassa o dwell (abre na hora), usado pelo caminho de clique/tap/pin.
///
/// So chama `onExpand`/`onHide` exatamente 1x por transicao real; eventos redundantes
/// (2 "true" seguidos, 2 "false" seguidos) sao no-op, entao nunca entra em loop
/// expand/hide mesmo com hover brincando na fronteira. `isPinned` e checado antes de
/// fechar (defesa em profundidade; NotchController.hide() ja tem o mesmo guard).
@MainActor
final class HoverIntentMachine {
    nonisolated static let defaultOpenDelay: TimeInterval = 0.8
    nonisolated static let defaultCloseGrace: TimeInterval = 0.3

    private enum State: Equatable {
        case closed
        case dwelling
        case open
        case closing
    }

    private let openDelay: TimeInterval
    private let closeGrace: TimeInterval
    private let scheduler: HoverIntentScheduler
    private let isPinned: () -> Bool
    private let onExpand: () -> Void
    private let onHide: () -> Void

    private var state: State = .closed
    /// Incrementado a cada evento que invalida um timer pendente; um timer agendado so
    /// age se o `generation` capturado no agendamento ainda bater com o atual (senao e'
    /// obsoleto, ex: um exit que cancelou o open pendente antes dele disparar).
    private var generation = 0

    init(
        openDelay: TimeInterval = HoverIntentMachine.defaultOpenDelay,
        closeGrace: TimeInterval = HoverIntentMachine.defaultCloseGrace,
        scheduler: HoverIntentScheduler,
        isPinned: @escaping () -> Bool = { false },
        onExpand: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.openDelay = openDelay
        self.closeGrace = closeGrace
        self.scheduler = scheduler
        self.isPinned = isPinned
        self.onExpand = onExpand
        self.onHide = onHide
    }

    /// Evento bruto de hover (true = mouse entrou/esta na regiao; false = saiu). Chame de
    /// qualquer fonte (HoverHotzone, notch.isHovering do DynamicNotchKit...): a maquina
    /// absorve entradas/saidas redundantes ou transitorias de qualquer uma delas.
    func hoverChanged(_ hovering: Bool) {
        hovering ? handleEnter() : handleExit()
    }

    /// Clique/tap/pin: abre na hora, ignorando o dwell. Cancela qualquer timer pendente.
    func click() {
        generation += 1
        state = .open
        onExpand()
    }

    private func handleEnter() {
        switch state {
        case .closed:
            state = .dwelling
            scheduleOpenTimer()
        case .dwelling, .open:
            break // ja aberto ou ja esperando o dwell, entrada redundante
        case .closing:
            // Voltou dentro da carencia: cancela o fechamento pendente, segue aberto.
            generation += 1
            state = .open
        }
    }

    private func handleExit() {
        switch state {
        case .closed, .closing:
            break // ja fechado ou ja esperando a carencia, saida redundante
        case .dwelling:
            // Saiu antes do dwell completar: cancela o open pendente.
            generation += 1
            state = .closed
        case .open:
            state = .closing
            scheduleCloseTimer()
        }
    }

    private func scheduleOpenTimer() {
        generation += 1
        let myGeneration = generation
        scheduler.schedule(after: openDelay) { [weak self] in
            self?.fireOpenTimer(myGeneration)
        }
    }

    private func scheduleCloseTimer() {
        generation += 1
        let myGeneration = generation
        scheduler.schedule(after: closeGrace) { [weak self] in
            self?.fireCloseTimer(myGeneration)
        }
    }

    private func fireOpenTimer(_ firedGeneration: Int) {
        guard firedGeneration == generation, state == .dwelling else { return } // obsoleto
        state = .open
        onExpand()
    }

    private func fireCloseTimer(_ firedGeneration: Int) {
        guard firedGeneration == generation, state == .closing else { return } // obsoleto
        state = .closed
        guard !isPinned() else { return }
        onHide()
    }
}
