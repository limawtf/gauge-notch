import Testing
@testable import ClaudeNotch

@Suite("Cor por limite (49/50/79/80/94/95/100)")
struct ThemeColorTests {
    // Comparamos a string de descricao da Color (identica para o mesmo valor RGB),
    // ja que SwiftUI.Color nao expoe RGB direto sem NSColor.

    @Test("49% ainda e verde, 50% ja e amarelo")
    func greenToYellowBoundary() {
        #expect(Theme.color(forPct: 49) == Theme.color(forPct: 0))
        #expect(Theme.color(forPct: 50) != Theme.color(forPct: 49))
        #expect(Theme.color(forPct: 50) == Theme.color(forPct: 79))
    }

    @Test("79% ainda e amarelo, 80% ja e laranja")
    func yellowToOrangeBoundary() {
        #expect(Theme.color(forPct: 79) != Theme.color(forPct: 80))
        #expect(Theme.color(forPct: 80) == Theme.color(forPct: 94))
    }

    @Test("94% ainda e laranja, 95% ja e vermelho")
    func orangeToRedBoundary() {
        #expect(Theme.color(forPct: 94) != Theme.color(forPct: 95))
        #expect(Theme.color(forPct: 95) == Theme.color(forPct: 100))
    }
}
