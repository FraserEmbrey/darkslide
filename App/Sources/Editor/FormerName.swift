import Foundation

/// The app was called Develop (bundle me.frsr.develop) until October 2026.
/// On the first launch as Darkslide this brings over what Develop kept: its
/// settings, its support folder (the catalog and darktable's database and
/// presets) and its caches. Anything already there under the new name stays.
enum FormerName {
    static let bundleIdentifier = "me.frsr.develop"
    static let folder = "Develop"
    private static let doneKey = "MigratedFromDevelop"

    static func migrate() {
        // settings once; the folders whenever they're still under the old name
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: doneKey) {
            let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            for (key, value) in defaults.persistentDomain(forName: bundleIdentifier) ?? [:] where current[key] == nil {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: doneKey)
        }
        let fm = FileManager.default
        // only folders that are recognisably the app's
        let signs: [FileManager.SearchPathDirectory: [String]] = [
            .applicationSupportDirectory: ["catalog.json", "darktable"],
            .cachesDirectory: ["thumbnails", "decoded", "photos"],
        ]
        for (directory, names) in signs {
            guard let base = fm.urls(for: directory, in: .userDomainMask).first else { continue }
            let old = base.appendingPathComponent(folder, isDirectory: true)
            let new = base.appendingPathComponent("Darkslide", isDirectory: true)
            guard !fm.fileExists(atPath: new.path),
                  names.contains(where: { fm.fileExists(atPath: old.appendingPathComponent($0).path) })
            else { continue }
            do {
                try fm.moveItem(at: old, to: new)
            } catch {
                FileHandle.standardError.write("Darkslide couldn't move \(old.path): \(error)\n".data(using: .utf8)!)
            }
        }
    }
}
