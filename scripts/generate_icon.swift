import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_icon.swift <output.png>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("unable to create graphics context\n", stderr)
    exit(1)
}

let canvas = CGRect(origin: .zero, size: size)
let outer = canvas.insetBy(dx: 42, dy: 42)
let path = CGPath(
    roundedRect: outer,
    cornerWidth: 220,
    cornerHeight: 220,
    transform: nil
)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.55, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.27, green: 0.12, blue: 0.53, alpha: 1).cgColor
    ] as CFArray,
    locations: [0, 1]
)!

context.saveGState()
context.addPath(path)
context.clip()
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 120, y: 900),
    end: CGPoint(x: 900, y: 120),
    options: []
)

context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
context.setLineWidth(3)
for offset in stride(from: -260, through: 1_240, by: 96) {
    context.move(to: CGPoint(x: offset, y: 50))
    context.addLine(to: CGPoint(x: offset + 520, y: 974))
}
context.strokePath()
context.restoreGState()

let nodes: [(CGPoint, CGFloat)] = [
    (CGPoint(x: 290, y: 660), 64),
    (CGPoint(x: 512, y: 760), 78),
    (CGPoint(x: 734, y: 660), 64),
    (CGPoint(x: 360, y: 390), 70),
    (CGPoint(x: 664, y: 390), 70),
    (CGPoint(x: 512, y: 520), 92)
]
let links = [(0, 1), (1, 2), (0, 3), (2, 4), (3, 5), (4, 5), (1, 5)]

context.setStrokeColor(NSColor.white.withAlphaComponent(0.78).cgColor)
context.setLineWidth(18)
context.setLineCap(.round)
for link in links {
    context.move(to: nodes[link.0].0)
    context.addLine(to: nodes[link.1].0)
}
context.strokePath()

for (point, radius) in nodes {
    let circle = CGRect(
        x: point.x - radius,
        y: point.y - radius,
        width: radius * 2,
        height: radius * 2
    )
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: circle)
    context.setFillColor(NSColor(calibratedRed: 0.23, green: 0.25, blue: 0.68, alpha: 1).cgColor)
    context.fillEllipse(in: circle.insetBy(dx: radius * 0.34, dy: radius * 0.34))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("unable to encode icon\n", stderr)
    exit(1)
}
try png.write(to: output, options: .atomic)
