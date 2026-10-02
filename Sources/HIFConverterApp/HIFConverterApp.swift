import AppKit
import Darwin
import SwiftUI
@testable import Hifconverter

@main
struct HIFConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(model: ConverterModel.shared)
                .frame(minWidth: 680, minHeight: 520)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1100, height: 720)
    }
}

@MainActor
@Observable
final class ConverterModel {
    static let shared = ConverterModel()

    var files: [QueueFile] = []
    var dropTargeted = false
    var settings = ConversionSettings()
    var running = false
    var stopped = false
    var writtenCount = 0
    var failedCount = 0
    var skippedCount = 0
    var selection: UUID?
    var preview: PreviewImages?
    var previewBusy = false
    private var cancelRequested = false
    private var previewToken = 0

    var summary: String {
        let counts = "\(writtenCount) written, \(failedCount) failed, \(skippedCount) skipped"
        if running { return "Working. \(counts)" }
        if stopped { return "Stopped. \(counts)" }
        if writtenCount + failedCount + skippedCount == 0 { return "\(files.count) files" }
        return counts
    }

    func add(_ urls: [URL]) {
        var known = Set(files.map { $0.source.standardizedFileURL.path })
        for url in ConversionQueue.files(from: urls) {
            let path = url.standardizedFileURL.path
            guard known.contains(path) == false else { continue }
            known.insert(path)
            let size = ConversionQueue.pixelSize(of: url)
            files.append(QueueFile(
                source: url,
                pixelWidth: size?.width,
                pixelHeight: size?.height
            ))
            log("added \(url.lastPathComponent)")
        }
        if selection == nil {
            selection = files.first?.id
            loadPreview()
        }
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func resetSettings() {
        settings = ConversionSettings()
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputDirectory = url
    }

    func convert() {
        guard running == false, files.isEmpty == false else { return }
        running = true
        stopped = false
        cancelRequested = false
        writtenCount = 0
        failedCount = 0
        skippedCount = 0
        let settings = settings
        if let directory = settings.outputDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sources = files.map { ($0.id, $0.source) }
        Task {
            for (id, source) in sources {
                if cancelRequested {
                    stopped = true
                    break
                }
                mark(id, .working)
                let status = await Task.detached {
                    ConversionQueue.convert(source, settings: settings)
                }.value
                mark(id, status)
                log("\(status.label) \(source.lastPathComponent)")
                switch status {
                case .written:
                    writtenCount += 1
                case .failed:
                    failedCount += 1
                case .skipped:
                    skippedCount += 1
                case .queued, .working:
                    break
                }
            }
            running = false
        }
    }

    func cancel() {
        guard running else { return }
        cancelRequested = true
    }

    func clear() {
        guard running == false else { return }
        files = []
        selection = nil
        preview = nil
        previewBusy = false
        previewToken += 1
        stopped = false
        writtenCount = 0
        failedCount = 0
        skippedCount = 0
    }

    func loadPreview() {
        previewToken += 1
        let token = previewToken
        preview = nil
        guard let id = selection, let source = files.first(where: { $0.id == id })?.source else {
            previewBusy = false
            return
        }
        previewBusy = true
        let settings = settings
        Task {
            let images = await Task.detached {
                ConversionQueue.preview(of: source, settings: settings)
            }.value
            guard token == previewToken else { return }
            preview = images
            previewBusy = false
            if let images, let index = files.firstIndex(where: { $0.id == id }) {
                files[index].headroom = images.headroom
            }
        }
    }

    private func log(_ line: String) {
        fputs(line + "\n", stdout)
        fflush(stdout)
    }

    private func mark(_ id: UUID, _ status: FileStatus) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].status = status
    }
}
