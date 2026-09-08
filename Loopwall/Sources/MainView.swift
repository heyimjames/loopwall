import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum AssignTarget: Hashable {
    case all
    case display(String)
}

@MainActor
enum ThumbnailCache {
    private static var cache: [String: NSImage] = [:]

    static func image(for item: WallpaperItem) -> NSImage? {
        if let cached = cache[item.thumbnailName] { return cached }
        guard let image = NSImage(contentsOf: item.thumbnailURL) else { return nil }
        cache[item.thumbnailName] = image
        return image
    }
}

struct MainView: View {
    @EnvironmentObject private var state: AppState
    @State private var target: AssignTarget = .all
    @State private var isDropTargeted = false
    @State private var renaming: WallpaperItem?
    @State private var draftName = ""
    @State private var showingAbout = false

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            displayStrip
            Divider()
            libraryArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: firstPending) { pending in
            ImportSheet(pending: pending)
                .environmentObject(state)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { state.errorMessage != nil },
                                    set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .sheet(item: $renaming) { item in
            RenameSheet(item: item, name: $draftName) { newName in
                state.library.rename(item, to: newName)
            }
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
    }

    /// Only offer the next file once the current transcode has finished, so
    /// dropping five files walks through them one at a time.
    private var firstPending: Binding<PendingImport?> {
        Binding(get: { state.importProgress == nil ? state.pendingImports.first : nil },
                set: { _ in })
    }

    // MARK: - Displays

    private var displayStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Displays")
                    .font(.headline)
                Spacer()
                Text(target.isAll ? "Changes apply to every display"
                                  : "Changes apply to the selected display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    TargetChip(title: "All displays",
                               subtitle: "\(state.engine.displays.count) connected",
                               thumbnail: nil,
                               isSelected: target.isAll,
                               isPlaceholder: true) {
                        target = .all
                    }

                    ForEach(state.engine.displays) { display in
                        let item = state.item(for: display)
                        TargetChip(title: display.name,
                                   subtitle: item?.name ?? "No wallpaper",
                                   thumbnail: item.flatMap { ThumbnailCache.image(for: $0) },
                                   isSelected: target == .display(display.id),
                                   isPlaceholder: false) {
                            target = .display(display.id)
                        }
                        .contextMenu {
                            Button("Remove Wallpaper From This Display") {
                                state.assign(nil, to: display.id)
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Library

    private var libraryArea: some View {
        ZStack {
            if state.library.items.isEmpty {
                WelcomeHero(isFirstLaunch: state.isFirstLaunch) {
                    state.presentOpenPanel()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(state.library.items) { item in
                            LibraryTile(item: item, isActive: isActive(item)) {
                                apply(item)
                            }
                            .contextMenu {
                                Button("Set on All Displays") { state.assignToAllDisplays(item) }
                                ForEach(state.engine.displays) { display in
                                    Button("Set on \(display.name)") { state.assign(item, to: display.id) }
                                }
                                Divider()
                                Button("Rename…") {
                                    draftName = item.name
                                    renaming = item
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                Divider()
                                Button("Delete", role: .destructive) { state.delete(item) }
                            }
                        }
                    }
                    .padding(18)
                }
            }

            // A quiet border at rest whenever the library is empty, so the
            // drop target is visible before a user ever starts dragging —
            // not just highlighted mid-drag, when it's too late to discover.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(10)
                    .allowsHitTesting(false)
            } else if state.library.items.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }

            if let progress = state.importProgress {
                ImportProgressOverlay(progress: progress) { state.cancelImport() }
            }

            if let moment = state.firstWallpaperMoment {
                FirstWallpaperCelebration(moment: moment) {
                    state.firstWallpaperMoment = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
                return type.conforms(to: .movie) || type.conforms(to: .gif) || type.conforms(to: .video)
            }
            guard !supported.isEmpty else { return false }
            state.enqueue(urls: supported)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func isActive(_ item: WallpaperItem) -> Bool {
        switch target {
        case .all:
            let displays = state.engine.displays
            return !displays.isEmpty && displays.allSatisfy { state.preferences.assignments[$0.id] == item.id }
        case .display(let id):
            return state.preferences.assignments[id] == item.id
        }
    }

    private func apply(_ item: WallpaperItem) {
        switch target {
        case .all: state.assignToAllDisplays(item)
        case .display(let id): state.assign(item, to: id)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                state.presentOpenPanel()
            } label: {
                Label("Add Video or GIF…", systemImage: "plus")
            }

            Button {
                state.togglePause()
            } label: {
                Label(state.preferences.manuallyPaused ? "Resume" : "Pause",
                      systemImage: state.preferences.manuallyPaused ? "play.fill" : "pause.fill")
            }
            .disabled(state.preferences.assignments.isEmpty)

            Spacer()

            if let reason = state.pauseReason {
                Label(reason, systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            optionsMenu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Fill", selection: $state.preferences.fitMode) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Divider()

            Toggle("Pause when covered by a window", isOn: $state.preferences.pauseWhenCovered)
            Toggle("Pause on battery", isOn: $state.preferences.pauseOnBattery)
            Toggle("Pause in Low Power Mode", isOn: $state.preferences.pauseInLowPowerMode)
            Toggle("Pause when locked or screen saver runs", isOn: $state.preferences.pauseOnScreenSaverAndLock)

            Divider()

            Toggle("Hide desktop icons (restarts Finder)", isOn: Binding(
                get: { state.desktopIconsHidden },
                set: { state.desktopIconsHidden = $0 }
            ))
            Toggle("Cap imports at 30 fps", isOn: $state.preferences.capFrameRateAt30)

            Divider()

            Toggle("Open at login", isOn: Binding(
                get: { state.launchesAtLogin },
                set: { state.launchesAtLogin = $0 }
            ))

            Divider()

            Button("About Loopwall") { showingAbout = true }
            Button("Quit Loopwall") { NSApplication.shared.terminate(nil) }
        } label: {
            Label("Options", systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private extension AssignTarget {
    var isAll: Bool { if case .all = self { return true }; return false }
}

// MARK: - Pieces

struct TargetChip: View {
    let title: String
    let subtitle: String
    let thumbnail: NSImage?
    let isSelected: Bool
    let isPlaceholder: Bool
    let action: () -> Void

    /// "No wallpaper" describes an absence, not a name — give it a lighter
    /// weight than a real filename so the two don't read as equally important.
    private var subtitleIsPlaceholder: Bool { subtitle == "No wallpaper" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: isPlaceholder ? "rectangle.on.rectangle" : "display")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 48, height: 30)
                .clipped()

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleIsPlaceholder ? .tertiary : .secondary)
                        .italic(subtitleIsPlaceholder)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 170, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct LibraryTile: View {
    let item: WallpaperItem
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(Color.black)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay {
                            if let image = ThumbnailCache.image(for: item) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(7)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isActive ? Color.accentColor : Color.black.opacity(0.12),
                                      lineWidth: isActive ? 2 : 1)
                )

                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(item.resolutionLabel)
                    Text("·")
                    Text(item.durationLabel)
                    Text("·")
                    Text(item.sizeLabel)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(item.savingsLabel.map { "\(item.name) — \($0) than the original" } ?? item.name)
    }
}

struct ImportProgressOverlay: View {
    let progress: ImportProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.fraction) {
                Text("\(progress.stage) \(progress.fileName)")
                    .font(.callout)
            } currentValueLabel: {
                Text("\(Int(progress.fraction * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 280)

            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 18, y: 6)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(spacing: 3) {
                Text("Loopwall").font(.title3.weight(.semibold))
                Text(versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Play any video or GIF as your desktop wallpaper.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Link("Made by OCTOBER", destination: URL(string: "https://octoberwip.com")!)
                    .font(.callout.weight(.medium))
                Text("© 2026 OCTOBER Ltd.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 300)
    }
}

struct RenameSheet: View {
    let item: WallpaperItem
    @Binding var name: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Wallpaper").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") {
                    onCommit(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
