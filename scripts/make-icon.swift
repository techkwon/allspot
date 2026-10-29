import AppKit

// 앱 아이콘(돋보기)을 그려 .iconset 폴더에 크기별 PNG로 저장한다.
let output = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let background = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.2, alpha: 1),
               ending: NSColor(calibratedRed: 0.93, green: 0.29, blue: 0.24, alpha: 1))!.draw(in: background, angle: -90)
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: s * 0.27, y: s * 0.37, width: s * 0.36, height: s * 0.36))
    ring.lineWidth = s * 0.065
    ring.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: s * 0.57, y: s * 0.41))
    handle.line(to: NSPoint(x: s * 0.73, y: s * 0.25))
    handle.lineWidth = s * 0.09
    handle.lineCapStyle = .round
    handle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)@2x.png"))
}
