import AppKit

let canvas = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let tile = NSBezierPath(roundedRect: NSRect(x: 98, y: 98, width: 828, height: 828), xRadius: 200, yRadius: 200)
    NSColor(srgbRed: 0.12, green: 0.15, blue: 0.15, alpha: 1).setFill()
    tile.fill()
    NSColor(srgbRed: 0.91, green: 0.97, blue: 0.97, alpha: 1).setStroke()
    let phone = NSBezierPath(roundedRect: NSRect(x: 336, y: 246, width: 352, height: 532), xRadius: 60, yRadius: 60)
    phone.lineWidth = 28
    phone.stroke()
    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: 472, y: 715)); speaker.line(to: NSPoint(x: 552, y: 715))
    speaker.lineWidth = 19; speaker.lineCapStyle = .round; speaker.stroke()
    NSColor(srgbRed: 0.40, green: 0.94, blue: 0.77, alpha: 1).setStroke()
    let arrows = NSBezierPath()
    arrows.move(to: NSPoint(x: 415, y: 558)); arrows.line(to: NSPoint(x: 606, y: 558))
    arrows.move(to: NSPoint(x: 558, y: 606)); arrows.line(to: NSPoint(x: 606, y: 558)); arrows.line(to: NSPoint(x: 558, y: 510))
    arrows.move(to: NSPoint(x: 609, y: 450)); arrows.line(to: NSPoint(x: 418, y: 450))
    arrows.move(to: NSPoint(x: 466, y: 498)); arrows.line(to: NSPoint(x: 418, y: 450)); arrows.line(to: NSPoint(x: 466, y: 402))
    arrows.lineWidth = 26; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round; arrows.stroke()
    return true
}
let result = NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try result.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
