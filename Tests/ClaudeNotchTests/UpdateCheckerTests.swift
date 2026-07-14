import Foundation
import Testing
@testable import ClaudeNotch

@Suite("Semver: compareVersions/isNewerVersion")
struct SemVerTests {
    @Test("0.1.0 < 0.1.1 < 0.2.0 < 1.0.0")
    func ordersCorrectly() {
        #expect(compareVersions("0.1.0", "0.1.1") < 0)
        #expect(compareVersions("0.1.1", "0.2.0") < 0)
        #expect(compareVersions("0.2.0", "1.0.0") < 0)
        #expect(compareVersions("0.1.1", "0.1.0") > 0)
        #expect(compareVersions("1.0.0", "0.2.0") > 0)
    }

    @Test("versao igual nao e mais nova (nao dispara update)")
    func equalIsNotNewer() {
        #expect(compareVersions("0.1.0", "0.1.0") == 0)
        #expect(isNewerVersion("0.1.0", than: "0.1.0") == false)
    }

    @Test("isNewerVersion reflete a direcao certa")
    func isNewerVersionDirection() {
        #expect(isNewerVersion("0.2.0", than: "0.1.9") == true)
        #expect(isNewerVersion("0.1.9", than: "0.2.0") == false)
        #expect(isNewerVersion("1.2.3", than: "1.2.3") == false)
    }

    @Test("componente ausente conta como 0 (patch faltando)")
    func missingComponentCountsAsZero() {
        #expect(compareVersions("1.2", "1.2.0") == 0)
        #expect(isNewerVersion("1.3", than: "1.2.9") == true)
    }

    @Test("sufixo tipo -beta e ignorado na comparacao numerica")
    func suffixIsIgnored() {
        #expect(compareVersions("1.2.0-beta", "1.2.0") == 0)
        #expect(isNewerVersion("1.3.0-beta", than: "1.2.0") == true)
    }

    @Test("versao malformada nao crasha, so compara o que da pra entender")
    func malformedNeverCrashes() {
        #expect(compareVersions("abc", "1.0.0") < 0) // "abc" vira 0.0.0
        #expect(compareVersions("", "") == 0)
        #expect(compareVersions("1.x.0", "1.0.0") == 0) // "x" vira 0
        #expect(isNewerVersion("not-a-version", than: "0.1.0") == false)
    }
}

@Suite("Manifesto (latest.json): decode + validacao")
struct UpdateManifestTests {
    @Test("decodifica um manifesto valido")
    func decodesValidManifest() throws {
        let json = """
        {"version":"0.2.0","notes":"correcoes","dmg":"https://github.com/limawtf/gauge-notch-releases/releases/download/v0.2.0/Gauge-0.2.0.dmg","sha256":"\(String(repeating: "a", count: 64))","minMacOS":"13.0"}
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "0.2.0")
        #expect(manifest.notes == "correcoes")
        #expect(manifest.sha256.count == 64)
    }

    @Test("campo faltando (notes/minMacOS opcionais) ainda decodifica")
    func decodesWithOptionalFieldsMissing() throws {
        let json = """
        {"version":"0.2.0","dmg":"https://example.com/x.dmg","sha256":"\(String(repeating: "b", count: 64))"}
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.notes == nil)
        #expect(manifest.minMacOS == nil)
    }

    @Test("campo obrigatorio faltando (version) falha o decode")
    func missingRequiredFieldFailsDecode() {
        let json = """
        {"dmg":"https://example.com/x.dmg","sha256":"\(String(repeating: "c", count: 64))"}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        }
    }

    @Test("JSON invalido (nao e objeto) falha o decode")
    func invalidJSONFailsDecode() {
        let data = Data("not json".utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(UpdateManifest.self, from: data)
        }
    }

    @Test("makeUpdateInfo aceita manifesto valido (https + sha256 de 64 hex)")
    func makeUpdateInfoAcceptsValid() {
        let manifest = UpdateManifest(
            version: "0.2.0", notes: "x",
            dmg: "https://github.com/limawtf/gauge-notch-releases/releases/download/v0.2.0/Gauge-0.2.0.dmg",
            sha256: String(repeating: "a", count: 64), minMacOS: "13.0"
        )
        let info = makeUpdateInfo(from: manifest)
        #expect(info != nil)
        #expect(info?.version == "0.2.0")
        #expect(info?.dmgURL.scheme == "https")
    }

    @Test("makeUpdateInfo rejeita URL nao-https")
    func makeUpdateInfoRejectsNonHTTPS() {
        let manifest = UpdateManifest(
            version: "0.2.0", notes: nil, dmg: "http://example.com/x.dmg",
            sha256: String(repeating: "a", count: 64), minMacOS: nil
        )
        #expect(makeUpdateInfo(from: manifest) == nil)
    }

    @Test("makeUpdateInfo rejeita sha256 com formato invalido (curto ou nao-hex)")
    func makeUpdateInfoRejectsBadHash() {
        let tooShort = UpdateManifest(
            version: "0.2.0", notes: nil, dmg: "https://example.com/x.dmg", sha256: "abc", minMacOS: nil
        )
        #expect(makeUpdateInfo(from: tooShort) == nil)

        let notHex = UpdateManifest(
            version: "0.2.0", notes: nil, dmg: "https://example.com/x.dmg",
            sha256: String(repeating: "z", count: 64), minMacOS: nil
        )
        #expect(makeUpdateInfo(from: notHex) == nil)
    }

    @Test("makeUpdateInfo rejeita URL sem host")
    func makeUpdateInfoRejectsNoHost() {
        let manifest = UpdateManifest(
            version: "0.2.0", notes: nil, dmg: "https://", sha256: String(repeating: "a", count: 64), minMacOS: nil
        )
        #expect(makeUpdateInfo(from: manifest) == nil)
    }

    @Test("isValidSHA256Hex so aceita 64 digitos hex")
    func sha256HexFormatCheck() {
        #expect(isValidSHA256Hex(String(repeating: "a", count: 64)) == true)
        #expect(isValidSHA256Hex(String(repeating: "A", count: 64)) == true)
        #expect(isValidSHA256Hex(String(repeating: "a", count: 63)) == false)
        #expect(isValidSHA256Hex(String(repeating: "g", count: 64)) == false)
    }
}
