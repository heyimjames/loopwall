import Foundation
import AppKit
import Combine

/// Owns the on-disk wallpaper library: `~/Library/Application Support/Loopwall/Media`
/// plus a small JSON index alongside it.
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Loopwall", isDirectory: true)
    }()

    static let mediaDirectory: URL = supportDirectory.appendingPathComponent("Media", isDirectory: true)

    private static let indexURL = supportDirectory.appendingPathComponent("library.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.mediaDirectory, withIntermediateDirectories: true)
        load()
    }

    func item(withID id: UUID?) -> WallpaperItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func add(_ item: WallpaperItem) {
        items.insert(item, at: 0)
        save()
    }

    func rename(_ item: WallpaperItem, to newName: String) {
        guard let index = items.firstIndex(of: item) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[index].name = trimmed
        save()
    }

    func delete(_ item: WallpaperItem) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: item.thumbnailURL)
        save()
    }

    /// Removes media files that no longer have an index entry — e.g. if an import
    /// was interrupted midway through.
    func pruneOrphans() {
        let known = Set(items.flatMap { [$0.fileName, $0.thumbnailName] })
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: Self.mediaDirectory.path)) ?? []
        for file in contents where !known.contains(file) {
            try? FileManager.default.removeItem(at: Self.mediaDirectory.appendingPathComponent(file))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([WallpaperItem].self, from: data)
        else { return }
        // Drop entries whose file vanished (user cleaned Application Support by hand).
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != decoded.count { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}
