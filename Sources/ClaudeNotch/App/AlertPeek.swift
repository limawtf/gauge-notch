import Foundation
import Combine

/// Como o idle e invisivel, isso da um "peek" de ~2s (expande e recolhe sozinho) quando
/// o pior percentual cruza >=90% ou cai bastante logo apos um reset. Toggle no rodape,
/// default ligado (AppSettings.peekEnabled).
@MainActor
final class AlertPeek {
    private let service: UsageService
    private let settings: AppSettings
    private let notchController: NotchController
    private let isHovering: () -> Bool

    private var cancellable: AnyCancellable?
    private var lastWorst: Int?

    init(
        service: UsageService,
        settings: AppSettings,
        notchController: NotchController,
        isHovering: @escaping () -> Bool
    ) {
        self.service = service
        self.settings = settings
        self.notchController = notchController
        self.isHovering = isHovering

        cancellable = service.$snapshot.sink { [weak self] snapshot in
            self?.evaluate(snapshot)
        }
    }

    private func evaluate(_ snapshot: UsageSnapshot) {
        defer { lastWorst = snapshot.worstPct }

        guard settings.peekEnabled, snapshot.state == .ok || snapshot.state == .offline else { return }
        guard let last = lastWorst else { return } // primeiro snapshot: nada pra comparar ainda

        let crossedHigh = last < 90 && snapshot.worstPct >= 90
        let justReset = last >= 90 && snapshot.worstPct < last - 20
        guard crossedHigh || justReset else { return }
        guard !isHovering(), !notchController.pinned else { return }

        peek()
    }

    private func peek() {
        notchController.expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.isHovering(), !self.notchController.pinned else { return }
            self.notchController.forceHide()
        }
    }
}
