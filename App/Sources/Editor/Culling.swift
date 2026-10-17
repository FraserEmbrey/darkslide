import CoreGraphics
import Foundation
import Observation

/// Culling a folder: each photo measured (CullAnalysis), bursts found, the
/// frame of each burst to keep suggested, and the big previews loaded ahead
/// of the one being looked at.
@MainActor
@Observable
final class Culling {
    private(set) var facts: [URL: CullFacts] = [:]
    /// the photos in order, split into bursts (a photo on its own is a run of one)
    private(set) var runs: [[URL]] = []
    private var runOf: [URL: Int] = [:]
    /// each burst's suggested frame
    private var suggestion: [Int: URL] = [:]
    /// photos measured of those asked for, while measuring
    private(set) var progress: (done: Int, total: Int)?
    private var job: Task<Void, Never>?
    private var asked: [URL] = []

    /// Measures the photos not yet measured (or changed since), then groups
    /// them. Asking again for the same photos does nothing.
    func analyse(_ photos: [URL]) {
        let files = photos.filter { PhotosLibrary.assetID($0) == nil }
        guard files != asked else { return }
        asked = files
        job?.cancel()
        let byFolder = Dictionary(grouping: files) { $0.deletingLastPathComponent() }
        job = Task {
            var todo: [(URL, URL)] = []      // folder, photo
            var stores: [URL: CullAnalysis.Store] = [:]
            for (folder, photos) in byFolder {
                let store = await Task.detached(priority: .userInitiated) { CullAnalysis.load(folder) }.value
                stores[folder] = store
                var known = facts
                for p in photos {
                    if let e = store.entries[p.lastPathComponent], let st = CullAnalysis.stamp(p),
                       e.size == st.size, e.modified == st.modified {
                        known[p] = e.facts
                    } else {
                        todo.append((folder, p))
                    }
                }
                facts = known
            }
            regroup()
            guard !todo.isEmpty else { progress = nil; return }
            progress = (0, todo.count)
            // a few at a time: each decodes a full-size JPEG
            let measured = await withTaskGroup(of: (URL, URL, CullFacts?).self) { group in
                var next = 0, done = 0
                var batch: [URL: CullFacts] = [:]
                var all: [(URL, URL, CullFacts)] = []
                func add() {
                    let (folder, photo) = todo[next]
                    next += 1
                    group.addTask { await Task.detached(priority: .utility) { (folder, photo, CullAnalysis.analyse(photo)) }.value }
                }
                for _ in 0..<min(6, todo.count) { add() }
                while let (folder, photo, f) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    done += 1
                    if let f { batch[photo] = f; all.append((folder, photo, f)) }
                    if batch.count >= 24 || done == todo.count {
                        facts.merge(batch) { $1 }
                        batch = [:]
                        progress = (done, todo.count)
                    }
                    if next < todo.count { add() }
                }
                return all
            }
            guard !Task.isCancelled else { return }
            for (folder, photo, f) in measured {
                guard let st = CullAnalysis.stamp(photo) else { continue }
                stores[folder, default: .init()].entries[photo.lastPathComponent] = .init(size: st.size, modified: st.modified, facts: f)
            }
            let finished = stores
            await Task.detached(priority: .utility) {
                for (folder, store) in finished { CullAnalysis.save(store, for: folder) }
            }.value
            progress = nil
            regroup()
        }
    }

    private func regroup() {
        // in the order taken; the file name breaks ties (and orders photos without a time)
        let ordered = asked.sorted {
            let a = facts[$0]?.time ?? 0, b = facts[$1]?.time ?? 0
            return a != b ? a < b : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        runs = CullAnalysis.bursts(ordered, facts: facts)
        var index: [URL: Int] = [:]
        var best: [Int: URL] = [:]
        for (i, run) in runs.enumerated() {
            for u in run { index[u] = i }
            if run.count > 1, let b = CullAnalysis.best(of: run, facts: facts) { best[i] = b }
        }
        runOf = index
        suggestion = best
    }

    /// the burst a photo is in, if it's in one
    func burst(of url: URL?) -> [URL]? {
        guard let url, let i = runOf[url], runs[i].count > 1 else { return nil }
        return runs[i]
    }

    func run(of url: URL?) -> Int? { url.flatMap { runOf[$0] } }

    func suggested(in run: Int) -> URL? { suggestion[run] }

    func isSuggested(_ url: URL) -> Bool { runOf[url].flatMap { suggestion[$0] } == url }

    /// sharpness against the sharpest frame of its burst, 0 to 1
    func relativeSharpness(_ url: URL) -> Double {
        guard let s = facts[url]?.sharpness, let run = burst(of: url) else { return 1 }
        let top = run.compactMap { facts[$0]?.sharpness }.max() ?? 0
        return top > 0 ? s / top : 0
    }

    /// where a frame sits between its burst's softest (0) and sharpest (1)
    /// frames, so the bars show the differences, small as they often are
    func sharpnessRank(_ url: URL) -> Double {
        guard let s = facts[url]?.sharpness, let run = burst(of: url) else { return 1 }
        let all = run.compactMap { facts[$0]?.sharpness }
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return 1 }
        return (s - lo) / (hi - lo)
    }

    var burstCount: Int { runs.filter { $0.count > 1 }.count }

    // MARK: Previews

    private var previews: [URL: CGImage] = [:]
    private var order: [URL] = []
    private var loading: [URL: Task<CGImage?, Never>] = [:]
    private static let kept = 16

    func cachedPreview(_ url: URL) -> CGImage? { previews[url] }

    /// the photo at screen size, loaded once and kept for a while
    func preview(_ url: URL, pixels: Int) async -> CGImage? {
        if let p = previews[url] { touch(url); return p }
        if let t = loading[url] { return await t.value }
        let t = Task.detached(priority: .userInitiated) { CullAnalysis.preview(url, pixels: pixels) }
        loading[url] = t
        let image = await t.value
        loading[url] = nil
        if let image {
            previews[url] = image
            touch(url)
        }
        return image
    }

    /// starts loading the neighbours, so stepping on is instant
    func prefetch(_ urls: [URL], pixels: Int) {
        for u in urls where previews[u] == nil && loading[u] == nil {
            Task { _ = await preview(u, pixels: pixels) }
        }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > Self.kept { previews[order.removeFirst()] = nil }
    }
}
