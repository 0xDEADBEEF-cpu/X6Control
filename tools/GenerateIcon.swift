import AppKit
import Foundation

let sizes = [16, 32, 128, 256, 512]
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func drawIcon() {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: 10, dy: 10), xRadius: 224, yRadius: 224)
    NSGradient(starting: color(0x263322), ending: color(0x0c100d))?.draw(in: background, angle: -54)

    let halo = NSBezierPath(ovalIn: CGRect(x: 240, y: 355, width: 544, height: 544))
    color(0x8eea43, alpha: 0.035).setFill()
    halo.fill()
    let orbit = NSBezierPath(ovalIn: CGRect(x: 205, y: 354, width: 614, height: 366))
    orbit.lineWidth = 2
    color(0xb2cf8f, alpha: 0.13).setStroke()
    orbit.stroke()

    let mouse = NSBezierPath()
    mouse.move(to: NSPoint(x: 512, y: 852))
    mouse.curve(to: NSPoint(x: 767, y: 617), controlPoint1: NSPoint(x: 700, y: 846), controlPoint2: NSPoint(x: 767, y: 757))
    mouse.line(to: NSPoint(x: 767, y: 506))
    mouse.curve(to: NSPoint(x: 512, y: 252), controlPoint1: NSPoint(x: 767, y: 365), controlPoint2: NSPoint(x: 653, y: 252))
    mouse.curve(to: NSPoint(x: 257, y: 506), controlPoint1: NSPoint(x: 371, y: 252), controlPoint2: NSPoint(x: 257, y: 365))
    mouse.line(to: NSPoint(x: 257, y: 617))
    mouse.curve(to: NSPoint(x: 512, y: 852), controlPoint1: NSPoint(x: 257, y: 757), controlPoint2: NSPoint(x: 324, y: 846))
    mouse.close()
    NSGradient(starting: color(0x56634c), ending: color(0x171d16))?.draw(in: mouse, angle: 34)
    mouse.lineWidth = 8
    color(0xc0d2a9, alpha: 0.78).setStroke()
    mouse.stroke()

    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: 512, y: 849))
    divider.line(to: NSPoint(x: 512, y: 624))
    divider.lineWidth = 5
    color(0xc3d5ad, alpha: 0.62).setStroke()
    divider.stroke()

    let wheel = NSBezierPath(roundedRect: CGRect(x: 474, y: 662, width: 76, height: 132), xRadius: 38, yRadius: 38)
    color(0x10140f).setFill()
    wheel.fill()
    wheel.lineWidth = 5
    color(0x849275, alpha: 0.9).setStroke()
    wheel.stroke()
    let wheelLight = NSBezierPath(roundedRect: CGRect(x: 497, y: 720, width: 30, height: 49), xRadius: 15, yRadius: 15)
    color(0xc9ff59).setFill()
    wheelLight.fill()

    let leftLight = NSBezierPath()
    leftLight.move(to: NSPoint(x: 274, y: 481))
    leftLight.line(to: NSPoint(x: 310, y: 481))
    leftLight.line(to: NSPoint(x: 310, y: 624))
    leftLight.lineWidth = 13
    leftLight.lineCapStyle = .round
    color(0xc9ff59).setStroke()
    leftLight.stroke()

    let rightLight = NSBezierPath()
    rightLight.move(to: NSPoint(x: 750, y: 481))
    rightLight.line(to: NSPoint(x: 714, y: 481))
    rightLight.line(to: NSPoint(x: 714, y: 624))
    rightLight.lineWidth = 13
    rightLight.lineCapStyle = .round
    color(0xc9ff59).setStroke()
    rightLight.stroke()

    let word = NSAttributedString(string: "X6", attributes: [
        .font: NSFont.systemFont(ofSize: 90, weight: .heavy),
        .foregroundColor: color(0xd8e8c7),
        .kern: 15,
    ])
    let wordSize = word.size()
    word.draw(at: NSPoint(x: (1024 - wordSize.width) / 2, y: 84))
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 410, y: 63))
    line.line(to: NSPoint(x: 614, y: 63))
    line.lineWidth = 4
    color(0xc9ff59, alpha: 0.72).setStroke()
    line.stroke()
}

for size in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create bitmap for icon size \(size)")
    }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let suffix = size == 512 ? "_512x512" : "_\(size)x\(size)"
    let filename = "icon\(suffix).png"
    let destination = output.appendingPathComponent(filename)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon size \(size)")
    }
    try data.write(to: destination)
    if size >= 16 {
        let doubled = size * 2
        let bigName = "icon_\(size)x\(size)@2x.png"
        if doubled <= 1024 {
            let doubledBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: doubled, pixelsHigh: doubled,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0)!
            doubledBitmap.size = NSSize(width: doubled, height: doubled)
            NSGraphicsContext.saveGraphicsState()
            let doubledContext = NSGraphicsContext(bitmapImageRep: doubledBitmap)!
            NSGraphicsContext.current = doubledContext
            doubledContext.imageInterpolation = .high
            doubledContext.cgContext.scaleBy(x: CGFloat(doubled) / 1024, y: CGFloat(doubled) / 1024)
            drawIcon()
            doubledContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            try doubledBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(bigName))
        }
    }
}
