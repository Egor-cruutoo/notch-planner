import AppKit

// Рисует иконку: тёмная плашка, «островок» сверху и цветные блоки дня.
// Использование: MakeIcon <путь к .iconset>

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.24, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1))!.draw(in: platePath, angle: -90)

    // островок
    let island = NSRect(x: 262 * s, y: 690 * s, width: 500 * s, height: 120 * s)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: 60 * s, yRadius: 60 * s).fill()
    NSColor(calibratedRed: 0.45, green: 0.86, blue: 0.50, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 312 * s, y: 732 * s, width: 36 * s, height: 36 * s)).fill()
    NSColor(white: 1, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 368 * s, y: 738 * s, width: 170 * s, height: 24 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSColor(white: 1, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: 600 * s, y: 738 * s, width: 110 * s, height: 24 * s), xRadius: 12 * s, yRadius: 12 * s).fill()

    // блоки дня
    let rows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (210, 300, 520, NSColor(calibratedRed: 0.42, green: 0.64, blue: 1.00, alpha: 1)),
        (560, 250, 520, NSColor(calibratedRed: 1.00, green: 0.64, blue: 0.26, alpha: 1)),
        (210, 220, 390, NSColor(calibratedRed: 0.68, green: 0.54, blue: 1.00, alpha: 1)),
        (470, 340, 390, NSColor(calibratedRed: 0.45, green: 0.86, blue: 0.50, alpha: 1)),
        (210, 400, 260, NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.42, alpha: 1)),
    ]
    for (x, w, y, c) in rows {
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: 92 * s), xRadius: 26 * s, yRadius: 26 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(size: px).representation(using: .png, properties: [:])!
        try! data.write(to: out.appendingPathComponent(name))
    }
}
