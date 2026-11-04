import SwiftUI
import AppKit

/// Cuadrícula con todas las terminales abiertas (Dividir / MultiExec).
struct TileGridView: View {
    @EnvironmentObject var state: AppState

    var tiles: [TerminalTab] { state.tabs.filter { $0.acceptsInput } }

    var body: some View {
        GeometryReader { geo in
            if tiles.isEmpty {
                Text("No hay terminales abiertas").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let cols = Int(ceil(Double(tiles.count).squareRoot()))
                let rows = Int(ceil(Double(tiles.count) / Double(cols)))
                VStack(spacing: 4) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(0..<cols, id: \.self) { c in
                                let i = r * cols + c
                                if i < tiles.count {
                                    TileView(tab: tiles[i], showExclude: state.multiExec).id(tiles[i].id)
                                } else {
                                    Color.clear
                                }
                            }
                        }
                    }
                }
                .padding(4)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

struct TileView: View {
    @ObservedObject var tab: TerminalTab
    let showExclude: Bool
    @EnvironmentObject var state: AppState

    var receiving: Bool { showExclude && !tab.excluded }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: tab.kind.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(tab.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer()
                if showExclude {
                    Image(systemName: receiving ? "dot.radiowaves.left.and.right" : "nosign")
                        .font(.system(size: 10)).foregroundStyle(receiving ? .orange : .secondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 22).background(.bar)
            NSViewHost(view: tab.content, tabID: tab.id, inset: NSEdgeInsets(top: 4, left: 6, bottom: 2, right: 2))
            if showExclude {
                HStack {
                    Toggle("Exclude", isOn: $tab.excluded).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 24).background(.bar)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(receiving ? Color.orange.opacity(0.8) : Color.primary.opacity(0.15), lineWidth: receiving ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { state.select(tab.id) }
    }
}

/// Barra inferior de MultiExec: lo que se teclea aquí se envía en directo a todas las terminales no excluidas.
struct MultiExecInput: View {
    @EnvironmentObject var state: AppState
    @State private var focused = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.orange)
                Text("MultiExec").font(.caption.bold())
                KeyCatcher(onText: { state.send($0, toAll: true) }, focused: $focused)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                    .overlay(alignment: .leading) {
                        Text(tr("Haz clic y teclea: se escribe en %@ terminal(es) (⌘V pega, Ctrl-C interrumpe)", "\(state.multiTargets.count)"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 8).allowsHitTesting(false)
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.orange : Color.primary.opacity(0.2), lineWidth: focused ? 2 : 1))
                Button("Marcar todas") { for t in state.tabs { t.excluded = false } }
                Button("Excluir todas") { for t in state.tabs { t.excluded = true } }
            }
            .padding(8).background(.bar)
        }
    }
}

/// Vista que captura el teclado y lo traduce a bytes de terminal.
struct KeyCatcher: NSViewRepresentable {
    let onText: (String) -> Void
    @Binding var focused: Bool

    final class V: NSView {
        var onText: (String) -> Void = { _ in }
        var onFocus: (Bool) -> Void = { _ in }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if let s = NSPasteboard.general.string(forType: .string) { onText(s) }
        }
        override func becomeFirstResponder() -> Bool { onFocus(true); return true }
        override func resignFirstResponder() -> Bool { onFocus(false); return true }
        override func performKeyEquivalent(with e: NSEvent) -> Bool {
            guard window?.firstResponder === self, e.modifierFlags.contains(.command) else { return false }
            if e.charactersIgnoringModifiers == "v", let s = NSPasteboard.general.string(forType: .string) { onText(s); return true }
            return false
        }
        override func keyDown(with e: NSEvent) {
            if e.modifierFlags.contains(.command) { return }
            if let s = KeyCatcher.sequence(for: e) { onText(s) }
        }
    }

    func makeNSView(context: Context) -> V {
        let v = V(); v.onText = onText
        v.onFocus = { f in DispatchQueue.main.async { focused = f } }
        return v
    }
    func updateNSView(_ v: V, context: Context) { v.onText = onText }

    static func sequence(for e: NSEvent) -> String? {
        let keys: [UInt16: String] = [36: "\r", 76: "\r", 48: "\t", 51: "\u{7f}", 53: "\u{1b}", 126: "\u{1b}[A", 125: "\u{1b}[B",
                                      124: "\u{1b}[C", 123: "\u{1b}[D", 115: "\u{1b}[H", 119: "\u{1b}[F", 117: "\u{1b}[3~",
                                      116: "\u{1b}[5~", 121: "\u{1b}[6~"]
        if let s = keys[e.keyCode] { return s }
        guard let c = e.characters, !c.isEmpty, !(c.unicodeScalars.first!.value >= 0xF700) else { return nil }
        return e.modifierFlags.contains(.option) && !c.isEmpty && c.unicodeScalars.allSatisfy({ $0.value < 0x80 }) ? "\u{1b}" + c : c
    }
}
