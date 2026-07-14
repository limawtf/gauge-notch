import Testing
import Foundation
@testable import ClaudeNotch

@Suite("SyncFolder: resolucao de pasta, criacao, escrita atomica, listagem")
struct SyncFolderTests {
    private func tmpFolder() -> (SyncFolder, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-sync-folder-tests-\(UUID().uuidString)")
        return (SyncFolder(cloudDocsRoot: tmpDir), tmpDir)
    }

    @Test("isAvailable == false quando a pasta-mae (iCloud Drive) nao existe")
    func unavailableWhenRootMissing() {
        let (folder, _) = tmpFolder() // nunca criado no disco
        #expect(folder.isAvailable == false)
    }

    @Test("isAvailable == true e ensureFolders cria machines/ e spend/")
    func availableAndCreatesSubfolders() throws {
        let (folder, tmpDir) = tmpFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        #expect(folder.isAvailable == true)
        #expect(folder.ensureFolders() == true)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.machinesDir.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: folder.spendDir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test("ensureFolders nao-op (false) quando indisponivel, nunca crasha")
    func ensureFoldersNoOpWhenUnavailable() {
        let (folder, _) = tmpFolder()
        #expect(folder.ensureFolders() == false)
    }

    @Test("writeAtomic escreve o conteudo certo (tmp + replace)")
    func writeAtomicWritesContent() throws {
        let (folder, tmpDir) = tmpFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        folder.ensureFolders()

        let url = folder.spendFileURL("mac-x")
        folder.writeAtomic(url, data: Data("ola".utf8))

        #expect(try Data(contentsOf: url) == Data("ola".utf8))
        // sem sobra de .tmp
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    @Test("otherMachineIds lista so os presentes agora, excluindo a propria")
    func otherMachineIdsExcludesSelf() throws {
        let (folder, tmpDir) = tmpFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        folder.ensureFolders()

        folder.writeAtomic(folder.spendFileURL("mac-a"), data: Data("{}".utf8))
        folder.writeAtomic(folder.spendFileURL("mac-b"), data: Data("{}".utf8))
        folder.writeAtomic(folder.spendFileURL("mac-c"), data: Data("{}".utf8))

        let others = Set(folder.otherMachineIds(excluding: "mac-a"))
        #expect(others == ["mac-b", "mac-c"])
    }

    @Test("removeMachine apaga machines/<id>.json e spend/<id>.json")
    func removeMachineDeletesBothFiles() throws {
        let (folder, tmpDir) = tmpFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        folder.ensureFolders()

        folder.writeAtomic(folder.spendFileURL("mac-a"), data: Data("{}".utf8))
        folder.writeAtomic(folder.machineFileURL("mac-a"), data: Data("{}".utf8))

        folder.removeMachine("mac-a")

        #expect(!FileManager.default.fileExists(atPath: folder.spendFileURL("mac-a").path))
        #expect(!FileManager.default.fileExists(atPath: folder.machineFileURL("mac-a").path))
    }
}
