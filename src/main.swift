import Cocoa
import Carbon
import IOKit.pwr_mgt
import ApplicationServices

// 关屏不待机 + 全部状态栏面板
// 1) 关屏:全屏黑窗 + 背光降 0 + 不待机声明;只有键盘按键能唤醒,鼠标一律忽略
// 2) 状态栏面板:左键点菜单栏图标,弹出面板列出所有 app 的状态栏项(含被刘海/溢出挤掉的),
//    点一项 = 通过辅助功能接口「按」那个状态栏项。需要「辅助功能」权限。

// MARK: 日志(~/Library/Logs/ScreenOff.log)
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenOff.log")
    static func w(_ msg: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(msg)\n"
        NSLog("%@", msg)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

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


// MARK: 状态栏项窗口(截图用)与事件合成
struct StatusWindow { let id: CGWindowID; let pid: pid_t; let bounds: CGRect }

enum StatusWindows {
    /// 所有状态栏层(layer 25)的窗口,含被刘海挡住的
    static func all() -> [StatusWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [StatusWindow] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 25,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.minY == 0, r.height <= 40, r.width < 400 else { continue }
            out.append(StatusWindow(id: id, pid: pid, bounds: r))
        }
        return out
    }
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }
    /// 截取某个状态栏项窗口的图像(需要屏幕录制权限)
    // CGWindowListCreateImage 在 SDK 里标成不可用,但系统里仍在,用 dlsym 取
    private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImageFn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let p = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(p, to: CreateImageFn.self)
    }()
    static func image(of w: StatusWindow) -> NSImage? {
        // kCGWindowListOptionIncludingWindow = 1<<3; kCGWindowImageBoundsIgnoreFraming = 1<<0, kCGWindowImageBestResolution = 1<<3
        guard let f = createImage, let cg = f(.null, 1 << 3, w.id, (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        guard cg.width > 1, cg.height > 1 else { return nil }
        return NSImage(cgImage: cg, size: w.bounds.size)
    }
    /// 图像里不透明像素的平均亮度(判断菜单栏是深色还是浅色)
    static func luminance(_ img: NSImage) -> CGFloat? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var sum: CGFloat = 0, n = 0
        let stepX = max(1, rep.pixelsWide / 40), stepY = max(1, rep.pixelsHigh / 20)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 {
                    sum += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent; n += 1
                }
                x += stepX
            }
            y += stepY
        }
        return n == 0 ? nil : sum / CGFloat(n)
    }
}

enum Synth {
    private static func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
    static var lastSeen = ""
    /// 在真实菜单栏位置点一下(左键或右键),然后把光标放回原处
    static func click(at p: CGPoint, right: Bool = false) {
        let origin = NSEvent.mouseLocation
        let restore = CGPoint(x: origin.x, y: (NSScreen.screens.first?.frame.height ?? 0) - origin.y)
        let btn: CGMouseButton = right ? .right : .left
        post(.mouseMoved, p)
        usleep(40_000)
        let m = NSEvent.mouseLocation; lastSeen = "\(Int(m.x)),\(Int(m.y))"
        post(right ? .rightMouseDown : .leftMouseDown, p, button: btn)
        usleep(60_000)
        post(right ? .rightMouseUp : .leftMouseUp, p, button: btn)
        usleep(80_000)
        CGWarpMouseCursorPosition(restore)
    }
    /// ⌘拖动:把状态栏项从 from 拖到 to
    static func cmdDrag(from: CGPoint, to: CGPoint) {
        let origin = NSEvent.mouseLocation
        let restore = CGPoint(x: origin.x, y: (NSScreen.screens.first?.frame.height ?? 0) - origin.y)
        post(.mouseMoved, from)
        usleep(60_000)
        post(.leftMouseDown, from, flags: .maskCommand)
        usleep(120_000)
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y)
            post(.leftMouseDragged, p, flags: .maskCommand)
            usleep(15_000)
        }
        usleep(120_000)
        post(.leftMouseUp, to, flags: .maskCommand)
        usleep(150_000)
        CGWarpMouseCursorPosition(restore)
    }
}

// MARK: 图标缓存:在可见区截到过一次就存下来,被刘海挡住时照样能显示原样
enum IconCache {
    private static var mem: [String: NSImage] = [:]
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenOff/icons")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func key(_ app: NSRunningApplication, _ label: String, _ width: CGFloat) -> String {
        let raw = "\(app.bundleIdentifier ?? app.localizedName ?? "?")|\(label)|\(Int(width))"
        return raw.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
    }
    static func get(_ k: String) -> NSImage? {
        if let m = mem[k] { return m }
        let f = dir.appendingPathComponent(k + ".png")
        guard let img = NSImage(contentsOf: f) else { return nil }
        mem[k] = img
        return img
    }
    static func put(_ k: String, _ img: NSImage) {
        mem[k] = img
        let f = dir.appendingPathComponent(k + ".png")
        if FileManager.default.fileExists(atPath: f.path) { return }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: f)
    }
}

// MARK: 状态栏项(辅助功能枚举)
struct BarItem {
    let element: AXUIElement
    let app: NSRunningApplication
    let label: String
    let x: CGFloat
    let width: CGFloat
    var window: StatusWindow?
    var image: NSImage?
    /// 真实菜单栏里的中心点(全局坐标,左上原点)
    var center: CGPoint {
        if let w = window { return CGPoint(x: w.bounds.midX, y: w.bounds.midY) }
        return CGPoint(x: x + width / 2, y: 12)
    }
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
        let wins = StatusWindows.all()
        let capture = StatusWindows.hasPermission
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier != getpid() && app.activationPolicy != .prohibited
            && app.bundleIdentifier != "com.apple.controlcenter" {
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
                var item = BarItem(element: it, app: app, label: label, x: pt.x, width: sz.width)
                // 同一进程里离 AX 位置最近的状态栏窗口就是它
                item.window = wins.filter { $0.pid == app.processIdentifier }.min { abs($0.bounds.minX - pt.x) < abs($1.bounds.minX - pt.x) }
                let k = IconCache.key(app, label, sz.width)
                if capture, let w = item.window, item.onScreen, let img = StatusWindows.image(of: w) {
                    item.image = img
                    IconCache.put(k, img)
                } else if let cached = IconCache.get(k) {
                    cached.size = item.window?.bounds.size ?? CGSize(width: sz.width, height: 24)
                    item.image = cached
                }
                out.append(item)
            }
        }
        let sorted = out.sorted { $0.center.x < $1.center.x }
        Log.w("scan: \(sorted.count) 项, 截图权限=\(capture), 有图 \(sorted.filter { $0.image != nil }.count), 无图: " +
              sorted.filter { $0.image == nil }.map { "\($0.label)@\(Int($0.center.x))" }.joined(separator: " "))
        Log.w("scan order: " + sorted.map { "\($0.label)@\(Int($0.center.x))\($0.onScreen ? "" : "(挡)")" }.joined(separator: " "))
        return sorted
    }
}


// MARK: 面板里的「第二条菜单栏」
final class ItemCell: NSView {
    let item: BarItem
    var hovered = false { didSet { needsDisplay = true } }
    var pressed = false { didSet { needsDisplay = true } }
    init(item: BarItem, height: CGFloat) {
        self.item = item
        let w = item.image != nil ? max(item.width, item.window?.bounds.width ?? item.width) : 30
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: height))
        toolTip = item.app.localizedName
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || pressed {
            let r = bounds.insetBy(dx: 1, dy: 4)
            NSColor.labelColor.withAlphaComponent(pressed ? 0.28 : 0.16).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
        if let img = item.image {
            let size = img.size
            let r = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            img.draw(in: r)
        } else if let icon = item.app.icon {
            icon.draw(in: NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18))
        }
        if !item.onScreen {   // 被挤出菜单栏的:底部一个小点
            NSColor.systemOrange.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: 2, width: 4, height: 4)).fill()
        }
    }
}

final class StripView: NSView {
    var cells: [ItemCell] = []
    var onClick: ((BarItem, Bool) -> Void)?           // (item, isRightClick)
    var onReorder: ((BarItem, Int, [BarItem]) -> Void)?  // (被拖的项, 新下标, 拖前顺序)
    private var dragging: ItemCell?
    private var dragStart = NSPoint.zero
    private var dragOffset: CGFloat = 0
    private var didDrag = false
    let rowH: CGFloat
    let pad: CGFloat = 6

    init(items: [BarItem], rowHeight: CGFloat) {
        rowH = rowHeight
        super.init(frame: .zero)
        for it in items { let c = ItemCell(item: it, height: rowH); cells.append(c); addSubview(c) }
        layoutCells(animated: false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    var contentWidth: CGFloat { cells.reduce(0) { $0 + $1.frame.width } + pad * 2 }
    func layoutCells(animated: Bool, skipping: ItemCell? = nil) {
        var x = pad
        for c in cells {
            let f = NSRect(x: x, y: 0, width: c.frame.width, height: rowH)
            if c !== skipping { if animated { c.animator().frame = f } else { c.frame = f } }
            x += c.frame.width
        }
        frame.size = NSSize(width: x + pad, height: rowH)
    }
    private func cell(at p: NSPoint) -> ItemCell? { cells.first { $0.frame.contains(p) } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let c = cell(at: p) else { return }
        dragging = c; dragStart = p; dragOffset = p.x - c.frame.minX; didDrag = false
        c.pressed = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let c = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !didDrag && abs(p.x - dragStart.x) < 5 { return }
        didDrag = true
        c.frame.origin.x = p.x - dragOffset
        c.superview?.addSubview(c, positioned: .above, relativeTo: nil)  // 拖的那个浮在最上面
        // 按中心点重新排序
        let sorted = cells.sorted { $0.frame.midX < $1.frame.midX }
        if sorted.map({ ObjectIdentifier($0) }) != cells.map({ ObjectIdentifier($0) }) {
            cells = sorted
            layoutCells(animated: true, skipping: c)
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard let c = dragging else { return }
        c.pressed = false
        dragging = nil
        if didDrag {
            let before = cells  // 注意:cells 已是新顺序;拖前顺序由调用方保存
            layoutCells(animated: true)
            if let idx = before.firstIndex(where: { $0 === c }) { onReorder?(c.item, idx, before.map { $0.item }) }
        } else {
            onClick?(c.item, false)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let c = cell(at: p) else { return }
        onClick?(c.item, true)
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
        if let i = CommandLine.arguments.firstIndex(of: "--capture"), i + 1 < CommandLine.arguments.count {   // 调试:截某项图像存 PNG
            let name = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSLog("capture permission=%d", StatusWindows.hasPermission ? 1 : 0)
                if !StatusWindows.hasPermission { StatusWindows.requestPermission() }
                for it in BarScanner.scan() where name == "all" || (it.app.localizedName ?? "") == name {
                    let w = it.window
                    NSLog("%@ ax.x=%.0f win=%@ img=%@", it.label, it.x, w.map { NSStringFromRect($0.bounds) } ?? "nil", it.image.map { NSStringFromSize($0.size) } ?? "nil")
                    if let img = it.image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                        let out = "/tmp/screenoff-\(it.app.localizedName ?? "x").png".replacingOccurrences(of: " ", with: "_")
                        try? png.write(to: URL(fileURLWithPath: out))
                        NSLog("saved %@ lum=%.2f", out, StatusWindows.luminance(img) ?? -1)
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--drag"), i + 2 < CommandLine.arguments.count {   // 调试:把某项 ⌘拖到某 x
            let name = CommandLine.arguments[i + 1], tx = CGFloat(Double(CommandLine.arguments[i + 2]) ?? 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let it = BarScanner.scan().first(where: { ($0.app.localizedName ?? "") == name }) else { NSLog("not found"); NSApp.terminate(nil); return }
                NSLog("before: %@ center=%@", it.label, NSStringFromPoint(it.center))
                Synth.cmdDrag(from: it.center, to: CGPoint(x: tx, y: it.center.y))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let after = BarScanner.scan().first(where: { ($0.app.localizedName ?? "") == name }) { NSLog("after: center=%@", NSStringFromPoint(after.center)) }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--press"), i + 1 < CommandLine.arguments.count {   // 调试:按某个项,看菜单弹哪(--click = 合成鼠标点击, --right = 右键)
            let name = CommandLine.arguments[i + 1]
            let area = NSScreen.main?.auxiliaryTopRightArea ?? .zero
            NSLog("topRightArea=%@", NSStringFromRect(area))
            usleep(1_000_000)
            guard let it = BarScanner.scan().first(where: { ($0.app.localizedName ?? "") == name || $0.label == name }) else { NSLog("not found"); NSApp.terminate(nil); return }
            if CommandLine.arguments.contains("--click") {
                Synth.click(at: it.center, right: CommandLine.arguments.contains("--right"))
                NSLog("Click %@ at %@", it.label, NSStringFromPoint(it.center))
            } else {
                let r = AXUIElementPerformAction(it.element, kAXPressAction as CFString)
                NSLog("AXPress %@ x=%.0f -> %d", it.label, it.x, r.rawValue)
            }
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
        Log.w("panel open")
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

    private var originalOrder: [BarItem] = []

    private func itemsView() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        box.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        if items.isEmpty {
            box.addArrangedSubview(NSTextField(labelWithString: "没有找到状态栏项"))
            return box
        }
        let rowH = items.compactMap { $0.window?.bounds.height }.max() ?? 24
        let strip = StripView(items: items, rowHeight: rowH)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.widthAnchor.constraint(equalToConstant: strip.contentWidth).isActive = true
        strip.heightAnchor.constraint(equalToConstant: rowH).isActive = true
        originalOrder = items
        strip.onClick = { [weak self] it, right in self?.activate(it, right: right) }
        strip.onReorder = { [weak self] it, idx, order in self?.reorder(it, to: idx, newOrder: order) }
        box.addArrangedSubview(strip)

        var tip = "左键 / 右键 / 拖动 = 和菜单栏里一样。橙点 = 被刘海挡住的：只能左键，不能右键和拖动。"
        if !StatusWindows.hasPermission {
            tip = "开启「屏幕录制」权限后可显示图标原样；现在显示的是 app 图标。"
            let b = NSButton(title: "去开启屏幕录制权限", target: self, action: #selector(requestCapture))
            b.bezelStyle = .rounded; b.controlSize = .small
            box.addArrangedSubview(b)
        }
        let hint = NSTextField(labelWithString: tip)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        box.addArrangedSubview(hint)
        return box
    }

    @objc private func requestCapture() {
        StatusWindows.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        closePanel()
        // 屏幕录制权限要重启 app 才生效
        let alert = NSAlert()
        alert.messageText = "开启权限后需要重新启动本 app"
        alert.informativeText = "在系统设置里打开「关屏不待机」的屏幕录制开关，然后点「重新启动」。"
        alert.addButton(withTitle: "重新启动")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\" --args --background"]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 可见项:在真实菜单栏位置发合成鼠标事件(左/右键都行);被刘海挡住的项:只能用辅助功能「按」(左键)
    private func activate(_ it: BarItem, right: Bool) {
        closePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if it.onScreen, it.window != nil {
                let before = NSEvent.mouseLocation
                Synth.click(at: it.center, right: right)
                Log.w("click \(right ? "右" : "左") \(it.label) at \(Int(it.center.x)),\(Int(it.center.y)) postAccess=\(CGPreflightPostEventAccess()) mouseBefore=\(Int(before.x)),\(Int(before.y)) mouseAfterMove=\(Synth.lastSeen)")
            } else if !right {
                let r = AXUIElementPerformAction(it.element, kAXPressAction as CFString)
                Log.w("axpress(挡) \(it.label) -> \(r.rawValue)")
            } else {
                Log.w("右键 \(it.label) 被刘海挡住,不支持")
                self.flash("「\(it.label)」被刘海挡住，只支持左键")
            }
        }
    }

    /// 面板下方一闪而过的提示
    private func flash(_ text: String) {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 12); t.textColor = .white
        t.backgroundColor = NSColor.black.withAlphaComponent(0.75); t.drawsBackground = true
        t.sizeToFit()
        let pad: CGFloat = 12
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: t.frame.width + pad * 2, height: t.frame.height + pad), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75); w.isOpaque = false; w.hasShadow = true
        w.level = .popUpMenu
        t.frame.origin = NSPoint(x: pad, y: pad / 2)
        w.contentView?.addSubview(t)
        if let sc = NSScreen.main { w.setFrameOrigin(NSPoint(x: sc.frame.maxX - w.frame.width - 12, y: sc.visibleFrame.maxY - w.frame.height - 12)) }
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { w.orderOut(nil) }
    }

    /// 面板里拖完 → 在真实菜单栏做 ⌘拖动
    private func reorder(_ it: BarItem, to idx: Int, newOrder: [BarItem]) {
        let others = newOrder.filter { $0.window?.id != it.window?.id }
        let leftNeighbor = idx > 0 ? others[idx - 1] : nil          // 新位置左边那个
        let rightNeighbor = idx < others.count ? others[idx] : nil   // 新位置右边那个
        var targetX: CGFloat
        if let l = leftNeighbor?.window?.bounds, let r = rightNeighbor?.window?.bounds {
            targetX = (l.maxX + r.minX) / 2
        } else if let r = rightNeighbor?.window?.bounds {
            targetX = r.minX - it.width / 2 - 2
        } else if let l = leftNeighbor?.window?.bounds {
            targetX = l.maxX + it.width / 2 + 2
        } else { return }
        // 目标在被拖项右边时,它自己让出的宽度要扣掉
        if targetX > it.center.x { targetX -= it.width }
        let visMinX = NSScreen.main?.auxiliaryTopRightArea?.minX ?? 0
        guard it.onScreen, targetX - it.width / 2 >= visMinX else {
            Log.w("drag \(it.label) 拒绝:源可见=\(it.onScreen) 目标x=\(Int(targetX)) 可见区起点=\(Int(visMinX))")
            flash(it.onScreen ? "目标位置在刘海底下，放不进去" : "「\(it.label)」被刘海挡住，拖不动")
            items = BarScanner.scan(); showPanel(content: itemsView())
            return
        }
        closePanel()
        let from = it.center
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Synth.cmdDrag(from: from, to: CGPoint(x: targetX, y: from.y))
            Log.w("drag \(it.label) from \(Int(from.x)) to \(Int(targetX)) (左邻 \(leftNeighbor?.label ?? "-") 右邻 \(rightNeighbor?.label ?? "-"))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.items = BarScanner.scan()
                self.showPanel(content: self.itemsView())
            }
        }
    }

    private func showPanel(content: NSView) {
        closePanel()
        let effect = NSVisualEffectView()
        effect.material = .menu
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
        if let img = items.first(where: { $0.image != nil })?.image, let lum = StatusWindows.luminance(img) {
            p.appearance = NSAppearance(named: lum > 0.5 ? .darkAqua : .aqua)
        }
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
