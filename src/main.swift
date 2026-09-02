import Cocoa
import Carbon
import IOKit.pwr_mgt
import ApplicationServices

// 关屏不待机 + 全部状态栏面板
// 1) 关屏:全屏黑窗 + 背光降 0 + 不待机声明;只有键盘按键能唤醒,鼠标一律忽略
// 2) 状态栏面板:左键点菜单栏图标,弹出面板列出所有 app 的状态栏项(含被刘海/溢出挤掉的),
//    点一项 = 通过辅助功能接口「按」那个状态栏项。需要「辅助功能」权限。

// MARK: 亮度(私有 API,取不到就跳过)
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
    static func get() -> Float? { var v: Float = 0; guard let f = getFn, f(CGMainDisplayID(), &v) == 0 else { return nil }; return v }
    static func set(_ v: Float) { _ = setFn?(CGMainDisplayID(), v) }
}

// MARK: 黑窗
final class BlackWindow: NSWindow {
    var onKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?() }
    override func flagsChanged(with event: NSEvent) { if !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { onKey?() } }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
}

// MARK: 状态栏项(辅助功能枚举)
struct BarItem {
    let element: AXUIElement
    let app: NSRunningApplication
    let label: String
    let x: CGFloat
    let width: CGFloat
    // 刘海屏:只有落在刘海右侧可视区(auxiliaryTopRightArea)里的才算看得见
    var onScreen: Bool {
        guard let screen = NSScreen.main else { return true }
        let area = screen.auxiliaryTopRightArea ?? NSRect(x: 0, y: 0, width: screen.frame.width, height: 0)
        return x >= area.minX && x + width <= area.maxX
    }
}

enum BarScanner {
    static func scan() -> [BarItem] {
        var out: [BarItem] = []
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier != getpid() && app.activationPolicy != .prohibited {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            var extras: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &extras) == .success, let bar = extras else { continue }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
                  let items = kids as? [AXUIElement] else { continue }
            for it in items {
                var t: CFTypeRef?, d: CFTypeRef?, p: CFTypeRef?, s: CFTypeRef?
                AXUIElementCopyAttributeValue(it, kAXTitleAttribute as CFString, &t)
                AXUIElementCopyAttributeValue(it, kAXDescriptionAttribute as CFString, &d)
                AXUIElementCopyAttributeValue(it, kAXPositionAttribute as CFString, &p)
                AXUIElementCopyAttributeValue(it, kAXSizeAttribute as CFString, &s)
                var pt = CGPoint.zero, sz = CGSize.zero
                if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
                if let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
                let title = (t as? String ?? "").trimmingCharacters(in: .whitespaces)
                let desc = (d as? String ?? "").trimmingCharacters(in: .whitespaces)
                let name = app.localizedName ?? "?"
                var label = !title.isEmpty ? title : (!desc.isEmpty ? desc : name)
                if label.count > 14 { label = String(label.prefix(13)) + "…" }
                out.append(BarItem(element: it, app: app, label: label, x: pt.x, width: sz.width))
            }
        }
        // 按菜单栏从右到左的顺序排,看不见的排在前面
        return out.sorted { a, b in
            if a.onScreen != b.onScreen { return !a.onScreen }
            return a.x > b.x
        }
    }
}

// MARK: 面板
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var screenItem: NSStatusItem!
    private let menu = NSMenu()
    private var panel: BarPanel?
    private var sleepAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var windows: [BlackWindow] = []
    private var savedBrightness: Float?
    private var keepKeyTimer: Timer?
    private var dark = false
    private var keepAwakeAlways = false
    private var holdingSleep = false
    private var clickMonitor: Any?
    private var escMonitor: Any?
    private var items: [BarItem] = []
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keepAwakeItem = NSMenuItem(title: "始终不待机（屏幕亮着也不睡）", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        // 首次运行把图标放到第三方最右边(0 = 距右侧偏移),菜单栏再满也看得见
        let d = UserDefaults.standard
        if d.object(forKey: "NSStatusItem Preferred Position screenoff_main") == nil {
            d.set(0, forKey: "NSStatusItem Preferred Position screenoff_main")
        }
        if d.object(forKey: "NSStatusItem Preferred Position screenoff_screen") == nil {
            d.set(30, forKey: "NSStatusItem Preferred Position screenoff_screen")
        }
        // 清掉旧版折叠功能留下的位置记录
        d.removeObject(forKey: "NSStatusItem Preferred Position screenoff_toggle")
        d.removeObject(forKey: "NSStatusItem Preferred Position screenoff_sep")

        // 显示器图标:左键 = 立即关屏,右键 = 菜单
        screenItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        screenItem.autosaveName = "screenoff_screen"
        if let btn = screenItem.button {
            btn.image = NSImage(systemSymbolName: "display", accessibilityDescription: "关屏")
            btn.image?.isTemplate = true
            btn.toolTip = "点一下关屏（键盘任意键唤醒）"
            btn.target = self
            btn.action = #selector(screenClicked)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // 网格图标:左键 = 全部状态栏面板,右键 = 菜单
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "screenoff_main"
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "全部状态栏")
            btn.image?.isTemplate = true
            btn.target = self
            btn.action = #selector(statusClicked)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "关闭屏幕（键盘任意键唤醒）  ⌘⇧L", action: #selector(toggle), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        let all = NSMenuItem(title: "显示全部状态栏图标（左键点图标）", action: #selector(togglePanel), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.addItem(.separator())
        keepAwakeItem.target = self
        menu.addItem(keepAwakeItem)
        loginItem.target = self
        loginItem.state = isLoginItem() ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        updateStatus()
        registerHotKey()
        if CommandLine.arguments.contains("--scan") {   // 调试:打印枚举结果后退出(没权限则弹系统授权提示)
            if !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                NSLog("AX trusted=0, prompted"); NSLog("main.x=%.0f", statusItem.button?.window?.frame.origin.x ?? -1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                return
            }
            for it in BarScanner.scan() { NSLog("item: %@ | %@ | x=%.0f w=%.0f onScreen=%d", it.app.localizedName ?? "?", it.label, it.x, it.width, it.onScreen ? 1 : 0) }
            NSLog("AX trusted=%d", AXIsProcessTrusted() ? 1 : 0)
            NSApp.terminate(nil)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--press"), i + 1 < CommandLine.arguments.count {   // 调试:按某个项,看菜单弹哪
            let name = CommandLine.arguments[i + 1]
            let area = NSScreen.main?.auxiliaryTopRightArea ?? .zero
            NSLog("topRightArea=%@", NSStringFromRect(area))
            guard let it = BarScanner.scan().first(where: { ($0.app.localizedName ?? "") == name || $0.label == name }) else { NSLog("not found"); NSApp.terminate(nil); return }
            let r = AXUIElementPerformAction(it.element, kAXPressAction as CFString)
            NSLog("AXPress %@ x=%.0f -> %d", it.label, it.x, r.rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
                for w in list where (w[kCGWindowOwnerName as String] as? String) == (it.app.localizedName ?? "") {
                    NSLog("win layer=%@ bounds=%@", "\(w[kCGWindowLayer as String] ?? "")", "\(w[kCGWindowBounds as String] ?? "")")
                }
                // 关掉弹出的菜单:发一个 Esc
                let src = CGEventSource(stateID: .hidSystemState)
                CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
            return
        }
        if !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.toggle() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { toggle(); return false }
    func applicationWillTerminate(_ notification: Notification) { if dark { wake() } }

    @objc private func screenClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            screenItem.menu = menu
            screenItem.button?.performClick(nil)
            screenItem.menu = nil
        } else {
            toggle()
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    // MARK: 全部状态栏面板
    @objc private func togglePanel() {
        if panel != nil { closePanel(); return }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            showPanel(content: permissionView())
            return
        }
        items = BarScanner.scan()
        showPanel(content: itemsView())
    }

    private func permissionView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let t = NSTextField(labelWithString: "需要「辅助功能」权限才能列出并点击其他 app 的状态栏图标")
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        let s = NSTextField(labelWithString: "系统设置 → 隐私与安全性 → 辅助功能 → 打开「关屏不待机」，然后再点一次菜单栏图标")
        s.font = .systemFont(ofSize: 12)
        s.textColor = .secondaryLabelColor
        let b = NSButton(title: "打开系统设置", target: self, action: #selector(openAXSettings))
        b.bezelStyle = .rounded
        v.addArrangedSubview(t); v.addArrangedSubview(s); v.addArrangedSubview(b)
        return v
    }

    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func itemsView() -> NSView {
        let perRow = 8
        let cellW: CGFloat = 78, cellH: CGFloat = 58
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        grid.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        if items.isEmpty {
            let t = NSTextField(labelWithString: "没有找到状态栏项")
            grid.addArrangedSubview(t)
            return grid
        }
        var row: NSStackView?
        for (i, it) in items.enumerated() {
            if i % perRow == 0 {
                row = NSStackView(); row!.orientation = .horizontal; row!.spacing = 4
                grid.addArrangedSubview(row!)
            }
            let b = NSButton(title: it.label, target: self, action: #selector(itemClicked(_:)))
            b.tag = i
            b.image = it.app.icon
            b.image?.size = NSSize(width: 24, height: 24)
            b.imagePosition = .imageAbove
            b.imageScaling = .scaleProportionallyDown
            b.isBordered = false
            b.font = .systemFont(ofSize: 10)
            b.lineBreakMode = .byTruncatingTail
            b.toolTip = (it.app.localizedName ?? "") + (it.onScreen ? "" : "（当前被挤出菜单栏）")
            b.alphaValue = it.onScreen ? 0.55 : 1.0
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: cellW).isActive = true
            b.heightAnchor.constraint(equalToConstant: cellH).isActive = true
            row!.addArrangedSubview(b)
        }
        let hint = NSTextField(labelWithString: "亮的 = 被挤出菜单栏的；暗的 = 菜单栏里本来就能看见的。点一下即打开。")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        grid.addArrangedSubview(hint)
        return grid
    }

    @objc private func itemClicked(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        let it = items[sender.tag]
        closePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let r = AXUIElementPerformAction(it.element, kAXPressAction as CFString)
            NSLog("AXPress %@ -> %d", it.label, r.rawValue)
        }
    }

    private func showPanel(content: NSView) {
        closePanel()
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = content.fittingSize
        let p = BarPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let f = screen.frame, vf = screen.visibleFrame
            let barBottom = vf.maxY      // 菜单栏下沿
            var x = f.maxX - size.width - 8
            if let bx = statusItem.button?.window?.frame.midX { x = min(max(bx - size.width / 2, f.minX + 8), f.maxX - size.width - 8) }
            p.setFrameOrigin(NSPoint(x: x, y: barBottom - size.height - 6))
        }
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
        // 点面板外面 / 按 Esc 关闭
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePanel() }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.closePanel(); return nil }
            return e
        }
    }

    private func closePanel() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: 关屏 / 唤醒
    @objc func toggle() { dark ? wake() : darken() }

    private func darken() {
        guard !dark else { return }
        dark = true
        closePanel()
        holdSleep()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "ScreenOff: 黑屏期间不让系统再休眠显示器" as CFString, &displayAssertion)
        for screen in NSScreen.screens {
            let w = BlackWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.isReleasedWhenClosed = false   // 否则 close() 后 ARC 再释放一次 → 崩溃
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.onKey = { [weak self] in self?.wake() }
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        NSCursor.hide()
        savedBrightness = Brightness.get()
        Brightness.set(0)
        keepKeyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.dark, let w = self.windows.first, !w.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        updateStatus()
    }

    private func wake() {
        guard dark else { return }
        dark = false
        keepKeyTimer?.invalidate(); keepKeyTimer = nil
        if let b = savedBrightness { Brightness.set(b > 0.05 ? b : 0.5) }
        savedBrightness = nil
        NSCursor.unhide()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if !keepAwakeAlways { releaseSleep() }
        NSApp.hide(nil)
        updateStatus()
    }

    // MARK: 不待机声明
    private func holdSleep() {
        guard !holdingSleep else { return }
        holdingSleep = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ScreenOff: 屏幕关闭期间保持电脑运行" as CFString, &sleepAssertion) == kIOReturnSuccess
        updateStatus()
    }
    private func releaseSleep() {
        guard holdingSleep else { return }
        IOPMAssertionRelease(sleepAssertion); holdingSleep = false
        updateStatus()
    }
    @objc private func toggleKeepAwake() {
        keepAwakeAlways.toggle()
        keepAwakeItem.state = keepAwakeAlways ? .on : .off
        if keepAwakeAlways { holdSleep() } else if !dark { releaseSleep() }
    }
    private func updateStatus() {
        statusLine.title = holdingSleep ? "状态：电脑保持运行，不会待机" : "状态：正常（按系统节能设置）"
    }

    // MARK: 全局快捷键 ⌘⇧L
    private var hotKeyRef: EventHotKeyRef?
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue().toggle()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x53434F46), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: 开机自启
    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.oncet.screenoff.plist")
    }
    private func isLoginItem() -> Bool { FileManager.default.fileExists(atPath: agentURL.path) }
    @objc private func toggleLogin() {
        if isLoginItem() {
            try? FileManager.default.removeItem(at: agentURL)
        } else {
            let exe = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.oncet.screenoff</string>
              <key>ProgramArguments</key><array><string>\(exe)</string><string>--background</string></array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plist.write(to: agentURL, atomically: true, encoding: .utf8)
        }
        loginItem.state = isLoginItem() ? .on : .off
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
