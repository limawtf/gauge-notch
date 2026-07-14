import Testing
@testable import ClaudeNotch

@Suite("Nome curto de modelo")
struct ModelNamingTests {
    @Test("Familia depois do numero (geracao nova)")
    func newStyleNaming() {
        #expect(shortModelName("claude-opus-4-8") == "Opus 4.8")
        #expect(shortModelName("claude-sonnet-4-5") == "Sonnet 4.5")
    }

    @Test("Familia antes do numero (geracao antiga), ignora a data no final")
    func oldStyleNamingIgnoresDate() {
        #expect(shortModelName("claude-3-5-haiku-20241022") == "Haiku 3.5")
    }

    @Test("Modelo desconhecido devolve o id cru")
    func unknownFamilyReturnsRaw() {
        #expect(shortModelName("gpt-4o") == "gpt-4o")
    }

    @Test("String vazia devolve placeholder, nunca crasha")
    func emptyModel() {
        #expect(shortModelName("") == "?")
    }

    @Test("modelDotColor mapeia por familia, ignorando o resto do id")
    func dotColorByFamily() {
        #expect(modelDotColor("claude-opus-4-8") == .opus)
        #expect(modelDotColor("claude-sonnet-4-5") == .sonnet)
        #expect(modelDotColor("claude-3-5-haiku-20241022") == .haiku)
        #expect(modelDotColor("") == .unknown)
    }
}
