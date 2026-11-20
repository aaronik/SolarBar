import AppKit
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func render(_ size: Int) -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.setShouldAntialias(true)
    NSBezierPath(roundedRect: CGRect(x: 58, y: 58, width: 908, height: 908), xRadius: 211, yRadius: 211).addClip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0.045, 0.07, 0.12).cgColor, color(0.09, 0.19, 0.23).cgColor] as CFArray,
                              locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: .init(x: 160, y: 100), end: .init(x: 810, y: 955), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sun = NSBezierPath(ovalIn: CGRect(x: 239, y: 239, width: 546, height: 546))
    sun.lineWidth = 30
    color(0.99, 0.75, 0.34).withAlphaComponent(0.8).setStroke()
    sun.stroke()
    let bolt = NSBezierPath()
    bolt.move(to: CGPoint(x: 572, y: 744))
    for (x, y) in [(356, 471), (489, 471), (450, 273), (668, 553), (533, 553)] {
        bolt.line(to: CGPoint(x: x, y: y))
    }
    bolt.close()
    color(0.38, 0.96, 0.78).setFill()
    bolt.fill()
    NSGraphicsContext.restoreGraphicsState()
    return image.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: target.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: target.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
