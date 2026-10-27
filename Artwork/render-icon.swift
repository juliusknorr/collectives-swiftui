import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int, mac: Bool, url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace, bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    bitmap.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    let tile = mac ? CGRect(x: 80, y: 80, width: 864, height: 864) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    if mac {
        bitmap.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
                         color: CGColor(gray: 0, alpha: 0.22))
    }
    bitmap.addPath(rounded(tile, mac ? 192 : 0))
    let blue = CGColor(red: 0, green: 130.0 / 255, blue: 201.0 / 255, alpha: 1)
    bitmap.setFillColor(blue)
    bitmap.fillPath()
    bitmap.setShadow(offset: .zero, blur: 0, color: nil)
    if mac { bitmap.translateBy(x: 80, y: 80); bitmap.scaleBy(x: 0.84375, y: 0.84375) }
    let white = CGColor(gray: 1, alpha: 1)
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 290
    bitmap.setFillColor(white)
    bitmap.setStrokeColor(white)
    bitmap.setLineWidth(44)
    bitmap.setLineCap(.round)
    for degrees in [90.0, 210, 330] {
        let angle = CGFloat(degrees * .pi / 180)
        let head = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        bitmap.fillEllipse(in: CGRect(x: head.x - 60, y: head.y - 60, width: 120, height: 120))
        bitmap.addArc(center: center, radius: radius,
                      startAngle: angle + 25 * .pi / 180, endAngle: angle + 95 * .pi / 180, clockwise: false)
        bitmap.strokePath()
    }

    func sheet(_ path: CGPath) {
        bitmap.addPath(path)
        bitmap.setStrokeColor(blue)
        bitmap.setLineWidth(30)
        bitmap.setLineJoin(.round)
        bitmap.strokePath()
        bitmap.addPath(path)
        bitmap.setFillColor(white)
        bitmap.fillPath()
    }
    sheet(rounded(CGRect(x: 370, y: 392, width: 164, height: 236), 18))
    sheet(rounded(CGRect(x: 424, y: 370, width: 164, height: 294), 18))
    let front = CGMutablePath()
    front.move(to: CGPoint(x: 496, y: 354))
    front.addLine(to: CGPoint(x: 654, y: 354))
    front.addQuadCurve(to: CGPoint(x: 672, y: 372), control: CGPoint(x: 672, y: 354))
    front.addLine(to: CGPoint(x: 672, y: 558))
    front.addLine(to: CGPoint(x: 614, y: 616))
    front.addLine(to: CGPoint(x: 496, y: 616))
    front.addQuadCurve(to: CGPoint(x: 478, y: 598), control: CGPoint(x: 478, y: 616))
    front.addLine(to: CGPoint(x: 478, y: 372))
    front.addQuadCurve(to: CGPoint(x: 496, y: 354), control: CGPoint(x: 478, y: 354))
    front.closeSubpath()
    sheet(front)
    bitmap.setFillColor(blue)
    for (y, width) in [(486.0, 120.0), (436, 104)] {
        bitmap.addPath(rounded(CGRect(x: 516, y: y, width: width, height: 24), 12))
        bitmap.fillPath()
    }
    let image = bitmap.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        try render(size: points * scale, mac: true, url: assets.appendingPathComponent(name))
        let iconName = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let destination = iconset.appendingPathComponent(iconName)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: assets.appendingPathComponent(name), to: iconset.appendingPathComponent(iconName))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
try render(size: 1024, mac: false, url: assets.appendingPathComponent("ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
let catalog: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: assets.appendingPathComponent("Contents.json"))
