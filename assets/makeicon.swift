import Cocoa
let S: CGFloat = 1024
func tinted(_ name: String, _ pt: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
    let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    return NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true }
}
let img = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    let inset = S * 0.098
    let rect = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width*0.2237, yRadius: rect.width*0.2237)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
    NSColor.black.set(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.36, alpha: 1),
                        NSColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1)])!.draw(in: rect, angle: -90)
    // 屏幕:白色显示器轮廓
    let mon = tinted("display", 520, NSColor(white: 0.96, alpha: 1))
    let mr = NSRect(x: (S - mon.size.width)/2, y: (S - mon.size.height)/2 - 20, width: mon.size.width, height: mon.size.height)
    mon.draw(in: mr)
    // 月亮:暖黄,放在屏幕面板内
    let moon = tinted("moon.fill", 170, NSColor(red: 1.0, green: 0.85, blue: 0.40, alpha: 1), weight: .bold)
    moon.draw(in: NSRect(x: S/2 - moon.size.width/2 + 4, y: S/2 + 30, width: moon.size.width, height: moon.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return true
}
let tiff = img.tiffRepresentation!, rep = NSBitmapImageRep(data: tiff)!
rep.size = NSSize(width: S, height: S)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon_1024.png ok")
