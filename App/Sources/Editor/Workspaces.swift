import Foundation

/// A named inspector set: the modules the Essentials tab lists and their
/// order, the cards that are open, and which of the fixed panels (histogram,
/// Look and so on, `InspectorPanel`) are hidden. The current workspace keeps
/// changes as they're made; Window › Workspace switches between them.
struct Workspace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var essentials: [String]
    /// module keys ("op:instance"), so a card stays open from photo to photo
    var expanded: [String]
    var hiddenPanels: [String] = []
}

@MainActor
enum Workspaces {
    private static let listKey = "Workspaces"
    private static let currentKey = "CurrentWorkspace"

    static let defaultExpanded = ["exposure:0", "channelmixerrgb:0", "toneequal:0", "colorbalancergb:0", "filmicrgb:0", "sigmoid:0"]

    /// Test runs (launched with -Test… or -Start… arguments) change the
    /// inspector as they go; they mustn't change the saved workspaces.
    static let persists = !ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Test") || $0.hasPrefix("-Start") }

    /// The saved list; the first time, one "Default" workspace from the
    /// Essentials list kept before workspaces existed.
    static func load() -> [Workspace] {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([Workspace].self, from: data), !list.isEmpty {
            return list
        }
        return [Workspace(name: "Default", essentials: EditorModel.loadEssentials(), expanded: defaultExpanded)]
    }

    static func store(_ list: [Workspace]) {
        guard persists, let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    static func currentID(in list: [Workspace]) -> UUID {
        let saved = UserDefaults.standard.string(forKey: currentKey).flatMap(UUID.init(uuidString:))
        return list.first { $0.id == saved }?.id ?? list[0].id
    }

    static func storeCurrent(_ id: UUID) {
        guard persists else { return }
        UserDefaults.standard.set(id.uuidString, forKey: currentKey)
    }
}

extension EditorModel {
    var currentWorkspace: Workspace? { workspaces.first { $0.id == workspaceID } }

    /// Brings in a workspace's Essentials, open cards and panels.
    func switchWorkspace(to id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        applyingWorkspace = true
        defer { applyingWorkspace = false }
        workspaceID = id
        essentials = w.essentials
        expanded = Set(w.expanded)
        hiddenPanels = Set(w.hiddenPanels)
    }

    /// A copy of the inspector as it is now, under a new name, which becomes current.
    func saveWorkspace(as name: String) {
        let w = Workspace(name: name, essentials: essentials, expanded: expanded.sorted(), hiddenPanels: hiddenPanels.sorted())
        workspaces.append(w)
        workspaceID = w.id
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = name
    }

    /// The last one can't go; deleting the current one switches to the first left.
    func deleteWorkspace(_ id: UUID) {
        guard workspaces.count > 1 else { return }
        workspaces.removeAll { $0.id == id }
        if workspaceID == id { switchWorkspace(to: workspaces[0].id) }
    }

    func setPanel(_ id: String, shown: Bool) {
        if shown { hiddenPanels.remove(id) } else { hiddenPanels.insert(id) }
    }

    /// the inspector's state goes into the current workspace as it changes
    func recordWorkspace() {
        guard !applyingWorkspace, let i = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let updated = Workspace(id: workspaceID, name: workspaces[i].name, essentials: essentials,
                                expanded: expanded.sorted(), hiddenPanels: hiddenPanels.sorted())
        if workspaces[i] != updated { workspaces[i] = updated }
    }
}
