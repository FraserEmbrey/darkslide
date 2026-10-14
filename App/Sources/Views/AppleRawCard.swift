import SwiftUI

/// The Apple raw engine's own settings, when it decodes the open photo (Image ›
/// Raw Decoder): tone, detail and lens correction as Core Image offers them for
/// this camera. A change decodes the raw again once the slider rests;
/// darktable's edits carry over.
struct AppleRawCard: View {
    @Environment(EditorModel.self) private var model
    @State private var isExpanded = true
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(title: model.decoderInUse ?? "Apple RAW", isExpanded: $isExpanded)
                if !model.appleRawSettings.isEmpty {
                    CardIconButton(systemImage: "arrow.counterclockwise", help: "Reset to the camera's defaults") {
                        model.resetAppleRaw()
                    }
                }
            }
            if isExpanded {
                Text("How macOS decodes this raw, before darktable. Changes decode it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.appleRawControls.filter { $0.group == .tone }) { slider($0) }
                let detail = model.appleRawControls.filter { $0.group == .detail }
                if !detail.isEmpty || model.appleRawLensDefault != nil {
                    DisclosureGroup("Noise, detail and lens", isExpanded: $showDetail) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(detail) { slider($0) }
                            if let lensDefault = model.appleRawLensDefault {
                                HStack {
                                    Text("Lens correction")
                                    Spacer()
                                    Toggle("Lens correction", isOn: Binding(
                                        get: { model.appleRawSettings.lensCorrection ?? lensDefault },
                                        set: { model.setAppleRawLensCorrection($0 == lensDefault ? nil : $0) }))
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                        .labelsHidden()
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func slider(_ c: AppleRawControl) -> some View {
        ParamSlider(label: c.title, value: model.appleRawSettings.values[c.id] ?? c.defaultValue,
                    defaultValue: c.defaultValue, range: c.range, isInteger: false, unit: c.unit,
                    trackColors: nil, editsPhoto: false) { v in
            model.setAppleRaw(c.id, to: abs(v - c.defaultValue) < 0.0005 ? nil : v)
        }
    }
}
