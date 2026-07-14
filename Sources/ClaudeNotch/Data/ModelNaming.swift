import Foundation

/// Nome curto pra exibir (ex. "claude-opus-4-8" -> "Opus 4.8"). Procura a familia
/// (opus/sonnet/haiku) em qualquer posicao do id (a ordem mudou entre geracoes: nos
/// modelos antigos o numero vem ANTES do nome, ex. "claude-3-5-haiku-20241022"; nos
/// novos vem DEPOIS, ex. "claude-sonnet-4-5"), e junta os pedacos puramente numericos
/// com "<8 digitos" como versao (exclui datas tipo 20241022).
func shortModelName(_ raw: String) -> String {
    guard !raw.isEmpty else { return "?" }
    let lower = raw.lowercased()
    let family: String
    if lower.contains("opus") { family = "Opus" }
    else if lower.contains("sonnet") { family = "Sonnet" }
    else if lower.contains("haiku") { family = "Haiku" }
    else { family = "" }

    let version = raw.split(separator: "-")
        .map(String.init)
        .filter { $0.count < 8 && Int($0) != nil }
        .joined(separator: ".")

    if family.isEmpty { return raw }
    return version.isEmpty ? family : "\(family) \(version)"
}

/// Cor do "dot" por familia de modelo, mesma linguagem visual do Theme (cores fixas,
/// nao dependem de limiar de uso).
func modelDotColor(_ model: String) -> AgentModelColor {
    let m = model.lowercased()
    if m.contains("opus") { return .opus }
    if m.contains("sonnet") { return .sonnet }
    if m.contains("haiku") { return .haiku }
    return .unknown
}

enum AgentModelColor: Equatable {
    case opus, sonnet, haiku, unknown
}
