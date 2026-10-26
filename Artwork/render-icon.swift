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
    bitmap.setFillColor(CGColor(red: 0, green: 0.48, blue: 0.88, alpha: 1))
    bitmap.fillPath()
    bitmap.setShadow(offset: .zero, blur: 0)
    bitmap.saveGState()
    bitmap.addPath(rounded(tile, mac ? 192 : 0)); bitmap.clip()
    let colors = [CGColor(red: 0.06, green: 0.67, blue: 0.98, alpha: 1),
                  CGColor(red: 0, green: 0.36, blue: 0.79, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    bitmap.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 1000), end: CGPoint(x: 850, y: 80), options: [])
    bitmap.restoreGState()
    if mac { bitmap.translateBy(x: 80, y: 80); bitmap.scaleBy(x: 0.84375, y: 0.84375) }
    func card(_ rect: CGRect, alpha: CGFloat) {
        bitmap.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                         color: CGColor(red: 0, green: 0.16, blue: 0.4, alpha: 0.18))
        bitmap.addPath(rounded(rect, 42))
        bitmap.setFillColor(CGColor(gray: 1, alpha: alpha)); bitmap.fillPath()
        bitmap.setShadow(offset: .zero, blur: 0)
    }
    card(CGRect(x: 388, y: 314, width: 364, height: 466), alpha: 0.45)
    card(CGRect(x: 304, y: 266, width: 364, height: 466), alpha: 0.7)
    card(CGRect(x: 220, y: 218, width: 364, height: 466), alpha: 1)
    bitmap.setFillColor(CGColor(red: 0, green: 0.47, blue: 0.86, alpha: 1))
    for (y, width) in [(566.0, 196.0), (492, 244), (418, 244), (344, 148)] {
        bitmap.addPath(rounded(CGRect(x: 280, y: y, width: width, height: 22), 11)); bitmap.fillPath()
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
