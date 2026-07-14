import Combine

/// Qual pagina o painel do notch mostra agora. Simples o bastante pra nao duplicar o
/// DynamicNotch (o conteudo interno do PanelView reage a essa troca; a janela em si
/// nao e recriada).
@MainActor
final class PanelNavigation: ObservableObject {
    enum Page {
        case usage
        case agents
    }

    @Published var page: Page = .usage
}
