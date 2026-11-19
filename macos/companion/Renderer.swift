import CoreGraphics
import Foundation
import ImageIO
import JavaScriptCore
import UniformTypeIdentifiers

/// Runs render.js, the single definition of the dashboard's layout and copy.
final class Renderer {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let context: JSContext
    private let dashboard: JSValue

    init(source: String) throws {
        guard let context = JSContext() else { throw Failure(description: "cannot create a JavaScript context") }
        self.context = context
        context.evaluateScript(source, withSourceURL: URL(string: "render.js"))
        try Self.check(context, "loading render.js")
        guard let dashboard = context.objectForKeyedSubscript("CorneDashboard"), dashboard.isObject else {
            throw Failure(description: "render.js does not define CorneDashboard")
        }
        self.dashboard = dashboard
    }

    /// The packed 1440-byte frame for `state`.
    func frame(_ state: DashboardState) throws -> [UInt8] {
        let result = dashboard.invokeMethod("render", withArguments: [state.json])
        try Self.check(context, "rendering")
        let values = result?.toArray() ?? []
        let bytes = values.compactMap { ($0 as? NSNumber).map(\.intValue) }.filter { (0...255).contains($0) }
        guard values.count == frameSize, bytes.count == frameSize else {
            throw Failure(description: "render returned \(values.count) values, expected \(frameSize) bytes")
        }
        return bytes.map { UInt8($0) }
    }

    private static func check(_ context: JSContext, _ action: String) throws {
        guard let exception = context.exception else { return }
        context.exception = nil
        throw Failure(description: "\(action): \(exception)")
    }
}

/// Writes `frame` as a PNG scaled up `scale` times, in the nice!view's panel colours.
func writeSnapshot(_ frame: [UInt8], to url: URL, scale: Int = 4) throws {
    let black: [UInt8] = [0x1B, 0x1B, 0x1B], white: [UInt8] = [0xCF, 0xD0, 0xC8]
    let width = frameWidth * scale, height = frameHeight * scale
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            pixels += isBlack(frame, x: x / scale, y: y / scale) ? black : white
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                              bytesPerRow: width * 3, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw Renderer.Failure(description: "cannot encode a PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Renderer.Failure(description: "cannot write \(url.path)")
    }
}
