import ColorSync
import CoreImage
import Foundation
import ImageIO
@testable import Hifconverter

// `swift run hifconvert-check` runs these checks. This Mac's command-line tools
// cannot load the Swift Testing macros, so the checks are an executable.

@main
struct HifconvertCheck {
    static func main() {
        let check = Check()
        do {
            try sdrHdrPair(check)
            try isoGainMap(check)
            try fileSafetyAndMetadata(check)
            try variedPictureKeepsDisplayP3(check)
            try orientationTurnsPixels(check)
            try stillWithoutHeadroom(check)
            try batchCommand(check)
        } catch {
            check.fail("\(error)")
        }
        if check.failed > 0 {
            fputs("\(check.failed) check(s) failed\n", stderr)
            exit(1)
        }
        print("ok")
    }
}

private final class Check: @unchecked Sendable {
    var failed = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) rethrows {
        if try condition() == false {
            failed += 1
            fputs("FAIL \(file):\(line) \(message)\n", stderr)
        }
    }
    func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        failed += 1
        fputs("FAIL \(file):\(line) \(message)\n", stderr)
    }
}

private func batchCommand(_ check: Check) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-batch-\(UUID().uuidString)", isDirectory: true)
    let card = root.appendingPathComponent("card", isDirectory: true)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: card.appendingPathComponent("nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = card.appendingPathComponent("DSC0001.HIF").resolvingSymlinksInPath()
    let second = card.appendingPathComponent("nested").appendingPathComponent("DSC0002.HIF").resolvingSymlinksInPath()
    try writeStampedHIF(first)
    try writeStampedHIF(second)
    try Data([0xFF, 0xD8]).write(to: card.appendingPathComponent("note.jpg"))

    let usage = Hifconvert.execute(arguments: ["hifconvert"])
    check.expect(usage.status == 2, "usage status \(usage.status)")
    check.expect(usage.stderr.contains("sibling HEIC"), "usage text")
    check.expect(usage.stderr.contains("--lift"), "usage lists lift")
    let badLift = Hifconvert.execute(arguments: ["hifconvert", "--lift", "bright", "x.hif"])
    check.expect(badLift.status == 2, "bad lift status \(badLift.status)")

    let converted = Hifconvert.execute(arguments: [
        "hifconvert",
        "--peak-nits", "1000",
        "--shoulder", "standard",
        "--quality", "0.85",
        "--out-dir", out.path,
        card.path
    ])
    check.expect(converted.status == 0, "batch status \(converted.status) \(converted.stdout)")
    check.expect(converted.stdout.contains("DSC0001.HIF") && converted.stdout.contains("DSC0001.heic"), converted.stdout)
    check.expect(converted.stdout.contains("DSC0002.HIF") && converted.stdout.contains("DSC0002.heic"), converted.stdout)
    check.expect(converted.stdout.contains("note.jpg") == false, "jpeg was listed")
    check.expect(Encode.hasISOGainMap(at: out.appendingPathComponent("DSC0001.heic")), "first gain map")
    check.expect(Encode.hasISOGainMap(at: out.appendingPathComponent("DSC0002.heic")), "second gain map")

    let plain = root.appendingPathComponent("plain", isDirectory: true)
    let zeroLift = Hifconvert.execute(arguments: ["hifconvert", "--lift", "0", "--out-dir", plain.path, first.path])
    check.expect(zeroLift.status == 0, "lift 0 status \(zeroLift.status) \(zeroLift.stdout)")
    if let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
        let context = CIContext(options: [.cacheIntermediates: false])
        let liftedHighlight = highlight(out.appendingPathComponent("DSC0001.heic"), context: context, space: space)
        let plainHighlight = highlight(plain.appendingPathComponent("DSC0001.heic"), context: context, space: space)
        let ratio = plainHighlight == 0 ? 0 : liftedHighlight / plainHighlight
        check.expect(abs(ratio - Convert.exposureGain) < Convert.exposureGain * 0.2, "lift ratio \(ratio) highlights \(liftedHighlight) \(plainHighlight)")
    } else {
        check.fail("missing extended linear Display P3")
    }

    let missing = card.appendingPathComponent("missing.HIF").resolvingSymlinksInPath().path
    let again = Hifconvert.execute(arguments: ["hifconvert", "--out-dir", out.path, missing, card.path])
    check.expect(again.status == 1, "partial failure status \(again.status)")
    check.expect(again.stdout.contains("failed ") && again.stdout.contains("missing.HIF") && again.stdout.contains("no such file"), again.stdout)
    check.expect(again.stdout.contains("failed ") && again.stdout.contains("DSC0001.HIF") && again.stdout.contains("already exists"), again.stdout)
    check.expect(again.stdout.contains("DSC0002.HIF") && again.stdout.contains("already exists"), again.stdout)

    let skipped = Hifconvert.execute(arguments: ["hifconvert", "--on-collision", "skip", "--out-dir", out.path, card.path])
    check.expect(skipped.status == 0, "skip status \(skipped.status) \(skipped.stdout)")
    check.expect(skipped.stdout.contains("skipped ") && skipped.stdout.contains("DSC0001.HIF") && skipped.stdout.contains("already exists"), skipped.stdout)
    check.expect(skipped.stdout.contains("DSC0002.HIF") && skipped.stdout.contains("already exists"), skipped.stdout)

    let suffixed = Hifconvert.execute(arguments: ["hifconvert", "--on-collision", "suffix", "--out-dir", out.path, first.path])
    check.expect(suffixed.status == 0, "suffix status \(suffixed.status) \(suffixed.stdout)")
    check.expect(suffixed.stdout.contains("DSC0001 HDR.heic"), suffixed.stdout)
    check.expect(Encode.hasISOGainMap(at: out.appendingPathComponent("DSC0001 HDR.heic")), "suffix gain map")
}

private func writeStampedHIF(_ url: URL) throws {
    let ramp = hlgRamp(width: 32, height: 16)
    let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    try CIContext(options: [.cacheIntermediates: false]).writeHEIF10Representation(
        of: ramp,
        to: url,
        colorSpace: hlg,
        options: [:]
    )
    try Metadata.write(fixtureProperties(), onto: url)
}

private func fileSafetyAndMetadata(_ check: Check) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hif = directory.appendingPathComponent("DSC0001.HIF")
    let ramp = hlgRamp(width: 64, height: 32)
    let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    try CIContext(options: [.cacheIntermediates: false]).writeHEIF10Representation(
        of: ramp,
        to: hif,
        colorSpace: hlg,
        options: [:]
    )
    try Metadata.write(fixtureProperties(), onto: hif)
    let stamped = Metadata.read(from: hif)
    let stampedExif = dictionary(stamped[kCGImagePropertyExifDictionary as String])
    check.expect(stampedExif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2024:06:15 10:30:00",
                 "fixture date \(String(describing: stampedExif))")

    do {
        _ = try Export.convert(source: hif, to: hif)
        check.fail("converted onto the source")
    } catch ExportError.sameAsSource {
    } catch {
        check.fail("expected sameAsSource, got \(error)")
    }

    let exported = try Export.convert(source: hif, collision: .fail)
    check.expect(Encode.hasISOGainMap(at: exported.output), "exported ISO gain map")
    let exif = dictionary(Metadata.read(from: exported.output)[kCGImagePropertyExifDictionary as String])
    let gps = dictionary(Metadata.read(from: exported.output)[kCGImagePropertyGPSDictionary as String])
    check.expect(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2024:06:15 10:30:00",
                 "exported date \(String(describing: exif))")
    let aperture = (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? -1
    let exposure = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? -1
    check.expect(abs(aperture - 2.8) < 0.001, "exported aperture \(aperture)")
    check.expect(abs(exposure - 0.01) < 0.00001, "exported exposure \(exposure)")
    let latitude = (gps?[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue ?? -1
    check.expect(abs(latitude - 35.6895) < 0.0001, "exported latitude \(latitude)")
    check.expect((gps?[kCGImagePropertyGPSLatitudeRef as String] as? String) == "N", "latitude ref")
    check.expect(hdrColorSpace(exported.output) == (CGColorSpace.displayP3_PQ as String),
                 "HDR primaries \(hdrColorSpace(exported.output))")

    do {
        _ = try Export.convert(source: hif, collision: .fail)
        check.fail("overwrote an existing HEIC")
    } catch ExportError.collision(let name) {
        check.expect(name == "DSC0001.heic", "collision name \(name)")
    } catch {
        check.fail("expected collision, got \(error)")
    }

    let suffixed = try Export.convert(source: hif, collision: .suffix)
    check.expect(suffixed.output.lastPathComponent == "DSC0001 HDR.heic", "suffix \(suffixed.output.lastPathComponent)")
    check.expect(Encode.hasISOGainMap(at: suffixed.output), "suffixed ISO gain map")

    let replaced = try Export.convert(source: hif, collision: .overwriteHEIC)
    check.expect(replaced.output.lastPathComponent == "DSC0001.heic", "overwrite path")
    check.expect(Encode.hasISOGainMap(at: replaced.output), "overwritten ISO gain map")
}

private func fixtureProperties() -> [String: Any] {
    [
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal as String: "2024:06:15 10:30:00",
            kCGImagePropertyExifOffsetTimeOriginal as String: "+09:00",
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifExposureTime as String: 0.01
        ],
        kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 35.6895,
            kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 139.6917,
            kCGImagePropertyGPSLongitudeRef as String: "E"
        ]
    ]
}

private func variedPictureKeepsDisplayP3(_ check: Check) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-varied-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hif = directory.appendingPathComponent("DSC0003.HIF")
    let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    try CIContext(options: [.cacheIntermediates: false]).writeHEIF10Representation(
        of: variedHLG(width: 64, height: 32),
        to: hif,
        colorSpace: hlg,
        options: [:]
    )
    let exported = try Export.convert(source: hif)
    let description = hdrProfileDescription(exported.output)
    check.expect(description.hasPrefix("Display P3"), "HDR profile \(description)")
    check.expect(description.contains("BT.2020") == false, description)
    check.expect(Encode.hasISOGainMap(at: exported.output), "varied gain map")
}

private func orientationTurnsPixels(_ check: Check) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-orient-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hif = directory.appendingPathComponent("DSC0004.HIF")
    let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    try CIContext(options: [.cacheIntermediates: false]).writeHEIF10Representation(
        of: hlgRamp(width: 64, height: 32),
        to: hif,
        colorSpace: hlg,
        options: [:]
    )
    let turned = directory.appendingPathComponent("turned.HIF")
    guard let source = CGImageSourceCreateWithURL(hif as CFURL, nil),
          let destination = CGImageDestinationCreateWithURL(turned as CFURL, "public.heic" as CFString, 1, nil) else {
        check.fail("could not tag orientation")
        return
    }
    var error: Unmanaged<CFError>?
    guard CGImageDestinationCopyImageSource(destination, source, [
        kCGImageDestinationOrientation: 8
    ] as CFDictionary, &error) else {
        check.fail("orientation tag \(String(describing: error?.takeRetainedValue()))")
        return
    }
    let exported = try Export.convert(source: turned)
    let props = Metadata.read(from: exported.output)
    check.expect(integer(props[kCGImagePropertyOrientation as String]) == 1, "output orientation \(String(describing: props[kCGImagePropertyOrientation as String]))")
    check.expect(integer(props[kCGImagePropertyPixelWidth as String]) == 32, "oriented width \(String(describing: props[kCGImagePropertyPixelWidth as String]))")
    check.expect(integer(props[kCGImagePropertyPixelHeight as String]) == 64, "oriented height \(String(describing: props[kCGImagePropertyPixelHeight as String]))")
    check.expect(Encode.hasISOGainMap(at: exported.output), "oriented gain map")
}

private func stillWithoutHeadroom(_ check: Check) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-sdr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hif = directory.appendingPathComponent("DSC0005.HIF")
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
    try CIContext(options: [.cacheIntermediates: false]).writeHEIFRepresentation(
        of: image,
        to: hif,
        format: .RGBA8,
        colorSpace: srgb,
        options: [:]
    )
    let exported = try Export.convert(source: hif)
    check.expect(FileManager.default.fileExists(atPath: exported.output.path), "SDR HEIC written")
    check.expect(Encode.hasISOGainMap(at: exported.output) == false, "SDR file has no gain map")
    let props = Metadata.read(from: exported.output)
    check.expect(integer(props[kCGImagePropertyPixelWidth as String]) == 32, "SDR width")
    check.expect(integer(props[kCGImagePropertyPixelHeight as String]) == 16, "SDR height")
}

private func integer(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

private func variedHLG(width: Int, height: Int) -> CIImage {
    let space = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    var pixels = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let signal = Float(x) / Float(width - 1)
            let index = (y * width + x) * 4
            pixels[index] = signal
            pixels[index + 1] = y < height / 2 ? signal * 0.4 : signal
            pixels[index + 2] = signal * 0.2
            pixels[index + 3] = 1
        }
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    return CIImage(
        bitmapData: data,
        bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
        size: CGSize(width: width, height: height),
        format: .RGBAf,
        colorSpace: space
    )
}

private func hdrProfileDescription(_ url: URL) -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "unreadable" }
    let options: [CFString: Any] = [
        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        kCGImageSourceShouldAllowFloat: true
    ]
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
          let space = image.colorSpace,
          let icc = space.copyICCData() else {
        return "no profile"
    }
    var error: Unmanaged<CFError>?
    guard let created = ColorSyncProfileCreate(icc as CFData, &error) else { return "no colorsync" }
    let profile = created.takeRetainedValue()
    return (ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?) ?? "no description"
}

private func hdrColorSpace(_ url: URL) -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "unreadable" }
    let options: [CFString: Any] = [
        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        kCGImageSourceShouldAllowFloat: true
    ]
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return "no image" }
    return (image.colorSpace?.name as String?) ?? "none"
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    guard let value = value as? NSDictionary else { return nil }
    var result: [String: Any] = [:]
    for (key, entry) in value {
        guard let key = key as? String else { continue }
        result[key] = entry
    }
    return result
}

private func isoGainMap(_ check: Check) throws {
    let pair = try Convert.pair(from: hlgRamp(width: 64, height: 32), shoulder: .standard)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-encode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ramp.heic")
    _ = try Encode.write(pair: pair, to: url)
    check.expect(Encode.hasISOGainMap(at: url), "ISO 21496-1 gain map")
    check.expect(FileManager.default.fileExists(atPath: url.path), "HEIC written")

    guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
        check.fail("missing extended linear Display P3")
        return
    }
    let context = CIContext(options: [.cacheIntermediates: false])
    let data = try Data(contentsOf: url)
    guard let reconstructed = CIImage(data: data, options: [.expandToHDR: true]) else {
        check.fail("expandToHDR returned nothing")
        return
    }
    let originalHighlight = pixel(pair.hdr, x: 48, y: 16, context: context, space: space)
    let restoredHighlight = pixel(reconstructed, x: 48, y: 16, context: context, space: space)
    let restoredWhite = pixel(reconstructed, x: 16, y: 16, context: context, space: space)
    check.expect(restoredHighlight > 1, "restored highlight \(restoredHighlight)")
    check.expect(abs(restoredHighlight - originalHighlight) < max(1.5, originalHighlight * 0.2), "highlight \(restoredHighlight) vs \(originalHighlight)")
    check.expect(abs(restoredWhite - Convert.exposureGain) < max(0.4, Convert.exposureGain * 0.25), "restored reference white \(restoredWhite)")

    let hif = directory.appendingPathComponent("DSC0001.HIF")
    do {
        _ = try Encode.write(pair: pair, to: hif)
        check.fail("wrote a HIF")
    } catch EncodeError.refusesHIF {
    } catch {
        check.fail("expected refusesHIF, got \(error)")
    }
}

private func sdrHdrPair(_ check: Check) throws {
    let ramp = hlgRamp(width: 64, height: 32)
    let pair = try Convert.pair(from: ramp, shoulder: .standard)
    let gain = Convert.exposureGain
    check.expect(abs(pair.sourceHeadroom - Convert.nominalHeadroom * gain) < 1e-9, "standard shoulder")

    guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
        check.fail("missing extended linear Display P3")
        return
    }
    let context = CIContext(options: [.cacheIntermediates: false])
    let white = pixel(pair.hdr, x: 16, y: 16, context: context, space: space)
    let highlight = pixel(pair.hdr, x: 48, y: 16, context: context, space: space)
    let sdrWhite = pixel(pair.sdr, x: 16, y: 16, context: context, space: space)
    let sdrHighlight = pixel(pair.sdr, x: 48, y: 16, context: context, space: space)

    check.expect(abs(white - gain) < max(0.25, gain * 0.15), "HDR reference white \(white)")
    check.expect(highlight > 1, "HDR highlight \(highlight)")
    check.expect(abs(highlight - Convert.nominalHeadroom * gain) < max(0.7, Convert.nominalHeadroom * gain * 0.12), "HDR highlight near lifted peak, got \(highlight)")
    check.expect(abs(sdrWhite - 1) < 0.08, "SDR reference white \(sdrWhite)")
    check.expect(abs(sdrHighlight - 1) < 0.08, "SDR highlight \(sdrHighlight)")

    let flat = try Convert.pair(from: ramp, shoulder: .standard, lift: 0)
    let flatWhite = pixel(flat.hdr, x: 16, y: 16, context: context, space: space)
    check.expect(abs(flatWhite - 1) < 0.08, "zero lift reference white \(flatWhite)")
    check.expect(abs(flat.sourceHeadroom - Convert.nominalHeadroom) < 1e-9, "zero lift headroom")

    check.expect(Convert.sourceHeadroom(measuredPeak: 1.1, shoulder: .matchFrame) == 1.5, "match frame floor")
    check.expect(abs(Convert.sourceHeadroom(measuredPeak: 8, shoulder: .matchFrame) - Convert.nominalHeadroom) < 1e-9, "match frame ceiling")
    check.expect(abs(Convert.sourceHeadroom(measuredPeak: 2.4, shoulder: .matchFrame) - 2.4) < 1e-9, "match frame uses the peak")

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hif-pair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ramp.heic")
    guard let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else {
        check.fail("missing HLG color space")
        return
    }
    try context.writeHEIF10Representation(of: ramp, to: url, colorSpace: hlg, options: [:])
    let decoded = try Convert.pair(from: Data(contentsOf: url), shoulder: .standard)
    let decodedHighlight = pixel(decoded.hdr, x: 48, y: 16, context: context, space: space)
    let decodedSDR = pixel(decoded.sdr, x: 48, y: 16, context: context, space: space)
    check.expect(decodedHighlight > 1, "decoded HDR highlight \(decodedHighlight)")
    check.expect(decodedSDR <= 1.05, "decoded SDR highlight \(decodedSDR)")
}

private func hlgRamp(width: Int, height: Int) -> CIImage {
    let space = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    var pixels = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let signal: Float = x < width / 2 ? 0.75 : 1
            let index = (y * width + x) * 4
            pixels[index] = signal
            pixels[index + 1] = signal
            pixels[index + 2] = signal
            pixels[index + 3] = 1
        }
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    return CIImage(
        bitmapData: data,
        bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
        size: CGSize(width: width, height: height),
        format: .RGBAf,
        colorSpace: space
    )
}

private func highlight(_ url: URL, context: CIContext, space: CGColorSpace) -> Double {
    guard let image = CIImage(data: tryData(url), options: [.expandToHDR: true]) else { return 0 }
    return pixel(image, x: 24, y: 8, context: context, space: space)
}

private func tryData(_ url: URL) -> Data {
    (try? Data(contentsOf: url)) ?? Data()
}

private func pixel(_ image: CIImage, x: Int, y: Int, context: CIContext, space: CGColorSpace) -> Double {
    var sample = [Float](repeating: 0, count: 4)
    sample.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        context.render(
            image,
            toBitmap: base,
            rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: space
        )
    }
    return Double(max(sample[0], sample[1], sample[2]))
}

