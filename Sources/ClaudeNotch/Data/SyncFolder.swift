import Foundation

/// Pasta compartilhada particionada por maquina, no iCloud Drive (feature
/// multimac-sync): `~/Library/Mobile Documents/com~apple~CloudDocs/Gauge-Sync/`, com
/// duas subpastas, `machines/` (quem e' cada maquina) e `spend/` (quanto cada uma
/// gastou). Cada maquina e' dona EXCLUSIVA do proprio arquivo em cada subpasta -> o
/// total e' sempre a soma das particoes, sem conflito por construcao (nunca duas
/// maquinas escrevem o mesmo arquivo).
struct SyncFolder {
    let cloudDocsRoot: URL
    let root: URL
    let machinesDir: URL
    let spendDir: URL

    /// `cloudDocsRoot` injetavel pra teste (aponta pra um tmp dir); em producao usa
    /// sempre `~/Library/Mobile Documents/com~apple~CloudDocs`.
    init(cloudDocsRoot: URL? = nil) {
        self.cloudDocsRoot = cloudDocsRoot ?? URL(
            fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        )
        self.root = self.cloudDocsRoot.appendingPathComponent("Gauge-Sync")
        self.machinesDir = root.appendingPathComponent("machines")
        self.spendDir = root.appendingPathComponent("spend")
    }

    /// iCloud Drive parece disponivel (a pasta-mae existe como diretorio). Nao garante
    /// espaco/permissao de escrita, so a checagem rapida pra nao tentar criar pasta com
    /// o iCloud Drive desligado (nesse caso a pasta-mae nem existe).
    var isAvailable: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cloudDocsRoot.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Cria machines/ e spend/ (raiz Gauge-Sync implicita). So chamado no 1o toggle ON
    /// (ou refresh com o toggle ja ligado). Nao-op se o iCloud Drive nao estiver
    /// disponivel.
    @discardableResult
    func ensureFolders() -> Bool {
        guard isAvailable else { return false }
        do {
            try FileManager.default.createDirectory(at: machinesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: spendDir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    func machineFileURL(_ machineId: String) -> URL {
        machinesDir.appendingPathComponent("\(machineId).json")
    }

    func spendFileURL(_ machineId: String) -> URL {
        spendDir.appendingPathComponent("\(machineId).json")
    }

    /// Escrita atomica (tmp + replace), mesmo padrao do `UsageCache`: silenciosa em
    /// erro (o iCloud Drive pode estar sincronizando/momentaneamente indisponivel;
    /// nunca derruba o refresh por causa disso).
    func writeAtomic(_ url: URL, data: Data) {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// machineIds com um `spend/<id>.json` presente agora, excluindo a maquina local.
    /// So enumera o que esta no disco AGORA: se o arquivo de uma maquina sumir (removida
    /// ou iCloud ainda nao materializou), ela simplesmente nao aparece nesta lista --
    /// quem chama (CrossMachineSpendProvider) decide o que fazer com isso
    /// (skip-and-keep o ultimo valor bom, nunca zera na hora).
    func otherMachineIds(excluding myId: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: spendDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != myId }
    }

    /// Apaga machines/<id>.json e spend/<id>.json (acao "Remover esta maquina", pra um
    /// Mac aposentado nao continuar somando pra sempre no total dos outros). Silencioso
    /// se os arquivos ja nao existirem.
    func removeMachine(_ machineId: String) {
        try? FileManager.default.removeItem(at: machineFileURL(machineId))
        try? FileManager.default.removeItem(at: spendFileURL(machineId))
    }
}
