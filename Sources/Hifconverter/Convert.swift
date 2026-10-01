import CoreImage
import Foundation
import ImageIO

enum Shoulder: Equatable {
    /// One tone-map headroom for every frame: the 1000 cd/m² HLG peak.
    case standard
    /// Tone-map headroom follows this frame, clamped to 1.5...the nominal peak.
    case matchFrame
}

struct HDRPair {
    /// Extended-linear Display P3 after the exposure lift. Highlights sit above 1.
    var hdr: CIImage
    /// The same picture tone-mapped to headroom 1.
    var sdr: CIImage
    var sourceHeadroom: Double
}

enum ConvertError: Error, Equatable {
    case noHeadroom
    case emptyImage
}

enum Picture {
    case hdr(HDRPair)
    case still(CIImage)
}

enum Convert {
    /// 1000 cd/m² peak divided by the 203 cd/m² reference white.
    static let nominalHeadroom = 1000.0 / 203.0
    /// Stops added when `--lift` is omitted.
    static let defaultLift = 0.5
    /// Linear multiplier for `defaultLift`.
    static var exposureGain: Double { gain(forLift: defaultLift) }

    static func gain(forLift stops: Double) -> Double {
        pow(2, stops)
    }

    static func picture(
        from data: Data,
        shoulder: Shoulder = .standard,
        peakNits: Double = HLGFormula.defaultPeakNits,
        lift: Double = defaultLift
    ) throws -> Picture {
        guard let image = decode(data) else { throw ConvertError.noHeadroom }
        do {
            return .hdr(try pair(from: image, shoulder: shoulder, peakNits: peakNits, lift: lift))
        } catch ConvertError.noHeadroom {
            return .still(try lifted(image, lift: lift))
        }
    }

    static func pair(
        from data: Data,
        shoulder: Shoulder = .standard,
        peakNits: Double = HLGFormula.defaultPeakNits,
        lift: Double = defaultLift
    ) throws -> HDRPair {
        guard let image = decode(data) else { throw ConvertError.noHeadroom }
        return try pair(from: image, shoulder: shoulder, peakNits: peakNits, lift: lift)
    }

    /// `image` is an HLG picture, or it is already extended-linear.
    /// The HLG opto-optical transfer is not applied again: the render into
    /// extended-linear Display P3 is the one conversion.
    static func pair(
        from image: CIImage,
        shoulder: Shoulder = .standard,
        peakNits: Double = HLGFormula.defaultPeakNits,
        lift: Double = defaultLift
    ) throws -> HDRPair {
        let extent = image.extent.integral
        guard extent.isEmpty == false, extent.isInfinite == false, extent.width >= 1, extent.height >= 1 else {
            throw ConvertError.emptyImage
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let gain = gain(forLift: lift)
        let measured = highPercentile(image, fraction: 0.999, context: context)
        // Judge headroom after the lift, so a frame that crosses SDR white gets a gain map.
        guard measured * gain > 1.02 else { throw ConvertError.noHeadroom }
        let hdr = try extendedDisplayP3(image, extent: extent, context: context, gain: gain)
        let source = sourceHeadroom(measuredPeak: measured, shoulder: shoulder, peakNits: peakNits) * gain
        let sdr = try toneMap(hdr, sourceHeadroom: source)
        return HDRPair(hdr: hdr, sdr: sdr, sourceHeadroom: source)
    }

    /// Below-reference frames skip the gain map, but they get the same lift.
    private static func lifted(_ image: CIImage, lift: Double) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.isEmpty == false, extent.isInfinite == false, extent.width >= 1, extent.height >= 1 else {
            throw ConvertError.emptyImage
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        return try extendedDisplayP3(image, extent: extent, context: context, gain: gain(forLift: lift))
    }

    static func sourceHeadroom(
        measuredPeak: Double,
        shoulder: Shoulder,
        peakNits: Double = HLGFormula.defaultPeakNits
    ) -> Double {
        let nominal = peakNits / HLGFormula.referenceWhiteNits
        switch shoulder {
        case .standard:
            return nominal
        case .matchFrame:
            return min(max(measuredPeak, 1.5), nominal)
        }
    }

    static func decode(_ data: Data) -> CIImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldAllowFloat: true
            ]
            if let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                let picture = CIImage(cgImage: image)
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
                return oriented(picture, properties: properties)
            }
        }
        return CIImage(data: data, options: [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false
        ])
    }

    /// ImageIO returns the stored pixels. EXIF orientation is applied here so the
    /// HEIC can be tagged upright.
    private static func oriented(_ image: CIImage, properties: [String: Any]) -> CIImage {
        guard let value = orientation(in: properties),
              let orientation = CGImagePropertyOrientation(rawValue: value),
              orientation != .up else {
            return image
        }
        return image.oriented(forExifOrientation: Int32(orientation.rawValue))
    }

    private static func orientation(in properties: [String: Any]) -> UInt32? {
        if let number = properties[kCGImagePropertyOrientation as String] as? NSNumber {
            return number.uint32Value
        }
        guard let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] else {
            return nil
        }
        let raw = tiff[kCGImagePropertyTIFFOrientation as String] ?? tiff[kCGImagePropertyOrientation as String]
        return (raw as? NSNumber)?.uint32Value
    }

    private static func extendedDisplayP3(_ image: CIImage, extent: CGRect, context: CIContext, gain: Double) throws -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw ConvertError.noHeadroom
        }
        return try bitmap(image, extent: extent, colorSpace: space, context: context, gain: gain)
    }

    private static func toneMap(_ hdr: CIImage, sourceHeadroom: Double) throws -> CIImage {
        guard let filter = CIFilter(name: "CIToneMapHeadroom") else { throw ConvertError.noHeadroom }
        filter.setValue(hdr, forKey: kCIInputImageKey)
        filter.setValue(sourceHeadroom, forKey: "inputSourceHeadroom")
        filter.setValue(1.0, forKey: "inputTargetHeadroom")
        guard let output = filter.outputImage else { throw ConvertError.noHeadroom }
        return output.cropped(to: hdr.extent)
    }

    /// 99.9th percentile of the per-pixel max channel, on a small render.
    static func highPercentile(_ image: CIImage, fraction: Double, context: CIContext) -> Double {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return 1 }
        let extent = image.extent.integral
        let longSide = max(extent.width, extent.height)
        guard longSide > 0 else { return 1 }
        let scale = min(1, 160 / longSide)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = scaled.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { return 1 }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.stride,
                bounds: bounds,
                format: .RGBAf,
                colorSpace: space
            )
        }
        var peaks = [Float]()
        peaks.reserveCapacity(width * height)
        var index = 0
        while index < pixels.count {
            peaks.append(max(pixels[index], pixels[index + 1], pixels[index + 2]))
            index += 4
        }
        peaks.sort()
        let rank = min(peaks.count - 1, max(0, Int((Double(peaks.count) * fraction).rounded(.down))))
        return Double(peaks[rank])
    }

    private static func bitmap(_ image: CIImage, extent: CGRect, colorSpace: CGColorSpace, context: CIContext, gain: Double) throws -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { throw ConvertError.emptyImage }
        var data = Data(count: width * height * 4 * MemoryLayout<Float>.stride)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                image,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.stride,
                bounds: extent,
                format: .RGBAf,
                colorSpace: colorSpace
            )
            let pixels = raw.bindMemory(to: Float.self)
            let scale = Float(gain)
            var index = 0
            while index < pixels.count {
                pixels[index] *= scale
                pixels[index + 1] *= scale
                pixels[index + 2] *= scale
                index += 4
            }
        }
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }
}
