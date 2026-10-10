import SwiftUI

/// The camera style suggestion plus every darktable style, grouped as darktable groups them.
struct LookCard: View {
    @Environment(EditorModel.self) private var model
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Look", isExpanded: $isExpanded)
            if isExpanded {
                if let style = model.suggestedStyle {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Camera style")
                            Text(style.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.appliedStyles.contains(style.name) {
                            Label("Applied", systemImage: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Button("Apply") { Task { await model.applyStyle(style) } }
                        }
                    }
                }
                if !model.appliedStyles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Applied styles").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(model.appliedStyles.enumerated()), id: \.offset) { i, name in
                            HStack {
                                Image(systemName: "checkmark").foregroundStyle(.secondary).imageScale(.small)
                                Text(StyleInfo(name: name).title)
                                Spacer()
                                if i == model.appliedStyles.count - 1 {
                                    Button("Undo") { Task { await model.undoLastStyle() } }
                                        .controlSize(.small)
                                        .disabled(model.editsSinceStyle > 0)
                                        .help(model.editsSinceStyle > 0
                                              ? "You've edited since applying this style; undoing it would remove those edits too"
                                              : "Remove this style")
                                }
                            }
                        }
                        if model.appliedStyles.count > 1 {
                            Text("Where styles set the same modules, the later one wins.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Menu("Add a style") {
                    ForEach(groups, id: \.title) { group in
                        Menu(group.title) {
                            ForEach(group.styles) { style in
                                Button(style.isCameraStyle ? style.title : (style.path.last ?? style.name)) {
                                    Task { await model.applyStyle(style) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private struct Group { let title: String; let styles: [StyleInfo] }

    /// camera styles by maker, everything else by darktable's own grouping
    private var groups: [Group] {
        var order: [String] = []
        var byGroup: [String: [StyleInfo]] = [:]
        for s in model.styles {
            let key: String
            if s.isCameraStyle { key = "Camera · \(s.cameraMaker!)" }
            else if s.isGlobalGeneric { key = "Camera · Generic" }
            else { key = s.group.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " · ") }
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(s)
        }
        return order.sorted().map { Group(title: $0.isEmpty ? "Other" : $0, styles: byGroup[$0]!) }
    }
}
