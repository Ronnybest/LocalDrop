import AppKit
import Foundation

/// The folder received files are saved to. Downloads by default; another folder the user picks
/// is kept as a security-scoped bookmark (the app is sandboxed), so access survives restarts.
@Observable
final class SaveFolder {
    /// nil: Downloads.
    private(set) var chosen: URL?
    /// The chosen folder can't be reached right now (drive unplugged, folder deleted).
    private(set) var isUnavailable = false

    private static let bookmarkKey = "localdrop.saveFolderBookmark"

    var displayName: String {
        FileManager.default.displayName(atPath: (chosen ?? ReceiveLocation.downloads).path)
    }

    var current: URL { chosen ?? ReceiveLocation.downloads }

    /// Restores the chosen folder. An unresolvable bookmark falls back to Downloads.
    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                Log.app.error("No access to the chosen save folder; using Downloads")
                return
            }
            if stale {
                // Moved or renamed: the bookmark still found it; store a fresh one.
                UserDefaults.standard.set(try url.bookmarkData(options: [.withSecurityScope]), forKey: Self.bookmarkKey)
            }
            use(url)
            Log.app.info("Saving received files to the chosen folder")
        } catch {
            Log.app.error("Save folder bookmark unusable (\(error.localizedDescription, privacy: .public)); using Downloads")
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
    }

    /// Asks for a folder. The menu bar app has no window, so the panel is brought forward itself.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Files received with Local Drop will be saved in this folder.")
        panel.directoryURL = current
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.set(url) }
        }
    }

    func useDownloads() {
        stopAccess()
        chosen = nil
        isUnavailable = false
        ReceiveLocation.setChosenDirectory(nil)
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        Log.app.info("Saving received files to Downloads")
    }

    /// Re-checks reachability, e.g. when the menu opens.
    func refresh() {
        guard let chosen else { return }
        isUnavailable = !ReceiveLocation.isReachable(chosen)
    }

    private func set(_ picked: URL) {
        let url = picked.resolvingSymlinksInPath()
        if url == ReceiveLocation.downloads {
            useDownloads()
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope])
            stopAccess()
            guard url.startAccessingSecurityScopedResource() else {
                Log.app.error("No access to the picked folder")
                return
            }
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            use(url)
            Log.app.info("Saving received files to a chosen folder")
        } catch {
            Log.app.error("Could not remember the picked folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func use(_ url: URL) {
        chosen = url
        isUnavailable = !ReceiveLocation.isReachable(url)
        ReceiveLocation.setChosenDirectory(url)
        // Partial files left there by a crash.
        Task.detached { IncomingFileWriter.removeLeftovers(in: url) }
    }

    private func stopAccess() {
        chosen?.stopAccessingSecurityScopedResource()
    }
}
