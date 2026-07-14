import Foundation
import Testing
@testable import ClaudeNotch

/// Scheduler fake: so GUARDA as acoes agendadas (com o delay pedido), sem nunca rodar
/// nada sozinho. O teste decide explicitamente se/quando "o tempo passou" chamando
/// `fire(at:)`/`fireAll()` -- e' assim que testamos dwell/carencia sem DispatchQueue
/// real nem esperar segundos de verdade.
@MainActor
private final class FakeHoverIntentScheduler: HoverIntentScheduler {
    struct Scheduled {
        let delay: TimeInterval
        let action: () -> Void
    }

    private(set) var scheduled: [Scheduled] = []

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        scheduled.append(Scheduled(delay: delay, action: action))
    }

    /// Dispara o timer mais recente (o dwell/carencia "completou"). Nao remove os
    /// anteriores da lista (um timer obsoleto disparado depois nao deve fazer nada,
    /// e os testes de "oscilacao" dependem disso).
    func fireLast() {
        scheduled.last?.action()
    }

    var count: Int { scheduled.count }
}

@MainActor
private final class HoverIntentSpy {
    private(set) var expandCount = 0
    private(set) var hideCount = 0
    var pinned = false

    lazy var scheduler = FakeHoverIntentScheduler()
    lazy var machine = HoverIntentMachine(
        scheduler: scheduler,
        isPinned: { [weak self] in self?.pinned ?? false },
        onExpand: { [weak self] in self?.expandCount += 1 },
        onHide: { [weak self] in self?.hideCount += 1 }
    )
}

@Suite("HoverIntentMachine: dwell de abertura + carencia de fechamento")
@MainActor
struct HoverIntentMachineTests {
    @Test("hover < 1.5s (exit antes do dwell disparar) nao abre")
    func hoverBelowDwellDoesNotOpen() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true)
        spy.machine.hoverChanged(false) // saiu antes do timer de 1.5s disparar
        spy.scheduler.fireLast() // mesmo se o timer obsoleto disparar depois, nao abre
        #expect(spy.expandCount == 0)
    }

    @Test("hover >= 1.5s (dwell completa sem exit no meio) abre")
    func hoverAtOrAboveDwellOpens() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true)
        #expect(spy.scheduler.scheduled.last?.delay == HoverIntentMachine.defaultOpenDelay)
        spy.scheduler.fireLast() // dwell completou, sem exit no meio
        #expect(spy.expandCount == 1)
    }

    @Test("exit cancela o open pendente (timer obsoleto disparado depois e' no-op)")
    func exitCancelsPendingOpen() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true)
        let pendingOpen = spy.scheduler.scheduled.last!.action
        spy.machine.hoverChanged(false)
        pendingOpen() // dispara o timer que ja foi cancelado pelo exit
        #expect(spy.expandCount == 0)
    }

    @Test("oscilacao rapida (enter/exit repetido, nunca completa o dwell) nunca abre")
    func rapidOscillationNeverOpens() {
        let spy = HoverIntentSpy()
        for _ in 0..<20 {
            spy.machine.hoverChanged(true)
            spy.machine.hoverChanged(false)
        }
        #expect(spy.expandCount == 0)
        #expect(spy.hideCount == 0)
    }

    @Test("un-hover transitorio (re-entra dentro da carencia) nao fecha")
    func transientUnhoverDoesNotClose() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true)
        spy.scheduler.fireLast() // abre
        #expect(spy.expandCount == 1)

        spy.machine.hoverChanged(false) // sai, agenda a carencia de fechamento
        let pendingClose = spy.scheduler.scheduled.last!.action
        spy.machine.hoverChanged(true) // volta antes da carencia passar: cancela o fechamento
        pendingClose() // timer obsoleto disparado depois
        #expect(spy.hideCount == 0)
    }

    @Test("un-hover sustentado (carencia completa sem re-entrar) fecha")
    func sustainedUnhoverCloses() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true)
        spy.scheduler.fireLast() // abre
        spy.machine.hoverChanged(false)
        #expect(spy.scheduler.scheduled.last?.delay == HoverIntentMachine.defaultCloseGrace)
        spy.scheduler.fireLast() // carencia completou, sem re-entrar
        #expect(spy.hideCount == 1)
    }

    @Test("pinned nao fecha, mesmo com a carencia completando")
    func pinnedNeverCloses() {
        let spy = HoverIntentSpy()
        spy.pinned = true
        spy.machine.hoverChanged(true)
        spy.scheduler.fireLast() // abre
        spy.machine.hoverChanged(false)
        spy.scheduler.fireLast() // carencia completou
        #expect(spy.hideCount == 0)
    }

    @Test("clique abre imediato, sem esperar o dwell")
    func clickOpensImmediately() {
        let spy = HoverIntentSpy()
        spy.machine.click()
        #expect(spy.expandCount == 1)
    }

    @Test("clique no meio de um dwell pendente tambem abre na hora (bypass)")
    func clickDuringPendingDwellOpensImmediately() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true) // comeca o dwell de 1.5s
        spy.machine.click() // usuario clica antes do dwell completar
        #expect(spy.expandCount == 1)

        // O timer do dwell antigo, se disparar depois, nao deve abrir de novo (estado
        // ja e' .open, o guard de "generation" barra o disparo obsoleto).
        spy.scheduler.scheduled.first?.action()
        #expect(spy.expandCount == 1)
    }

    @Test("entradas/saidas redundantes nao disparam expand/hide duplicado")
    func redundantEventsAreNoOps() {
        let spy = HoverIntentSpy()
        spy.machine.hoverChanged(true)
        spy.machine.hoverChanged(true) // redundante, ainda dwelling
        spy.scheduler.fireLast()
        #expect(spy.expandCount == 1)

        spy.machine.hoverChanged(true) // redundante, ja aberto
        #expect(spy.expandCount == 1)

        spy.machine.hoverChanged(false)
        spy.machine.hoverChanged(false) // redundante, ja fechando
        #expect(spy.scheduler.count == 2) // 1 open timer + 1 close timer, nada extra
    }
}
