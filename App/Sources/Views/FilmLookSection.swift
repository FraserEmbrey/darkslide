import AppKit
import SwiftUI

/// The Look card's film looks: LUTs from the chosen folder, in menus by its
/// folders and by film (push and pull variants together), with a strength.
struct FilmLookSection: View {
    @Environment(EditorModel.self) private var model

    private var current: FilmLook? { model.filmLooks.first { $0.path == model.currentLook } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Film look")
                    Text(current?.title ?? model.currentLook ?? "None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu("Choose") { menuContent }
                    .fixedSize()
            }
            if model.currentLook != nil {
                ParamSlider(label: "Strength", value: model.lookStrength, defaultValue: 100, range: 0...100,
                            isInteger: true, unit: "%", trackColors: nil, step: 5, ticks: [100]) {
                    model.setLookStrength($0.rounded())
                }
                if model.viewHDR {
                    Label("Film LUTs are made for SDR, so in HDR the look clips everything brighter than white.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if model.lutFolder == nil {
            Button("Choose LUT Folder…", action: chooseFolder)
        } else {
            Button("None") { model.applyLook(nil) }
                .disabled(model.currentLook == nil)
            Divider()
            ForEach(tree, id: \.name) { node in branch(node) }
            Divider()
            Button("Choose LUT Folder…", action: chooseFolder)
        }
    }

    // MARK: menus from the folders

    private final class Node {
        let name: String
        var children: [Node] = []
        var films: [(film: String, looks: [FilmLook])] = []
        init(_ name: String) { self.name = name }
        func child(_ name: String) -> Node {
            if let c = children.first(where: { $0.name == name }) { return c }
            let c = Node(name); children.append(c); return c
        }
    }

    private var tree: [Node] {
        let root = Node("")
        for look in model.filmLooks {
            var node = root
            for g in look.group { node = node.child(g) }
            if let i = node.films.firstIndex(where: { $0.film == look.film }) {
                node.films[i].looks.append(look)
            } else {
                node.films.append((look.film, [look]))
            }
        }
        // looks at the top level sit in a menu of their own
        if !root.films.isEmpty {
            let loose = Node("Other")
            loose.films = root.films
            return root.children + [loose]
        }
        return root.children
    }

    private func branch(_ node: Node) -> AnyView {
        AnyView(Menu(node.name.replacingOccurrences(of: "-", with: " ")) {
            ForEach(node.children, id: \.name) { branch($0) }
            ForEach(node.films, id: \.film) { entry in
                if entry.looks.count == 1, let look = entry.looks.first {
                    item(look, label: entry.film)
                } else {
                    Menu(entry.film) {
                        ForEach(entry.looks) { look in item(look, label: look.variant ?? look.film) }
                    }
                }
            }
        })
    }

    private func item(_ look: FilmLook, label: String) -> some View {
        Button {
            model.applyLook(look)
        } label: {
            if look.path == model.currentLook { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of film looks: Hald CLUT images (.png) or .cube files, in folders if you like."
        panel.directoryURL = model.lutFolder
        if panel.runModal() == .OK, let url = panel.url { model.lutFolder = url }
    }
}
