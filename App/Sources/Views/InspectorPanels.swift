import AppKit
import SwiftUI

/// The inspector's fixed panels, as descriptors: each has an id (what a
/// workspace hides it by), a title and icon for the Workspace menu, where it
/// sits (pinned above the scrolling cards, or first among them), when it
/// applies, and its view. The module cards come after them.
@MainActor
struct InspectorPanel: Identifiable {
    enum Placement { case pinned, cards }

    let id: String
    let title: String
    let icon: String
    let placement: Placement
    let applies: (EditorModel) -> Bool
    let content: () -> AnyView

    static let all: [InspectorPanel] = [
        InspectorPanel(id: "histogram", title: "Histogram", icon: "chart.bar.xaxis", placement: .pinned,
                       applies: { $0.url != nil }, content: { AnyView(PinnedHistogram()) }),
        // the decoder's own settings first: they come before everything darktable does
        InspectorPanel(id: "appleRaw", title: "Apple RAW", icon: "camera.aperture", placement: .cards,
                       applies: { !$0.appleRawControls.isEmpty }, content: { AnyView(AppleRawCard()) }),
        // the SDR card before the HDR one, so switching views with its Show button
        // doesn't move it when the HDR card comes and goes
        InspectorPanel(id: "sdrVersion", title: "SDR Version", icon: "sun.min", placement: .cards,
                       applies: { $0.exportTarget.isHDR }, content: { AnyView(SDRVersionCard()) }),
        InspectorPanel(id: "hdrDetails", title: "HDR Details", icon: "sun.max", placement: .cards,
                       applies: { $0.viewHDR }, content: { AnyView(HDRDetailsCard()) }),
        InspectorPanel(id: "look", title: "Look", icon: "camera.filters", placement: .cards,
                       applies: { _ in true }, content: { AnyView(LookCard()) }),
        InspectorPanel(id: "local", title: "Local Adjustments", icon: "circle.lefthalf.filled", placement: .cards,
                       applies: { $0.url != nil }, content: { AnyView(LocalAdjustmentsCard()) }),
        InspectorPanel(id: "composite", title: "Composite", icon: "square.on.square", placement: .cards,
                       applies: { $0.url != nil }, content: { AnyView(CompositeCard()) }),
    ]

    /// the panels to show here now: placed here, applying, and not hidden by the workspace
    static func shown(_ placement: Placement, in model: EditorModel) -> [InspectorPanel] {
        all.filter { $0.placement == placement && $0.applies(model) && !model.hiddenPanels.contains($0.id) }
    }
}

/// Window › Workspace, and the same menu beside the module search: switch
/// workspaces (⌃⌘1 to ⌃⌘9), show or hide the fixed panels, and save, rename
/// or delete workspaces.
struct WorkspaceMenuContent: View {
    let model: EditorModel

    var body: some View {
        ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { i, w in
            Toggle(w.name, isOn: Binding(get: { model.workspaceID == w.id },
                                         set: { if $0 { model.switchWorkspace(to: w.id) } }))
                .keyboardShortcut(Self.shortcut(i))
        }
        Divider()
        Menu("Panels") {
            ForEach(InspectorPanel.all) { p in
                Toggle(isOn: Binding(get: { !model.hiddenPanels.contains(p.id) },
                                     set: { model.setPanel(p.id, shown: $0) })) {
                    Label(p.title, systemImage: p.icon)
                }
            }
        }
        Divider()
        Button("New Workspace…") {
            if let name = WorkspaceNamePrompt.ask(title: "New Workspace",
                                                  message: "Saves the inspector as it is now: the Essentials modules and their order, the open cards and the panels shown.",
                                                  initial: "") {
                model.saveWorkspace(as: name)
            }
        }
        Button("Rename Workspace…") {
            guard let w = model.currentWorkspace,
                  let name = WorkspaceNamePrompt.ask(title: "Rename Workspace", message: nil, initial: w.name) else { return }
            model.renameWorkspace(w.id, to: name)
        }
        Button("Delete Workspace") {
            if let w = model.currentWorkspace { model.deleteWorkspace(w.id) }
        }
        .disabled(model.workspaces.count < 2)
    }
}

extension WorkspaceMenuContent {
    /// ⌃⌘1 to ⌃⌘9 for the first nine
    static func shortcut(_ index: Int) -> KeyboardShortcut? {
        guard index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command])
    }
}

/// Asks for a workspace's name in a sheet-style alert; nil if cancelled or empty.
enum WorkspaceNamePrompt {
    @MainActor
    static func ask(title: String, message: String?, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
