import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var fonts: [String] {
        let preferred = ["Menlo", "Monaco", "SF Mono", "Courier New", "JetBrains Mono", "Fira Code", "Hack", "Source Code Pro"]
        return preferred.filter { NSFont(name: $0, size: 12) != nil }
    }

    var body: some View {
        TabView {
            Form {
                Section("Fuente") {
                    Picker("Fuente", selection: $settings.data.fontName) { ForEach(fonts, id: \.self) { Text($0).tag($0) } }
                    Stepper("Tamaño: \(settings.data.fontSize)", value: $settings.data.fontSize, in: 8...36)
                }
                Section("Tema de color") {
                    Picker("Tema", selection: $settings.data.themeName) { ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) } }
                    ThemePreview(theme: settings.theme)
                }
            }.formStyle(.grouped).tabItem { Label("Apariencia", systemImage: "paintpalette") }

            Form {
                Section("Comportamiento") {
                    Toggle("Usar Option como tecla Meta (Alt)", isOn: $settings.data.optionAsMeta)
                    Toggle("Copiar al seleccionar", isOn: $settings.data.copyOnSelect)
                    Toggle("Confirmar al cerrar pestañas activas", isOn: $settings.data.confirmClose)
                    Stepper("Historial de desplazamiento: \(settings.data.scrollback) líneas", value: $settings.data.scrollback, in: 1000...200000, step: 1000)
                }
                Section("Terminal local") {
                    TextField("Shell (vacío = la del sistema)", text: $settings.data.defaultShell)
                    Toggle("Añadir la caja de herramientas Unix al PATH", isOn: $settings.data.keepToolboxInPath)
                }
            }.formStyle(.grouped).tabItem { Label("Terminal", systemImage: "terminal") }

            Form {
                Section("SSH") {
                    Picker("Claves de host nuevas", selection: $settings.data.hostKeyPolicy) {
                        Text("Aceptar las nuevas, avisar si cambian (recomendado)").tag("accept-new")
                        Text("Preguntar siempre").tag("ask")
                        Text("No comprobar (inseguro)").tag("no")
                    }
                    Toggle("Guardar un registro (log) de cada sesión SSH", isOn: $settings.data.logSessions)
                    Button("Abrir carpeta de registros") { NSWorkspace.shared.open(Paths.logsDir) }
                }
                Section("Panel de archivos") {
                    Stepper("Ancho del panel SFTP: \(settings.data.sftpPanelWidth) px", value: $settings.data.sftpPanelWidth, in: 220...640, step: 20)
                }
            }.formStyle(.grouped).tabItem { Label("SSH", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 440)
    }
}

struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("usuario@servidor:~$ ls -la").foregroundStyle(Color(nsColor: NSColor(hex: theme.foreground)))
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { i in Rectangle().fill(Color(nsColor: NSColor(hex: theme.ansi[i]))).frame(height: 14) }
            }
        }
        .font(.system(.body, design: .monospaced)).padding(10)
        .background(Color(nsColor: NSColor(hex: theme.background)), in: RoundedRectangle(cornerRadius: 8))
    }
}
