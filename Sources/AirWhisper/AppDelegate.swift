import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: AppController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var terminating = false
    private var terminationFallback: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = AppController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Air Whisper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onShowSettings = { [weak self] in self?.showSettings() }
        controller.onStatusChange = { [weak self] in self?.updateStatus() }
        controller.launch()
        updateStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        // Native driver/GPU teardown may fail to return. Process exit is the final
        // bound, releasing OS-owned microphone resources even in that case.
        terminationFallback = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            Darwin._exit(0)
        }
        Task {
            await controller.shutdown()
            terminationFallback?.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        if controller.isBusy { add("Cancel Dictation", action: #selector(cancelDictation), to: menu) }
        if controller.pendingTranscript != nil { add("Copy Dictation", action: #selector(copyDictation), to: menu) }
        add("Settings…", action: #selector(showSettings), key: ",", to: menu)
        add("Reset Dictation", action: #selector(resetDictation), to: menu)
        menu.addItem(.separator())
        add("Quit Air Whisper", action: #selector(quit), key: "q", to: menu)
    }

    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func updateStatus() {
        let symbol: String
        switch controller.phase {
        case .listening: symbol = "mic.fill"
        case .starting, .stopping: symbol = "mic.badge.ellipsis"
        case .transcribing: symbol = "ellipsis.bubble"
        case .cancelling: symbol = "xmark.circle"
        case .idle: symbol = controller.setupComplete ? "mic" : "mic.badge.xmark"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: controller.statusText)
        statusItem.button?.toolTip = "Air Whisper — \(controller.statusText)"
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let content = SettingsView(controller: controller, settings: controller.settings,
                                       devices: controller.devices, models: controller.models)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Air Whisper Settings"
            window.contentView = NSHostingView(rootView: content)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 660, height: 640)
            window.center()
            settingsWindow = window
        }
        controller.refreshDevicesAndDisplays()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelDictation() { controller.cancelSession() }
    @objc private func resetDictation() { controller.reset() }
    @objc private func copyDictation() { controller.copyPendingTranscript() }
    @objc private func quit() { NSApp.terminate(nil) }
}
