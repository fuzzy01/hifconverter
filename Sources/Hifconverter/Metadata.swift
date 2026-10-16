import Foundation
import ImageIO

enum Metadata {
    /// EXIF, GPS, and IPTC worth keeping on the Display P3 HEIC.
    /// Orientation is written as normal because the pixels are already turned.
    /// Color-space tags are left out so the primary image is not marked HLG.
    static func properties(from data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
            return [:]
        }
        let properties = stringKeyed(raw)
        var kept: [String: Any] = [
            kCGImagePropertyOrientation as String: 1
        ]
        if let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary as String]) {
            let names = [
                kCGImagePropertyTIFFMake,
                kCGImagePropertyTIFFModel,
                kCGImagePropertyTIFFSoftware,
                kCGImagePropertyTIFFArtist,
                kCGImagePropertyTIFFCopyright,
                kCGImagePropertyTIFFDateTime
            ].map { $0 as String }
            var copy = tiff.filter { names.contains($0.key) }
            copy[kCGImagePropertyOrientation as String] = 1
            if copy.isEmpty == false {
                kept[kCGImagePropertyTIFFDictionary as String] = copy
            }
        }
        if let exif = dictionary(properties[kCGImagePropertyExifDictionary as String]) {
            let copy = exif.filter { skippedExif.contains($0.key) == false }
            if copy.isEmpty == false {
                kept[kCGImagePropertyExifDictionary as String] = copy
            }
        }
        if let aux = dictionary(properties[kCGImagePropertyExifAuxDictionary as String]), aux.isEmpty == false {
            kept[kCGImagePropertyExifAuxDictionary as String] = aux
        }
        if let gps = dictionary(properties[kCGImagePropertyGPSDictionary as String]), gps.isEmpty == false {
            kept[kCGImagePropertyGPSDictionary as String] = gps
        }
        if let iptc = dictionary(properties[kCGImagePropertyIPTCDictionary as String]), iptc.isEmpty == false {
            kept[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        return kept
    }

    /// Writes `properties` onto an existing HEIC and keeps its ISO gain map.
    static func write(_ properties: [String: Any], onto url: URL) throws {
        try stamp(url, properties: properties)
    }

    static func apply(from source: Data, onto url: URL) throws {
        try stamp(url, properties: properties(from: source))
    }

    static func read(from url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
            return [:]
        }
        return stringKeyed(raw)
    }

    /// Copies tags onto the HEIC without re-encoding it.
    /// `CGImageDestinationAddImageFromSource` rebuilds the gain map and tags the HDR
    /// view as BT.2100 PQ, which Preview reports as BT.2020 primaries.
    private static func stamp(_ url: URL, properties: [String: Any]) throws {
        let side = url.appendingPathExtension("meta")
        defer { try? FileManager.default.removeItem(at: side) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(side as CFURL, "public.heic" as CFString, 1, nil) else {
            throw ExportError.metadata
        }
        var error: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(destination, source, [
            kCGImageDestinationMetadata: metadata(from: properties)
        ] as CFDictionary, &error)
        guard copied else { throw ExportError.metadata }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: side)
    }

    private static func metadata(from properties: [String: Any]) -> CGMutableImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        if let orientation = properties[kCGImagePropertyOrientation as String] {
            set(metadata, dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFOrientation as String, value: orientation)
        }
        copy(properties[kCGImagePropertyTIFFDictionary as String], dictionary: kCGImagePropertyTIFFDictionary, into: metadata)
        copy(properties[kCGImagePropertyExifDictionary as String], dictionary: kCGImagePropertyExifDictionary, into: metadata)
        copy(properties[kCGImagePropertyExifAuxDictionary as String], dictionary: kCGImagePropertyExifAuxDictionary, into: metadata)
        copy(properties[kCGImagePropertyGPSDictionary as String], dictionary: kCGImagePropertyGPSDictionary, into: metadata)
        copy(properties[kCGImagePropertyIPTCDictionary as String], dictionary: kCGImagePropertyIPTCDictionary, into: metadata)
        return metadata
    }

    private static func copy(_ value: Any?, dictionary: CFString, into metadata: CGMutableImageMetadata) {
        guard let fields = self.dictionary(value) else { return }
        for (key, entry) in fields {
            set(metadata, dictionary: dictionary, key: key, value: entry)
        }
    }

    private static func set(_ metadata: CGMutableImageMetadata, dictionary: CFString, key: String, value: Any) {
        guard let boxed = metadataValue(value, key: key) else { return }
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key as CFString, boxed)
    }

    /// These tags describe the HIF encoding. Copying them would mark the HEIC as HLG
    /// or give it the source pixel size after the pixels have been turned upright.
    private static let skippedExif: Set<String> = [
        kCGImagePropertyExifColorSpace as String,
        kCGImagePropertyExifPixelXDimension as String,
        kCGImagePropertyExifPixelYDimension as String,
        kCGImagePropertyExifComponentsConfiguration as String,
        kCGImagePropertyExifCompressedBitsPerPixel as String,
        kCGImagePropertyExifVersion as String,
        kCGImagePropertyExifFlashPixVersion as String
    ]

    /// EXIF rationals. A plain number is stored as an integer, which drops the fraction.
    private static let rationalExif: Set<String> = [
        kCGImagePropertyExifExposureTime as String,
        kCGImagePropertyExifFNumber as String,
        kCGImagePropertyExifFocalLength as String,
        kCGImagePropertyExifExposureBiasValue as String,
        kCGImagePropertyExifBrightnessValue as String,
        kCGImagePropertyExifShutterSpeedValue as String,
        kCGImagePropertyExifApertureValue as String,
        kCGImagePropertyExifMaxApertureValue as String,
        kCGImagePropertyExifSubjectDistance as String,
        kCGImagePropertyExifFlashEnergy as String,
        kCGImagePropertyExifDigitalZoomRatio as String,
        kCGImagePropertyExifAuxFlashCompensation as String
    ]

    private static let rationalArrayExif: Set<String> = [
        kCGImagePropertyExifLensSpecification as String,
        kCGImagePropertyExifAuxLensInfo as String
    ]

    private static func metadataValue(_ value: Any, key: String) -> CFTypeRef? {
        if let data = value as? Data {
            return data as CFData
        }
        if let text = value as? String {
            return text as CFString
        }
        if key == kCGImagePropertyExifISOSpeedRatings as String, let first = firstNumber(value) {
            return first
        }
        if key == kCGImagePropertyExifFlash as String, let bits = firstNumber(value)?.intValue {
            return flashStructure(bits)
        }
        if rationalArrayExif.contains(key), let items = rationalItems(value) {
            return items as CFArray
        }
        if let number = value as? NSNumber {
            if rationalExif.contains(key) {
                return rational(number.doubleValue) as CFString
            }
            return number
        }
        if let items = value as? [Any] {
            return items as CFArray
        }
        if let items = value as? NSArray {
            return items
        }
        return nil
    }

    private static func firstNumber(_ value: Any) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let numbers = value as? [NSNumber] { return numbers.first }
        if let numbers = value as? NSArray { return numbers.firstObject as? NSNumber }
        return nil
    }

    private static func rational(_ value: Double) -> String {
        guard value.isFinite else { return "0/1" }
        if value == 0 { return "0/1" }
        let denominator = 1_000_000
        let numerator = Int64((abs(value) * Double(denominator)).rounded())
        let sign = value < 0 ? "-" : ""
        return "\(sign)\(numerator)/\(denominator)"
    }

    /// ImageIO stores Flash as a structure. A packed integer is read back as 0.
    private static func flashStructure(_ bits: Int) -> CFDictionary {
        let xmlns = "http://ns.adobe.com/exif/1.0/" as CFString
        func tag(_ name: String, _ value: CFTypeRef) -> CGImageMetadataTag {
            CGImageMetadataTagCreate(xmlns, "exif" as CFString, name as CFString, .default, value)!
        }
        let fields: [String: Any] = [
            "Fired": tag("Fired", (bits & 1) == 0 ? kCFBooleanFalse : kCFBooleanTrue),
            "Return": tag("Return", NSNumber(value: (bits >> 1) & 0x3)),
            "Mode": tag("Mode", NSNumber(value: (bits >> 3) & 0x3)),
            "Function": tag("Function", (bits & 0x20) == 0 ? kCFBooleanFalse : kCFBooleanTrue),
            "RedEyeMode": tag("RedEyeMode", (bits & 0x40) == 0 ? kCFBooleanFalse : kCFBooleanTrue)
        ]
        return fields as CFDictionary
    }

    private static func rationalItems(_ value: Any) -> [String]? {
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let array = value as? NSArray {
            items = (0..<array.count).map { array[$0] }
        } else {
            return nil
        }
        var result: [String] = []
        for entry in items {
            if let number = entry as? NSNumber {
                result.append(rational(number.doubleValue))
            } else if let text = entry as? String {
                if text.contains("/") {
                    result.append(text)
                } else if let number = Double(text) {
                    result.append(rational(number))
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return result
    }

    private static func stringKeyed(_ raw: Any) -> [String: Any] {
        guard let dictionary = raw as? NSDictionary else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else { continue }
            result[key] = value
        }
        return result
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        guard let value else { return nil }
        let keyed = stringKeyed(value)
        return keyed.isEmpty && (value as? NSDictionary)?.count != 0 ? nil : keyed
    }
}
