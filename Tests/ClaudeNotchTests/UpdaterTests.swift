import Foundation
import Testing
@testable import ClaudeNotch

@Suite("sha256: hash + verificacao")
struct Sha256Tests {
    @Test("hash de string vazia bate com o vetor conhecido")
    func knownVectorEmptyString() {
        // sha256("") e um vetor de teste padrao, sempre o mesmo hash.
        #expect(sha256Hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("hash de 'abc' bate com o vetor conhecido do NIST")
    func knownVectorAbc() {
        #expect(sha256Hex(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("verifySHA256 aceita quando o hash bate (case-insensitive)")
    func verifyAcceptsMatch() {
        let data = Data("conteudo do dmg".utf8)
        let hex = sha256Hex(of: data)
        #expect(verifySHA256(data: data, expectedHex: hex) == true)
        #expect(verifySHA256(data: data, expectedHex: hex.uppercased()) == true)
    }

    @Test("verifySHA256 rejeita quando o hash NAO bate")
    func verifyRejectsMismatch() {
        let data = Data("conteudo do dmg".utf8)
        let wrongHex = String(repeating: "0", count: 64)
        #expect(verifySHA256(data: data, expectedHex: wrongHex) == false)
    }

    @Test("verifySHA256 rejeita se o conteudo foi alterado (mesmo 1 byte)")
    func verifyRejectsTamperedContent() {
        let original = Data("conteudo do dmg".utf8)
        let tampered = Data("conteudo do Dmg".utf8) // 1 char de diferenca
        let expectedHex = sha256Hex(of: original)
        #expect(verifySHA256(data: tampered, expectedHex: expectedHex) == false)
    }

    @Test("sha256HexOfFile (streaming em disco) bate com sha256Hex (em memoria)")
    func streamingMatchesInMemory() throws {
        let data = Data(repeating: 0x42, count: 5_000_000) // maior que o chunk de 1MB, forca varias iteracoes
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fromMemory = sha256Hex(of: data)
        let fromDisk = try sha256HexOfFile(at: tmp)
        #expect(fromMemory == fromDisk)
    }
}

@Suite("Bundle identifier: le do Info.plist bruto")
struct BundleIdentifierTests {
    private func plistData(_ dict: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    @Test("le o CFBundleIdentifier certo de um plist valido")
    func readsValidIdentifier() {
        let data = plistData(["CFBundleIdentifier": "wtf.lima.gauge", "CFBundleName": "Gauge"])
        #expect(readBundleIdentifier(plistData: data) == "wtf.lima.gauge")
    }

    @Test("plist sem a chave CFBundleIdentifier retorna nil")
    func missingKeyReturnsNil() {
        let data = plistData(["CFBundleName": "Gauge"])
        #expect(readBundleIdentifier(plistData: data) == nil)
    }

    @Test("dados nao-plist (malformado) retorna nil, sem crashar")
    func malformedDataReturnsNil() {
        let data = Data("nao e um plist".utf8)
        #expect(readBundleIdentifier(plistData: data) == nil)
    }

    @Test("bundle identifier de um app diferente e detectavel (comparacao explicita)")
    func differentBundleIdentifierIsDetected() {
        let data = plistData(["CFBundleIdentifier": "com.malicioso.outroapp"])
        let id = readBundleIdentifier(plistData: data)
        #expect(id != expectedGaugeBundleIdentifier)
    }
}

@Suite("Helper de relaunch: script gerado nao vaza dado do manifesto")
struct RelaunchHelperScriptTests {
    @Test("shellSingleQuote escapa aspas simples embutidas")
    func escapesSingleQuotes() {
        let quoted = shellSingleQuote("it's a path")
        #expect(quoted == "'it'\\''s a path'")
    }

    @Test("script contem o path extraido e o path fixo de instalacao, ambos entre aspas")
    func containsQuotedPaths() {
        let script = makeRelaunchHelperScript(waitingOnPID: 4242, extractedAppPath: "/tmp/Gauge-abc.app")
        #expect(script.contains("'/tmp/Gauge-abc.app'"))
        #expect(script.contains("'/Applications/Gauge.app'"))
        #expect(script.contains("4242"))
    }

    @Test("script so usa o path fixo /Applications/Gauge.app como destino, nunca outro")
    func targetIsAlwaysFixedPath() {
        let script = makeRelaunchHelperScript(waitingOnPID: 1, extractedAppPath: "/tmp/whatever.app")
        #expect(script.contains(installedGaugeAppPath))
    }

    @Test("nada do manifesto (versao/notas/url remota) aparece no script")
    func neverLeaksManifestData() {
        let script = makeRelaunchHelperScript(waitingOnPID: 999, extractedAppPath: "/tmp/Gauge-xyz.app")
        // strings tipicas de um manifesto (versao arbitraria, notas, host remoto) nunca deveriam
        // aparecer. O script so conhece PID + 2 paths locais/fixos.
        #expect(!script.contains("raw.githubusercontent.com"))
        #expect(!script.contains("github.com"))
        #expect(!script.contains("notes"))
        #expect(!script.contains("sha256"))
    }

    @Test("espera o PID atual sair antes de mexer no bundle instalado")
    func waitsForPIDBeforeSwapping() {
        let script = makeRelaunchHelperScript(waitingOnPID: 555, extractedAppPath: "/tmp/x.app")
        let killIndex = script.range(of: "kill -0 555")
        let rmIndex = script.range(of: "rm -rf '/Applications/Gauge.app'")
        #expect(killIndex != nil)
        #expect(rmIndex != nil)
        if let killIndex, let rmIndex {
            #expect(killIndex.lowerBound < rmIndex.lowerBound)
        }
    }
}
