import AppKit
import SwiftUI
import WorkLightCore

@main
@MainActor
enum WorkLightApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
public final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    private let lamp: LampController
    private let tokenStore: TokenStore
    private let callMonitor: CallActivitySource
    private lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var settingsWindow: NSWindow?
    private var pollingTask: Task<Void, Never>?
    private var callMonitorTask: Task<Void, Never>?

    public init(
        lamp: LampController = LampController(),
        tokenStore: TokenStore = KeychainTokenStore(),
        callMonitor: CallActivitySource = CoreAudioMicrophoneMonitor()
    ) {
        self.lamp = lamp
        self.tokenStore = tokenStore
        self.callMonitor = callMonitor
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("WorkLight")
        }
        lamp.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.lamp.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }

        callMonitorTask = Task { [weak self] in
            var pendingState: Bool?
            var stableTicks = 0
            var publishedState = false

            while !Task.isCancelled {
                if let self, self.lamp.settings.autoBusyOnMicrophone {
                    let active = self.callMonitor.isMicrophoneActive()
                    if active != publishedState {
                        if pendingState == active {
                            stableTicks += 1
                        } else {
                            pendingState = active
                            stableTicks = 1
                        }
                        let requiredTicks = active ? 2 : 3
                        if stableTicks >= requiredTicks {
                            publishedState = active
                            pendingState = nil
                            stableTicks = 0
                            await self.lamp.handleCallActivityChanged(active: active)
                        }
                    } else {
                        pendingState = nil
                        stableTicks = 0
                    }
                } else {
                    pendingState = nil
                    stableTicks = 0
                    if publishedState {
                        publishedState = false
                        await self?.lamp.handleCallActivityChanged(active: false)
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
        callMonitorTask?.cancel()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func statusClick(_ button: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let y = button.isFlipped ? button.bounds.maxY : button.bounds.minY
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
        } else if case .unconfigured = lamp.status {
            showSettings()
        } else if case .problem = lamp.status {
            Task { await lamp.refresh() }
        } else {
            Task { await lamp.toggle() }
        }
    }

    private func updateIcon() {
        let image: NSImage?
        switch lamp.status {
        case .unconfigured:
            image = NSImage(systemSymbolName: "lightbulb.circle", accessibilityDescription: nil)
        case .reading, .applying:
            image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        case let .ready(scene, _):
            image = icon(for: scene, tinted: true)
        case .problem:
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        item.button?.image = image
        let callBadge = lamp.settings.autoBusyOnMicrophone && lamp.isCallActive ? " · Mic Active" : ""
        item.button?.toolTip = "WorkLight · \(lamp.status.title)\(callBadge)"
        item.button?.setAccessibilityValue(lamp.status.title)
    }

    private func icon(for scene: LampScene, tinted: Bool) -> NSImage? {
        let name: String
        let color: NSColor?
        switch scene {
        case .busy: name = "minus.circle.fill"; color = .systemRed
        case .free: name = "checkmark.circle.fill"; color = .systemGreen
        case .normal: name = "sun.max.fill"; color = .systemYellow
        case .off: name = "lightbulb.slash"; color = nil
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard tinted, let color else { return image }
        let colored = image?.withSymbolConfiguration(.init(paletteColors: [color]))
        colored?.isTemplate = false
        return colored ?? image
    }

    public func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let statusItem = NSMenuItem(title: lamp.status.title, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        if lamp.settings.autoBusyOnMicrophone {
            let micState = lamp.isCallActive ? "Auto-Busy: Mic Active" : "Auto-Busy: Watching Mic"
            let autoItem = NSMenuItem(title: micState, action: nil, keyEquivalent: "")
            autoItem.isEnabled = false
            menu.addItem(autoItem)
        }
        menu.addItem(.separator())
        for (index, scene) in LampScene.allCases.enumerated() {
            let entry = NSMenuItem(
                title: scene == .off ? "Turn Off" : scene.title,
                action: #selector(selectScene(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.tag = index
            entry.isEnabled = lamp.status.canSelect
            entry.image = icon(for: scene, tinted: false)
            if case let .ready(active, _) = lamp.status, active == scene { entry.state = .on }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(showSettings), key: ","))
        menu.addItem(menuItem("Refresh Status", #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit WorkLight", #selector(quit), key: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func selectScene(_ entry: NSMenuItem) {
        let scene = LampScene.allCases[entry.tag]
        Task { await lamp.select(scene, initiatedByUser: true) }
    }

    @objc private func refresh() {
        Task { await lamp.refresh() }
    }

    @objc private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(
            draft: lamp.settings,
            hasStoredToken: tokenStore.hasToken(),
            save: { [weak self] updatedSettings, newToken in
                guard let self else { return nil }
                if let newToken, !newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try self.tokenStore.saveToken(newToken)
                    } catch {
                        return LampError.credential.errorDescription ?? "Invalid token"
                    }
                }
                self.lamp.save(updatedSettings)
                self.settingsWindow?.close()
                Task { await self.lamp.refresh() }
                return nil
            },
            clearToken: { [weak self] in
                try? self?.tokenStore.deleteToken()
            },
            cancel: { [weak self] in self?.settingsWindow?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "WorkLight Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
