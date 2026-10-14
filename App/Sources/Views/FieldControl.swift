import AppKit
import SwiftUI

/// A control generated from darktable's params metadata.
struct FieldControl: View {
    let op: String
    let field: EngineField
    let onChange: (FieldValue) -> Void
    @Environment(\.fieldLabelOverride) private var labelOverride

    var body: some View {
        switch field.kind {
        case .float, .int:
            if let range = Presentation.range(op: op, field: field) {
                ParamSlider(label: label, value: field.value.number, defaultValue: field.defaultValue.number,
                            range: range, isInteger: field.kind == .int,
                            unit: Presentation.units["\(op).\(field.name)"],
                            trackColors: Presentation.trackColors["\(op).\(field.name)"],
                            clipping: Presentation.clippingOps.contains(op)) { onChange(.number($0)) }
            } else {
                // no usable range (darktable left it unbounded): type the value
                HStack {
                    Text(label)
                    Spacer()
                    TextField(label, value: Binding(get: { field.value.number }, set: { onChange(.number($0)) }),
                              format: .number.precision(.fractionLength(0...4)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
        case .bool:
            HStack {
                Text(label)
                Spacer()
                Toggle(label, isOn: Binding(get: { field.value.bool }, set: { onChange(.bool($0)) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        case .enum where Presentation.describedOptions["\(op).\(field.name)"] != nil:
            DescribedPicker(label: label, value: Int(field.value.number),
                            options: Presentation.describedOptions["\(op).\(field.name)"]!) { onChange(.number(Double($0))) }
        case .enum:
            HStack {
                Text(label)
                Spacer()
                Picker(label, selection: Binding(get: { Int(field.value.number) },
                                                 set: { onChange(.number(Double($0))) })) {
                    ForEach((field.options ?? []).filter { !FieldControl.isInternalOption($0.label) }, id: \.value) {
                        Text(Self.optionLabel($0.label, among: field.options ?? [])).tag($0.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var label: String {
        labelOverride ?? Presentation.fieldLabels["\(op).\(field.name)"] ?? (field.label.prefix(1).uppercased() + field.label.dropFirst())
    }

    /// enum values that are counters or interface actions, not settings
    static func isInternalOption(_ label: String) -> Bool {
        label.hasPrefix("DT_") && (label.hasSuffix("_LAST") || label.contains("DETECT"))
    }

    /// Undescribed enum values arrive as C names ("DT_COLORSPACE_HLG_P3"): drop the
    /// prefix they share and make the rest readable ("HLG P3").
    static func optionLabel(_ raw: String, among options: [EngineField.Option]) -> String {
        guard raw == raw.uppercased(), raw.contains("_") else { return raw }
        let names = options.map(\.label).filter { $0 == $0.uppercased() }
        var prefix = names.first ?? ""
        for n in names { while !n.hasPrefix(prefix) { prefix.removeLast() } }
        if let cut = prefix.lastIndex(of: "_") { prefix = String(prefix[...cut]) } else { prefix = "" }
        let words = raw.dropFirst(prefix.count).split(separator: "_").map { w -> String in
            // short words and ones with digits are acronyms or names (HLG, P3, REC2020)
            w.count <= 4 || w.contains(where: \.isNumber) ? String(w) : w.capitalized
        }
        let text = words.joined(separator: " ")
        return text.isEmpty ? raw : text
    }
}

/// Photomator-style slider: label and value above a thin track, a white
/// thumb, and a fill from the default value to the current one.
/// Drag anywhere on the track to adjust (hold Shift for fine control, Option
/// to see what clips), double-click the track or label to reset, click the
/// value to type one. A whole drag is one undo step.
struct ParamSlider: View {
    let label: String
    let value: Double
    let defaultValue: Double
    let range: ClosedRange<Double>
    let isInteger: Bool
    let unit: String?
    let trackColors: [Color]?
    /// snaps to multiples of this while dragging (Shift drags freely)
    var step: Double? = nil
    /// values marked under the track
    var ticks: [Double] = []
    /// false for sliders that don't edit the photo: no undo grouping
    var editsPhoto = true
    /// Option-drag shows what clips: for tone sliders, where clipping is what matters
    var clipping = false
    let onChange: (Double) -> Void

    @State private var dragStart: Double?
    /// the unsnapped value and pointer x so far in this drag: each movement
    /// adds to it, at a tenth with Shift, so pressing or releasing Shift
    /// mid-drag changes the speed from there instead of making the thumb jump
    @State private var dragValue: Double = 0
    @State private var lastX: CGFloat = 0
    @State private var hovering = false
    @Environment(\.sliderDrag) private var sliderDrag

    private var span: Double { range.upperBound - range.lowerBound }

    /// where the fill starts: the default if it's inside the range, else the left end
    private var origin: Double { range.contains(defaultValue) ? defaultValue : range.lowerBound }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .onTapGesture(count: 2) { onChange(defaultValue) }
                Spacer()
                ValueField(value: value, isInteger: isInteger, decimals: decimals, onCommit: onChange)
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
            track
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...decimals))))
        .accessibilityAdjustableAction { direction in
            let step = isInteger ? 1 : span / 100
            onChange(clamp(value + (direction == .increment ? step : -step)))
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) -> CGFloat in CGFloat((clamp(v) - range.lowerBound) / span) * w }
            ZStack(alignment: .leading) {
                if let trackColors {
                    Capsule()
                        .fill(LinearGradient(colors: trackColors, startPoint: .leading, endPoint: .trailing))
                        .opacity(0.85)
                        .frame(height: 4)
                } else {
                    Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(abs(x(value) - x(origin)), 0), height: 4)
                        .offset(x: min(x(value), x(origin)))
                }
                ForEach(ticks.filter { range.contains($0) }, id: \.self) { t in
                    Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1, height: 5)
                        .offset(x: x(t) - 0.5, y: 8)
                }
                // default marker, so you can see where "reset" goes
                if range.contains(defaultValue), defaultValue != range.lowerBound {
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 3, height: 3)
                        .offset(x: x(defaultValue) - 1.5, y: 7)
                }
                Capsule()
                    .fill(.white)
                    .frame(width: 10, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .scaleEffect(dragStart != nil ? 1.1 : hovering ? 1.05 : 1)
                    .offset(x: x(value) - 5)
                    .animation(.easeOut(duration: 0.12), value: dragStart != nil)
            }
            .frame(width: w, height: 22)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStart == nil {
                            dragStart = value
                            dragValue = value
                            lastX = g.startLocation.x
                        }
                        let flags = NSEvent.modifierFlags
                        let fine = flags.contains(.shift)
                        // tell the editor before the value changes, so the change joins the drag's undo step
                        if editsPhoto { sliderDrag?(true, clipping && flags.contains(.option)) }
                        dragValue = clamp(dragValue + Double((g.location.x - lastX) / max(w, 1)) * span * (fine ? 0.1 : 1))
                        lastX = g.location.x
                        var v = dragValue
                        if let step, !fine { v = clamp((v / step).rounded() * step) }
                        onChange(isInteger ? v.rounded() : v)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        if editsPhoto { sliderDrag?(false, false) }
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(defaultValue) })
        }
        .frame(height: 22)
        .help(clipping ? "Drag to adjust: hold Shift for fine control, Option to see what clips. Double-click to reset."
                       : "Drag to adjust, hold Shift for fine control, double-click to reset")
    }

    private var decimals: Int {
        if isInteger { return 0 }
        return span <= 0.5 ? 4 : span <= 2 ? 3 : span <= 20 ? 2 : span <= 200 ? 1 : 0
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

private struct SliderDragKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (Bool, Bool) -> Void)? = nil }
extension EnvironmentValues {
    /// told when a photo slider's drag starts, changes and ends: (dragging, Option held)
    var sliderDrag: (@MainActor @Sendable (Bool, Bool) -> Void)? {
        get { self[SliderDragKey.self] }
        set { self[SliderDragKey.self] = newValue }
    }
}

/// The number above a slider: looks like a label, click to type a value.
private struct ValueField: View {
    let value: Double
    let isInteger: Bool
    let decimals: Int
    let onCommit: (Double) -> Void

    var body: some View {
        TextField("Value", value: Binding(get: { value }, set: { onCommit(isInteger ? $0.rounded() : $0) }),
                  format: .number.precision(.fractionLength(0...max(decimals, 0))))
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 64)
    }
}

/// A menu of choices in a deliberate order, each with an explanation: as a
/// tooltip on the menu item, and under the menu for the current choice.
struct DescribedPicker: View {
    let label: String
    let value: Int
    let options: [Presentation.Option]
    let onChange: (Int) -> Void

    var body: some View {
        let current = options.first { $0.value == value }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Menu(current?.name ?? "Other") {
                    ForEach(options, id: \.value) { o in
                        Button {
                            onChange(o.value)
                        } label: {
                            if o.value == value { Label(o.name, systemImage: "checkmark") } else { Text(o.name) }
                        }
                        .help(o.detail)
                    }
                }
                .fixedSize()
                .help(current?.detail ?? "")
            }
            if let current {
                Text(current.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
