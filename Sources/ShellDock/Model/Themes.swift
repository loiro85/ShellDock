import AppKit
import SwiftTerm

struct TerminalTheme: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let background: String
    let foreground: String
    let cursor: String
    let ansi: [String]     // 16 colores

    static func named(_ n: String) -> TerminalTheme { all.first { $0.name == n } ?? all[0] }

    static let all: [TerminalTheme] = [
        TerminalTheme(name: "ShellDock Oscuro", background: "#14171f", foreground: "#d7dae0", cursor: "#ffb703",
            ansi: ["#1b1f2b", "#ff6b6b", "#7ee787", "#ffd166", "#6cb6ff", "#d2a8ff", "#56d4dd", "#c9d1d9",
                   "#4b5263", "#ff8b8b", "#9bf0a3", "#ffe08a", "#8cc8ff", "#e1c2ff", "#7be3ea", "#ffffff"]),
        TerminalTheme(name: "Solarized Oscuro", background: "#002b36", foreground: "#93a1a1", cursor: "#93a1a1",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#586e75", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalTheme(name: "Solarized Claro", background: "#fdf6e3", foreground: "#586e75", cursor: "#586e75",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalTheme(name: "Dracula", background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2",
            ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                   "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        TerminalTheme(name: "Nord", background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9",
            ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                   "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        TerminalTheme(name: "Monokai", background: "#272822", foreground: "#f8f8f2", cursor: "#f8f8f0",
            ansi: ["#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                   "#75715e", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"]),
        TerminalTheme(name: "One Dark", background: "#282c34", foreground: "#abb2bf", cursor: "#528bff",
            ansi: ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                   "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
        TerminalTheme(name: "Gruvbox", background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2",
            ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                   "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        TerminalTheme(name: "Claro clásico", background: "#ffffff", foreground: "#1f2328", cursor: "#0969da",
            ansi: ["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                   "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"]),
        TerminalTheme(name: "Matrix", background: "#000000", foreground: "#33ff66", cursor: "#33ff66",
            ansi: ["#000000", "#ff3333", "#33ff66", "#ffff33", "#3399ff", "#ff33ff", "#33ffff", "#cccccc",
                   "#555555", "#ff6666", "#66ff99", "#ffff66", "#66b3ff", "#ff66ff", "#66ffff", "#ffffff"]),
    ]

    func apply(to view: TerminalView, font: NSFont) {
        view.font = font
        view.nativeBackgroundColor = NSColor(hex: background)
        view.nativeForegroundColor = NSColor(hex: foreground)
        view.caretColor = NSColor(hex: cursor)
        view.installColors(ansi.map { Self.swiftTermColor($0) })
    }

    static func swiftTermColor(_ hex: String) -> SwiftTerm.Color {
        let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
        return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535), blue: UInt16(c.blueComponent * 65535))
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
