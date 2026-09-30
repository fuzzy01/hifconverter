import CoreImage
import Foundation
import ImageIO

enum EncodeError: Error, Equatable {
    case refusesHIF
    case destinationExists
    case writeFailed
}

enum Encode {
    static let defaultQuality = 0.85

    static func write(
        pair: HDRPair,
        to destination: URL,
        quality: Double = defaultQuality,
        replacing: Bool = false
    ) throws -> URL {
        try prepare(destination, replacing: replacing)
        try writeHEIC(sdr: pair.sdr, hdr: tagged(pair.hdr, headroom: pair.sourceHeadroom), to: destination, quality: quality)
        return destination
    }

    /// A picture that did not decode as HLG, written as a Display P3 HEIC with no gain map.
    static func write(
        image: CIImage,
        to destination: URL,
        quality: Double = defaultQuality,
        replacing: Bool = false
    ) throws -> URL {
        try prepare(destination, replacing: replacing)
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw EncodeError.writeFailed
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
            CIImageRepresentationOption(rawValue: kCGImageDestinationEmbedThumbnail as String): true
        ]
        try context.writeHEIFRepresentation(
            of: image,
            to: destination,
            format: .RGBA8,
            colorSpace: displayP3,
            options: options
        )
        return destination
    }

    private static func prepare(_ destination: URL, replacing: Bool) throws {
        if destination.pathExtension.lowercased() == "hif" {
            throw EncodeError.refusesHIF
        }
        if replacing {
            try? FileManager.default.removeItem(at: destination)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            throw EncodeError.destinationExists
        }
    }

    static func hasISOGainMap(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }

    private static func writeHEIC(sdr: CIImage, hdr: CIImage, to url: URL, quality: Double) throws {
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw EncodeError.writeFailed
        }
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: linear
        ])
        defer { context.clearCaches() }
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            .hdrGainMapAsRGB: true,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
            CIImageRepresentationOption(rawValue: kCGImageDestinationEmbedThumbnail as String): true
        ]
        try context.writeHEIF10Representation(of: sdr, to: url, colorSpace: displayP3, options: options)
    }

    private static func tagged(_ hdr: CIImage, headroom: Double) -> CIImage {
        if #available(macOS 26.0, *) {
            return hdr.settingContentHeadroom(Float(headroom))
        }
        return hdr
    }
}
