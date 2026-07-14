import Foundation

/// Le a conta Claude logada agora, direto de `~/.claude.json` (porta de `current_account`
/// do plugin Python). Nunca lanca: qualquer falha (arquivo ausente, JSON invalido, campo
/// faltando) devolve `.none`. So email/displayName importam aqui, a UI e discreta.
enum AccountReader {
    static func currentAccount(
        path: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
    ) -> LoggedInAccount {
        guard
            let data = try? Data(contentsOf: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauthAccount = root["oauthAccount"] as? [String: Any]
        else {
            return .none
        }
        return LoggedInAccount(
            email: oauthAccount["emailAddress"] as? String,
            displayName: oauthAccount["displayName"] as? String
        )
    }
}
