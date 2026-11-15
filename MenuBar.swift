// Reading and opening other apps' menu bar items.
//
// Reading: every app exposes its status items through the Accessibility API
// (AXExtrasMenuBar) with owner, position and size. No screen recording needed.
// Opening: AXPress on the item, the same as clicking it.
// Both need the Accessibility permission. Tuck never moves your mouse.

import AppKit
import ApplicationServices

struct BarItem: Identifiable, Equatable {
    let id: String
    let name: String
    var frame: CGRect           // global CG coordinates (top-left origin)
    let icon: NSImage?
    let pid: pid_t
    let element: AXUIElement?

    static let dividerID = "tuck.divider"
    static let alwaysID = "tuck.always"
    static let toggleID = "tuck.toggle"
    var isDivider: Bool { id == Self.dividerID || id == Self.alwaysID }

    static func == (a: BarItem, b: BarItem) -> Bool { a.id == b.id && a.frame == b.frame }
}

enum MenuBar {
    static let ownBundle = Bundle.main.bundleIdentifier ?? "local.tuck"

    /// Items macOS pins in place; ⌘-dragging them does nothing.
    private static let immovable: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
        "com.apple.menuextra.audiovideo",   // the orange/green "in use" pill
    ]

    private static let friendlyNames: [String: String] = [
        "com.apple.TextInputMenuAgent": "Input Sources",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Every movable item from apps known to have some, left to right. Off the main thread.
    // Of ~100 running processes only a dozen own menu bar items. Asking all of
    // them is slow (helper processes like Safari Web Content time out), so a
    // full sweep runs rarely (launch, app launched/quit) and `scan` only asks
    // the apps known to have items.
    nonisolated(unsafe) private static var knownPids: Set<pid_t> = []
    private static let lock = NSLock()

    /// Full sweep to find which apps own menu bar items. Call off the main thread.
    static func discover() {
        guard isTrusted else { return }
        var found: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, bid != ownBundle, !app.isTerminated,
                  !bid.contains(".WebContent"), !bid.hasSuffix(".xpc") else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.1)
            if attr(ax, "AXExtrasMenuBar") != nil { found.insert(app.processIdentifier) }
        }
        lock.lock(); knownPids = found; lock.unlock()
    }

    static func scan() -> [BarItem] {
        guard isTrusted else { return [] }
        lock.lock(); var pids = knownPids; lock.unlock()
        if pids.isEmpty { discover(); lock.lock(); pids = knownPids; lock.unlock() }
        var out: [BarItem] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  let bid = app.bundleIdentifier else { continue }
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.25)   // a hung app can't stall us
            guard let barRef = attr(ax, "AXExtrasMenuBar"),
                  CFGetTypeID(barRef) == AXUIElementGetTypeID() else { continue }
            let kids = attr(barRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let isSystem = bid == "com.apple.controlcenter" || bid == "com.apple.systemuiserver"
            for (i, k) in kids.enumerated() {
                guard let f = frame(of: k), f.width > 1 else { continue }
                let ident = attr(k, "AXIdentifier") as? String
                if let ident, immovable.contains(ident) { continue }
                let title = (attr(k, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                let desc = (attr(k, kAXDescriptionAttribute) as? String)?
                    .components(separatedBy: ",").first.flatMap { $0.isEmpty ? nil : $0 }
                // Control Center keeps invisible placeholder items around; skip them.
                if isSystem && ident == nil && desc == nil { continue }

                var name = friendlyNames[bid] ?? app.localizedName ?? bid
                if isSystem { name = desc ?? name }
                else if kids.count > 1, let extra = desc ?? title, extra != name { name += " – \(extra)" }

                let key = ident ?? title ?? desc ?? "\(i)"
                out.append(BarItem(id: "\(bid)|\(key)", name: name, frame: f,
                                   icon: app.icon, pid: app.processIdentifier, element: k))
            }
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Click an item (opens its menu or popover). Blocks while some apps'
    /// menus track, so call off the main thread.
    static func press(_ item: BarItem) {
        guard let e = item.element else { return }
        AXUIElementSetMessagingTimeout(e, 2)
        AXUIElementPerformAction(e, kAXPressAction as CFString)
    }

    /// Is `pid` showing a menu, popover or panel right now?
    static func hasOpenMenu(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            ($0[kCGWindowLayer as String] as? Int).map { $0 != 0 && $0 != statusLevel } == true
        }
    }
}
