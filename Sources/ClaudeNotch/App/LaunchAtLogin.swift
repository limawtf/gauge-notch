import ServiceManagement

/// "Abrir no login" via SMAppService (macOS 13+). So funciona de verdade no .app
/// empacotado e instalado (Info.plist com CFBundleIdentifier valido, ver
/// `scripts/make-app.sh`); num dev build solto (`swift run`/`.build/debug`, sem bundle
/// de verdade) `register()` tende a falhar. Falha e sempre silenciosa (nunca trava o
/// menu de config por causa disso) -- PENDENTE conferir ao vivo com o .app instalado.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // silencioso de proposito: ver comentario acima.
        }
    }
}
