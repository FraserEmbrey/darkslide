import SwiftUI

/// Makes or changes a smart album, laid out as Photos' smart album sheet:
/// a name, whether all or any rules must match, then a row per rule.
struct SmartAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var album: SmartAlbum
    let onSave: (SmartAlbum) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Smart Album Name", text: $album.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            HStack(spacing: 6) {
                Text("Match")
                Picker("Match", selection: $album.matchAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following conditions:")
            }
            VStack(spacing: 8) {
                ForEach($album.rules) { $rule in
                    RuleRow(rule: $rule,
                            canRemove: album.rules.count > 1,
                            add: { album.rules.insert(SmartRule(), at: (album.rules.firstIndex { $0.id == rule.id } ?? 0) + 1) },
                            remove: { album.rules.removeAll { $0.id == rule.id } })
                }
            }
            Text("Looks through the photos in the library's folders, up to \(Library.scanLimit.formatted()), each time it's shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    if album.name.trimmingCharacters(in: .whitespaces).isEmpty { album.name = "Smart Album" }
                    onSave(album)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

extension SmartAlbumSheet {
    /// for the TestSmartAlbums launch argument: the sheet in a window of its own
    static func showForTesting(_ album: SmartAlbum) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SmartAlbumSheet(album: album) { _ in }))
        w.title = "Smart album test"
        w.makeKeyAndOrderFront(nil)
    }
}

private struct RuleRow: View {
    @Binding var rule: SmartRule
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: Binding(get: { rule.field }, set: { rule.setField($0) })) {
                ForEach(SmartRule.Field.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            Picker("Condition", selection: $rule.op) {
                ForEach(SmartRule.Op.ops(for: rule.field.kind)) { Text($0.title(for: rule.field)).tag($0) }
            }
            .labelsHidden()
            .frame(width: rule.field.kind == .flag ? 160 : 130)
            value
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove this condition")
            Button(action: add) { Image(systemName: "plus") }
                .help("Add a condition")
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var value: some View {
        switch rule.field.kind {
        case .rating where rule.op != .rejected:
            Picker("Stars", selection: Binding(get: { Int(rule.number) }, set: { rule.number = Double($0) })) {
                ForEach(rule.op == .exactly ? Array(0...5) : Array(1...5), id: \.self) { n in
                    Text(n == 0 ? "unrated" : String(repeating: "★", count: n)).tag(n)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        case .text:
            TextField(placeholder, text: $rule.text)
                .textFieldStyle(.roundedBorder)
        case .date where rule.op == .lastDays:
            TextField("Days", value: $rule.number, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Text("days")
        case .date:
            DatePicker("Date", selection: $rule.date, displayedComponents: .date)
                .labelsHidden()
        default:
            EmptyView()
        }
    }

    private var placeholder: String {
        switch rule.field {
        case .camera: "Z6 III"
        case .lens: "50mm"
        case .keyword: "wedding"
        case .folder: "Brighton"
        default: "text"
        }
    }
}
