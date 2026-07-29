import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private let monitor = BatteryMonitor.shared

    private var selectedDeviceNames: [String] {
        get { UserDefaults.standard.stringArray(forKey: "selectedDeviceNames") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "selectedDeviceNames") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        monitor.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshUI()
            }
        }

        refreshUI()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.monitor.refresh()
        }
    }

    private func refreshUI() {
        statusItem.button?.image = compositeIcon(for: selectedDeviceNames)
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let selected = selectedDeviceNames

        let deviceNames = monitor.availableDeviceNames
        if deviceNames.isEmpty {
            let item = NSMenuItem(title: "Geen Bluetooth devices gevonden", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for name in deviceNames {
                let title = monitor.batteryByName[name].map { "\(name) (\($0)%)" } ?? name
                let item = NSMenuItem(title: title, action: #selector(toggleDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = selected.contains(name) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var names = selectedDeviceNames
        if let index = names.firstIndex(of: name) {
            names.remove(at: index)
        } else {
            names.append(name)
        }
        selectedDeviceNames = names
        refreshUI()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("toggleLaunchAtLogin failed: \(error.localizedDescription)")
        }
        refreshUI()
    }

    private func log(_ text: String) {
        NSLog("BlueBars: %@", text)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private let fullColor = NSColor(calibratedRed: 0.02, green: 0.13, blue: 0.45, alpha: 1)
    private let emptyColor = NSColor(calibratedRed: 0.80, green: 0.90, blue: 1.00, alpha: 1)
    private let unknownColor = NSColor(calibratedWhite: 0.6, alpha: 1)

    private let pillWidth: CGFloat = 6
    private let pillHeight: CGFloat = 16
    private let pillGap: CGFloat = 3

    private func compositeIcon(for names: [String]) -> NSImage? {
        guard !names.isEmpty else {
            return NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "BlueBars")
        }

        let count = CGFloat(names.count)
        let width = count * pillWidth + max(0, count - 1) * pillGap
        let size = NSSize(width: width, height: pillHeight + 2)
        let image = NSImage(size: size)

        image.lockFocus()
        for (index, name) in names.enumerated() {
            let x = CGFloat(index) * (pillWidth + pillGap)
            let rect = NSRect(x: x, y: 1, width: pillWidth, height: pillHeight)
            color(for: monitor.batteryByName[name]).setFill()
            NSBezierPath(roundedRect: rect, xRadius: pillWidth / 2, yRadius: pillWidth / 2).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func color(for percent: Int?) -> NSColor {
        guard let percent else { return unknownColor }
        let t = CGFloat(max(0, min(100, percent))) / 100.0
        return blend(fullColor, emptyColor, fraction: 1 - t)
    }

    private func blend(_ a: NSColor, _ b: NSColor, fraction: CGFloat) -> NSColor {
        NSColor(
            calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
            alpha: 1
        )
    }
}
