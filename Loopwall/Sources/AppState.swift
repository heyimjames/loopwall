import Foundation
import AppKit
import AVFoundation
import ServiceManagement
import Combine
import UniformTypeIdentifiers

/// A file the user dropped or picked, waiting for the user to choose a quality.
struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
    let info: MediaInfo
    var isGIF: Bool { Transcoder.isGIF(url) }
}

struct ImportProgress {
    var fileName: String
    var fraction: Double
    var stage: String
}

@MainActor
final class AppState: ObservableObject {

    static let supportedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .gif, .movie, .video]

    @Published var preferences: Preferences {
        didSet {
            preferences.save()
            engine.apply(preferences: preferences)
        }
    }

    @Published var library = LibraryStore()
    @Published var pendingImports: [PendingImport] = []
    @Published var importProgress: ImportProgress?
    @Published var errorMessage: String?
    @Published var firstWallpaperMoment: FirstWallpaperMoment?

    /// Captured once at launch, before `applicationDidFinishLaunching` marks
    /// first-run complete — so the welcome copy can tell "never used before"
    /// from "library is just empty right now."
    let isFirstLaunch: Bool

    let policy = PowerPolicy()
    let engine: WallpaperEngine

    private var importTask: Task<Void, Never>?
    private var observers: [AnyCancellable] = []

    init() {
        let loaded = Preferences.load()
        self.isFirstLaunch = !loaded.hasCompletedFirstRun
        self.preferences = loaded
        self.engine = WallpaperEngine(policy: policy)

        engine.itemProvider = { [weak self] displayKey in
            guard let self else { return nil }
            return self.library.item(withID: self.preferences.assignments[displayKey])
        }
        // Views observe AppState only, so forward the nested objects' changes.
        library.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
        library.pruneOrphans()
        seedBundledWallpapersIfNeeded()
        engine.apply(preferences: preferences)
    }

    // MARK: - Bundled wallpapers

    /// On a genuinely fresh install, copies the wallpapers shipped inside
    /// the app into the user's library and applies the first one — so
    /// opening Loopwall for the first time shows something playing rather
    /// than an empty library waiting for the user to already have a file
    /// ready. Silent: no first-wallpaper celebration, since the user didn't
    /// do anything — that's reserved for their own first import.
    private func seedBundledWallpapersIfNeeded() {
        guard isFirstLaunch, library.items.isEmpty else { return }
        var primary: WallpaperItem?
        // Reversed: LibraryStore.add inserts at index 0, so adding in
        // reverse leaves BundledWallpapers.all's declared order on top.
        for bundled in BundledWallpapers.all.reversed() {
            if let item = importBundledWallpaper(bundled) {
                primary = item
            }
        }
        if let primary {
            assignToAllDisplays(primary)
        }
    }

    private func importBundledWallpaper(_ bundled: BundledWallpaper) -> WallpaperItem? {
        guard let resources = BundledWallpapers.resourceURLs(for: bundled) else { return nil }
        let destination = LibraryStore.mediaDirectory.appendingPathComponent(bundled.fileName)
        guard (try? FileManager.default.copyItem(at: resources.video, to: destination)) != nil else { return nil }
        try? FileManager.default.copyItem(
            at: resources.thumbnail,
            to: LibraryStore.mediaDirectory.appendingPathComponent(bundled.thumbnailName)
        )
        let item = WallpaperItem(
            id: bundled.id,
            name: bundled.name,
            fileName: bundled.fileName,
            thumbnailName: bundled.thumbnailName,
            width: bundled.width,
            height: bundled.height,
            duration: bundled.duration,
            byteSize: bundled.byteSize,
            originalByteSize: bundled.byteSize,
            addedAt: Date()
        )
        library.add(item)
        return item
    }

    // MARK: - Assignment

    func item(for display: DisplayInfo) -> WallpaperItem? {
        library.item(withID: preferences.assignments[display.id])
    }

    func assign(_ item: WallpaperItem?, to displayID: String) {
        if let item {
            preferences.assignments[displayID] = item.id
        } else {
            preferences.assignments.removeValue(forKey: displayID)
        }
    }

    func assignToAllDisplays(_ item: WallpaperItem?) {
        for display in engine.displays {
            if let item {
                preferences.assignments[display.id] = item.id
            } else {
                preferences.assignments.removeValue(forKey: display.id)
            }
        }
    }

    var currentItemName: String? {
        let assigned = engine.displays.compactMap { library.item(withID: preferences.assignments[$0.id]) }
        guard let first = assigned.first else { return nil }
        let allSame = assigned.allSatisfy { $0.id == first.id }
        return allSame ? first.name : "\(assigned.count) wallpapers"
    }

    func delete(_ item: WallpaperItem) {
        for (displayID, assignedID) in preferences.assignments where assignedID == item.id {
            preferences.assignments.removeValue(forKey: displayID)
        }
        library.delete(item)
    }

    // MARK: - Playback

    func togglePause() {
        preferences.manuallyPaused.toggle()
        engine.updatePlayback()
    }

    var pauseReason: String? { policy.pauseReason(preferences: preferences) }

    // MARK: - Import

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedTypes
        panel.prompt = "Add"
        panel.message = "Choose a video or GIF to use as a wallpaper"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        enqueue(urls: panel.urls)
    }

    func enqueue(urls: [URL]) {
        Task {
            for url in urls {
                do {
                    let info = try await Transcoder.probe(url)
                    pendingImports.append(PendingImport(url: url, info: info))
                } catch {
                    errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelPending(_ pending: PendingImport) {
        pendingImports.removeAll { $0.id == pending.id }
    }

    func startImport(_ pending: PendingImport, quality: Quality) {
        pendingImports.removeAll { $0.id == pending.id }
        preferences.lastImportQuality = quality

        importTask = Task {
            let id = UUID()
            let destination = LibraryStore.mediaDirectory.appendingPathComponent("\(id.uuidString).mp4")
            let name = pending.url.deletingPathExtension().lastPathComponent
            let stage = pending.isGIF ? "Converting GIF" : (quality == .original ? "Copying" : "Compressing")
            importProgress = ImportProgress(fileName: name, fraction: 0, stage: stage)

            do {
                let result = try await Transcoder.makeWallpaperFile(
                    from: pending.url,
                    to: destination,
                    quality: quality,
                    capFrameRate: preferences.capFrameRateAt30
                ) { fraction in
                    Task { @MainActor in
                        self.importProgress?.fraction = fraction
                    }
                }

                importProgress?.stage = "Finishing"
                let thumbnailName = try await makeThumbnail(for: result.url, id: id)

                let item = WallpaperItem(
                    id: id,
                    name: name,
                    fileName: destination.lastPathComponent,
                    thumbnailName: thumbnailName,
                    width: result.width,
                    height: result.height,
                    duration: result.duration,
                    byteSize: result.byteSize,
                    originalByteSize: pending.info.byteSize,
                    addedAt: Date()
                )
                library.add(item)

                // First thing in the library? Put it on every screen immediately —
                // otherwise the user imports a file and nothing visibly happens.
                let isFirstItemEver = library.items.count == 1
                if isFirstItemEver || preferences.assignments.isEmpty {
                    assignToAllDisplays(item)
                }
                importProgress = nil

                // The very first wallpaper going live is worth a moment; every
                // import after that is routine and gets none.
                if isFirstItemEver {
                    firstWallpaperMoment = FirstWallpaperMoment(item: item, displayCount: engine.displays.count)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
                importProgress = nil
            } catch {
                try? FileManager.default.removeItem(at: destination)
                importProgress = nil
                if case TranscodeError.cancelled = error { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importProgress = nil
    }

    private func makeThumbnail(for url: URL, id: UUID) async throws -> String {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: min(max(duration * 0.25, 0), max(duration - 0.1, 0)), preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw TranscodeError.writerFailed("thumbnail")
        }
        let name = "\(id.uuidString)-thumb.png"
        try data.write(to: LibraryStore.mediaDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    // MARK: - Desktop icons

    var desktopIconsHidden: Bool {
        get { DesktopIcons.areHidden }
        set {
            DesktopIcons.setHidden(newValue)
            objectWillChange.send()
        }
    }

    // MARK: - Login item

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                objectWillChange.send()
            } catch {
                errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
            }
        }
    }
}
