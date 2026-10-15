import AppKit
import SwiftUI

/// A control generated from darktable's params metadata.
struct FieldControl: View {
    let op: String
    let field: EngineField
    let onChange: (FieldValue) -> Void
    @Environment(\.fieldLabelOverride) private var labelOverride

    var body: some View {
        if let help = Presentation.fieldHelp["\(op).\(field.name)"] { control.help(help) } else { control }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .float, .int:
            if let range = Presentation.range(op: op, field: field) {
                // shown in its own units where darktable's GUI scales it
                let k = Presentation.displayFactors["\(op).\(field.name)"] ?? 1
                if Presentation.filmSpeedFields.contains("\(op).\(field.name)") {
                    FilmSpeedSlider(label: label, iso: field.value.number * k, defaultISO: field.defaultValue.number * k) {
                        onChange(.number($0 / k))
                    }
                } else {
                ParamSlider(label: label, value: field.value.number * k, defaultValue: field.defaultValue.number * k,
                            range: range.lowerBound * k...range.upperBound * k, isInteger: field.kind == .int || k != 1,
                            unit: Presentation.units["\(op).\(field.name)"],
                            trackColors: Presentation.trackColors["\(op).\(field.name)"],
                            clipping: Presentation.clippingOps.contains(op)) { onChange(.number($0 / k)) }
                }
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
/// Drag anywhere on the track to adjust (hold Option on tone sliders to see
/// what clips), double-click the track or label to reset, click the value to
/// type one. A whole drag is one undo step. For small changes: scroll
/// sideways over it (a two-finger swipe), or use the arrow keys once it's been
/// used (Shift for bigger steps). Vertical scrolling still scrolls the inspector.
struct ParamSlider: View {
    let label: String
    let value: Double
    let defaultValue: Double
    let range: ClosedRange<Double>
    let isInteger: Bool
    let unit: String?
    let trackColors: [Color]?
    /// snaps to multiples of this while dragging
    var step: Double? = nil
    /// values marked under the track
    var ticks: [Double] = []
    /// false for sliders that don't edit the photo: no undo grouping
    var editsPhoto = true
    /// Option-drag shows what clips: for tone sliders, where clipping is what matters
    var clipping = false
    /// how the number reads, where the track works in other units
    var readout: Readout? = nil
    let onChange: (Double) -> Void

    /// The number shown for a track value, and back: ISO 1600 on a track in stops.
    struct Readout {
        let prefix: String?
        let shown: (Double) -> Double
        let value: (Double) -> Double
    }

    @State private var dragStart: Double?
    /// the unsnapped value so far in this drag
    @State private var dragValue: Double = 0
    @State private var lastX: CGFloat = 0
    /// While dragging, the thumb and number show this, not the model's value:
    /// they follow the pointer at once, whatever the editor is busy with, and
    /// the value goes to the editor at most every 33 ms (the engine can't
    /// render faster, and each change redraws the inspector)
    @State private var liveValue: Double?
    @State private var lastSent = ContinuousClock.now
    @State private var trailingSend: Task<Void, Never>?

    /// what the slider shows: the drag's value while dragging
    private var shown: Double { liveValue ?? value }
    @State private var hovering = false
    @Environment(\.sliderDrag) private var sliderDrag
    /// sideways scrolling over the slider, while the pointer is on it
    @State private var scrollMonitor: Any?
    @State private var scrollEnd: Task<Void, Never>?
    /// a slider that's been dragged takes the arrow keys
    @FocusState private var focused: Bool

    private var span: Double { range.upperBound - range.lowerBound }

    /// where the fill starts: the default if it's inside the range, else the left end
    private var origin: Double { range.contains(defaultValue) ? defaultValue : range.lowerBound }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .onTapGesture(count: 2) { onChange(defaultValue) }
                Spacer()
                if let readout {
                    if let prefix = readout.prefix { Text(prefix).foregroundStyle(.secondary) }
                    ValueField(value: readout.shown(shown), isInteger: true, decimals: 0, grouping: false,
                               onCommit: { onChange(clamp(readout.value($0))) })
                        .fixedSize()
                } else {
                    ValueField(value: shown, isInteger: isInteger, decimals: decimals, onCommit: onChange)
                }
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
            track
        }
        // the arrow keys, once the slider has been dragged (Shift: 10% steps)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let size = press.modifiers.contains(.shift) ? 0.1 : 0.01
            nudge(by: press.key == .rightArrow ? size : -size)
            return .handled
        }
        .onHover { inside in
            if inside, scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in scrolled(e) ? nil : e }
            } else if !inside, let m = scrollMonitor {
                NSEvent.removeMonitor(m)
                scrollMonitor = nil
            }
        }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text(readout?.shown(value) ?? value, format: .number.precision(.fractionLength(0...(readout == nil ? decimals : 0)))))
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
                        .frame(width: max(abs(x(shown) - x(origin)), 0), height: 4)
                        .offset(x: min(x(shown), x(origin)))
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
                    // ringed while it takes the arrow keys
                    .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2).opacity(focused ? 1 : 0))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .scaleEffect(dragStart != nil ? 1.1 : hovering ? 1.05 : 1)
                    .offset(x: x(shown) - 5)
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
                        if !focused { focused = true }
                        // tell the editor before the value changes, so the change joins the drag's undo step
                        if editsPhoto { sliderDrag?(true, clipping && NSEvent.modifierFlags.contains(.option)) }
                        dragValue = clamp(dragValue + Double((g.location.x - lastX) / max(w, 1)) * span)
                        lastX = g.location.x
                        send(snapped(dragValue))
                    }
                    .onEnded { _ in
                        trailingSend?.cancel()
                        if let v = liveValue { onChange(v) }
                        liveValue = nil
                        dragStart = nil
                        if editsPhoto { sliderDrag?(false, false) }
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(defaultValue) })
        }
        .frame(height: 22)
        .help(clipping ? "Drag to adjust, with Option to see what clips. Swipe sideways or use the arrow keys for small steps. Double-click to reset."
                       : "Drag to adjust. Swipe sideways or use the arrow keys for small steps. Double-click to reset.")
    }

    private func snapped(_ v: Double) -> Double {
        var v = v
        if let step { v = clamp((v / step).rounded() * step) }
        return isInteger ? v.rounded() : v
    }

    /// Sideways scrolling nudges the value: a trackpad's two-finger swipe moves
    /// it a little per point (about 0.15% of the range), a mouse wheel's
    /// sideways click 1%. Fingers right, value up, whichever way scrolling
    /// is set. Vertical scrolling is left to the inspector.
    private func scrolled(_ event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dx) > abs(dy), dx != 0 else { return false }
        let fingers = event.isDirectionInvertedFromDevice ? dx : -dx
        let per = event.hasPreciseScrollingDeltas ? span * 0.0015 : span * 0.01
        var next = clamp((liveValue ?? value) + Double(fingers) * per)
        if isInteger { next = (liveValue ?? value) + (fingers > 0 ? 1 : -1); next = clamp(next) }
        send(next)
        // the last value goes in once scrolling stops
        scrollEnd?.cancel()
        scrollEnd = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, dragStart == nil else { return }
            trailingSend?.cancel()
            trailingSend = nil
            if let v = liveValue { onChange(v) }
            liveValue = nil
        }
        return true
    }

    private func nudge(by fraction: Double) {
        let delta = isInteger ? (fraction > 0 ? 1 : -1) * max(1, (abs(fraction) * span).rounded()) : fraction * span
        onChange(clamp(value + delta))
    }

    /// shows the value at once; passes it on now if 33 ms have gone by, else
    /// once they have (the latest value then)
    private func send(_ v: Double) {
        liveValue = v
        let now = ContinuousClock.now
        if now - lastSent >= .milliseconds(33) {
            trailingSend?.cancel()
            trailingSend = nil
            lastSent = now
            onChange(v)
        } else if trailingSend == nil {
            let wait = .milliseconds(33) - (now - lastSent)
            trailingSend = Task { @MainActor in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let v = liveValue else { return }
                trailingSend = nil
                lastSent = ContinuousClock.now
                onChange(v)
            }
        }
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
    /// thousands separators: off for film speeds, which read ISO 1600
    var grouping = true
    let onCommit: (Double) -> Void

    var body: some View {
        TextField("Value", value: Binding(get: { shown }, set: { onCommit(isInteger ? $0.rounded() : $0) }),
                  format: .number.precision(.fractionLength(0...max(decimals, 0))).grouping(grouping ? .automatic : .never))
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 64)
    }

    /// a tiny negative value that rounds to nothing reads 0, not "-0"
    private var shown: Double {
        let scale = pow(10, Double(max(decimals, 0)))
        return (value * scale).rounded() == 0 ? 0 : value
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

/// A film speed slider, as darktable's grain coarseness: in stops along the
/// track, snapping to thirds, reading ISO 1600.
struct FilmSpeedSlider: View {
    let label: String
    let iso: Double
    let defaultISO: Double
    let onChange: (Double) -> Void

    var body: some View {
        ParamSlider(label: label, value: FilmSpeed.stops(iso), defaultValue: FilmSpeed.stops(defaultISO),
                    range: FilmSpeed.stops(FilmSpeed.range.lowerBound)...FilmSpeed.stops(FilmSpeed.range.upperBound),
                    isInteger: false, unit: nil, trackColors: nil, step: 1.0 / 3,
                    ticks: [100, 400, 1600].map(FilmSpeed.stops),
                    readout: .init(prefix: "ISO", shown: { FilmSpeed.iso(stops: $0) }, value: FilmSpeed.stops)) {
            onChange(FilmSpeed.iso(stops: $0))
        }
    }
}
