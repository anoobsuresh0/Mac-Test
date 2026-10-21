// Draws the "Verified" app icon and writes AppIcon.icns.  Run: swift make-icon.swift
// Artwork is designed on a 130-unit grid and placed in Apple's 824 px icon area on a 1024 px canvas.
import AppKit

func hex(_ v: UInt32) -> CGColor {
    CGColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)        // y grows downward, like the SVG
    ctx.scaleBy(x: k, y: k)

    // drop shadow under the squircle, as on Apple's icons
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(hex(0xF1EFE8)); ctx.fillPath()
    ctx.restoreGState()

    ctx.translateBy(x: 100, y: 100); ctx.scaleBy(x: 824 / 130, y: 824 / 130)

    func rect(_ r: CGRect, _ radius: CGFloat, fill: UInt32, stroke: UInt32? = nil, width: CGFloat = 0) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(hex(fill))
        if let stroke { ctx.setStrokeColor(hex(stroke)); ctx.setLineWidth(width); ctx.drawPath(using: .fillStroke) } else { ctx.fillPath() }
    }

    rect(CGRect(x: 0.5, y: 0.5, width: 129, height: 129), 29, fill: 0xF1EFE8, stroke: 0xD3D1C7, width: 1)   // tile edge
    rect(CGRect(x: 22, y: 28, width: 80, height: 54), 5, fill: 0x444441, stroke: 0x2C2C2A, width: 5)        // screen
    rect(CGRect(x: 10, y: 86, width: 104, height: 9), 4.5, fill: 0x2C2C2A)                                 // base

    ctx.addEllipse(in: CGRect(x: 98 - 23, y: 88 - 23, width: 46, height: 46))                            // seal
    ctx.setFillColor(hex(0x639922)); ctx.setStrokeColor(hex(0xF1EFE8)); ctx.setLineWidth(5); ctx.drawPath(using: .fillStroke)

    ctx.move(to: CGPoint(x: 88, y: 88)); ctx.addLine(to: CGPoint(x: 95, y: 95)); ctx.addLine(to: CGPoint(x: 108, y: 81))   // tick
    ctx.setStrokeColor(hex(0xFFFFFF)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "AppIcon.png"))
