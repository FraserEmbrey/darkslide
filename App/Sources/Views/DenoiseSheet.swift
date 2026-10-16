import SwiftUI

/// Denoise to New DNG…: the amount, as Lightroom's Denoise asks for it. Less
/// than 100 blends the original sensor values back in, keeping some grain.
struct DenoiseSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amount = EditorModel.denoiseAmount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Denoise to New DNG").font(.headline)
            Text("Takes the noise out of the raw before it's turned into a picture, and saves the result as a new DNG next to the original, with your edit. The original isn't changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Amount")
                Slider(value: $amount, in: 0...100, step: 5)
                Text("\(Int(amount))")
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
            Text("Lower keeps some of the original grain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Denoise") {
                    EditorModel.denoiseAmount = amount
                    dismiss()
                    Task { await model.denoiseToDNG(amount: amount) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(amount == 0)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
