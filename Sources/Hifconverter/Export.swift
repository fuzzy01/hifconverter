import Foundation

enum Collision: Equatable {
    /// An existing HEIC stops the job. The name is in the error.
    case fail
    /// An existing HEIC gets a sibling named `Name HDR.heic`.
    case suffix
    /// An existing `.heic` is replaced. A `.HIF` is never replaced.
    case overwriteHEIC
    /// An existing HEIC is left untouched and reported as skipped.
    case skip
}

struct ExportResult: Equatable {
    var output: URL
}

enum ExportError: Error, Equatable {
    case sameAsSource
    case collision(String)
    case refusesHIF
    case metadata
    case skipped(String)
}

enum Export {
    static func convert(
        source: URL,
        to destination: URL? = nil,
        collision: Collision = .fail,
        shoulder: Shoulder = .standard,
        quality: Double = Encode.defaultQuality,
        peakNits: Double = HLGFormula.defaultPeakNits,
        lift: Double = Convert.defaultLift
    ) throws -> ExportResult {
        // The inner pool frees the picture. Its teardown autoreleases the pixel
        // buffer into the outer pool, which then frees that too. One pool leaves
        // every frame's bitmap alive until the batch ends.
        try autoreleasepool {
            try autoreleasepool {
                let data = try Data(contentsOf: source)
                let output = try outputURL(source: source, requested: destination, collision: collision)
                let replacing = collision == .overwriteHEIC && FileManager.default.fileExists(atPath: output.path)
                let encoded: URL
                switch try Convert.picture(from: data, shoulder: shoulder, peakNits: peakNits, lift: lift) {
                case .hdr(let pair):
                    encoded = try Encode.write(pair: pair, to: output, quality: quality, replacing: replacing)
                case .still(let image):
                    encoded = try Encode.write(image: image, to: output, quality: quality, replacing: replacing)
                }
                do {
                    try Metadata.apply(from: data, onto: encoded)
                } catch {
                    try? FileManager.default.removeItem(at: encoded)
                    throw ExportError.metadata
                }
                return ExportResult(output: encoded)
            }
        }
    }

    static func outputURL(source: URL, requested: URL?, collision: Collision) throws -> URL {
        let proposed = requested ?? source.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("heic")
        if proposed.standardizedFileURL.path == source.standardizedFileURL.path {
            throw ExportError.sameAsSource
        }
        if proposed.pathExtension.lowercased() == "hif" {
            throw ExportError.refusesHIF
        }
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        switch collision {
        case .fail:
            throw ExportError.collision(proposed.lastPathComponent)
        case .overwriteHEIC:
            guard proposed.pathExtension.lowercased() == "heic" else {
                throw ExportError.collision(proposed.lastPathComponent)
            }
            return proposed
        case .suffix:
            return suffixedURL(folder: proposed.deletingLastPathComponent(), base: proposed.deletingPathExtension().lastPathComponent)
        case .skip:
            throw ExportError.skipped(proposed.lastPathComponent)
        }
    }

    private static func suffixedURL(folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent("\(base) HDR").appendingPathExtension("heic")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) HDR \(number)").appendingPathExtension("heic")
            number += 1
        }
        return url
    }
}
