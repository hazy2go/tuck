// Tuck: a tiny menu bar icon hider.
//
// Layout, left to right:
//   [always hidden…] ‖ [hidden…] │ [shown…] ‹
// Hiding works by stretching a divider to 10,000pt so everything left of it is
// pushed off-screen. Arranging is plain macOS ⌘-drag. Only public APIs: the
// dropdown reads items via Accessibility; Tuck never moves your mouse.
//
// Click ‹      show/hide the hidden group (or a dropdown if they won't fit)
// ⌥-click ‹    reveal everything, including always-hidden
// Right-click  menu (Settings…, Quit)

import AppKit
import ServiceManagement
import SwiftUI

let collapsedLength: CGFloat = 10_000
let dividerLength: CGFloat = 14

enum OverflowMode: String, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Dropdown when icons don't fit"
        case .always: "Always use dropdown"
        case .never: "Never (always slide in)"
        }
    }
}

enum Pref {
    static let autoHide = "tuck.autoHideSeconds"
    static let overflow = "tuck.overflowMode"
    static let hasLaunched = "tuck.hasLaunched"
}

@MainActor
final class Tuck: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: Tuck!

    enum State { case collapsed, shown, all }
    private(set) var state: State = .shown

    private var toggle: NSStatusItem!
    private var divider: NSStatusItem!
    private var alwaysDivider: NSStatusItem!
    private var hideTimer: Timer?
    private var menuWatch: Timer?
    private var settingsWindow: NSWindow?

    var autoHideSeconds: Int {
        get { UserDefaults.standard.object(forKey: Pref.autoHide) as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: Pref.autoHide) }
    }

    var overflowMode: OverflowMode {
        get { OverflowMode(rawValue: UserDefaults.standard.string(forKey: Pref.overflow) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Pref.overflow) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Self.shared = self
        // First run: seed the chevron and divider just left of the system
        // icons. The always-hidden divider isn't seeded: new status items land
        // leftmost, which means "nothing is always hidden" until you say so.
        let d = UserDefaults.standard
        if !d.bool(forKey: Pref.hasLaunched) {
            d.set(0, forKey: "NSStatusItem Preferred Position \(BarItem.toggleID)")
            d.set(1, forKey: "NSStatusItem Preferred Position \(BarItem.dividerID)")
            d.set(true, forKey: Pref.hasLaunched)
        }

        toggle = makeItem(BarItem.toggleID, length: NSStatusItem.variableLength, label: "Tuck")
        divider = makeItem(BarItem.dividerID, length: dividerLength, label: "Tuck divider")
        divider.button?.image = bar(lines: 1)
        alwaysDivider = makeItem(BarItem.alwaysID, length: dividerLength, label: "Tuck always-hidden divider")
        alwaysDivider.button?.image = bar(lines: 2)

        if !MenuBar.isTrusted { MenuBar.requestTrust() }
        rediscover(after: 0)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rediscoverQuick() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // New apps take a moment to add their icon; look twice.
                Task { @MainActor in self?.rediscover(after: 2); self?.rediscover(after: 8) }
            }
        }

        // Give macOS a beat to place the items before measuring positions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.set(.collapsed) }
    }

    /// Last scan, so the dropdown can open instantly. Refreshed in the background.
    private var cache: [BarItem] = []

    private func rediscover(after delay: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            MenuBar.discover()
            let items = MenuBar.scan()
            DispatchQueue.main.async { self.cache = items }
        }
    }

    private func makeItem(_ id: String, length: CGFloat, label: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = id
        item.behavior = []                      // can't be ⌘-dragged off the bar
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.setAccessibilityLabel(label)
        }
        return item
    }

    // MARK: state

    func set(_ wanted: State) {
        hideTimer?.invalidate()
        var s = wanted
        // Safety: if a divider is on the wrong side, stretching it would shove
        // the chevron off-screen and you'd lose the toggle. Refuse and show all.
        if s != .all && !isLeft(divider, of: toggle) {
            s = .all
            notice("Hold ⌘ and drag the │ divider to the left of ‹")
        }
        let alwaysOK = isLeft(alwaysDivider, of: divider)
        state = s
        divider.length = s == .collapsed ? collapsedLength : dividerLength
        alwaysDivider.length = (s == .shown && alwaysOK) ? collapsedLength : dividerLength
        divider.button?.isHidden = s == .collapsed
        alwaysDivider.button?.isHidden = s != .all
        toggle.button?.image = symbol(s == .collapsed ? "chevron.left" : "chevron.right")
        toggle.button?.toolTip = s == .collapsed ? "Show hidden icons (⌥-click: show all)" : "Hide icons"
        if s != .collapsed { scheduleAutoHide() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.rediscoverQuick() } }
    }

    private func isLeft(_ a: NSStatusItem, of b: NSStatusItem) -> Bool {
        guard let fa = a.button?.window?.frame, let fb = b.button?.window?.frame else { return true }
        return fa.maxX <= fb.minX + 1
    }

    /// Our three items' frames in CG coordinates, for Settings and the dropdown.
    func ownFrames() -> [String: CGRect] {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var out: [String: CGRect] = [:]
        for (id, item) in [(BarItem.toggleID, toggle), (BarItem.dividerID, divider), (BarItem.alwaysID, alwaysDivider)] {
            guard let f = item?.button?.window?.frame else { continue }
            out[id] = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
        }
        return out
    }

    /// Splits scanned items into (always hidden, hidden, shown) by divider position.
    func sections(_ items: [BarItem]) -> (always: [BarItem], hidden: [BarItem], shown: [BarItem]) {
        let own = ownFrames()
        guard let div = own[BarItem.dividerID] else { return ([], [], items) }
        let always = isLeft(alwaysDivider, of: divider) ? own[BarItem.alwaysID] : nil
        var a: [BarItem] = [], h: [BarItem] = [], s: [BarItem] = []
        for it in items {
            if let always, it.frame.midX < always.minX { a.append(it) }
            else if it.frame.midX < div.minX { h.append(it) }
            else { s.append(it) }
        }
        return (a, h, s)
    }

    private func scheduleAutoHide() {
        guard autoHideSeconds > 0 else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoHideSeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state != .collapsed else { return }
                // Don't yank icons away while the pointer is in the menu bar
                // (you're probably about to click one) or a menu is open.
                if self.pointerInMenuBar || self.menuWatch != nil { self.scheduleAutoHide() }
                else { self.set(.collapsed) }
            }
        }
    }

    private var pointerInMenuBar: Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return p.y >= screen.frame.maxY - max(barHeight, 24)
    }

    // MARK: clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        let flags = e?.modifierFlags ?? []
        if e?.type == .rightMouseUp || flags.contains(.control) {
            showMainMenu()
        } else if flags.contains(.option) {
            set(state == .all ? .collapsed : .all)
        } else if state != .collapsed {
            set(.collapsed)
        } else {
            expandOrDropdown()
        }
    }

    private func expandOrDropdown() {
        switch overflowMode {
        case .never: set(.shown)
        case .always: scanThen { self.showDropdown($0) }
        case .auto: scanThen { $0.isEmpty || self.fits($0) ? self.set(.shown) : self.showDropdown($0) }
        }
    }

    /// Uses the cached scan when there is one (instant), and refreshes it
    /// in the background for next time.
    private func scanThen(_ then: @escaping @MainActor ([BarItem]) -> Void) {
        if !cache.isEmpty {
            then(cache)
            rediscoverQuick()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = MenuBar.scan()
            DispatchQueue.main.async { self.cache = items; then(items) }
        }
    }

    private func rediscoverQuick() {
        DispatchQueue.global(qos: .utility).async {
            let items = MenuBar.scan()
            DispatchQueue.main.async { self.cache = items }
        }
    }

    /// Would the hidden group fit next to the shown icons on this screen?
    /// Only notched screens overflow; elsewhere macOS shortens app menus instead.
    private func fits(_ items: [BarItem]) -> Bool {
        guard let screen = toggle.button?.window?.screen,
              let right = screen.auxiliaryTopRightArea,
              let div = divider.button?.window?.frame else { return true }
        let shownWidth = screen.frame.maxX - div.maxX          // shown icons + ‹ + system icons
        let hiddenWidth = sections(items).hidden.reduce(0) { $0 + $1.frame.width }
        return shownWidth + dividerLength + hiddenWidth <= right.width - 8
    }

    // MARK: dropdown

    private func showDropdown(_ items: [BarItem]) {
        let (always, hidden, _) = sections(items)
        let m = NSMenu()
        if hidden.isEmpty && always.isEmpty {
            m.addItem(disabled: "No hidden icons")
        }
        for it in hidden { m.addItem(entry(for: it, always: false)) }
        if !always.isEmpty {
            if !hidden.isEmpty { m.addItem(.separator()) }
            let sub = NSMenu()
            for it in always { sub.addItem(entry(for: it, always: true)) }
            let parent = NSMenuItem(title: "Always Hidden", action: nil, keyEquivalent: "")
            parent.image = symbol("eye.slash")
            parent.submenu = sub
            m.addItem(parent)
        }
        m.addItem(.separator())
        m.addItem(action: "Slide Into Menu Bar", #selector(slideIn), target: self)
        m.addItem(action: "Settings…", #selector(openSettings), target: self, key: ",")
        popUp(m)
    }

    private func entry(for it: BarItem, always: Bool) -> NSMenuItem {
        let mi = NSMenuItem(title: it.name, action: #selector(openItem(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = it.id
        mi.tag = always ? 1 : 0
        if let icon = it.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
        }
        return mi
    }

    @objc private func slideIn() { set(.shown) }

    /// Opens a hidden item's own menu. Its menu appears wherever the item is,
    /// so it's slid back into the bar first (even behind the notch, the menu
    /// drops down below it where you can see it), then hidden again once its
    /// menu closes.
    @objc private func openItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = cache.first(where: { $0.id == id }) else { return }
        set(sender.tag == 1 ? .all : .shown)
        hideTimer?.invalidate()
        watchMenu(of: item.pid)
        // One short beat for the bar to re-lay out, then click the item using
        // the cached accessibility handle (no re-scan).
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) {
            MenuBar.press(item)
        }
    }

    private func watchMenu(of pid: pid_t) {
        menuWatch?.invalidate()
        var closedTicks = 0, ticks = 0
        menuWatch = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { return t.invalidate() }
                ticks += 1
                closedTicks = MenuBar.hasOpenMenu(pid: pid) ? 0 : closedTicks + 1
                // Grace period for the menu to appear, then hide once it's gone.
                // Capped at 60s: some system apps keep extra windows around
                // that would otherwise look like a menu that never closes.
                if (ticks > 3 && closedTicks >= 2) || ticks > 150 {
                    t.invalidate()
                    self.menuWatch = nil
                    self.set(.collapsed)
                }
            }
        }
    }

    // MARK: menus

    private func showMainMenu() {
        let m = NSMenu()
        m.addItem(action: state == .collapsed ? "Show Hidden Icons" : "Hide Icons", #selector(toggleShown), target: self)
        m.addItem(action: state == .all ? "Hide Everything" : "Show Everything", #selector(toggleAll), target: self)
        m.addItem(.separator())
        m.addItem(action: "Settings…", #selector(openSettings), target: self, key: ",")
        m.addItem(.separator())
        m.addItem(action: "Quit Tuck", #selector(quit), target: self, key: "q")
        popUp(m)
    }

    private func popUp(_ m: NSMenu) {
        m.delegate = self
        toggle.menu = m
        toggle.button?.performClick(nil)
    }

    private func notice(_ text: String) {
        let m = NSMenu()
        m.addItem(disabled: text)
        popUp(m)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left-click toggles instead of reopening the menu.
        Task { @MainActor in self.toggle.menu = nil }
    }

    @objc private func toggleShown() { set(state == .collapsed ? .shown : .collapsed) }
    @objc private func toggleAll() { set(state == .all ? .collapsed : .all) }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Tuck Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel()))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        // Leave everything visible on the way out.
        divider.length = dividerLength
        alwaysDivider.length = dividerLength
        NSApp.terminate(nil)
    }

    // MARK: drawing

    func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    /// A thin vertical bar (│) or double bar (‖) for the dividers.
    private func bar(lines: Int) -> NSImage {
        let w: CGFloat = lines == 1 ? 8 : 10
        let img = NSImage(size: NSSize(width: w, height: 16), flipped: false) { r in
            NSColor.black.setFill()
            let xs: [CGFloat] = lines == 1 ? [r.midX] : [r.midX - 2, r.midX + 2]
            for x in xs {
                NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: 2, width: 1.5, height: 12),
                             xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

extension NSMenu {
    func addItem(disabled title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        addItem(i)
    }

    func addItem(action title: String, _ sel: Selector, target: AnyObject, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = target
        addItem(i)
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Tuck()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
