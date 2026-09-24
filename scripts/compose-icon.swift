// Builds the app icon from square artwork.
// Default (and what ships): full-bleed square, no rounded corners, since macOS applies
// its own icon mask. --preview renders the rounded, shadowed look for mockups only.
//
//   swift scripts/compose-icon.swift <art.png> Resources/AppIcon.png --icns
//   swift scripts/compose-icon.swift <art.png> <out.png> --preview
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let art = NSImage(contentsOfFile: args[1]) else {
    print("usage: compose-icon.swift <art.png> <out.png> [--icns]"); exit(1)
}
let makeIcns = args.contains("--icns")
let preview = args.contains("--preview")

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    if !preview {
        art.draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()
    ctx.saveGState()
    shape.addClip()
    art.draw(in: body, from: .zero, operation: .copy, fraction: 1)
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shape.lineWidth = 2; shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
if makeIcns {
    let iconset = URL(fileURLWithPath: ".build/AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try render(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
    try p.run(); p.waitUntilExit()
    print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
}
