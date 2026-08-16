import Testing
import Foundation
@testable import ClaudeNotch

@Suite("PATH aumentado pros processos filhos (bug do launchd/login item)")
struct AugmentedPATHTests {
    @Test("PATH minimo do launchd ganha os prefixos de pacote na frente, sem perder os originais")
    func prependsKnownPrefixesToMinimalPATH() {
        let env = augmentedPATHEnvironment(base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        let parts = env["PATH"]!.split(separator: ":").map(String.init)
        let localBin = NSHomeDirectory() + "/.local/bin"
        #expect(parts.prefix(3) == ["/opt/homebrew/bin", "/usr/local/bin", localBin])
        #expect(parts.suffix(4) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }

    @Test("prefixo ja presente nao duplica nem muda de posicao")
    func doesNotDuplicateExistingEntries() {
        let base = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        let parts = augmentedPATHEnvironment(base: base)["PATH"]!
            .split(separator: ":").map(String.init)
        #expect(parts.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        // /usr/local/bin e ~/.local/bin faltavam: entram na frente; homebrew fica onde ja estava
        #expect(parts.contains("/usr/local/bin"))
        #expect(parts.last == "/bin")
    }

    @Test("sem PATH no base, ainda sai um PATH com os prefixos")
    func buildsPATHFromScratchWhenAbsent() {
        let env = augmentedPATHEnvironment(base: [:])
        #expect(env["PATH"]!.contains("/opt/homebrew/bin"))
    }

    @Test("outras variaveis do base sao preservadas")
    func preservesOtherVariables() {
        let env = augmentedPATHEnvironment(base: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        #expect(env["HOME"] == "/Users/x")
    }

    // Par de controle do mecanismo real: um script cujo shebang resolve o interpretador
    // via `/usr/bin/env` (como o ccusage do Homebrew resolve `node`) FALHA com o PATH
    // minimo do launchd e FUNCIONA quando o dir do interpretador entra no PATH. Sem o
    // lado que falha, o lado que passa nao provaria que o PATH e o que decide.
    @Test("shebang via env: falha sem o dir no PATH, funciona com ele")
    func shebangInterpreterResolvedThroughPATH() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("augpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let interp = dir.appendingPathComponent("fake-node")
        try "#!/bin/sh\necho ok\n".write(to: interp, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("fake-ccusage")
        try "#!/usr/bin/env fake-node\n".write(to: script, atomically: true, encoding: .utf8)
        for f in [interp, script] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }

        func run(path: String) -> Data? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [script.path]
            p.environment = ["PATH": path]
            return runProcessCapturingStdout(p, timeout: 10)
        }

        // controle: PATH do launchd (sem o dir do interpretador) -> exit != 0 -> nil
        #expect(run(path: "/usr/bin:/bin:/usr/sbin:/sbin") == nil)
        // com o dir prepended (o que augmentedPATHEnvironment faz pro homebrew) -> roda
        let out = run(path: dir.path + ":/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(out.map { String(decoding: $0, as: UTF8.self) }?.contains("ok") == true)
    }
}
