// Renders Harbor's app icon into an asset catalog icon set.
// Usage: swift Scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func render(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let scale = size / 1024
        // macOS icon grid: 824pt body centred on a 1024 canvas.
        let body = rect.insetBy(dx: 100 * scale, dy: 100 * scale)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        shadow.set()
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.11, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
        ])!.draw(in: body, angle: -90)

        // Soft glow behind the prompt.
        let glow = NSGradient(colors: [NSColor(srgbRed: 0.48, green: 0.55, blue: 1, alpha: 0.35), .clear])!
        glow.draw(fromCenter: NSPoint(x: body.midX - 60 * scale, y: body.midY + 30 * scale), radius: 0,
                  toCenter: NSPoint(x: body.midX - 60 * scale, y: body.midY + 30 * scale), radius: 420 * scale, options: [])

        // Harbour water lines.
        for (index, alpha) in [0.22, 0.14, 0.08].enumerated() {
            let wave = NSBezierPath()
            let y = body.minY + (150 - CGFloat(index) * 46) * scale
            wave.move(to: NSPoint(x: body.minX, y: y))
            var x = body.minX
            while x < body.maxX {
                wave.curve(to: NSPoint(x: x + 140 * scale, y: y),
                           controlPoint1: NSPoint(x: x + 35 * scale, y: y + 22 * scale),
                           controlPoint2: NSPoint(x: x + 105 * scale, y: y - 22 * scale))
                x += 140 * scale
            }
            wave.lineWidth = 10 * scale
            NSColor(srgbRed: 0.43, green: 0.83, blue: 0.89, alpha: alpha).setStroke()
            wave.stroke()
        }

        // The chevron prompt.
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: body.minX + 200 * scale, y: body.midY + 165 * scale))
        chevron.line(to: NSPoint(x: body.minX + 385 * scale, y: body.midY + 10 * scale))
        chevron.line(to: NSPoint(x: body.minX + 200 * scale, y: body.midY - 145 * scale))
        chevron.lineWidth = 78 * scale
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSGraphicsContext.current?.saveGraphicsState()
        chevron.setClip()
        let strokePath = chevron.copy() as! NSBezierPath
        NSGraphicsContext.current?.restoreGraphicsState()
        let chevronImage = NSImage(size: rect.size, flipped: false) { _ in
            NSColor.white.setStroke()
            strokePath.stroke()
            return true
        }
        let gradient = NSGradient(colors: [NSColor(srgbRed: 0.62, green: 0.72, blue: 1, alpha: 1), NSColor(srgbRed: 0.36, green: 0.53, blue: 0.94, alpha: 1)])!
        let masked = NSImage(size: rect.size, flipped: false) { maskRect in
            chevronImage.draw(in: maskRect)
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            gradient.draw(in: maskRect, angle: -90)
            return true
        }
        masked.draw(in: rect)

        // The cursor.
        let cursor = NSBezierPath(roundedRect: NSRect(x: body.minX + 450 * scale, y: body.midY - 150 * scale, width: 230 * scale, height: 74 * scale),
                                  xRadius: 37 * scale, yRadius: 37 * scale)
        NSColor(srgbRed: 0.76, green: 0.59, blue: 0.95, alpha: 1).setFill()
        cursor.fill()

        // Hairline highlight.
        NSColor.white.withAlphaComponent(0.10).setStroke()
        shape.lineWidth = 4 * scale
        shape.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        return true
    }
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: CGFloat(pixels)).write(to: output.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
