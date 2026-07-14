import Testing
@testable import ClaudeNotch

@Suite("tier -> label do plano")
struct PlanLabelTests {
    @Test("default_claude_max_20x -> Max 20x")
    func max20x() {
        #expect(planLabel(tier: "default_claude_max_20x", fallback: nil) == "Max 20x")
    }

    @Test("max_5x -> Max 5x")
    func max5x() {
        #expect(planLabel(tier: "default_claude_max_5x", fallback: nil) == "Max 5x")
    }

    @Test("pro -> Pro")
    func pro() {
        #expect(planLabel(tier: "pro", fallback: nil) == "Pro")
    }

    @Test("free -> Free")
    func free() {
        #expect(planLabel(tier: "free", fallback: nil) == "Free")
    }

    @Test("tier ausente cai pro fallback do keychain, capitalizado")
    func fallsBackToKeychainSubscriptionType() {
        #expect(planLabel(tier: nil, fallback: "pro") == "Pro")
        #expect(planLabel(tier: "", fallback: "max") == "Max")
    }

    @Test("sem tier e sem fallback -> 'Subscription'")
    func noTierNoFallback() {
        #expect(planLabel(tier: nil, fallback: nil) == "Subscription")
    }
}
