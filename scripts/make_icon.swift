// Renders the 1024px app icon. Usage: swift scripts/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824px body inset 100px, ~185px corner radius
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.12, alpha: 1).cgColor,
                             NSColor(srgbRed: 0.03, green: 0.05, blue: 0.045, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// faint price grid
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
ctx.setLineWidth(3)
for y in stride(from: 300.0, through: 760.0, by: 115.0) {
    ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y))
}
ctx.strokePath()

// rising tick line
let green = NSColor(srgbRed: 0.18, green: 0.86, blue: 0.52, alpha: 1)
let pts: [CGPoint] = [
    CGPoint(x: 210, y: 360), CGPoint(x: 330, y: 470), CGPoint(x: 430, y: 410),
    CGPoint(x: 560, y: 590), CGPoint(x: 660, y: 520), CGPoint(x: 800, y: 720),
]
let line = CGMutablePath()
line.addLines(between: pts)

// glow under the line
let area = CGMutablePath()
area.addLines(between: pts)
area.addLine(to: CGPoint(x: 800, y: 100)); area.addLine(to: CGPoint(x: 210, y: 100)); area.closeSubpath()
ctx.saveGState()
ctx.addPath(area); ctx.clip()
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [green.withAlphaComponent(0.32).cgColor, green.withAlphaComponent(0).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: 720), end: CGPoint(x: 0, y: 200), options: [])
ctx.restoreGState()

ctx.addPath(line)
ctx.setStrokeColor(green.cgColor)
ctx.setLineWidth(44)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// live dot
let end = pts.last!
ctx.setFillColor(green.withAlphaComponent(0.25).cgColor)
ctx.fillEllipse(in: CGRect(x: end.x - 70, y: end.y - 70, width: 140, height: 140))
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: end.x - 36, y: end.y - 36, width: 72, height: 72))
ctx.restoreGState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
