import Foundation

/// Nome legivel do projeto. Preferimos o `cwd` capturado de dentro do proprio jsonl
/// (ultimo componente do path), que e exato. So caimos pro slug da pasta de projeto
/// (`-Users-you-Documents-Apps-claude-notch`) quando ainda nao lemos nenhum cwd
/// (arquivo novo, primeira linha ainda nao chegou): revertendo o slug com "-" -> "/"
/// da errado quando o nome de uma pasta real tem hifen (ex. "claude-notch" vira
/// "claude/notch"), entao no fallback so pegamos o ULTIMO pedaco do slug mesmo assim
/// (aproximado, mas nunca pior que mostrar o slug cru inteiro).
func projectDisplayName(cwd: String?, folderSlug: String) -> String {
    if let cwd, let last = cwd.split(separator: "/").last, !last.isEmpty {
        return String(last)
    }
    let stripped = folderSlug.hasPrefix("-") ? String(folderSlug.dropFirst()) : folderSlug
    let parts = stripped.split(separator: "-")
    guard let last = parts.last, !last.isEmpty else { return folderSlug }
    return String(last)
}
