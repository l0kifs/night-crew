import AppKit
import NightCrewCore

/// `nightcrew menu`: one real poll (dry: nothing executed), then the §10 menu printed as text.
struct MenuCommand {
    func run() {
        var poller = Poller(processes: ProcessProbe(), transcripts: TranscriptProbe(), power: PowerControl(),
                            ownership: OwnershipFile(), clock: SystemClock())
        let settings = Settings()
        let tick = poller.tick(mode: settings.mode)
        let menu = NSMenu()
        MenuController.build(into: menu, tick: tick, settings: settings, now: Date(),
                             apply: { _, _ in }, retry: {}, quit: {})
        print("icon: \(MenuText.iconSymbol(tick.output))")
        printItems(menu, depth: 0)
    }

    private func printItems(_ menu: NSMenu, depth: Int) {
        for item in menu.items {
            let pad = String(repeating: "    ", count: depth + item.indentationLevel)
            if item.isSeparatorItem { print("\(pad)──────────"); continue }
            let mark = item.state == .on ? "✓ " : (item.submenu == nil && item.isEnabled ? "  " : "")
            print("\(pad)\(mark)\(item.title)\(item.submenu != nil ? " ▸" : "")\(item.isEnabled ? "" : "   (disabled)")"
                  + (item.keyEquivalent.isEmpty ? "" : "   ⌘\(item.keyEquivalent.uppercased())"))
            if let submenu = item.submenu { printItems(submenu, depth: depth + 1) }
        }
    }
}
