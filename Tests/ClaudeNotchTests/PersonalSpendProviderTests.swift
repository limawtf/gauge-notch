import Testing
import Foundation
@testable import ClaudeNotch

@Suite("Parse de 'ccusage daily --json' nos 4 buckets (porta de compute_costs)")
struct PersonalSpendProviderTests {
    /// Data fixa (meio-dia UTC) pra "hoje"/"7 dias"/"mes" nao dependerem de quando o
    /// teste roda. UTC pra bater com o timeZone passado ao parser.
    private func fixedToday() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 9; comps.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: comps)!
    }

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("hoje soma so as linhas com a data de hoje")
    func sumsToday() {
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 4.32},
            {"date": "2026-07-08", "totalCost": 10.0}
        ], "totals": {"totalCost": 14.32}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.today == 4.32)
    }

    @Test("7 dias INCLUI hoje (janela de 7 dias fechada, hoje - 6 ate hoje)")
    func last7IncludesToday() {
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 1.0},
            {"date": "2026-07-03", "totalCost": 2.0},
            {"date": "2026-07-02", "totalCost": 100.0}
        ], "totals": {"totalCost": 103.0}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        // since7 = 2026-07-03 (hoje - 6): 07-09 e 07-03 entram, 07-02 fica de fora
        #expect(spend?.last7 == 3.0)
    }

    @Test("mes soma so as linhas do mes corrente (prefixo yyyy-MM)")
    func sumsMonth() {
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 1.0},
            {"date": "2026-07-01", "totalCost": 2.0},
            {"date": "2026-06-30", "totalCost": 999.0}
        ], "totals": {"totalCost": 1002.0}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.month == 3.0)
    }

    @Test("lifetime IGNORA totals bruto do ccusage (inclui outras CLIs) e soma so as linhas")
    func lifetimeIgnoresTotalsUsesRows() {
        // totals=812.47 inclui gasto de outras CLIs; a soma das linhas (Claude) e' 1.0
        let json = """
        {"daily": [{"date": "2026-07-09", "totalCost": 1.0}], "totals": {"totalCost": 812.47}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.lifetime == 1.0)
    }

    @Test("So gasto Claude: com modelBreakdowns, ignora modelos nao-claude (Gemini etc.)")
    func filtersToClaudeOnly() {
        // ccusage daily agrega TODAS as CLIs; a linha tem breakdown misto claude+gemini.
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 8.0, "modelBreakdowns": [
                {"modelName": "claude-opus-4-8", "cost": 5.0},
                {"modelName": "gemini-3-flash-preview", "cost": 3.0}
            ]},
            {"date": "2026-05-01", "totalCost": 2.0, "modelBreakdowns": [
                {"modelName": "gemini-3-flash-preview", "cost": 2.0}
            ]}
        ], "totals": {"totalCost": 10.0}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.today == 5.0)      // so o claude do dia (nao 8.0)
        #expect(spend?.lifetime == 5.0)   // 5 (claude) + 0 (dia so-gemini), nao 10
    }

    @Test("sem 'totals', lifetime cai pra soma manual das linhas")
    func lifetimeFallsBackToRowSum() {
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 1.0},
            {"date": "2026-01-01", "totalCost": 2.5}
        ]}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.lifetime == 3.5)
    }

    @Test("'period' e aceito como fallback de 'date' (formatos alternativos do ccusage)")
    func acceptsPeriodAsDateFallback() {
        let json = """
        {"daily": [{"period": "2026-07-09", "totalCost": 4.0}], "totals": {"totalCost": 4.0}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.today == 4.0)
    }

    @Test("JSON invalido devolve nil, nunca crasha")
    func invalidJSONReturnsNil() {
        let spend = parsePersonalSpend(Data("nao e json".utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend == nil)
    }

    @Test("'daily' ausente devolve todos os buckets zerados (nunca crasha)")
    func missingDailyReturnsZeroBuckets() {
        let json = """
        {"totals": {"totalCost": 0}}
        """
        let spend = parsePersonalSpend(Data(json.utf8), today: fixedToday(), calendar: utcCalendar)
        #expect(spend?.today == 0)
        #expect(spend?.last7 == 0)
        #expect(spend?.month == 0)
        #expect(spend?.lifetime == 0)
    }

    // MARK: - parsePersonalSpendDailyMap (feature multimac-sync: particao local do sync)

    @Test("mapa bruto: 1 chave por data, custo Claude-only (mesmo filtro dos buckets)")
    func dailyMapFiltersToClaudeOnlyPerDate() {
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 8.0, "modelBreakdowns": [
                {"modelName": "claude-opus-4-8", "cost": 5.0},
                {"modelName": "gemini-3-flash-preview", "cost": 3.0}
            ]},
            {"date": "2026-07-08", "totalCost": 10.0}
        ]}
        """
        let map = parsePersonalSpendDailyMap(Data(json.utf8))
        #expect(map?["2026-07-09"] == 5.0)
        #expect(map?["2026-07-08"] == 10.0)
        #expect(map?.count == 2)
    }

    @Test("mapa bruto e' a mesma fonte dos buckets: personalSpendBuckets(fromDailyCost:) bate com parsePersonalSpend")
    func dailyMapAgreesWithBuckets() {
        let json = """
        {"daily": [
            {"date": "2026-07-09", "totalCost": 4.32},
            {"date": "2026-07-03", "totalCost": 2.0},
            {"date": "2026-06-30", "totalCost": 99.0}
        ]}
        """
        let data = Data(json.utf8)
        let map = parsePersonalSpendDailyMap(data)!
        let derived = personalSpendBuckets(fromDailyCost: map, today: fixedToday(), calendar: utcCalendar)
        let direct = parsePersonalSpend(data, today: fixedToday(), calendar: utcCalendar)!
        #expect(derived == direct)
    }

    @Test("linha sem date E sem period (chave vazia) e' ignorada, nao contamina nenhum bucket")
    func rowsWithoutAnyDateKeyAreSkipped() {
        let json = """
        {"daily": [
            {"totalCost": 500.0},
            {"date": "2026-07-09", "totalCost": 1.0}
        ]}
        """
        let map = parsePersonalSpendDailyMap(Data(json.utf8))
        #expect(map?.count == 1)
        #expect(map?["2026-07-09"] == 1.0)
    }

    @Test("JSON invalido devolve nil (mesmo contrato de parsePersonalSpend)")
    func dailyMapInvalidJSONReturnsNil() {
        let map = parsePersonalSpendDailyMap(Data("nao e json".utf8))
        #expect(map == nil)
    }
}
