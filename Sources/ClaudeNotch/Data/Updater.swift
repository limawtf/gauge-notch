import AppKit
import CryptoKit
import Foundation

/// Bundle identifier esperado dentro do .dmg baixado. Confere ANTES de copiar pra
/// /Applications: nunca instala um app com identidade diferente, mesmo que o resto (hash,
/// https) tenha batido. Defesa em profundidade, nao so contra o manifesto.
let expectedGaugeBundleIdentifier = "wtf.lima.gauge"

/// Path fixo de instalacao. Literal (nunca vem de fora): usado tanto pelo Updater quanto
/// pelo script helper de relaunch.
let installedGaugeAppPath = "/Applications/Gauge.app"

enum UpdaterError: LocalizedError {
    case insecureURL
    case downloadFailed(String)
    case hashMismatch
    case mountFailed(String)
    case appNotFoundInImage
    case wrongBundleIdentifier(found: String?)
    case copyFailed(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL:
            return "URL do update nao e HTTPS."
        case .downloadFailed(let reason):
            return "Falha ao baixar o update: \(reason)"
        case .hashMismatch:
            return "O arquivo baixado nao bateu com o hash esperado (sha256). Update abortado por seguranca."
        case .mountFailed(let reason):
            return "Falha ao montar a imagem do update: \(reason)"
        case .appNotFoundInImage:
            return "Nao encontrei o Gauge.app dentro da imagem baixada."
        case .wrongBundleIdentifier(let found):
            return "O app dentro da imagem nao e o Gauge (identifier \(found ?? "ausente")). Update abortado."
        case .copyFailed(let reason):
            return "Falha ao copiar o novo app: \(reason)"
        case .helperFailed(let reason):
            return "Falha ao preparar a troca do app: \(reason)"
        }
    }
}

// MARK: - Funcoes puras (testaveis sem disco/rede)

/// Hash sha256 em hex de um blob em memoria. Puro, usado pelos testes com fixtures pequenas;
/// o download real usa `sha256HexOfFile` (streaming, nao carrega o .dmg inteiro na RAM).
func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// True se o sha256 de `data` bate com `expectedHex` (case-insensitive).
func verifySHA256(data: Data, expectedHex: String) -> Bool {
    sha256Hex(of: data).caseInsensitiveCompare(expectedHex) == .orderedSame
}

/// Le o CFBundleIdentifier de um Info.plist bruto (bytes). Pura, sem disk I/O, o
/// chamador le o arquivo e passa os bytes. nil se malformado ou sem a chave.
func readBundleIdentifier(plistData: Data) -> String? {
    guard
        let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
            as? [String: Any]
    else {
        return nil
    }
    return plist["CFBundleIdentifier"] as? String
}

/// Escapa uma string pra uso segura dentro de aspas simples do shell (`'` vira `'\''`).
/// Defesa em profundidade: os paths que entram no helper script sao todos locais/fixos (nunca
/// vem do manifesto), mas isto protege mesmo assim contra um path com aspas/espaco/caractere
/// especial no meio.
func shellSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Gera o conteudo do script helper que troca o .app e reabre. So recebe o PID (numero) e o
/// path LOCAL do app ja extraido (gerado por nos via mktemp, nunca dado do manifesto/rede).
/// Nada do latest.json (versao, notas, URL) entra aqui. O destino e SEMPRE o literal
/// `installedGaugeAppPath`, nao um parametro vindo de fora.
func makeRelaunchHelperScript(waitingOnPID pid: Int32, extractedAppPath: String) -> String {
    let quotedExtracted = shellSingleQuote(extractedAppPath)
    let quotedTarget = shellSingleQuote(installedGaugeAppPath)
    let quotedStaging = shellSingleQuote(installedGaugeAppPath + ".update-staging")
    return """
    #!/bin/bash
    set -e
    # espera o processo atual do Gauge sair antes de mexer no bundle instalado
    while kill -0 \(pid) 2>/dev/null; do
        sleep 0.5
    done
    # copia pro staging ANTES de tocar no app instalado: se o cp falhar (permissao/disco), o
    # app atual fica INTACTO (nunca deleta sem ter a copia pronta). So entao rm + mv (mesmo
    # filesystem em /Applications, troca final quase instantanea, sem janela de app-deletado).
    rm -rf \(quotedStaging)
    cp -R \(quotedExtracted) \(quotedStaging)
    rm -rf \(quotedTarget)
    mv \(quotedStaging) \(quotedTarget)
    open \(quotedTarget)
    rm -rf \(quotedExtracted)
    """
}

// MARK: - Updater (orquestracao real: download, hash, mount, swap)

/// Instala um UpdateInfo: baixa o .dmg, verifica o sha256 (a defesa principal, nunca instala
/// sem bater), monta e confere a identidade do bundle, copia, e entrega a troca final pra um
/// script helper detached (o app atual precisa sair do caminho antes do `rm -rf` do bundle
/// instalado). Toda falha e reportada (NSAlert), nunca silenciosa.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var isInstalling = false

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300 // .dmg pode demorar mais que o timeout de API
        session = URLSession(configuration: config)
    }

    func install(_ info: UpdateInfo) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }

        do {
            let dmgURL = try await downloadDMG(info)
            try verifyChecksum(at: dmgURL, expectedHex: info.sha256)
            let appURL = try mountAndExtractApp(from: dmgURL)
            try? FileManager.default.removeItem(at: dmgURL) // .dmg nao serve mais pra nada
            try relaunchAndTerminate(extractedAppPath: appURL)
        } catch {
            presentError(error)
        }
    }

    // MARK: 1. Download (HTTPS only)

    private func downloadDMG(_ info: UpdateInfo) async throws -> URL {
        guard info.dmgURL.scheme == "https" else { throw UpdaterError.insecureURL }
        let tmpURL: URL
        let response: URLResponse
        do {
            (tmpURL, response) = try await session.download(for: URLRequest(url: info.dmgURL))
        } catch {
            throw UpdaterError.downloadFailed("\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmpURL)
            throw UpdaterError.downloadFailed("HTTP \(http.statusCode)")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw UpdaterError.downloadFailed("nao consegui mover o download pro tmp: \(error.localizedDescription)")
        }
        return dest
    }

    // MARK: 2. Verificacao do hash: A DEFESA PRINCIPAL

    /// Se o hash NAO bater: apaga o arquivo baixado e aborta. Nunca instala sem o hash bater.
    private func verifyChecksum(at fileURL: URL, expectedHex: String) throws {
        let actual: String
        do {
            actual = try sha256HexOfFile(at: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdaterError.downloadFailed("nao consegui ler o arquivo baixado pra verificar o hash")
        }
        guard actual.caseInsensitiveCompare(expectedHex) == .orderedSame else {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdaterError.hashMismatch
        }
    }

    // MARK: 3. Monta, confere identidade, copia

    private func mountAndExtractApp(from dmgURL: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-mount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, dmgURL.path]
        // stdout/stderr pro /dev/null (nunca um Pipe nao-drenado): hdiutil pode escrever mais
        // que o buffer do Pipe (~64KB) antes de sair, e ninguem aqui fica lendo enquanto
        // espera o waitUntilExit, deadlock classico (mesmo motivo documentado em
        // runProcessCapturingStdout). Como so precisamos do codigo de saida, /dev/null
        // elimina o risco de vez, em vez de duplicar a logica de drain concorrente.
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        do {
            try attach.run()
        } catch {
            throw UpdaterError.mountFailed("nao consegui iniciar o hdiutil: \(error.localizedDescription)")
        }
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            throw UpdaterError.mountFailed("hdiutil attach saiu com codigo \(attach.terminationStatus)")
        }

        defer { detach(mountPoint: mountPoint) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appInImage = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.appNotFoundInImage
        }

        let plistURL = appInImage.appendingPathComponent("Contents/Info.plist")
        guard
            let plistData = try? Data(contentsOf: plistURL),
            let bundleID = readBundleIdentifier(plistData: plistData),
            bundleID == expectedGaugeBundleIdentifier
        else {
            let found = (try? Data(contentsOf: plistURL)).flatMap(readBundleIdentifier(plistData:))
            throw UpdaterError.wrongBundleIdentifier(found: found)
        }

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Gauge-\(UUID().uuidString).app")
        do {
            try FileManager.default.copyItem(at: appInImage, to: dest)
        } catch {
            throw UpdaterError.copyFailed(error.localizedDescription)
        }
        return dest
    }

    private func detach(mountPoint: URL) {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint.path, "-quiet"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        try? detach.run()
        detach.waitUntilExit()
    }

    // MARK: 4. Entrega a troca pro helper (detached) e sai

    /// Escreve o script helper em tmp, roda destacado (Process sem stdio ligado a este
    /// processo/terminal, entao sobrevive ao NSApp.terminate como um `nohup`), e encerra
    /// o app. So paths fixos/locais entram no script (ver makeRelaunchHelperScript).
    private func relaunchAndTerminate(extractedAppPath: URL) throws {
        let script = makeRelaunchHelperScript(
            waitingOnPID: ProcessInfo.processInfo.processIdentifier,
            extractedAppPath: extractedAppPath.path
        )
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-relaunch-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw UpdaterError.helperFailed(error.localizedDescription)
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run() // detached: nao esperamos, ele espera A GENTE sair
        } catch {
            throw UpdaterError.helperFailed(error.localizedDescription)
        }

        NSApp.terminate(nil)
    }

    // MARK: Erro em voz alta (nunca silencioso)

    private func presentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Nao foi possivel atualizar"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Calcula o sha256 de um arquivo em disco por streaming (nao carrega o .dmg inteiro na RAM).
func sha256HexOfFile(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1 << 20) // 1MB por vez
        guard let chunk, !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
