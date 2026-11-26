import AppKit

// 生成与菜单栏一致的雪花应用图标：深墨蓝圆角底 + 白色雪花。
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon-1024.png"
let side: CGFloat = 1024
let inset: CGFloat = 80
let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

let symbol = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
let tinted = symbol?.withSymbolConfiguration(config)

let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
    NSColor.clear.setFill()
    rect.fill()
    let path = NSBezierPath(roundedRect: body, xRadius: 190, yRadius: 190)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.24, blue: 0.37, alpha: 1),
                              ending: NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.13, alpha: 1))
    gradient?.draw(in: path, angle: -45)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    path.lineWidth = 3
    path.stroke()
    if let tinted {
        let size = tinted.size
        let target = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                            width: size.width, height: size.height)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.96)
    }
    return true
}

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("图标渲染失败")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
print("已写出 \(output)")
