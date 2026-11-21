import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
}

func drawIcon(size: Int, name: String) {
    let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    canvas.scaleBy(x: scale, y: scale)
    let tile = CGRect(x: 96, y: 96, width: 832, height: 832)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 188, cornerHeight: 188, transform: nil)
    canvas.saveGState()
    canvas.addPath(tilePath)
    canvas.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0.26, 0.40, 0.99), color(0.14, 0.18, 0.49)] as CFArray,
                              locations: [0, 1])!
    canvas.drawLinearGradient(gradient, start: CGPoint(x: 210, y: 900),
                              end: CGPoint(x: 814, y: 130), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    canvas.restoreGState()

    canvas.setStrokeColor(color(0.97, 0.99, 1))
    canvas.setLineWidth(52)
    canvas.setLineCap(.round)
    canvas.setLineJoin(.round)
    for (x, y, horizontal, vertical): (CGFloat, CGFloat, CGFloat, CGFloat) in
        [(295, 295, 1, 1), (729, 295, -1, 1), (295, 729, 1, -1), (729, 729, -1, -1)] {
        canvas.move(to: CGPoint(x: x, y: y + vertical * 125))
        canvas.addLine(to: CGPoint(x: x, y: y))
        canvas.addLine(to: CGPoint(x: x + horizontal * 125, y: y))
    }
    canvas.strokePath()
    canvas.setFillColor(color(1, 0.37, 0.38))
    canvas.fillEllipse(in: CGRect(x: 426, y: 426, width: 172, height: 172))

    let file = directory.appendingPathComponent(name + ".png")
    let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, canvas.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
}

for size in [16, 32, 128, 256, 512] {
    drawIcon(size: size, name: "icon_\(size)x\(size)")
    drawIcon(size: size * 2, name: "icon_\(size)x\(size)@2x")
}
