import CoreImage
import SwiftUI

/// Rescue Focus: an overview to choose where to look, that part at full size
/// before and after, and the amount. Makes a new photo; the original isn't
/// changed.
struct RescueFocusSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photo: URL
    @State private var overview: CGImage?
    @State private var centre = CGPoint(x: 0.5, y: 0.5)
    @State private var amount = 100.0
    @State private var settled = 100.0
    @State private var showAfter = true
    @State private var pair: (before: CGImage, after: CGImage)?
    @State private var working = false
    @State private var failure: String?

    private struct Request: Equatable { let centre: CGPoint; let amount: Double }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rescue Focus").font(.headline)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    overviewPicker
                    Text("Click where focus matters, such as the eyes, to see it at full size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text("\(Int(amount))").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $amount, in: 0...100, step: 5) { editing in
                            if !editing { settled = amount }
                        }
                    }
                    Text("For focus that clearly missed. A model trained on real out-of-focus photos restores the detail the blur spread out; detail that's gone entirely comes back smooth rather than invented. For a slightly soft lens, sharpening does better. Makes a new photo next to this one; the original isn't changed. A 24 MP photo takes about two minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 380)
                VStack(spacing: 8) {
                    Picker("Show", selection: $showAfter) {
                        Text("Before").tag(false)
                        Text("After").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    ZStack {
                        Color.black.opacity(0.85)
                        if let pair {
                            Image(decorative: showAfter ? pair.after : pair.before, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                        } else if let failure {
                            Text(failure).foregroundStyle(.secondary).padding()
                        }
                        if working {
                            ProgressView().controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .frame(width: 512, height: 512)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("Shown at 200%").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let a = settled
                    dismiss()
                    Task { await model.createRescueFocus(photo, amount: a / 100) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(overview == nil || settled == 0)
            }
        }
        .padding(20)
        .task {
            do {
                let image = try await model.rescueFocusImage(photo)
                let s = 380 / max(image.extent.width, image.extent.height)
                let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                overview = CIContext().createCGImage(small, from: small.extent.integral)
            } catch {
                failure = error.localizedDescription
                return
            }
            await refresh()
        }
        // after that, again when the square moves or the amount settles
        .task(id: Request(centre: centre, amount: settled)) {
            guard overview != nil else { return }
            await refresh()
        }
    }

    private func refresh() async {
        working = true
        defer { working = false }
        do {
            pair = try await model.rescueFocusPreview(photo, centre: centre, amount: settled / 100)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// the whole photo, with the square shown on the right marked; click to move it
    @ViewBuilder private var overviewPicker: some View {
        if let overview {
            let w = CGFloat(overview.width), h = CGFloat(overview.height)
            let scale = 380 / max(w, h)
            let size = CGSize(width: w * scale, height: h * scale)
            // the square's share of the photo, from its full size
            let full = model.rescueFocusSource?.image.extent.size ?? CGSize(width: 512, height: 512)
            let side = 512 / max(full.width, full.height) * max(size.width, size.height)
            Image(decorative: overview, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: max(side, 8), height: max(side, 8))
                        .offset(x: centre.x * size.width - side / 2, y: centre.y * size.height - side / 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { p in
                    centre = CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
                }
                .accessibilityLabel("Choose where to look")
        } else if let failure {
            Text(failure).foregroundStyle(.secondary).frame(width: 380, height: 260)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Rendering the photo…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 380, height: 260)
        }
    }
}
