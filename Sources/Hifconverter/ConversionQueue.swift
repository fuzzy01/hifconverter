import CoreImage
import Foundation
import ImageIO

struct ConversionSettings: Equatable, Sendable {
    var peakNits = HLGFormula.defaultPeakNits
    var lift = Convert.defaultLift
    var shoulder = Shoulder.standard
    var quality = Encode.defaultQuality
    var collision = Collision.fail
    var outputDirectory: URL?
}

enum FileStatus: Equatable, Sendable {
    case queued
    case working
    case written(URL, gainMap: Bool)
    case skipped(String)
    case failed(String)

    var label: String {
        switch self {
        case .queued:
            return "queued"
        case .working:
            return "working"
        case .written(let url, true):
            return "written \(url.lastPathComponent)"
        case .written(let url, false):
            return "written \(url.lastPathComponent), no gain map"
        case .skipped(let reason):
            return "skipped \(reason)"
        case .failed(let reason):
            return "failed \(reason)"
        }
    }
}

struct QueueFile: Identifiable, Equatable, Sendable {
    var id = UUID()
    var source: URL
    var pixelWidth: Int?
    var pixelHeight: Int?
    var headroom: Double?
    var status = FileStatus.queued
}

struct PreviewImages: @unchecked Sendable {
    var headroom: Double
    var sdr: CGImage
    var hdr: CGImage?
}

enum ConversionQueue {
    /// Folders contribute their `.hif` files. Any other existing file is kept so the queue can report it.
    static func files(from urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                found.append(contentsOf: Hifconvert.hifFiles(under: url))
            } else {
                found.append(url)
            }
        }
        return found
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = integer(props[kCGImagePropertyPixelWidth as String]),
              let height = integer(props[kCGImagePropertyPixelHeight as String]) else {
            return nil
        }
        let orientation = integer(props[kCGImagePropertyOrientation as String]) ?? 1
        if (5...8).contains(orientation) {
            return (height, width)
        }
        return (width, height)
    }

    static func convert(_ file: URL, settings: ConversionSettings) -> FileStatus {
        guard file.pathExtension.lowercased() == "hif" else {
            return .failed("not a HIF")
        }
        let destination = settings.outputDirectory?
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("heic")
        do {
            let result = try Export.convert(
                source: file,
                to: destination,
                collision: settings.collision,
                shoulder: settings.shoulder,
                quality: settings.quality,
                peakNits: settings.peakNits,
                lift: settings.lift
            )
            return .written(result.output, gainMap: Encode.hasISOGainMap(at: result.output))
        } catch ExportError.skipped(let name) {
            return .skipped("\(name) already exists")
        } catch {
            return .failed(Hifconvert.reason(error))
        }
    }

    /// SDR and HDR pictures from the same lift and tone map as the writer, rendered at `maxSide`.
    static func preview(of file: URL, settings: ConversionSettings, maxSide: CGFloat = 960) -> PreviewImages? {
        guard let data = try? Data(contentsOf: file), let image = Convert.decode(data) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let headroom = Convert.highPercentile(image, fraction: 0.999, context: context)
        let extent = image.extent.integral
        let longSide = max(extent.width, extent.height)
        guard longSide >= 1,
              let displayP3 = CGColorSpace(name: CGColorSpace.displayP3),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            return nil
        }
        let scale = min(1, maxSide / longSide)
        let small = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        do {
            switch try Convert.picture(from: small, shoulder: settings.shoulder, peakNits: settings.peakNits, lift: settings.lift) {
            case .hdr(let pair):
                guard let sdr = context.createCGImage(pair.sdr, from: pair.sdr.extent, format: .RGBA8, colorSpace: displayP3),
                      let hdr = context.createCGImage(pair.hdr, from: pair.hdr.extent, format: .RGBAf, colorSpace: linear) else {
                    return nil
                }
                return PreviewImages(headroom: headroom, sdr: sdr, hdr: hdr)
            case .still(let still):
                guard let sdr = context.createCGImage(still, from: still.extent, format: .RGBA8, colorSpace: displayP3) else {
                    return nil
                }
                return PreviewImages(headroom: headroom, sdr: sdr, hdr: nil)
            }
        } catch {
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
