import Foundation

/// Le o token OAuth do Claude Code no Keychain (service "Claude Code-credentials").
///
/// USA o CLI `/usr/bin/security` (como o plugin SwiftBar), NAO o Security framework direto.
/// Motivo: o macOS atribui o acesso ao Keychain ao processo que chama. Chamando
/// `SecItemCopyMatching` de dentro do app, o "dono" do acesso e o proprio Claude Notch, que
/// e assinado AD-HOC (`codesign --sign -`) -- e a assinatura ad-hoc MUDA a cada rebuild, entao
/// o "Sempre Permitir" do Keychain fica preso naquela assinatura e o macOS re-pergunta a
/// senha a cada nova build/deploy (floodava). Delegando pro `/usr/bin/security` (binario
/// assinado pela Apple, assinatura ESTAVEL), o "Sempre Permitir" gruda de vez -- e como o
/// item costuma ja estar autorizado pro `security` (o plugin le assim ha tempos), normalmente
/// nem pergunta.
enum KeychainReader {
    static let service = "Claude Code-credentials"

    struct Credentials: Sendable {
        let accessToken: String
        let subscriptionType: String?
    }

    /// nil quando o item nao existe / nao decodifica. BLOQUEANTE (roda um subprocesso e pode
    /// esperar um prompt do Keychain na 1a vez): chamar FORA da main thread.
    static func readCredentials() -> Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        // timeout generoso: se o macOS mostrar o prompt de "permitir" (so na 1a vez por
        // assinatura do `security`), o `security` fica bloqueado esperando o usuario.
        guard let data = runProcessCapturingStdout(process, timeout: 60) else { return nil }
        return parseCredentials(data)
    }

    /// Parse puro do que o `security -w` imprime (o proprio blob JSON das credenciais + \n).
    /// Sem I/O -> testavel isoladamente.
    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let blob = trimmed.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
        else {
            return nil
        }
        return Credentials(accessToken: accessToken, subscriptionType: oauth["subscriptionType"] as? String)
    }
}
