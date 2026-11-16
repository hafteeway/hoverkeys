import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

struct Target {
    let app: NSRunningApplication
    let window: AXUIElement?
}

final class Controller: NSObject, NSApplicationDelegate, ObservableObject {
    var status: NSStatusItem!
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var cachedTarget: Target?
    @Published var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); refreshMenu() }
    }
    @Published var disabledKeys = Set(UserDefaults.standard.array(forKey: "disabledKeys") as? [Int] ?? [])
    @Published var trusted = false
    @Published var listening = false
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    var settingsWindow: NSWindow?

    func setShortcut(_ key: Int, enabled: Bool) {
        if enabled { disabledKeys.remove(key) } else { disabledKeys.insert(key) }
        UserDefaults.standard.set(Array(disabledKeys), forKey: "disabledKeys")
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            syncLogin()
        } catch {
            loginMessage = error.localizedDescription
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
    func syncLogin() {
        let state = SMAppService.mainApp.status
        loginEnabled = state == .enabled || state == .requiresApproval
        loginMessage = state == .requiresApproval ? "请在 Login Items（登录项）中允许 HoverKeys" : (state == .enabled ? "下次登录时自动在后台启动" : "登录时不自动启动")
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "HoverKeys · Settings（设置）"
            window.contentView = NSHostingView(rootView: SettingsView(controller: self))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    var swallowed = Set<Int64>()
    let system = AXUIElementCreateSystemWide()
    var lastResult = "尚未执行操作"

    func applicationDidFinishLaunching(_ notification: Notification) {
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.hoverkeys.HoverKeys") where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            other.terminate()
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "cursorarrow.and.square.on.square.dashed", accessibilityDescription: "HoverKeys")
        refreshMenu()
        syncLogin()
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            setLogin(true)
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                UserDefaults.standard.set(true, forKey: "loginConfigured")
            }
        }
        if !UserDefaults.standard.bool(forKey: "settingsIntroduced") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "settingsIntroduced")
        }
        start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.tap == nil && AXIsProcessTrusted() { self.start() }
            if self.trusted != AXIsProcessTrusted() { self.trusted = AXIsProcessTrusted() }
            let active = self.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            if self.listening != active { self.listening = active }
            let point = CGEvent(source: nil)?.location ?? .zero
            self.cachedTarget = AXIsProcessTrusted() ? self.resolve(at: point) : nil
            let data: [String: Any] = ["trusted": AXIsProcessTrusted(), "listening": self.tap != nil, "x": point.x, "y": point.y, "target": self.cachedTarget?.app.localizedName ?? "none", "lastResult": self.lastResult, "path": Bundle.main.bundlePath]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
                try? json.write(to: URL(fileURLWithPath: "/private/tmp/hoverkeys-status.json"), options: .atomic)
            }
        }
        if !AXIsProcessTrusted() { showSettings() }
    }

    func refreshMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "HoverKeys · 悬停快捷键", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(withTitle: AXIsProcessTrusted() ? "Accessibility 已授权" : "需要 Accessibility（辅助功能）授权", action: nil, keyEquivalent: "")
        let toggle = NSMenuItem(title: "Enabled（启用）", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        for label in ["⌘Q  Quit app（退出应用）", "⌘W  Close window（关闭窗口）", "⌘M  Minimize（最小化）", "⌘H  Hide app（隐藏应用）"] {
            menu.addItem(withTitle: label, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: lastResult, action: nil, keyEquivalent: "")
        for (label, selector) in [("Settings（设置）…", #selector(showSettings)), ("Setup & Help（设置与帮助）", #selector(showHelp)), ("Quit HoverKeys（退出工具）", #selector(quit))] {
            let item = NSMenuItem(title: label, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        status.menu = menu
    }
    @objc func toggleEnabled() { enabled.toggle(); refreshMenu() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "HoverKeys · 悬停快捷键"
        alert.informativeText = "将指针放在 Dock（程序坞）的应用图标或 Mission Control（调度中心）的窗口上，再按 ⌘Q / ⌘W / ⌘M / ⌘H。\n\nDock 上的窗口操作作用于应用最近使用的窗口。⌘W 关闭整个窗口。⌘Q 使用普通退出，应用可以提示保存。\n\n请在 System Settings（系统设置）→ Privacy & Security（隐私与安全）→ Accessibility（辅助功能）中添加并启用 HoverKeys。\n\n授权后会自动开始监听。菜单中显示最近一次识别结果。"
        alert.addButton(withTitle: "Open Accessibility（打开辅助功能）")
        alert.addButton(withTitle: "OK（好）")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        refreshMenu()
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return controller.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            lastResult = "监听未启动，请重新授权后重开工具"
            refreshMenu()
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        refreshMenu()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowed.remove(key) != nil }
        guard type == .keyDown else { return false }
        if swallowed.contains(key) { return true }
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard enabled, !disabledKeys.contains(Int(key)), modifiers == .maskCommand, [12, 13, 46, 4].contains(key) else { return false }
        lastResult = "已收到快捷键"
        guard let target = cachedTarget, target.app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        // Finder cannot quit normally. Leave that shortcut to macOS.
        if key == 12 && target.app.bundleIdentifier == "com.apple.finder" { return false }
        guard key == 12 || key == 4 || target.window != nil else { return false }
        swallowed.insert(key)
        DispatchQueue.main.async { self.perform(key, on: target) }
        return true
    }

    func resolve(at point: CGPoint) -> Target? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard let owner = NSRunningApplication(processIdentifier: pid), ["com.apple.dock", "com.apple.WindowManager"].contains(owner.bundleIdentifier ?? "") else { return nil }
        var ancestors: [AXUIElement] = []
        var current: AXUIElement? = hit
        for _ in 0..<12 {
            guard let node = current else { break }
            ancestors.append(node)
            current = element(attribute(node, kAXParentAttribute))
        }
        // Dock icons expose the application URL. Never infer identity from a label alone.
        for node in ancestors where string(node, kAXSubroleAttribute) == "AXApplicationDockItem" {
            guard let url = attribute(node, kAXURLAttribute) as? URL else { return nil }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) else { return nil }
            return Target(app: app, window: preferredWindow(app))
        }
        // Mission Control previews expose the actual window number through Accessibility.
        // Match that number to an application's AX window before issuing an action.
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let missionActive = visible.contains { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            let bundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
            return (bundle == "com.apple.WindowManager" && layer == 19) || (bundle == "com.apple.dock" && layer == 20)
        }
        guard missionActive else { return nil }
        let visibleIDs = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let numbers = ancestors.flatMap { node in
            ["wid", "AXWindowNumber"].compactMap { attribute(node, $0) as? NSNumber }.map { $0.uint32Value }
        }.filter { visibleIDs.contains($0) }
        guard !numbers.isEmpty else { return nil }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != pid {
            for window in windows(app) {
                var number: CGWindowID = 0
                if AXWindowNumber(window, &number) == .success && numbers.contains(number) {
                    return Target(app: app, window: window)
                }
            }
        }
        return nil
    }
    func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        return attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    func preferredWindow(_ app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        return element(attribute(root, kAXFocusedWindowAttribute)) ?? element(attribute(root, kAXMainWindowAttribute)) ?? windows(app).first
    }
    func perform(_ key: Int64, on target: Target) {
        var success = false
        switch key {
        case 12: success = target.app.terminate()
        case 4: success = target.app.hide()
        case 13:
            if let window = target.window, let close = element(attribute(window, kAXCloseButtonAttribute)) {
                success = AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
            }
        case 46:
            if let window = target.window {
                success = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
            }
        default: break
        }
        lastResult = "\(target.app.localizedName ?? "App") · \(success ? "已发送操作" : "操作未成功")"
        refreshMenu()
    }
}


struct SettingsView: View {
    @ObservedObject var controller: Controller
    private let shortcuts: [(Int, String, String, String)] = [
        (12, "⌘ Q", "Quit app（退出应用）", "power"),
        (13, "⌘ W", "Close window（关闭窗口）", "xmark.square"),
        (46, "⌘ M", "Minimize（最小化）", "minus.square"),
        (4, "⌘ H", "Hide app（隐藏应用）", "eye.slash")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("HoverKeys").font(.system(size: 29, weight: .bold, design: .rounded))
                        Text("悬停目标，按下快捷键").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(controller.listening ? Color.green : Color.orange).frame(width: 9, height: 9)
                    Text(controller.listening ? "后台运行中" : "等待授权").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Enable HoverKeys（启用悬停快捷键）", isOn: $controller.enabled)
                        Divider()
                        Toggle("Launch at Login（登录时启动）", isOn: Binding(get: { controller.loginEnabled }, set: { controller.setLogin($0) }))
                        Text(controller.loginMessage).font(.caption).foregroundStyle(.secondary)
                        if SMAppService.mainApp.status == .requiresApproval {
                            Button("Open Login Items（打开登录项）") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }.padding(10)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shortcuts（快捷键）").font(.headline)
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(shortcuts, id: \.0) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.3).foregroundStyle(Color.accentColor).frame(width: 22)
                                    Text(item.2)
                                    Spacer()
                                    Text(item.1).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 55)
                                    Toggle("", isOn: Binding(get: { !controller.disabledKeys.contains(item.0) }, set: { controller.setShortcut(item.0, enabled: $0) })).labelsHidden().toggleStyle(.switch)
                                }.padding(.vertical, 9)
                                if item.0 != 4 { Divider() }
                            }
                        }.padding(.horizontal, 10)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: controller.trusted ? "checkmark.shield.fill" : "lock.shield").foregroundStyle(controller.trusted ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(controller.trusted ? "Accessibility（辅助功能）已授权" : "需要 Accessibility（辅助功能）授权").font(.subheadline.weight(.medium))
                        Text("关闭设置窗口后，HoverKeys 继续在菜单栏后台运行。Dock 的窗口操作作用于应用最近使用的窗口。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !controller.trusted { Button("授权设置") { controller.openAccessibility() } }
                }
                HStack {
                    Text("0.2.0").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Done（完成）") { controller.settingsWindow?.close() }.keyboardShortcut(.defaultAction)
                }
            }.padding(28)
        }.frame(width: 590, height: 650).background(Color(nsColor: .windowBackgroundColor))
    }
}

@_silgen_name("_AXUIElementGetWindow")
func AXWindowNumber(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
