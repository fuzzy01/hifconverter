import Darwin
import Foundation

struct BatchResult: Equatable {
    var stdout: String
    var stderr: String
    var status: Int32
}

enum Hifconvert {
    static var usage: String {
        let stops = String(format: "%g", Convert.defaultLift)
        return """
        hifconvert reads Sony HLG HEIF files and writes a sibling HEIC.
        Files are converted one at a time.
        --lift adds stops after the HLG decode. Default is \(stops). 0 keeps the decoded brightness.

        usage: hifconvert [--peak-nits 1000] [--lift \(stops)] [--shoulder standard|match] [--quality 0.85]
                          [--out-dir directory] [--on-collision fail|suffix|overwrite|skip]
                          file-or-folder ...
        """
    }

    static func run(arguments: [String]) -> Int32 {
        let result = execute(arguments: arguments)
        if result.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if result.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        return result.status
    }

    static func execute(arguments: [String]) -> BatchResult {
        let args = Array(arguments.dropFirst())
        guard let options = parse(args) else {
            return BatchResult(stdout: "", stderr: usage + "\n", status: 2)
        }
        if options.help {
            return BatchResult(stdout: usage + "\n", stderr: "", status: 0)
        }
        var job = options
        if let directory = job.outputDirectory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                job.outputDirectory = canonical(directory)
            } catch {
                return BatchResult(stdout: "", stderr: "hifconvert: \(directory.path): \(error)\n", status: 2)
            }
        }

        var lines: [String] = []
        var failures = 0
        for input in job.inputs {
            let url = canonical(URL(fileURLWithPath: input))
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                lines.append("failed \(input) no such file")
                failures += 1
                continue
            }
            let files = isDirectory.boolValue ? hifFiles(under: url) : [url]
            if isDirectory.boolValue, files.isEmpty {
                lines.append("skipped \(input) no HIF files")
                continue
            }
            for file in files {
                switch convert(file, options: job) {
                case .ok(let output):
                    lines.append("ok \(file.path) \(output.path)")
                case .skipped(let reason):
                    lines.append("skipped \(file.path) \(reason)")
                case .failed(let reason):
                    lines.append("failed \(file.path) \(reason)")
                    failures += 1
                }
            }
        }
        let stdout = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return BatchResult(stdout: stdout, stderr: "", status: failures == 0 ? 0 : 1)
    }

    private struct Options {
        var help = false
        var peakNits = HLGFormula.defaultPeakNits
        var lift = Convert.defaultLift
        var shoulder = Shoulder.standard
        var quality = Encode.defaultQuality
        var outputDirectory: URL?
        var collision = Collision.fail
        var inputs: [String] = []
    }

    private enum Outcome {
        case ok(URL)
        case skipped(String)
        case failed(String)
    }

    /// One file finishes, including its HEIC write, before the next file starts.
    private static func convert(_ file: URL, options: Options) -> Outcome {
        let destination = options.outputDirectory?
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("heic")
        do {
            let result = try Export.convert(
                source: file,
                to: destination,
                collision: options.collision,
                shoulder: options.shoulder,
                quality: options.quality,
                peakNits: options.peakNits,
                lift: options.lift
            )
            return .ok(result.output)
        } catch ExportError.skipped(let name) {
            return .skipped("\(name) already exists")
        } catch {
            return .failed(reason(error))
        }
    }

    private static func canonical(_ url: URL) -> URL {
        if let resolved = url.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path {
            return url
        }
        return canonical(parent).appendingPathComponent(url.lastPathComponent)
    }

    private static func hifFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.pathExtension.lowercased() == "hif" {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func parse(_ args: [String]) -> Options? {
        if args.isEmpty {
            return nil
        }
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help", "-h":
                options.help = true
                return options
            case "--peak-nits":
                guard let value = value(after: &index, args: args), let nits = Double(value), nits > 0 else { return nil }
                options.peakNits = nits
            case "--lift":
                guard let value = value(after: &index, args: args), let stops = Double(value), stops.isFinite else { return nil }
                options.lift = stops
            case "--shoulder":
                guard let value = value(after: &index, args: args) else { return nil }
                switch value {
                case "standard":
                    options.shoulder = .standard
                case "match":
                    options.shoulder = .matchFrame
                default:
                    return nil
                }
            case "--quality":
                guard let value = value(after: &index, args: args), let quality = Double(value), quality > 0, quality <= 1 else {
                    return nil
                }
                options.quality = quality
            case "--out-dir":
                guard let value = value(after: &index, args: args) else { return nil }
                options.outputDirectory = URL(fileURLWithPath: value)
            case "--on-collision":
                guard let value = value(after: &index, args: args) else { return nil }
                switch value {
                case "fail":
                    options.collision = .fail
                case "suffix":
                    options.collision = .suffix
                case "overwrite":
                    options.collision = .overwriteHEIC
                case "skip":
                    options.collision = .skip
                default:
                    return nil
                }
            case let other where other.hasPrefix("-"):
                return nil
            default:
                options.inputs.append(arg)
            }
            index += 1
        }
        if options.inputs.isEmpty {
            return nil
        }
        return options
    }

    private static func value(after index: inout Int, args: [String]) -> String? {
        index += 1
        guard index < args.count else { return nil }
        return args[index]
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case ExportError.sameAsSource:
            return "output is the source file"
        case ExportError.collision(let name):
            return "\(name) already exists"
        case ExportError.refusesHIF:
            return "refuses to write a HIF"
        case ExportError.metadata:
            return "metadata copy failed"
        case ExportError.skipped(let name):
            return "\(name) already exists"
        case ConvertError.noHeadroom:
            return "decoded without HLG headroom"
        case ConvertError.emptyImage:
            return "empty image"
        case EncodeError.destinationExists:
            return "output already exists"
        case EncodeError.refusesHIF:
            return "refuses to write a HIF"
        case EncodeError.writeFailed:
            return "write failed"
        default:
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain {
                return nsError.localizedDescription
            }
            return String(describing: error)
        }
    }
}
