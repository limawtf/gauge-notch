import Testing
@testable import ClaudeNotch

@Suite("Des-slug do projeto")
struct ProjectNamingTests {
    @Test("Com cwd disponivel, usa o ultimo componente do path real")
    func usesCwdWhenAvailable() {
        let name = projectDisplayName(
            cwd: "/Users/you/Documents/Apps/claude-notch",
            folderSlug: "-Users-you-Documents-Apps-claude-notch"
        )
        #expect(name == "claude-notch")
    }

    @Test("Sem cwd, cai pro fallback do slug (ultimo pedaco apos hifen)")
    func fallsBackToSlugWhenNoCwd() {
        let name = projectDisplayName(cwd: nil, folderSlug: "-Users-you-Documents-Apps-webapp")
        #expect(name == "webapp")
    }

    @Test("Slug sem prefixo de hifen tambem funciona")
    func slugWithoutLeadingDash() {
        let name = projectDisplayName(cwd: nil, folderSlug: "Users-you-myapp")
        #expect(name == "myapp")
    }

    @Test("cwd com barra no final ignora componente vazio")
    func cwdWithTrailingSlash() {
        let name = projectDisplayName(cwd: "/Users/you/Documents/Apps/claude-notch/", folderSlug: "x")
        #expect(name == "claude-notch")
    }
}
