import SwiftUI

/// Copy Some Adjustments: the edit's adjustments as a checklist. Those that
/// belong to the photo (white balance, lens correction, orientation) start
/// unticked, as darktable's own copy leaves them out.
struct CopyAdjustmentsSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    private var items: [EngineModule] { model.copyableModules }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy Adjustments").font(.headline)
            Text("Choose what to paste onto other photos. White balance, lens correction and orientation belong to this photo, so they start unticked.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(items) { m in
                    Toggle(isOn: Binding(get: { chosen.contains(m.key) },
                                         set: { if $0 { chosen.insert(m.key) } else { chosen.remove(m.key) } })) {
                        HStack {
                            Text(title(m))
                            if EditorModel.photoSpecificOps.contains(m.op) {
                                Text("this photo").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 260)
            HStack {
                Button("Select All") { chosen = Set(items.map(\.key)) }
                Button("Select None") { chosen = [] }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    // in the order the edit has them
                    model.copyAdjustments(items.map(\.key).filter(chosen.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 460)
        .onAppear {
            chosen = Set(items.filter { !EditorModel.photoSpecificOps.contains($0.op) }.map(\.key))
        }
    }

    private func title(_ m: EngineModule) -> String {
        if EditorModel.isLocal(m) { return "Local adjustment: \(model.localTitle(m))" }
        if EditorModel.isChannelCurve(m) { return "RGB curve: colour curves" }
        return Presentation.title(of: m)
    }
}
