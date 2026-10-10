import SwiftUI

/// Info for several selected photos, as Photos shows it: how many, when they
/// were taken, on what, and how much space they take; a rating and keywords
/// set here go to all of them.
struct MultiInfo: View {
    @Environment(EditorModel.self) private var model
    let photos: [URL]
    @State private var facts: [PhotoMetadata.Facts] = []
    @State private var keywordDraft = ""
    @State private var rating = 0

    /// read in full up to here; past it the count still shows
    private static let readLimit = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(photos.count) Photos").font(.headline)
                        Spacer()
                        stars
                    }
                    if let range = dateRange { Text(range).foregroundStyle(.secondary) }
                }
                .padding(12)
                Divider()
                if facts.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                } else {
                    row("camera", summary(facts.compactMap(\.camera), none: "Unknown camera"))
                    row("camera.aperture", summary(facts.compactMap(\.lens), none: "Unknown lens"))
                    if let size = totalSize { row("internaldrive", size) }
                    Divider()
                    keywords
                    if photos.count > facts.count {
                        Text("Details from the first \(facts.count) photos.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
        }
        .task(id: photos) { await load() }
    }

    private func load() async {
        let list = Array(photos.prefix(Self.readLimit))
        let read = await Task.detached(priority: .userInitiated) { list.map { PhotoMetadata.read($0).facts } }.value
        guard !Task.isCancelled else { return }
        facts = read
        let ratings = Set(read.map { max($0.rating ?? 0, 0) })
        rating = ratings.count == 1 ? ratings.first! : 0
    }

    // MARK: pieces

    private var dateRange: String? {
        let dates = facts.compactMap(\.taken).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = Calendar.current.isDate(first, inSameDayAs: last) ? .short : .none
        if Calendar.current.isDate(first, inSameDayAs: last) {
            let t = DateFormatter(); t.timeStyle = .short
            return "\(f.string(from: first)) – \(t.string(from: last))"
        }
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    private var totalSize: String? {
        let sizes = facts.compactMap(\.fileSize)
        guard !sizes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }

    /// the one value, or the most common and how many others
    private func summary(_ values: [String], none: String) -> String {
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        guard let top = counts.max(by: { $0.value < $1.value }) else { return none }
        return counts.count == 1 ? top.key : "\(top.key) and \(counts.count - 1) more"
    }

    /// click a star to rate all of them; the same star again clears it
    private var stars: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    let new = rating == i ? 0 : i
                    rating = new
                    Task { for p in photos { await model.setInfo(p, rating: new) } }
                } label: {
                    Image(systemName: i <= rating ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .help(rating == i ? "Clear the rating of all \(photos.count)" : "Rate all \(photos.count) \(i) \(i == 1 ? "star" : "stars")")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// keywords every selected photo has; one typed here goes to all of them
    private var keywords: some View {
        let common = facts.dropFirst().reduce(Set(facts.first?.tags ?? [])) { $0.intersection($1.tags) }.sorted()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tag").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                if !common.isEmpty { Text(common.joined(separator: ", ")) }
                TextField("Add a Keyword to All", text: $keywordDraft)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let k = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        keywordDraft = ""
                        guard !k.isEmpty else { return }
                        Task {
                            for p in photos { await model.setInfo(p, addKeyword: k) }
                            await load()
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
