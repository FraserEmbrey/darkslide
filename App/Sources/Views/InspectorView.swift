import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if model.isCropping {
            CropPanel()
        } else {
            adjustments
        }
    }

    private var adjustments: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            InspectorTabBar(selection: $model.filter, searching: !model.search.isEmpty)
            Divider()

            SearchField(text: $model.search, prompt: "Search modules")
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if model.url != nil {
                PinnedHistogram()
            }
            Divider()
            .padding(.top, model.url == nil ? 10 : 0)

            if model.modules.isEmpty {
                ContentUnavailableView("No Adjustments", systemImage: "slider.horizontal.3",
                                       description: Text("Open a photo to see its modules."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if model.search.isEmpty, model.decodedTIFF != nil, !model.openedAsHDR, let d = model.decoderInUse {
                            // raw-only modules are hidden: say why, and how to have them
                            Label("Decoded by \(d), so darktable's raw tools (demosaic, raw denoise, hot pixels, raw chromatic aberration) don't apply. Choose darktable in Image › Raw Decoder to use them, if it can read this file, or convert it to DNG.",
                                  systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        // the Look and Local adjustments cards come up in searches too
                        if !model.search.isEmpty, model.url != nil {
                            if FuzzySearch.matches(model.search, in: ["look", "film look", "film simulation", "lut", "camera style", "style", "preset look"]) {
                                LookCard()
                            }
                            if FuzzySearch.matches(model.search, in: ["local adjustments", "linear gradient", "radial gradient", "graduated filter", "mask", "dodge", "burn", "vignette"]) {
                                LocalAdjustmentsCard()
                            }
                        }
                        if model.search.isEmpty {
                            AutoButton()
                            // the SDR card first, so switching views with its Show button
                            // doesn't move it when the HDR card comes and goes
                            if model.exportTarget.isHDR { SDRVersionCard() }
                            if model.viewHDR { HDRDetailsCard() }
                            LookCard()
                            if model.url != nil { LocalAdjustmentsCard() }
                        }
                        if model.filter != .essentials, model.search.isEmpty {
                            Label("In processing order: the top module runs last, as in darktable.",
                                  systemImage: "arrow.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        ForEach(model.visibleModules) { module in
                            ModuleCard(module: module)
                        }
                        if model.filter == .essentials, model.search.isEmpty { EssentialsFooter() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)

                InspectorBottomBar()
            }
        }
        // keep everything at the top, including before a photo is open
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Cards

extension View {
    /// The rounded panel every inspector section sits on.
    func cardStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Card title that opens and closes the card when clicked anywhere on it.
struct CardTitle: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }
}

/// Small round icon button used in card headers (reset, auto).
struct CardIconButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.black : Color.primary.opacity(0.8))
                .frame(width: 30, height: 22)
                .background(isActive ? Color.yellow : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ModuleCard: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if model.filter == .essentials, model.search.isEmpty, model.isEssential(module.op) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder")
                        .draggable(module.op)
                }
                CardTitle(title: title, isExpanded: expandedBinding)
                if let rule = Presentation.autoModes[module.op] {
                    AutoPill(isOn: model.isAuto(module), help: rule.help(module)) {
                        model.setAuto(!model.isAuto(module), module: module)
                    }
                }
                ModuleMenu(module: module, title: title)
                CardIconButton(systemImage: "arrow.counterclockwise", help: "Reset \(title)") {
                    model.reset(module: module.key)
                }
                if module.canDisable {
                    Toggle("Enabled", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }

            if expandedBinding.wrappedValue, module.op == "channelmixerrgb" {
                SceneWhiteControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "lens" {
                LensControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "rgbcurve" {
                RGBCurveControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "exposure", !EditorModel.isLocal(module) {
                ExposureControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "bilat" {
                LocalContrastControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "ashift" {
                RotatePerspectiveSummary(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "colorequal" {
                HueCurveControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, module.op == "demosaic" {
                DemosaicControls(module: module)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue, let layout = Presentation.layouts[module.op] {
                LayoutControls(module: module, sections: layout)
                    .transition(.opacity)
            } else if expandedBinding.wrappedValue {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleFields) { field in
                        FieldControl(op: module.op, field: field) { value in
                            model.setValue(value, module: module.key, field: field.name)
                        }
                    }
                    if module.unsupportedFields > 0 {
                        Label("\(module.unsupportedFields) more \(module.unsupportedFields == 1 ? "setting needs" : "settings need") a custom editor",
                              systemImage: "hammer")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .cardStyle()
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        }
        .dropDestination(for: String.self) { items, _ in
            guard model.filter == .essentials, let op = items.first else { return false }
            withAnimation { model.moveEssential(op, before: module.op) }
            return true
        } isTargeted: { isDropTarget = $0 && model.filter == .essentials }
        .contextMenu {
            Button(model.isEssential(module.op) ? "Remove from Essentials" : "Add to Essentials") {
                withAnimation { model.toggleEssential(module.op) }
            }
            Divider()
            Button("Reset \(title)") { model.reset(module: module.key) }
        }
    }

    private var title: String {
        let name = Presentation.title(of: module)
        // darktable labels auto-applied presets "_builtin_…"; those aren't names
        let instance = module.instanceName
        return instance.isEmpty || instance == "0" || instance.hasPrefix("_builtin")
            ? name : "\(name) (\(instance))"
    }

    // darktable's own interface shows undescribed fields too (exposure's main
    // slider has no description), so every scalar is shown unless it belongs
    // to a mode that isn't selected
    private var visibleFields: [EngineField] {
        module.fields.filter { Presentation.isVisible($0, in: module) }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(get: { model.expanded.contains(module.key) },
                set: { if $0 { model.expanded.insert(module.key) } else { model.expanded.remove(module.key) } })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { module.enabled }, set: { model.setEnabled($0, module: module.key) })
    }
}

struct EssentialsFooter: View {
    @Environment(EditorModel.self) private var model
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 10) {
            Button { showingPicker = true } label: {
                Label("Add Module…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPicker, arrowEdge: .top) {
                ModulePicker()
            }

            Text("Drag the handles to reorder. Right-click a module to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Restore Default Essentials") { withAnimation { model.resetEssentials() } }
                .controlSize(.small)
        }
        .padding(.top, 6)
    }
}

/// Every darktable module, searchable; click to add to or remove from Essentials.
/// Stays open so several can be added in one go.
struct ModulePicker: View {
    @Environment(EditorModel.self) private var model
    @State private var search = ""

    private struct Entry: Identifiable { let op: String; let name: String; var id: String { op } }

    /// one entry per module type, alphabetical
    private var entries: [Entry] {
        var seen = Set<String>()
        return model.modules
            .filter { seen.insert($0.op).inserted }
            .map { Entry(op: $0.op, name: $0.name.prefix(1).uppercased() + $0.name.dropFirst()) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $search, prompt: "Search modules")
                .padding(10)
            Divider()
            List(entries) { entry in
                let included = model.isEssential(entry.op)
                Button {
                    withAnimation { model.toggleEssential(entry.op) }
                } label: {
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Image(systemName: included ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(included ? Color.accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(included ? "In Essentials" : "Not in Essentials")
            }
            .listStyle(.plain)
        }
        .frame(width: 280, height: 380)
    }
}


/// macOS-style search field: magnifying glass, plain text, clear button,
/// on a filled rounded background like Finder's and Mail's.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2)
        }
        .onExitCommand { text = ""; focused = false }   // Esc clears, as in Finder
    }
}

/// Inspector tabs in the style of Keynote's and Pages' inspectors: full-width,
/// equal tabs along the top edge, the selected one marked by a fill.
struct InspectorTabBar: View {
    @Binding var selection: EditorModel.Filter
    /// while searching, results come from every module, so no tab is highlighted
    var searching = false
    @State private var hovered: EditorModel.Filter?
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EditorModel.Filter.allCases) { tab in
                let isSelected = tab == selection && !searching
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    Text(tab.rawValue)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            // one shared fill that slides to the selected tab
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: pill)
                            } else if hovered == tab {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? tab : nil }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Full-width Auto at the top of the inspector, like Photomator's Auto
/// Enhance. Its tooltip lists what it does: darktable's automatic tools,
/// nothing that analyses the content.
struct AutoButton: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Button { Task { await model.autoAll() } } label: {
            Label("Auto", systemImage: "wand.and.rays")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!model.canAuto)
        .help("Applies darktable's automatic tools: the camera style for this camera, automatic exposure, filmic's auto-tune (if filmic is on) and the tone equalizer fit (if it's on).")
    }
}

/// Compare and Reset along the bottom of the inspector, as in Photomator.
struct InspectorBottomBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Toggle(isOn: $model.comparing) {
                    Image(systemName: "square.split.2x1")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .toggleStyle(.button)
                .help("Compare with the photo as it was when opened (⇧⌘B)")
                Button { model.confirmingReset = true } label: {
                    Text("Reset")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                // only when there's something to reset
                .disabled(!model.canReset)
                .help(model.canReset ? "Reset all edits" : "No edits to reset")
            }
            .controlSize(.large)
            .padding(12)
        }
        .disabled(model.url == nil)
    }
}

/// "Auto" switch for modules with a rule-based automatic mode. Text, not a
/// wand, because darktable's automatic modes are metering rules, not AI.
struct AutoPill: View {
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Auto")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.black : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isOn ? Color.yellow : Color.primary.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Automatic")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// darktable sets the scene's white in color calibration (chromatic adaptation),
/// leaving the white balance module on "camera reference". This shows that as
/// temperature and tint; changing either sets a custom illuminant at that xy.
struct SceneWhiteControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var showAdvanced = false

    private func field(_ name: String) -> EngineField? { module.fields.first { $0.name == name } }
    private func number(_ name: String) -> Double { field(name)?.value.number ?? 0 }

    /// current illuminant as temperature and tint
    private var current: (kelvin: Double, tint: Double) {
        switch Int(number("illuminant")) {
        case 2, 6:   // daylight, black body: darktable uses the temperature field
            return (number("temperature"), 0)
        default:     // custom and the rest: the stored chromaticity
            return Illuminant.kelvinAndTint(x: number("x"), y: number("y"))
        }
    }

    private func set(kelvin: Double, tint: Double) {
        let p = Illuminant.xy(kelvin: kelvin, tint: tint)
        model.setValue(.number(7), module: module.key, field: "illuminant")   // custom
        model.setValue(.number(p.x), module: module.key, field: "x")
        model.setValue(.number(p.y), module: module.key, field: "y")
        model.setValue(.number(kelvin), module: module.key, field: "temperature")
    }

    var body: some View {
        let c = current
        VStack(alignment: .leading, spacing: 14) {
            if let f = field("illuminant") {
                FieldControl(op: module.op, field: f) { model.setValue($0, module: module.key, field: f.name) }
            }
            ParamSlider(label: "Temperature", value: c.kelvin, defaultValue: 5000,
                        range: Illuminant.kelvinRange, isInteger: true, unit: "K",
                        trackColors: [.blue, .yellow]) { set(kelvin: $0, tint: c.tint) }
            ParamSlider(label: "Tint", value: c.tint, defaultValue: 0,
                        range: Illuminant.tintRange, isInteger: false, unit: nil,
                        trackColors: [.green, Color(red: 0.85, green: 0.3, blue: 0.85)]) { set(kelvin: c.kelvin, tint: $0) }
            Text("The colour of the light in the scene. darktable corrects it here, in color calibration, rather than in white balance.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(module.fields.filter(isAdvanced)) { f in
                        FieldControl(op: module.op, field: f) { model.setValue($0, module: module.key, field: f.name) }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    /// everything except what the main controls already cover; the per-channel
    /// "normalize" switches belong to the channel mixer tabs, which need custom editors
    private func isAdvanced(_ f: EngineField) -> Bool {
        !["illuminant", "x", "y", "temperature"].contains(f.name) && !f.name.hasPrefix("normalize_")
            && Presentation.isVisible(f, in: module)
    }
}

/// A module laid out from Presentation.layouts: the first section shown
/// openly, later sections as disclosures, everything else under Advanced.
struct LayoutControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    let sections: [Presentation.Section]
    @State private var open: Set<String> = []

    private func field(_ name: String) -> EngineField? { module.fields.first { $0.name == name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if module.op == "toneequal" { ToneEqualizerMacros(module: module) }
            if module.op == "filmicrgb" {
                HStack {
                    Text("Sets white and black relative exposure from the photo's brightest and darkest tones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Auto-Tune Levels") { Task { await model.autoTuneFilmic() } }
                        .controlSize(.small)
                        .help("darktable's auto tune levels, over the whole photo")
                }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                if let title = section.title {
                    DisclosureGroup(title, isExpanded: binding(title)) { fields(section.fields).padding(.top, 8) }
                } else {
                    fields(section.fields)
                }
            }
            let listed = Set(sections.flatMap(\.fields))
            let rest = module.fields.filter { !listed.contains($0.name) && Presentation.isVisible($0, in: module) }
            if !rest.isEmpty {
                DisclosureGroup("Advanced", isExpanded: binding("Advanced")) { fields(rest.map(\.name)).padding(.top, 8) }
            }
        }
    }

    private func fields(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(names.compactMap(field).filter { Presentation.isVisible($0, in: module) }) { f in
                FieldControl(op: module.op, field: f) { model.setValue($0, module: module.key, field: f.name) }
            }
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { open.contains(key) }, set: { if $0 { open.insert(key) } else { open.remove(key) } })
    }
}

/// Shadows and Highlights for the tone equalizer. Each moves a weighted group
/// of exposure zones, so the change rolls off smoothly into its neighbours.
struct ToneEqualizerMacros: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var fitting = false
    @State private var pendingMacro: (Double, Double)?

    private func value(_ zone: String) -> Double { module.fields.first { $0.name == zone }?.value.number ?? 0 }

    var body: some View {
        let shadows = value(Presentation.toneAnchors.shadows), highlights = value(Presentation.toneAnchors.highlights)
        VStack(alignment: .leading, spacing: 14) {
            ParamSlider(label: "Shadows", value: shadows, defaultValue: 0, range: -2...2, isInteger: false,
                        unit: "EV", trackColors: nil) { apply(shadows: $0, highlights: highlights) }
            ParamSlider(label: "Highlights", value: highlights, defaultValue: 0, range: -2...2, isInteger: false,
                        unit: "EV", trackColors: nil) { apply(shadows: shadows, highlights: $0) }
            HStack(alignment: .firstTextBaseline) {
                Text(model.toneEqualizerIsFitted
                     ? "Brightens or darkens by exposure zone, with darktable's edge-aware mask so local contrast is kept."
                     : "The mask isn't fitted to this photo yet; that happens the first time you move a slider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fit to Photo") { Task { await model.fitToneEqualizer() } }
                    .controlSize(.small)
                    .help("Spreads the photo's tones across the zones, as darktable's auto-adjust does for the mask's exposure and contrast")
            }
        }
    }

    private func apply(shadows s: Double, highlights h: Double) {
        // the zones only mean "shadows" and "highlights" once the mask is fitted:
        // fit once, then apply whatever the slider says by then
        if !model.toneEqualizerIsFitted {
            pendingMacro = (s, h)
            guard !fitting else { return }
            fitting = true
            Task {
                await model.ensureToneEqualizerFitted()
                fitting = false
                if let latest = pendingMacro { setZones(shadows: latest.0, highlights: latest.1) }
                pendingMacro = nil
            }
            return
        }
        setZones(shadows: s, highlights: h)
    }

    private func setZones(shadows s: Double, highlights h: Double) {
        let w = Presentation.toneZoneWeights
        let zones = Set(w.shadows.keys).union(w.highlights.keys)
        for zone in zones {
            let v = (w.shadows[zone] ?? 0) * s + (w.highlights[zone] ?? 0) * h
            model.setValue(.number(min(max(v, -2), 2)), module: module.key, field: zone)
        }
    }
}

/// Demosaicing, laid out for the photo's sensor as darktable's interface does:
/// only the methods that apply, with a plain description of each, and only
/// the settings the chosen method uses.
struct DemosaicControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var showAdvanced = false

    struct Method: Identifiable {
        let value: Int
        let name: String
        let detail: String
        var id: Int { value }
    }

    // darktable's dt_iop_demosaic_method_t values (1024 = X-Trans, 2048 = dual)
    static let bayer: [Method] = [
        Method(value: 5, name: "RCD", detail: "darktable's default: sharp detail, few artefacts, fast."),
        Method(value: 1, name: "AMaZE", detail: "The finest detail at low ISO; slower, and can show maze patterns in noise."),
        Method(value: 6, name: "LMMSE", detail: "Best for high ISO and noisy photos."),
        Method(value: 2, name: "VNG4", detail: "Softer, but avoids maze patterns in fine repeating detail."),
        Method(value: 0, name: "PPG", detail: "Fast and simple; an older default."),
    ]
    static let bayerDual: [Method] = [
        Method(value: 2048 | 5, name: "RCD + VNG4", detail: "RCD on detail, VNG4 in flat areas to keep them clean."),
        Method(value: 2048 | 1, name: "AMaZE + VNG4", detail: "AMaZE on detail, VNG4 in flat areas."),
    ]
    static let xtrans: [Method] = [
        Method(value: 1024 | 2, name: "Markesteijn 3-pass", detail: "darktable's best for Fujifilm X-Trans: most detail, fewest artefacts."),
        Method(value: 1024 | 1, name: "Markesteijn 1-pass", detail: "Nearly as good, noticeably faster."),
        Method(value: 1024 | 4, name: "Frequency domain chroma", detail: "Cleaner colour in high-ISO X-Trans photos."),
        Method(value: 1024 | 0, name: "VNG", detail: "Fast and soft."),
    ]
    static let xtransDual: [Method] = [
        Method(value: 2048 | 1024 | 2, name: "Markesteijn 3-pass + VNG", detail: "Markesteijn on detail, VNG in flat areas."),
    ]
    static func special(xtrans: Bool) -> [Method] {
        let base = xtrans ? 1024 : 0
        return [
            Method(value: base | 3, name: "Monochrome (passthrough)", detail: "Skips colour reconstruction: black and white at full resolution. Mainly for cameras with the colour filter removed."),
            Method(value: base | (xtrans ? 5 : 4), name: "Photosite colour", detail: "Shows the raw sensor pattern, for diagnosis."),
        ]
    }

    private func value(_ name: String) -> Double { module.fields.first { $0.name == name }?.value.number ?? 0 }
    private func set(_ name: String, _ v: Double) { model.setValue(.number(v), module: module.key, field: name) }

    private var isXTrans: Bool { model.sensor == "xtrans" }
    private var methods: [Method] {
        (isXTrans ? Self.xtrans + Self.xtransDual : Self.bayer + Self.bayerDual) + Self.special(xtrans: isXTrans)
    }

    var body: some View {
        let current = Int(value("demosaicing_method"))
        let method = methods.first { $0.value == current }
        VStack(alignment: .leading, spacing: 14) {
            if model.sensor == "monochrome" || model.sensor == "linear" {
                Text(model.sensor == "monochrome"
                     ? "This camera has no colour filter, so there's nothing to demosaic."
                     : "This photo isn't a mosaiced raw, so demosaicing doesn't apply.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Method")
                    Spacer()
                    Menu(method?.name ?? "Other") {
                        Section("Recommended") {
                            ForEach(isXTrans ? Self.xtrans : Self.bayer) { m in Button(m.name) { set("demosaicing_method", Double(m.value)) } }
                        }
                        Section("Dual: detail and flat areas") {
                            ForEach(isXTrans ? Self.xtransDual : Self.bayerDual) { m in Button(m.name) { set("demosaicing_method", Double(m.value)) } }
                        }
                        Section("Special") {
                            ForEach(Self.special(xtrans: isXTrans)) { m in Button(m.name) { set("demosaicing_method", Double(m.value)) } }
                        }
                    }
                    .fixedSize()
                }
                if let method { Text(method.detail).font(.caption).foregroundStyle(.secondary) }

                // settings that apply to the chosen method (darktable's gui_changed)
                let passing = (current & 1023) == 3 || (current & 1023) == 4 || (isXTrans && (current & 1023) == 5)
                let dual = current & 2048 != 0
                if dual { field("dual_thrs", label: "Detail threshold") }
                if !isXTrans && current == 0 { field("median_thrs", label: "Median threshold") }
                if current == 6 { field("lmmse_refine", label: "Refinement") }

                Divider()
                field("cs_enabled", label: "Capture sharpening")
                if value("cs_enabled") != 0 {
                    Text("Restores fine detail lost to the lens and sensor, before anything else in the pipeline.")
                        .font(.caption).foregroundStyle(.secondary)
                    field("cs_radius", label: "Radius")
                    field("cs_thrs", label: "Threshold")
                    field("cs_boost", label: "Corner boost")
                    if value("cs_boost") != 0 { field("cs_center", label: "Corner boost centre") }
                    field("cs_iter", label: "Iterations")
                }

                if !passing {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            if !isXTrans { field("green_eq", label: "Match greens") }
                            if !dual { field("color_smoothing", label: "Colour smoothing") }
                        }
                        .padding(.top, 8)
                    }
                }
                Label("Differences between methods only show at 100% zoom: below that, darktable previews with a fast simplified demosaic.",
                      systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func field(_ name: String, label: String) -> some View {
        if let f = module.fields.first(where: { $0.name == name }) {
            FieldControl(op: module.op, field: f) { model.setValue($0, module: module.key, field: f.name) }
                .environment(\.fieldLabelOverride, label)
        }
    }
}

private struct FieldLabelOverrideKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// lets a custom card relabel a generated control
    var fieldLabelOverride: String? {
        get { self[FieldLabelOverrideKey.self] }
        set { self[FieldLabelOverrideKey.self] = newValue }
    }
}

/// Lens correction, plainly: which lens, where the correction comes from, and
/// what it corrects. darktable's own panel has many more settings (scale,
/// geometry, focal length overrides), which are left at their defaults.
struct LensControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var showPicker = false

    private func number(_ name: String) -> Double? { module.fields.first { $0.name == name }?.value.number }

    private var method: Int { Int(number("method") ?? 1) }
    private var flags: Int { Int(number("modify_flags") ?? 7) }

    /// Lensfun names fixed lenses after their cameras ("X100V & compatibles
    /// (Standard)"); without its marketing parts
    private static func tidyLensfun(_ name: String) -> String {
        name.replacingOccurrences(of: " & compatibles", with: "")
            .replacingOccurrences(of: "(Standard)", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// the lens as the photo records it; a fixed lens by its focal length and aperture
    private var lensName: String? {
        let info = model.lensInfo
        if let m = info.model { return PhotoMetadata.typesetApertures(m) }
        let lensfun = module.text?["lens"] ?? ""
        if let f = info.focal, lensfun.isEmpty || lensfun.contains("compatibles") || lensfun.lowercased().contains("fixed") {
            let ap = info.maxAperture.map { " ƒ/" + PhotoMetadata.trim(($0 * 10).rounded() / 10) } ?? ""
            return "Built-in \(PhotoMetadata.trim(f)) mm\(ap) lens"
        }
        return lensfun.isEmpty ? nil : PhotoMetadata.typesetApertures(Self.tidyLensfun(lensfun))
    }

    var body: some View {
        let lensfun = PhotoMetadata.typesetApertures(Self.tidyLensfun(module.text?["lens"] ?? ""))
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if method == 2 {
                    Text("Manual vignette only")
                } else if method == 1 {
                    // the lens name opens the profile picker, as a pop-up button does
                    Button { showPicker = true } label: {
                        HStack(spacing: 4) {
                            if let lensName { Text(lensName) } else {
                                Label("Choose a lens", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose the Lensfun profile, if the photo's lens isn't the one used")
                    .popover(isPresented: $showPicker, arrowEdge: .leading) {
                        LensfunPicker(module: module)
                    }
                } else if let lensName {
                    Text(lensName)
                } else {
                    Label("Lens not recognised", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text(method == 0 ? "Corrected with the data the camera embeds in the raw"
                     : method == 1 ? (lensfun.isEmpty || lensfun.caseInsensitiveCompare(lensName ?? "") == .orderedSame || (lensName ?? "").hasPrefix("Built-in") ? "Corrected with its Lensfun profile" : "Corrected with the Lensfun profile for \(lensfun)")
                     : "No lens profile; vignetting set by hand")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // short labels, segments sharing the card's full width
            WideSegments(options: ["Embedded", "Lensfun", "Manual"],
                         selection: Binding(get: { method }, set: { set("method", $0) }))
            .help("Embedded: the camera's own correction data, which Sony, Fujifilm, Olympus and others write into the raw; it usually matches the camera's JPEGs. Lensfun: darktable's database of measured lenses. Manual: no lens profile, a vignette set by hand.")

            if method != 2 {
                VStack(alignment: .leading, spacing: 6) {
                    toggle("Distortion", bit: 4, help: "Straightens lines bent by the lens")
                    toggle("Vignetting", bit: 2, help: "Brightens the darker corners")
                    toggle("Chromatic aberration", bit: 1, help: "Removes coloured fringes along edges (transverse chromatic aberration)")
                }
            }
            if method == 0 {
                slider("Distortion strength", field: "cor_dist_ft")
                slider("Vignetting strength", field: "cor_vig_ft")
            }
            if method == 2 {
                slider("Vignette strength", field: "v_strength", range: 0...1, defaultValue: 0)
                slider("Radius", field: "v_radius", range: 0...1, defaultValue: 0.5)
            }

            // the rest of darktable's settings for the chosen method, mostly for
            // when the camera's metadata or the lens detection is wrong
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(advancedFields) { field in
                        FieldControl(op: module.op, field: field) { model.setValue($0, module: module.key, field: field.name) }
                    }
                    if method == 1 {
                        Text("Focal length, aperture and distance come from the photo's metadata; change them only if it's wrong.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private static let advancedNames: [Int: [String]] = [
        0: ["cor_ca_r_ft", "cor_ca_b_ft", "scale_md"],
        1: ["inverse", "target_geom", "scale", "tca_override", "tca_r", "tca_b", "focal", "aperture", "distance"],
        2: ["v_steepness"],
    ]

    private var advancedFields: [EngineField] {
        let names = Self.advancedNames[method] ?? []
        let tcaOverride = (number("tca_override") ?? 0) != 0
        return names.compactMap { name in module.fields.first { $0.name == name } }
            // the manual chromatic aberration amounts only apply with the override on
            .filter { tcaOverride || ($0.name != "tca_r" && $0.name != "tca_b") }
    }

    private func toggle(_ title: String, bit: Int, help: String) -> some View {
        Toggle(title, isOn: Binding(get: { flags & bit != 0 },
                                    set: { set("modify_flags", $0 ? flags | bit : flags & ~bit) }))
            .toggleStyle(.checkbox)
            .help(help)
    }

    /// strengths as percentages: 100% is the correction as profiled
    private func slider(_ title: String, field: String, range: ClosedRange<Double> = 0...2, defaultValue: Double = 1) -> some View {
        ParamSlider(label: title, value: (number(field) ?? defaultValue) * 100, defaultValue: defaultValue * 100,
                    range: (range.lowerBound * 100)...(range.upperBound * 100), isInteger: true, unit: "%",
                    trackColors: nil, step: 5, ticks: [100]) {
            model.setValue(.number($0 / 100), module: module.key, field: field)
        }
    }

    private func set(_ field: String, _ value: Int) {
        model.setValue(.number(Double(value)), module: module.key, field: field)
    }
}

/// A segmented control that shares the full width between its segments,
/// which the standard one won't stretch to: the selected segment filled in the
/// accent colour, as the standard one draws it.
struct WideSegments: View {
    let options: [String]
    @Binding var selection: Int
    @Namespace private var fill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, title in
                let selected = i == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = i }
                } label: {
                    Text(title)
                        .foregroundStyle(selected ? Color.white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "selected", in: fill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Picks the Lensfun profile by hand, for a lens the metadata names wrongly
/// or not at all: the lenses that fit the camera, searchable by any words of
/// their name, and the camera itself if Lensfun didn't recognise it.
struct LensfunPicker: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var lenses: [Engine.LensfunLens] = []
    @State private var camera = ""
    @State private var search = ""
    @State private var cameraSearch = ""
    @State private var cameras: [Engine.LensfunCamera] = []
    @State private var tab = 0          // 0 lens, 1 camera
    @State private var loading = true

    private var current: String { module.text?["lens"] ?? "" }

    private var shown: [Engine.LensfunLens] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return lenses
            .filter { lens in
                let name = (lens.maker + " " + lens.model).lowercased()
                return words.allSatisfy { name.contains($0) }
            }
            .sorted { ($0.maker, $0.model) < ($1.maker, $1.model) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // the camera only needs choosing when Lensfun didn't recognise it
            if camera.isEmpty && !loading {
                WideSegments(options: ["Lens", "Camera"], selection: $tab)
            }
            if tab == 0 {
                TextField("Search lenses", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text(camera.isEmpty ? "Lensfun doesn't know this camera, so every lens is listed. Choose the camera to narrow them." : "Lenses that fit the \(camera)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(shown) { lens in
                    Button { model.setText(lens.model, module: module.key, field: "lens") } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(PhotoMetadata.typesetApertures(lens.model))
                                Text(lens.maker).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if lens.model == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay { if loading { ProgressView() } else if shown.isEmpty { Text("No lenses match").foregroundStyle(.secondary) } }
            } else {
                TextField("Search cameras", text: $cameraSearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await findCameras() } }
                    .onChange(of: cameraSearch) { Task { await findCameras() } }
                Text("Now: \(module.text?["camera"] ?? "none")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(cameras) { cam in
                    Button {
                        model.setText(cam.model, module: module.key, field: "camera")
                        Task { try? await Task.sleep(for: .milliseconds(400)); await loadLenses() }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(cam.maker) \(cam.model)")
                            Text([cam.mount, cam.crop > 0 ? "crop \(PhotoMetadata.trim((cam.crop * 100).rounded() / 100))×" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 340, height: 420)
        .task { await loadLenses() }
    }

    private func loadLenses() async {
        guard let engine = model.engineForPickers else { return }
        loading = true
        if let r = try? await engine.lensfunLenses() {
            camera = r.camera
            lenses = r.lenses
        }
        loading = false
    }

    private func findCameras() async {
        guard let engine = model.engineForPickers, cameraSearch.count >= 2 else { cameras = []; return }
        cameras = (try? await engine.lensfunCameras(matching: cameraSearch)) ?? []
    }
}

/// A card's menu: darktable's presets for the module (grouped where their
/// names are, as "group | name"), saving the settings as a preset, and
/// instances.
struct ModuleMenu: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    let title: String
    @State private var naming = false
    @State private var presetName = ""

    private struct Group: Identifiable { let id: String; let presets: [Engine.PresetInfo] }

    /// presets named "group | name" gather under their group
    private var groups: (loose: [Engine.PresetInfo], grouped: [Group]) {
        let all = model.presets(for: module.op)
        var loose: [Engine.PresetInfo] = []
        var grouped: [String: [Engine.PresetInfo]] = [:]
        var order: [String] = []
        for p in all {
            let parts = p.title.components(separatedBy: " | ")
            if parts.count > 1 {
                if grouped[parts[0]] == nil { order.append(parts[0]) }
                grouped[parts[0], default: []].append(p)
            } else {
                loose.append(p)
            }
        }
        return (loose, order.map { Group(id: $0, presets: grouped[$0]!) })
    }

    var body: some View {
        Menu {
            let g = groups
            if g.loose.isEmpty && g.grouped.isEmpty {
                Text("No presets")
            }
            ForEach(g.loose, id: \.name) { p in presetItem(p, label: p.title) }
            ForEach(g.grouped) { group in
                Menu(group.id.capitalizedSentence) {
                    ForEach(group.presets, id: \.name) { p in
                        presetItem(p, label: p.title.components(separatedBy: " | ").dropFirst().joined(separator: " | "))
                    }
                }
            }
            Divider()
            Button("Save as Preset…") { presetName = ""; naming = true }
            let own = model.presets(for: module.op).filter { !$0.builtin }
            if !own.isEmpty {
                Menu("Delete Preset") {
                    ForEach(own, id: \.name) { p in Button(p.title) { model.deletePreset(p) } }
                }
            }
            Divider()
            Button("New Instance") { model.newInstance(of: module.key) }
            if !module.key.hasSuffix(":0") {
                Button("Delete Instance", role: .destructive) { model.deleteInstance(module.key) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Presets and instances of \(title)")
        .alert("Save \(title) as a Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName, module: module.key) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved in Develop's darktable presets, for any photo.")
        }
    }

    private func presetItem(_ p: Engine.PresetInfo, label: String) -> some View {
        Button(label) { model.applyPreset(p, module: module.key) }
    }
}

/// darktable's local contrast in its usual (local laplacian) mode, as its own
/// interface shows it: detail, highlights and shadows as percentages.
struct LocalContrastControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var showAdvanced = false

    private func value(_ f: String) -> Double { module.fields.first { $0.name == f }?.value.number ?? 0 }
    private var laplacian: Bool { value("mode") == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brings out texture and detail by raising contrast between neighbouring tones, without changing the overall brightness, as Clarity does elsewhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if laplacian {
                slider("Detail", "detail", scale: 100, offset: 100, range: 0...300, defaultValue: 125,
                       help: "How much local contrast is added: 100% leaves the photo as it is")
                slider("Highlights", "sigma_r", scale: 100, offset: 0, range: 0...200, defaultValue: 50,
                       help: "How much the bright areas take part")
                slider("Shadows", "sigma_s", scale: 100, offset: 0, range: 0...200, defaultValue: 50,
                       help: "How much the dark areas take part")
            } else {
                slider("Detail", "detail", scale: 100, offset: 100, range: 0...300, defaultValue: 125,
                       help: "How much local contrast is added")
                slider("Coarseness", "sigma_s", scale: 1, offset: 0, range: 1...100, defaultValue: 50,
                       help: "The size of the detail affected")
                slider("Contrast", "sigma_r", scale: 1, offset: 0, range: 1...100, defaultValue: 20,
                       help: "Which tonal differences count as edges")
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if laplacian {
                        slider("Midtone range", "midtone", scale: 100, offset: 0, range: 0...100, defaultValue: 50,
                               help: "How wide a range of tones counts as midtones")
                    }
                    if let mode = module.fields.first(where: { $0.name == "mode" }) {
                        FieldControl(op: module.op, field: mode) { model.setValue($0, module: module.key, field: "mode") }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func slider(_ label: String, _ field: String, scale: Double, offset: Double, range: ClosedRange<Double>,
                        defaultValue: Double, help: String) -> some View {
        ParamSlider(label: label, value: value(field) * scale + offset, defaultValue: defaultValue, range: range,
                    isInteger: true, unit: scale == 1 ? "" : "%", trackColors: nil) {
            model.setValue(.number(($0 - offset) / scale), module: module.key, field: field)
        }
        .help(help)
    }
}

/// Rotation and perspective are set in Crop and Straighten, which keeps the
/// crop that goes with them; the card says what's set and opens it.
struct RotatePerspectiveSummary: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule

    var body: some View {
        let g = model.perspective
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Straighten", g.rotation == 0 ? "None" : String(format: "%.2f°", g.rotation))
                row("Vertical", g.vertical == 0 ? "None" : "\(Int((g.vertical * 100).rounded()))")
                row("Horizontal", g.horizontal == 0 ? "None" : "\(Int((g.horizontal * 100).rounded()))")
            }
            Button("Edit in Crop and Straighten") { model.beginCrop() }
                .help("Opens Crop and Straighten (C), where rotation and perspective are set with the crop that goes with them")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// Exposure, with darktable's technical settings out of the way: its black
/// level correction unclips negative values and isn't a Blacks slider.
struct ExposureControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var showAdvanced = false

    private func field(_ name: String) -> EngineField? { module.fields.first { $0.name == name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ev = field("exposure") {
                FieldControl(op: module.op, field: ev) { model.setValue($0, module: module.key, field: ev.name) }
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(["compensate_exposure_bias", "compensate_hilite_pres"].compactMap(field)) { f in
                        FieldControl(op: module.op, field: f) { model.setValue($0, module: module.key, field: f.name) }
                    }
                    if let black = field("black") {
                        ParamSlider(label: "Black level correction", value: black.value.number * 100, defaultValue: 0,
                                    range: -10...10, isInteger: false, unit: "%", trackColors: nil, step: 0.01) {
                            model.setValue(.number(($0 / 100 * 10000).rounded() / 10000), module: module.key, field: "black")
                        }
                        Text("Lifts the deepest values so none are negative, which can happen with noisy shadows. It isn't a Blacks slider: pushed further it makes near-black colours go wrong. To darken or lift the blacks, use the tone equaliser's Shadows or the tone mapper's black target.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}
