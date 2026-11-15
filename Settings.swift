// Settings: a live view of which icons are shown / hidden / always hidden,
// plus preferences. Arranging is done the macOS way: hold ⌘ and drag.

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var shown: [BarItem] = []
    @Published var hidden: [BarItem] = []
    @Published var always: [BarItem] = []
    @Published var trusted = MenuBar.isTrusted
    @Published var autoHide = Tuck.shared.autoHideSeconds { didSet { Tuck.shared.autoHideSeconds = autoHide } }
    @Published var overflow = Tuck.shared.overflowMode { didSet { Tuck.shared.overflowMode = overflow } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    /// Refresh while the window is open, so ⌘-drags show up live.
    func start() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func reload() {
        trusted = MenuBar.isTrusted
        guard trusted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = MenuBar.scan()
            DispatchQueue.main.async {
                let s = Tuck.shared.sections(items)
                // Settings reads top-to-bottom as right-to-left: the icon
                // nearest the chevron first.
                let shown = Array(s.shown.reversed()), hidden = Array(s.hidden.reversed()),
                    always = Array(s.always.reversed())
                if shown.map(\.id) != self.shown.map(\.id) { self.shown = shown }
                if hidden.map(\.id) != self.hidden.map(\.id) { self.hidden = hidden }
                if always.map(\.id) != self.always.map(\.id) { self.always = always }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        let s = SMAppService.mainApp
        try? (on ? s.register() : s.unregister())
        launchAtLogin = s.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.trusted { permissionBanner }

            howTo

            List {
                group("Shown", "eye", model.shown, empty: "Nothing between │ and ‹")
                group("Hidden", "eye.slash", model.hidden, empty: "Drag icons left of │ to hide them")
                group("Always hidden", "eye.trianglebadge.exclamationmark", model.always,
                      empty: "⌥-click ‹, then drag icons left of ‖")
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 300)

            Divider()

            Form {
                Picker("Auto-hide", selection: $model.autoHide) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("After \($0) seconds").tag($0) }
                    Text("After 1 minute").tag(60)
                }
                Picker("Dropdown menu", selection: $model.overflow) {
                    ForEach(OverflowMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
            }
            .formStyle(.columns)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 600)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arrange with ⌘-drag").font(.headline)
            Group {
                Text("Hold ⌘ and drag any icon in the menu bar. Left of **│** is hidden, left of **‖** is always hidden.")
                Text("Click **‹** to show hidden icons · ⌥-click to show everything (and see **‖**) · right-click for the menu.")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func group(_ title: String, _ symbol: String, _ items: [BarItem], empty: String) -> some View {
        Section {
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(nsImage: item.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                        .resizable().frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1)
                }
            }
        } header: {
            Label("\(title) · \(items.count)", systemImage: symbol)
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tuck needs Accessibility access").font(.headline)
                Text("For the dropdown and this list: it lets Tuck see which app owns each icon and open its menu. Plain hide/show works without it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Accessibility Settings") {
                        MenuBar.requestTrust()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("Check Again") { model.reload() }
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
