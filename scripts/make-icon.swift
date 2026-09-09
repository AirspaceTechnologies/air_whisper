import AppKit

// Draw the app's icon locally so packaging needs no image service or downloaded artwork.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let unit = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: unit)
        (transform as NSAffineTransform).concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.29, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.50, blue: 0.48, alpha: 1))!
        gradient.draw(in: background, angle: 65)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 404, y: 390, width: 216, height: 390), xRadius: 108, yRadius: 108).fill()
        let cradle = NSBezierPath()
        cradle.move(to: NSPoint(x: 324, y: 510))
        cradle.line(to: NSPoint(x: 324, y: 438))
        cradle.curve(to: NSPoint(x: 700, y: 438), controlPoint1: NSPoint(x: 324, y: 192), controlPoint2: NSPoint(x: 700, y: 192))
        cradle.line(to: NSPoint(x: 700, y: 510))
        cradle.lineWidth = 42
        cradle.lineCapStyle = .round
        NSColor.white.setStroke()
        cradle.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 260))
        stand.line(to: NSPoint(x: 512, y: 190))
        stand.move(to: NSPoint(x: 420, y: 190))
        stand.line(to: NSPoint(x: 604, y: 190))
        stand.lineWidth = 42
        stand.lineCapStyle = .round
        stand.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
