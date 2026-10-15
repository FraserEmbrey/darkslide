import SwiftUI

/// Adjustments for the SDR rendition of an HDR edit (see SDRVersion).
struct SDRVersionCard: View {
    @Environment(EditorModel.self) private var model
    @State private var isExpanded = true
    @State private var appleBase = ExportSettings.load().sdrBase == .automatic

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(title: "SDR version", isExpanded: $isExpanded)
                if !model.sdrVersion.isNeutral {
                    Button("Reset", systemImage: "arrow.counterclockwise") { model.sdrVersion = SDRVersion() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reset the SDR version's adjustments")
                }
            }
            if model.viewHDR {
                // compact while viewing HDR: the adjustments only show in the SDR view
                HStack {
                    Text(model.sdrVersion.isNeutral ? "What displays without HDR show, and the base of a JPEG with HDR gain map."
                                                    : "Adjusted. What displays without HDR show, and the base of a JPEG with HDR gain map.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show") { model.viewHDR = false }
                        .help("Switch the view to SDR to see and adjust the SDR version")
                }
            } else if isExpanded {
                Text("You're seeing the SDR version: what displays without HDR show, and the base of a JPEG with HDR gain map. These adjustments change only this version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ParamSlider(label: "Brightness", value: model.sdrVersion.brightness, defaultValue: 0, range: -2...2,
                            isInteger: false, unit: "EV", trackColors: nil, clipping: true) { model.sdrVersion.brightness = $0 }
                ParamSlider(label: "Contrast", value: model.sdrVersion.contrast, defaultValue: 0, range: -1...1,
                            isInteger: false, unit: nil, trackColors: nil, clipping: true) { model.sdrVersion.contrast = $0 }
                ParamSlider(label: "Saturation", value: model.sdrVersion.saturation, defaultValue: 0, range: -1...1,
                            isInteger: false, unit: nil, trackColors: nil) { model.sdrVersion.saturation = $0 }
                // what HDR exports use as their SDR image (their base, under the gain map)
                Toggle("Use Apple's tone mapping instead", isOn: Binding(
                    get: { appleBase },
                    set: { on in
                        var e = ExportSettings.load()
                        e.sdrBase = on ? .automatic : .darktable
                        e.save()
                        appleBase = on
                    }))
                    .font(.caption)
                    .help("HDR exports carry an SDR version for screens without HDR. Normally it's this one; Apple's automatic tone mapping of the HDR image is quicker but flatter, and ignores these adjustments.")
            }
        }
        .cardStyle()
    }
}
