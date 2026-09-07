//
// Rasterises one of Resources/Icons/*.svg to a square PNG at a given pixel size.
// AppKit reads SVG directly, so icon generation needs no third-party tooling.
//
// Usage: swift scripts/render-icon.swift <input.svg> <pixel-size> <output.png>
//

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-icon: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: render-icon.swift <input.svg> <pixel-size> <output.png>")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
guard let size = Int(CommandLine.arguments[2]), size > 0 else {
    fail("pixel size must be a positive integer, got: \(CommandLine.arguments[2])")
}
let output = URL(fileURLWithPath: CommandLine.arguments[3])

guard let image = NSImage(contentsOf: input) else {
    fail("could not read \(input.path)")
}

guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("could not allocate a \(size)x\(size) bitmap")
}
canvas.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: canvas) else {
    fail("could not create a drawing context")
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else {
    fail("could not encode PNG data")
}
do {
    try png.write(to: output)
} catch {
    fail("could not write \(output.path): \(error.localizedDescription)")
}
