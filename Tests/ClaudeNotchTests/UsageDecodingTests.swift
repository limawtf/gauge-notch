import Foundation
import Testing
@testable import ClaudeNotch

@Suite("Decode de usage/profile")
struct UsageDecodingTests {
    @Test("decodifica five_hour, seven_day, opus e sonnet")
    func decodesFullUsage() throws {
        let data = Fixtures.usageJSON()
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)

        #expect(resp.fiveHour?.utilization == 42)
        #expect(resp.sevenDay?.utilization == 17)
        #expect(resp.sevenDayOpus?.utilization == 5)
        #expect(resp.sevenDaySonnet?.utilization == 12)
    }

    @Test("opus/sonnet ausentes decodificam como nil, sem quebrar o resto")
    func decodesWithoutOpusSonnet() throws {
        let data = Fixtures.usageJSON(includeOpusSonnet: false)
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)

        #expect(resp.fiveHour?.utilization == 42)
        #expect(resp.sevenDayOpus == nil)
        #expect(resp.sevenDaySonnet == nil)
    }

    @Test("resets_at parseia como Date valida")
    func parsesResetsAt() throws {
        let data = Fixtures.usageJSON()
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)
        let date = parseISO8601(resp.fiveHour?.resetsAt)
        #expect(date != nil)
    }

    @Test("profile decodifica rate_limit_tier de dentro de organization")
    func decodesProfileTier() throws {
        let data = Fixtures.profileJSON(tier: "default_claude_max_20x")
        let resp = try JSONDecoder().decode(ProfileResponse.self, from: data)
        #expect(resp.tier == "default_claude_max_20x")
    }

    @Test("extra_usage ausente decodifica como nil, sem quebrar o resto")
    func decodesWithoutExtraUsage() throws {
        let data = Fixtures.usageJSON()
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(resp.extraUsage == nil)
    }

    @Test("extra_usage presente decodifica todos os campos")
    func decodesExtraUsageFields() throws {
        let data = Fixtures.usageJSON(extraUsageJSON: """
        {"is_enabled": true, "monthly_limit": 200, "used_credits": 143.6,
         "utilization": 71.8, "currency": "BRL"}
        """)
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(resp.extraUsage?.isEnabled == true)
        #expect(resp.extraUsage?.monthlyLimit == 200)
        #expect(resp.extraUsage?.usedCredits == 143.6)
        #expect(resp.extraUsage?.utilization == 71.8)
        #expect(resp.extraUsage?.currency == "BRL")
    }

    @Test("extra_usage com is_enabled false decodifica normalmente (o gate e na UI)")
    func decodesExtraUsageDisabled() throws {
        let data = Fixtures.usageJSON(extraUsageJSON: """
        {"is_enabled": false, "monthly_limit": 0, "used_credits": 0,
         "utilization": 0, "currency": "USD"}
        """)
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(resp.extraUsage?.isEnabled == false)
    }

    @Test("gate so mostra quando is_enabled == true (nil, false ou ausente -> escondido)")
    func extraUsageGate() {
        #expect(shouldShowExtraUsage(nil) == false)
        #expect(shouldShowExtraUsage(ExtraUsageNode(isEnabled: false, monthlyLimit: 200,
                                                     usedCredits: 10, utilization: 5, currency: "BRL")) == false)
        #expect(shouldShowExtraUsage(ExtraUsageNode(isEnabled: nil, monthlyLimit: nil,
                                                     usedCredits: nil, utilization: nil, currency: nil)) == false)
        #expect(shouldShowExtraUsage(ExtraUsageNode(isEnabled: true, monthlyLimit: 200,
                                                     usedCredits: 10, utilization: 5, currency: "BRL")) == true)
    }
}
