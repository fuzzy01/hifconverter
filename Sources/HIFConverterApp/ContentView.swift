import AppKit
import SwiftUI
@testable import Hifconverter

struct ContentView: View {
    var model: ConverterModel

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 880 {
                HStack(spacing: 0) {
                    queue.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    side.frame(width: min(420, geo.size.width * 0.42))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: 0) {
                    queue.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    side.frame(maxWidth: .infinity)
                        .frame(height: max(280, geo.size.height * 0.48))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onOpenURL { model.add([$0]) }
        .onChange(of: model.selection) { _, _ in model.loadPreview() }
        .onChange(of: model.settings.lift) { _, _ in model.loadPreview() }
        .onChange(of: model.settings.peakNits) { _, _ in model.loadPreview() }
        .onChange(of: model.settings.shoulder) { _, _ in model.loadPreview() }
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Open…") { model.chooseSources() }
                Button("Clear") { model.clear() }
                    .disabled(model.running || model.files.isEmpty)
                Button("Convert") { model.convert() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.running || model.files.isEmpty)
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.running == false)
                Spacer()
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                if model.files.isEmpty {
                    Text("Drop HIF files or a folder")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(model.files) { file in
                    row(file).tag(file.id)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { model.dropTargeted },
                set: { model.dropTargeted = $0 }
            )) { providers in
                model.takeDrop(providers)
                return true
            }
            .overlay {
                if model.dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func row(_ file: QueueFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.source.lastPathComponent)
                .lineLimit(1)
            Text(detail(file))
                .font(.caption)
                .foregroundStyle(color(for: file.status))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func detail(_ file: QueueFile) -> String {
        var parts: [String] = []
        if let width = file.pixelWidth, let height = file.pixelHeight {
            parts.append("\(width)×\(height)")
        }
        if let headroom = file.headroom {
            parts.append(String(format: "peak %.2f", headroom))
        }
        parts.append(file.status.label)
        return parts.joined(separator: "  ")
    }

    private func color(for status: FileStatus) -> Color {
        switch status {
        case .failed:
            return .red
        case .written:
            return .primary
        case .working:
            return .accentColor
        case .queued, .skipped:
            return .secondary
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            settings
            Button("Set defaults") { model.resetSettings() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.headline)
            if model.previewBusy {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else if let preview = model.preview {
                HStack(alignment: .top, spacing: 8) {
                    previewColumn("SDR") {
                        Image(decorative: preview.sdr, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    if let hdr = preview.hdr {
                        previewColumn("HDR") {
                            HDRPreview(image: hdr)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                Text(model.selection == nil ? "Select a file" : "No preview")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    private func previewColumn<V: View>(_ title: String, @ViewBuilder image: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            image()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settings: some View {
        Form {
            TextField("Lift, stops", value: setting(\.lift), format: .number)
            TextField("Peak, cd/m²", value: setting(\.peakNits), format: .number.precision(.fractionLength(0)))
            Picker("Shoulder", selection: setting(\.shoulder)) {
                Text("Standard").tag(Shoulder.standard)
                Text("Match frame").tag(Shoulder.matchFrame)
            }
            LabeledContent("Quality") {
                Slider(value: setting(\.quality), in: 0.1...1)
            }
            Picker("If the HEIC exists", selection: setting(\.collision)) {
                Text("Fail").tag(Collision.fail)
                Text("Add HDR suffix").tag(Collision.suffix)
                Text("Overwrite").tag(Collision.overwriteHEIC)
                Text("Skip").tag(Collision.skip)
            }
            LabeledContent("Output") {
                VStack(alignment: .leading) {
                    Text(model.settings.outputDirectory?.path ?? "Next to each HIF")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Choose…") { model.chooseOutput() }
                        Button("Same folder") { model.settings.outputDirectory = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<ConversionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings[keyPath: keyPath] = newValue
                model.settings = settings
            }
        )
    }
}

private final class FlexibleImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct HDRPreview: NSViewRepresentable {
    var image: CGImage

    func makeNSView(context: Context) -> FlexibleImageView {
        let view = FlexibleImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.wantsLayer = true
        view.preferredImageDynamicRange = .high
        return view
    }

    func updateNSView(_ view: FlexibleImageView, context: Context) {
        let longSide = max(image.width, image.height)
        let scale = longSide > 0 ? 160.0 / Double(longSide) : 1
        let size = NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        view.image = NSImage(cgImage: image, size: size)
        view.preferredImageDynamicRange = .high
    }
}

extension ConverterModel {
    func takeDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                guard let url = object else { return }
                Task { @MainActor in
                    self.add([url])
                }
            }
        }
    }
}
