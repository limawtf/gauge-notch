import Testing
import Foundation
@testable import ClaudeNotch

@Suite("Keychain: parse do blob do security -w")
struct KeychainReaderTests {
    @Test("Extrai accessToken e subscriptionType (tolera o \\n final do security -w)")
    func parsesBlob() {
        let blob = "{\"claudeAiOauth\":{\"accessToken\":\"tok_abc\",\"subscriptionType\":\"max\"}}\n"
        let creds = KeychainReader.parseCredentials(Data(blob.utf8))
        #expect(creds?.accessToken == "tok_abc")
        #expect(creds?.subscriptionType == "max")
    }

    @Test("subscriptionType ausente -> nil, mas ainda le o token")
    func missingSubscription() {
        let blob = #"{"claudeAiOauth":{"accessToken":"t"}}"#
        let creds = KeychainReader.parseCredentials(Data(blob.utf8))
        #expect(creds?.accessToken == "t")
        #expect(creds?.subscriptionType == nil)
    }

    @Test("blob invalido / sem oauth -> nil, nunca crasha")
    func invalid() {
        #expect(KeychainReader.parseCredentials(Data("nao e json".utf8)) == nil)
        #expect(KeychainReader.parseCredentials(Data(#"{"outra":"coisa"}"#.utf8)) == nil)
        #expect(KeychainReader.parseCredentials(Data("".utf8)) == nil)
    }
}
