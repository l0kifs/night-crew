import AppKit
import NightCrewCore

/// A menu item that runs a closure; the menu retains it, and it is its own target.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// SPEC §10. The menu is rebuilt each time it opens, from the latest tick; the icon follows every tick.
final class MenuController: NSObject, NSMenuDelegate {
    static let fixCommand = "curl -fsSL https://raw.githubusercontent.com/l0kifs/nightcrew/main/scripts/install.sh | bash"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let settings: Settings
    private let loop: PollLoop
    private let quit: () -> Void
    private var tick: Tick?

    init(settings: Settings, loop: PollLoop, quit: @escaping () -> Void) {
        self.settings = settings
        self.loop = loop
        self.quit = quit
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon("moon.zzz")
    }

    func update(_ tick: Tick) {
        self.tick = tick
        setIcon(MenuText.iconSymbol(tick.output))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        Self.build(into: menu, tick: tick, settings: settings, now: Date(), apply: apply, retry: { [loop] in
            loop.retry()
            loop.pollNow()
        }, quit: quit)
    }

    private func apply(mode: Mode?, config: Config?) {
        if let mode {
            settings.mode = mode
            loop.mode = mode
        }
        if let config {
            settings.config = config
            loop.config = config
        }
        loop.pollNow()
    }

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NightCrew")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Builds the §10 menu. Static and data-driven so `nightcrew menu` can print it without a status item.
    static func build(into menu: NSMenu, tick: Tick?, settings: Settings, now: Date,
                      apply: @escaping (_ mode: Mode?, _ config: Config?) -> Void,
                      retry: @escaping () -> Void, quit: @escaping () -> Void) {
        func info(_ title: String, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = indent
            menu.addItem(item)
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            items.forEach(child.addItem)
            parent.submenu = child
            menu.addItem(parent)
        }

        let home = NSHomeDirectory()
        if let tick {
            info(MenuText.statusLine(tick.output.status, sessions: tick.activity.sessions, now: now))
            if let degraded = MenuText.degradedLine(tick.activity.degraded) { info(degraded) }
            for session in tick.activity.sessions.sorted(by: { $0.root.pid < $1.root.pid }) {
                info(MenuText.sessionRow(session, home: home), indent: 1)
            }
            if tick.output.status == .setupRequired {
                menu.addItem(ActionItem("Copy fix command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fixCommand, forType: .string)
                })
            }
            switch tick.output.status {
            case .setupRequired, .error: menu.addItem(ActionItem("Retry", handler: retry))
            default: break
            }
        } else {
            info("Starting…")
        }
        menu.addItem(.separator())

        let mode = settings.mode
        var config = settings.config
        let alwaysOnTitle: String
        if case .alwaysOn(let until) = mode, until > now {
            alwaysOnTitle = "Always awake (reverts in \(MenuText.duration(until.timeIntervalSince(now))))"
        } else {
            alwaysOnTitle = "Always awake (\(MenuText.duration(config.alwaysAwakeDuration)))"
        }
        let isAlwaysOn: Bool = { if case .alwaysOn(let until) = mode { return until > now }; return false }()
        submenu("Mode", [
            ActionItem("Auto", checked: mode == .auto) { apply(.auto, nil) },
            ActionItem(alwaysOnTitle, checked: isAlwaysOn) { apply(.alwaysOn(until: Date().addingTimeInterval(config.alwaysAwakeDuration)), nil) },
            ActionItem("Off", checked: mode == .off) { apply(.off, nil) },
        ])
        submenu("Grace period", [0, 5, 10, 30].map { minutes in
            ActionItem("\(minutes) min", checked: Int(config.grace / 60) == minutes) {
                var changed = config
                changed.grace = TimeInterval(minutes * 60)
                apply(nil, changed)
            }
        })
        submenu("Battery floor", [nil, 10, 15, 30].map { floor in
            ActionItem(floor.map { "\($0)%" } ?? "Off", checked: config.batteryFloor == floor) {
                var changed = config
                changed.batteryFloor = floor
                apply(nil, changed)
            }
        })
        menu.addItem(ActionItem("Sleep display when lid closes", checked: config.sleepDisplayOnLidClose) {
            config.sleepDisplayOnLidClose.toggle()
            apply(nil, config)
        })
        menu.addItem(ActionItem("Sleep Mac when agents finish (lid closed)", checked: config.sleepWhenDone) {
            config.sleepWhenDone.toggle()
            apply(nil, config)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit NightCrew", key: "q", handler: quit))
    }
}
