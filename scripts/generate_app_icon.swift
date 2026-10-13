// Renders Ledger's 1024×1024 app icon (opaque PNG) with Core Graphics.
// Usage: swift scripts/generate_app_icon.swift <output.png>

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate_app_icon.swift <output.png>\n".utf8))
    exit(64)
}

let side = 1024
let canvas = CGFloat(side)
guard
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
else {
    FileHandle.standardError.write(Data("could not create drawing context\n".utf8))
    exit(1)
}

// Deep emerald diagonal gradient.
let gradientColors = [
    CGColor(srgbRed: 0.020, green: 0.200, blue: 0.165, alpha: 1),
    CGColor(srgbRed: 0.047, green: 0.420, blue: 0.341, alpha: 1),
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1]) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: canvas, y: 0),
        options: []
    )
}

// Faint ruled lines, like ledger paper.
context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07))
context.setLineWidth(5)
for row in 1...7 {
    let y = CGFloat(row) * canvas / 8
    context.move(to: CGPoint(x: 0, y: y))
    context.addLine(to: CGPoint(x: canvas, y: y))
}
context.strokePath()

// Centered peso sign in SF Pro Rounded.
let baseFont = NSFont.systemFont(ofSize: 640, weight: .semibold)
let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
let font = NSFont(descriptor: roundedDescriptor, size: 640) ?? baseFont
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "₱", attributes: attributes))
let glyphBounds = CTLineGetImageBounds(line, context)
context.textPosition = CGPoint(
    x: (canvas - glyphBounds.width) / 2 - glyphBounds.minX,
    y: (canvas - glyphBounds.height) / 2 - glyphBounds.minY
)
CTLineDraw(line, context)

guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[1]) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    FileHandle.standardError.write(Data("could not create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write PNG\n".utf8))
    exit(1)
}
print("wrote \(arguments[1])")
