import Testing
@testable import ClaudeNotch

/// Feature A: o heroi de gasto passa a mostrar 3 valores sempre (Hoje . Mes . Total),
/// onde "Total" e o lifetime (nao o 7 dias). `spendHeroValues` isola esse mapeamento
/// da SwiftUI View pra poder testar sem renderizar nada.
@Suite("spendHeroValues: Hoje . Mes . Total (Total == lifetime)")
struct SpendHeroValuesTests {
    @Test("'Total' e o lifetime, distinto de mes e de 7 dias")
    func totalIsLifetimeNotLast7() {
        let spend = PersonalSpend(today: 4.32, last7: 38.90, month: 96.14, lifetime: 812.47)
        let values = spendHeroValues(spend)

        #expect(values.today == spend.today)
        #expect(values.month == spend.month)
        #expect(values.total == spend.lifetime)
        #expect(values.total != spend.last7)
    }

    @Test("nil (sem gasto pessoal ainda, ex. ccusage indisponivel) devolve os 3 nil")
    func nilSpendYieldsAllNil() {
        let values = spendHeroValues(nil)
        #expect(values.today == nil)
        #expect(values.month == nil)
        #expect(values.total == nil)
    }
}
