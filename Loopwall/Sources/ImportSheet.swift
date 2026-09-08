import SwiftUI

/// Shown once per dropped file. One dropdown, one estimate, one button.
struct ImportSheet: View {
    let pending: PendingImport
    @EnvironmentObject private var state: AppState
    @State private var quality: Quality = .fhd

    /// Presets that produce a distinct output size for *this* file. A 1280×800
    /// source can't be upscaled, so "4K", "1440p" and "1080p" would all be the
    /// same encode — only the first is worth showing.
    private var choices: [Quality] {
        var seen = Set<String>()
        return Quality.allCases.filter { option in
            // A GIF always gets re-encoded; there is no "keep the original" for it.
            if option == .original { return !pending.isGIF }
            let size = outputSize(for: option)
            return seen.insert("\(size.width)x\(size.height)").inserted
        }
    }

    private func outputSize(for option: Quality) -> (width: Int, height: Int) {
        Transcoder.targetSize(width: pending.info.width,
                              height: pending.info.height,
                              maxDimension: option.maxDimension)
    }

    private func label(for option: Quality) -> String {
        guard option != .original else { return option.label }
        let size = outputSize(for: option)
        let isNative = size.width == pending.info.width && size.height == pending.info.height
        let prefix = isNative ? "Native size" : option.shortLabel
        return "\(prefix) · \(size.width)×\(size.height)"
    }

    private var estimate: Int64 {
        guard quality != .original else { return pending.info.byteSize }
        return quality.estimatedBytes(sourceWidth: pending.info.width,
                                      sourceHeight: pending.info.height,
                                      fps: pending.info.fps,
                                      duration: pending.info.duration,
                                      capFrameRate: state.preferences.capFrameRateAt30)
    }

    private var currentOutputSize: (width: Int, height: Int) { outputSize(for: quality) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sourceSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Picker("Compress to", selection: $quality) {
                ForEach(choices) { option in
                    Text(label(for: option)).tag(option)
                }
            }
            .pickerStyle(.menu)

            Toggle("Cap at 30 fps", isOn: $state.preferences.capFrameRateAt30)
                .disabled(quality == .original)

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Result")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(currentOutputSize.width)×\(currentOutputSize.height) · HEVC")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(quality == .original ? "Size" : "Estimated size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                }
                .padding(4)
            }

            if pending.isGIF {
                Label("GIFs are converted to HEVC video — usually a fraction of the size, and far cheaper to play.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { state.cancelPending(pending) }
                    .keyboardShortcut(.cancelAction)
                Button("Add Wallpaper") { state.startImport(pending, quality: quality) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            let preferred = state.preferences.lastImportQuality
            quality = choices.contains(preferred) ? preferred : (choices.first ?? .fhd)
        }
    }

    private var sourceSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: pending.info.byteSize, countStyle: .file)
        let seconds = String(format: "%.1fs", pending.info.duration)
        let fps = String(format: "%.0f fps", pending.info.fps)
        return "\(pending.info.width)×\(pending.info.height) · \(seconds) · \(fps) · \(size)"
    }
}
