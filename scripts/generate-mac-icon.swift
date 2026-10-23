import AppKit
import Foundation

// Android's launcher vector is the source of truth for both platforms.
final class Vector: NSObject, XMLParserDelegate {
    var attributes: [String: String] = [:]
    var paths: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "vector" { self.attributes = attributes }
        if name == "path" { paths.append(attributes) }
    }
}

func color(_ hex: String) -> CGColor {
    let digits = String(hex.dropFirst())
    guard hex.first == "#", [6, 8].contains(digits.count), let value = UInt32(digits, radix: 16) else {
        fatalError("Unsupported vector color")
    }
    let alpha = digits.count == 8 ? CGFloat((value >> 24) & 255) / 255 : 1
    return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
}

func path(_ source: String) -> CGPath {
    // The shared icon uses straight M/H/V/Z commands. Fail on new unsupported
    // commands so future Android changes cannot silently produce a wrong icon.
    let pattern = try! NSRegularExpression(pattern: "[MmHhVvZz]|[-+]?(?:[0-9]*\\.)?[0-9]+")
    let range = NSRange(source.startIndex..., in: source)
    let tokens = pattern.matches(in: source, range: range).map { String(source[Range($0.range, in: source)!]) }
    let compact = source.filter { !$0.isWhitespace && $0 != "," }
    precondition(tokens.joined() == compact, "Unsupported vector path")
    let result = CGMutablePath()
    var cursor = CGPoint.zero
    var index = 0
    func number() -> CGFloat {
        precondition(index < tokens.count)
        guard let value = Double(tokens[index]) else { fatalError("Missing path coordinate") }
        index += 1
        return CGFloat(value)
    }
    while index < tokens.count {
        let command = tokens[index]; index += 1
        switch command {
        case "M", "m":
            let x = number(), y = number()
            cursor = command == "M" ? CGPoint(x: x, y: y) : CGPoint(x: cursor.x + x, y: cursor.y + y)
            result.move(to: cursor)
        case "h", "H": cursor.x = command == "h" ? cursor.x + number() : number(); result.addLine(to: cursor)
        case "v", "V": cursor.y = command == "v" ? cursor.y + number() : number(); result.addLine(to: cursor)
        case "z", "Z": result.closeSubpath(); cursor = result.currentPoint
        default: fatalError("Unsupported vector command")
        }
    }
    return result
}

precondition(CommandLine.arguments.count == 3, "Usage: generate-mac-icon.swift android-vector.xml output.iconset")
let vector = Vector()
let parser = XMLParser(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
parser.delegate = vector
precondition(parser.parse(), "Cannot parse Android icon")
let width = CGFloat(Double(vector.attributes["android:viewportWidth"]!)!)
let height = CGFloat(Double(vector.attributes["android:viewportHeight"]!)!)
precondition(width == height && !vector.paths.isEmpty)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let inset = size * 100 / 1024
        let edge = size - 2 * inset
        context.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: edge, height: edge),
            cornerWidth: edge * 0.22, cornerHeight: edge * 0.22, transform: nil))
        context.clip()
        context.translateBy(x: inset, y: size - inset)
        context.scaleBy(x: edge / width, y: -edge / height)
        for attributes in vector.paths {
            let shape = path(attributes["android:pathData"]!)
            if let fill = attributes["android:fillColor"] {
                context.addPath(shape); context.setFillColor(color(fill)); context.fillPath()
            }
            if let stroke = attributes["android:strokeColor"] {
                context.addPath(shape); context.setStrokeColor(color(stroke))
                context.setLineWidth(CGFloat(Double(attributes["android:strokeWidth"]!)!))
                context.strokePath()
            }
        }
        let suffix = scale == 2 ? "@2x" : ""
        let destination = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
}
print("Generated macOS iconset from the Android launcher vector.")
