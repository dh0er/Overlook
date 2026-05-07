import Foundation
import CoreVideo
import CoreImage
import CoreGraphics

final class LetterboxDetector {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let blackThreshold: UInt8 = 24
    private let analysisRows = 9
    private let analysisCols = 9
    private let stableSampleCount = 2

    private var recentSamples: [CGRect] = []

    func sample(_ pixelBuffer: CVPixelBuffer) -> CGRect? {
        guard let detected = analyze(pixelBuffer) else { return nil }
        recentSamples.append(detected)
        if recentSamples.count > stableSampleCount {
            recentSamples.removeFirst(recentSamples.count - stableSampleCount)
        }
        guard recentSamples.count >= stableSampleCount else { return nil }
        return aggregate(recentSamples)
    }

    func reset() {
        recentSamples.removeAll(keepingCapacity: true)
    }

    private func aggregate(_ rects: [CGRect]) -> CGRect {
        let xs = rects.map { $0.minX }.sorted()
        let ys = rects.map { $0.minY }.sorted()
        let mxs = rects.map { $0.maxX }.sorted()
        let mys = rects.map { $0.maxY }.sorted()
        let mid = rects.count / 2
        let minX = xs[mid]
        let minY = ys[mid]
        let maxX = mxs[mid]
        let maxY = mys[mid]
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func analyze(_ pixelBuffer: CVPixelBuffer) -> CGRect? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }

        let w = cg.width
        let h = cg.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let drawCtx = pixels.withUnsafeMutableBytes({ ptr -> CGContext? in
            guard let base = ptr.baseAddress else { return nil }
            return CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo)
        }) else { return nil }
        drawCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        return pixels.withUnsafeBufferPointer { buf -> CGRect? in
            return findContentBounds(in: buf, width: w, height: h)
        }
    }

    private func findContentBounds(in pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> CGRect? {
        let rowIndices = sampleIndices(count: analysisRows, range: height)
        let colIndices = sampleIndices(count: analysisCols, range: width)

        var leftEdge = width
        var rightEdge = -1
        for y in rowIndices {
            let rowStart = y * width * 4
            for x in 0..<width {
                let i = rowStart + x * 4
                if pixels[i] > blackThreshold || pixels[i+1] > blackThreshold || pixels[i+2] > blackThreshold {
                    if x < leftEdge { leftEdge = x }
                    break
                }
            }
            for x in stride(from: width - 1, through: 0, by: -1) {
                let i = rowStart + x * 4
                if pixels[i] > blackThreshold || pixels[i+1] > blackThreshold || pixels[i+2] > blackThreshold {
                    if x > rightEdge { rightEdge = x }
                    break
                }
            }
        }

        var topEdge = height
        var bottomEdge = -1
        for x in colIndices {
            for y in 0..<height {
                let i = (y * width + x) * 4
                if pixels[i] > blackThreshold || pixels[i+1] > blackThreshold || pixels[i+2] > blackThreshold {
                    if y < topEdge { topEdge = y }
                    break
                }
            }
            for y in stride(from: height - 1, through: 0, by: -1) {
                let i = (y * width + x) * 4
                if pixels[i] > blackThreshold || pixels[i+1] > blackThreshold || pixels[i+2] > blackThreshold {
                    if y > bottomEdge { bottomEdge = y }
                    break
                }
            }
        }

        guard leftEdge <= rightEdge, topEdge <= bottomEdge else { return nil }

        let minViableContentFraction: CGFloat = 0.5
        let contentWidth = CGFloat(rightEdge - leftEdge + 1) / CGFloat(width)
        let contentHeight = CGFloat(bottomEdge - topEdge + 1) / CGFloat(height)
        guard contentWidth >= minViableContentFraction, contentHeight >= minViableContentFraction else {
            return nil
        }

        return CGRect(
            x: CGFloat(leftEdge) / CGFloat(width),
            y: CGFloat(topEdge) / CGFloat(height),
            width: CGFloat(rightEdge - leftEdge + 1) / CGFloat(width),
            height: CGFloat(bottomEdge - topEdge + 1) / CGFloat(height)
        )
    }

    private func sampleIndices(count: Int, range: Int) -> [Int] {
        guard count > 0, range > 0 else { return [] }
        if count == 1 { return [range / 2] }
        var result: [Int] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let t = (Double(i) + 0.5) / Double(count)
            let idx = min(range - 1, max(0, Int((Double(range) * t).rounded())))
            result.append(idx)
        }
        return result
    }
}
