// Draws the app icon (AppIcon.icns): the two "Calçadão" waves, cream on charcoal, the same
// marks as the dictation indicator (the waves of Copacabana's sidewalk).
// Usage: swiftc -O scripts/make-icon.swift -o build/make-icon && build/make-icon build/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Prosa-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let charcoal = NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2A / 255.0, alpha: 1)
let cream = NSColor(srgbRed: 0xF1 / 255.0, green: 0xEF / 255.0, blue: 0xE8 / 255.0, alpha: 1)

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // macOS icon grid: the rounded square takes ~80% of the canvas.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    charcoal.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()

    // Two parallel waves, like the sidewalk's mosaic stripes.
    let width = rect.width * 0.62
    let left = rect.midX - width / 2
    let amplitude = rect.height * 0.05
    let wavelength = width / 1.35
    cream.setStroke()
    for offset in [0.1, -0.1] as [CGFloat] {
        let mid = rect.midY + rect.height * offset
        let path = NSBezierPath()
        path.lineWidth = max(1.5, rect.width * 0.068)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var x: CGFloat = 0
        path.move(to: NSPoint(x: left, y: mid + sin(0) * amplitude))
        while x < width {
            x = min(width, x + max(0.5, s / 256))
            path.line(to: NSPoint(x: left + x, y: mid + sin(x / wavelength * 2 * .pi) * amplitude))
        }
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: base * scale)?.write(to: iconset.appendingPathComponent(name))
    }
}
// A preview next to the .icns, to look at the icon without installing.
try render(size: 512)?.write(to: output.deletingPathExtension().appendingPathExtension("png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
