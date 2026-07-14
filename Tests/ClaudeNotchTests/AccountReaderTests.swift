import Testing
import Foundation
@testable import ClaudeNotch

@Suite("Leitura da conta logada (~/.claude.json)")
struct AccountReaderTests {
    private func writeTempClaudeJSON(_ json: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch-test-\(UUID().uuidString).json")
        try? json.data(using: .utf8)?.write(to: url)
        return url
    }

    @Test("le email e displayName de dentro de oauthAccount")
    func readsAccountFields() {
        let url = writeTempClaudeJSON("""
        {"oauthAccount": {"emailAddress": "you@example.com", "displayName": "You",
                           "accountUuid": "abc-123"}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = AccountReader.currentAccount(path: url)
        #expect(account.email == "you@example.com")
        #expect(account.displayName == "You")
    }

    @Test("arquivo ausente devolve conta vazia, nunca lanca")
    func missingFileReturnsNone() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nao-existe-\(UUID().uuidString).json")
        let account = AccountReader.currentAccount(path: url)
        #expect(account.email == nil)
        #expect(account.displayName == nil)
    }

    @Test("JSON invalido devolve conta vazia, nunca lanca")
    func invalidJSONReturnsNone() {
        let url = writeTempClaudeJSON("nao e json")
        defer { try? FileManager.default.removeItem(at: url) }
        let account = AccountReader.currentAccount(path: url)
        #expect(account.email == nil)
    }

    @Test("oauthAccount ausente (deslogado) devolve conta vazia")
    func missingOauthAccountReturnsNone() {
        let url = writeTempClaudeJSON("{}")
        defer { try? FileManager.default.removeItem(at: url) }
        let account = AccountReader.currentAccount(path: url)
        #expect(account.email == nil)
        #expect(account.displayName == nil)
    }
}
