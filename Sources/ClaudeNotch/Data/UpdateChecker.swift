import Foundation

/// Forma crua do manifesto publico (latest.json), nomes iguais ao JSON. O repo
/// `limawtf/gauge-notch` e PUBLICO de proposito (so releases), entao este cliente
/// nunca carrega token/credencial nenhuma, e o contrato com scripts/publish-release.sh.
struct UpdateManifest: Codable, Equatable {
    let version: String
    let notes: String?
    let dmg: String
    let sha256: String
    let minMacOS: String?
}

/// Update disponivel, ja validado (URL parseada, hash com formato correto), pronto pra UI/Updater.
struct UpdateInfo: Equatable {
    let version: String
    let notes: String
    let dmgURL: URL
    let sha256: String
}

enum UpdateCheckError: Error {
    case insecureURL
    case http(Int)
}

// MARK: - Semver (puro, sem I/O)

/// Compara duas versoes "major.minor.patch" (sufixo tipo "-beta" e ignorado). Retorna >0 se
/// `a` e mais nova que `b`, 0 se iguais, <0 se `a` e mais velha. Componente ausente ou
/// nao-numerico conta como 0, nunca crasha com uma versao malformada, so compara o
/// que da pra entender.
func compareVersions(_ a: String, _ b: String) -> Int {
    let pa = versionComponents(a)
    let pb = versionComponents(b)
    for i in 0..<3 where pa[i] != pb[i] {
        return pa[i] < pb[i] ? -1 : 1
    }
    return 0
}

/// True quando `remote` e estritamente mais nova que `local` (versao igual NUNCA atualiza).
func isNewerVersion(_ remote: String, than local: String) -> Bool {
    compareVersions(remote, local) > 0
}

private func versionComponents(_ version: String) -> [Int] {
    let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
    let parts = core.split(separator: ".")
    var result = [0, 0, 0]
    for i in 0..<min(3, parts.count) {
        result[i] = Int(parts[i]) ?? 0
    }
    return result
}

// MARK: - Validacao do manifesto (puro, sem I/O)

/// Constroi um UpdateInfo a partir do manifesto cru, validando o suficiente pra nunca deixar
/// um payload malformado seguir adiante: URL do dmg tem que ser HTTPS, sha256 tem que
/// parecer um hash de verdade (64 hex). nil se qualquer coisa estiver fora do formato.
func makeUpdateInfo(from manifest: UpdateManifest) -> UpdateInfo? {
    guard !manifest.version.isEmpty else { return nil }
    guard let url = URL(string: manifest.dmg), url.scheme == "https", url.host != nil else { return nil }
    guard isValidSHA256Hex(manifest.sha256) else { return nil }
    return UpdateInfo(version: manifest.version, notes: manifest.notes ?? "", dmgURL: url, sha256: manifest.sha256.lowercased())
}

/// True se a string tem exatamente 64 digitos hexadecimais (formato de um sha256 em hex).
func isValidSHA256Hex(_ s: String) -> Bool {
    s.count == 64 && s.allSatisfy(\.isHexDigit)
}

// MARK: - Cliente HTTP (so GET, HTTPS, sem auth: o manifesto e publico)

/// Cliente fino pro manifesto de update. Publico/sem token (o repo de releases e publico
/// de proposito, pra nao embutir credencial nenhuma no app. Ver contrato no topo do arquivo.
final class UpdateManifestClient {
    static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/limawtf/gauge-notch/main/latest.json"
    )!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config)
    }

    /// Bytes crus do latest.json. O chamador decodifica.
    func fetchManifestRaw() async throws -> Data {
        guard Self.manifestURL.scheme == "https" else { throw UpdateCheckError.insecureURL }
        var request = URLRequest(url: Self.manifestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateCheckError.http(http.statusCode)
        }
        return data
    }
}

/// Log discreto (stdout): o app e LSUIElement sem console visivel em uso normal, entao isto
/// nunca vira UI. So ajuda a diagnosticar via `Console.app`/terminal quando alguem for atras.
private func logUpdateCheck(_ message: String) {
    print("[UpdateChecker] \(message)")
}

// MARK: - Servico observavel

/// Checa o manifesto e expoe `available` pra UI observar. Boot com delay (nao compete com
/// o resto do boot), depois um loop periodico; falha de rede e sempre silenciosa (so loga e
/// tenta de novo no proximo ciclo (so a INSTALACAO, Updater, fala alto em erro).
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var available: UpdateInfo?

    private static let bootDelay: TimeInterval = 5
    private static let checkInterval: TimeInterval = 6 * 3600

    private let client: UpdateManifestClient
    private let currentVersion: () -> String
    private let decoder = JSONDecoder()
    private var timer: Timer?
    private var bootTask: Task<Void, Never>?

    init(
        client: UpdateManifestClient = UpdateManifestClient(),
        currentVersion: @escaping () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        }
    ) {
        self.client = client
        self.currentVersion = currentVersion
    }

    /// Dispara a checagem inicial (com delay pra nao competir com o resto do boot) + o loop
    /// periodico de ~6h. Chamar 1x, no AppDelegate.
    func start() {
        stop()
        bootTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.bootDelay))
            guard !Task.isCancelled else { return }
            await self?.checkNow()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.checkNow() }
        }
    }

    func stop() {
        bootTask?.cancel()
        bootTask = nil
        timer?.invalidate()
        timer = nil
    }

    /// Checagem manual (ex. botao "Atualizar agora" do rodape). Mesma politica de falha
    /// silenciosa que o boot/loop: rede fora do ar nunca vira erro visivel aqui.
    func checkNow() async {
        do {
            let raw = try await client.fetchManifestRaw()
            let manifest = try decoder.decode(UpdateManifest.self, from: raw)
            guard let info = makeUpdateInfo(from: manifest) else {
                logUpdateCheck("manifesto malformado (url/hash fora do formato esperado)")
                return
            }
            available = isNewerVersion(info.version, than: currentVersion()) ? info : nil
        } catch {
            logUpdateCheck("falha ao checar update: \(error)")
        }
    }
}
