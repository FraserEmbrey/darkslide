import SwiftUI

/// One look for both histograms: overlapping red, green and blue areas on a
/// dark panel, square-root scaled so small peaks stay visible, over a background
/// running gently dark to light that shows what the axis means. The channels are pure
/// primaries added together, so where they coincide (a neutral or monochrome
/// photo) they read neutral grey. The HDR one adds reference lines and shades the
/// range the display can't reach.
struct HistogramChart: View {
    struct Marker: Identifiable {
        let id = UUID()
        let position: Double      // 0...1 across the chart
        let color: Color
        var dash: [CGFloat] = [3, 3]
    }

    let channels: [[Int]]         // red, green, blue
    var markers: [Marker] = []
    var shadeFrom: Double?        // shade everything right of this position
    var whiteAt: Double = 1       // where the background is lightest (reference white in HDR)
    // softened primaries; any three whose sums match add up to neutral
    private static let primaries = [Color(.sRGB, red: 0.95, green: 0.2, blue: 0.2), Color(.sRGB, red: 0.2, green: 0.95, blue: 0.2),
                                    Color(.sRGB, red: 0.2, green: 0.2, blue: 0.95)]

    var body: some View {
        Canvas { context, size in
            // a gentle dark-to-light background shows what the axis means,
            // reaching its lightest at white (reference white in HDR)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                 .init(color: .white.opacity(0.10), location: min(max(whiteAt, 0.01), 1))]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            if let shadeFrom {
                let x = size.width * shadeFrom
                context.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)),
                             with: .color(.orange.opacity(0.14)))
            }

            // ignore the end bins when scaling so clipped blacks or whites
            // don't flatten everything else
            let peak = channels.flatMap { $0.dropFirst().dropLast() }.max().map { sqrt(Double(max($0, 1))) } ?? 1
            context.blendMode = .plusLighter
            for (bins, color) in zip(channels, Self.primaries) where bins.count > 1 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, c) in bins.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                    let y = size.height * (1 - CGFloat(min(sqrt(Double(c)) / peak, 1)))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.5)))
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1)
            }

            context.blendMode = .normal
            for m in markers {
                let x = size.width * m.position
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(m.color), style: StrokeStyle(lineWidth: 1, dash: m.dash))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension HDRAnalysis {
    static func position(forStops s: Double, upTo top: Double = maxStops) -> Double {
        min(max((s - minStops) / (top - minStops), 0), 1)
    }

    /// The brightest level the export can hold, in stops: the peak limit if
    /// one is set, otherwise the format's own peak (HLG about +2.3). The
    /// chart ends a little above it, rather than at +6 for every image.
    func chartTop(limitStops: Double) -> Double {
        var top = Self.maxStops
        if let peak = target.peak { top = min(top, log2(peak)) }
        if limitStops > 0 { top = min(top, limitStops) }
        return min(top + 0.4, Self.maxStops)
    }

    /// the bins up to `top`, for drawing the shortened range
    func bins(_ channel: [Int], upTo top: Double) -> [Int] {
        let count = Int((Double(Self.binCount) * (top - Self.minStops) / (Self.maxStops - Self.minStops)).rounded(.up))
        return Array(channel.prefix(max(count, 2)))
    }

    func markers(upTo top: Double, limitStops: Double) -> [HistogramChart.Marker] {
        var m = [HistogramChart.Marker(position: Self.position(forStops: 0, upTo: top), color: .white.opacity(0.7))]
        if let peak = target.peak, log2(peak) < top {
            m.append(.init(position: Self.position(forStops: log2(peak), upTo: top), color: .cyan.opacity(0.9), dash: [1, 2]))
        }
        if limitStops > 0, limitStops < top {
            m.append(.init(position: Self.position(forStops: limitStops, upTo: top), color: .purple.opacity(0.9), dash: [4, 2]))
        }
        if displayHeadroom > 1.01, log2(displayHeadroom) < top {
            m.append(.init(position: Self.position(forStops: log2(displayHeadroom), upTo: top), color: .orange))
        }
        return m
    }

    func shadeFrom(upTo top: Double) -> Double? {
        displayHeadroom > 1.01 && log2(displayHeadroom) < top ? Self.position(forStops: log2(displayHeadroom), upTo: top) : nil
    }

    var peakText: String {
        let sign = peakStops >= 0 ? "+" : "−"
        return "\(sign)\(abs(peakStops).formatted(.number.precision(.fractionLength(1)))) stops · \(Int(peakNits.rounded())) nits"
    }
}

/// Compact histogram pinned above the inspector's tabs, so it stays in view.
struct PinnedHistogram: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.viewHDR, let a = model.hdrAnalysis {
                // only the range the export can hold: up to the peak limit or the format's peak
                let top = a.chartTop(limitStops: model.hdrLimitStops)
                HistogramChart(channels: a.channelBins.map { a.bins($0, upTo: top) },
                               markers: a.markers(upTo: top, limitStops: model.hdrLimitStops),
                               shadeFrom: a.shadeFrom(upTo: top),
                               whiteAt: HDRAnalysis.position(forStops: 0, upTo: top))
                    .frame(height: 62)
                HStack(spacing: 4) {
                    Text("Peak \(a.peakText)")
                    Text("·")
                    Text("\(a.fractionAboveSDR.formatted(.percent.precision(.fractionLength(0)))) above white")
                    if a.fractionAboveDisplay >= HDRAnalysis.beyondDisplayShown {
                        Text("·")
                        Text("\(a.fractionAboveDisplay.formatted(.percent.precision(.fractionLength(1)))) beyond display")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else if let h = model.rgbHistogram, !model.viewHDR {
                HistogramChart(channels: [h.red, h.green, h.blue])
                    .frame(height: 62)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)).frame(height: 62)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.viewHDR ? "HDR histogram" : "Histogram")
    }
}

/// Everything about the HDR result that doesn't fit under the pinned chart,
/// including the export format, which can be changed right here.
struct HDRDetailsCard: View {
    @Environment(EditorModel.self) private var model
    @State private var isExpanded = true

    private static let hdrProfiles: [(name: String, type: Int)] = [
        ("HLG P3", 25), ("HLG Rec.2020", 23), ("PQ P3", 24), ("PQ Rec.2020", 22),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "HDR", isExpanded: $isExpanded)
            if isExpanded, let a = model.hdrAnalysis {
                HStack {
                    Text("Export format")
                    Spacer()
                    Menu(a.target.isHDR ? a.target.name : "SDR") {
                        ForEach(Self.hdrProfiles, id: \.type) { p in
                            Button(p.name) { model.setOutputProfile(p.type) }
                        }
                        Divider()
                        Button("sRGB (SDR)") { model.setOutputProfile(1) }
                    }
                    .fixedSize()
                }

                if a.target.isHDR {
                    let displayStops = log2(max(model.displayHeadroom, 1))
                    HStack { Text("Limit the peak"); Spacer(); Toggle("Limit the peak", isOn: Binding(
                        get: { model.hdrLimitStops > 0 },
                        set: { model.hdrLimitStops = $0 ? 2 : 0 })).labelsHidden() }
                        .toggleStyle(.switch)
                        .help("Rolls the brightest highlights off smoothly below a set brightness. A lower peak glows rather than glares, and looks more alike on different HDR displays. Applies to the HDR view and to JPEG with HDR gain map exports.")
                    if model.hdrLimitStops > 0 {
                        ParamSlider(label: "Peak", value: model.hdrLimitStops, defaultValue: 2, range: 0.5...4,
                                    isInteger: false, unit: "stops", trackColors: nil,
                                    step: 0.5, ticks: [1, 2, 3, 4], clipping: true) { model.hdrLimitStops = max($0, 0.5) }
                    }

                    HStack { Text("Preview a dimmer display"); Spacer(); Toggle("Preview a dimmer display", isOn: Binding(
                        get: { model.previewHeadroomStops != nil },
                        set: { model.previewHeadroomStops = $0 ? 1 : nil })).labelsHidden() }
                        .toggleStyle(.switch)
                        .help("Shows what a JPEG with HDR gain map looks like on a display with less headroom. Viewers blend the SDR version and the HDR one to fit the display, so check the photo works in between.")
                    if let stops = model.previewHeadroomStops {
                        // a fixed range: the display's own headroom moves with its brightness
                        ParamSlider(label: "Display headroom", value: stops, defaultValue: 1,
                                    range: 0...4, isInteger: false, unit: "stops", trackColors: nil,
                                    step: 0.5, ticks: [1, 2, 3, 4]) { model.previewHeadroomStops = min(max($0, 0), 4) }
                        if stops > displayStops + 0.05 {
                            Label("This display can only show \(Self.stops(displayStops)) at its current brightness, so the preview stops there. Lower the screen brightness to see more.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label(stops < 0.05 ? "Showing the SDR version, as on a display without HDR."
                                               : "Many laptops and phones have 1 to 2 stops, and less when turned up bright. This display has \(Self.stops(displayStops)) right now.",
                                  systemImage: "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !a.target.isHDR {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("The output colour profile is SDR, so an export won't be HDR.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Use HLG P3") { model.setOutputProfile(25) }
                            Button("Use PQ P3") { model.setOutputProfile(24) }
                        }
                        Text("HLG suits most HDR displays and sharing; PQ is absolute and can use your display's full range.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        LegendRow(color: .white.opacity(0.7), text: "Reference white (203 nits)")
                        if let peak = a.target.peak {
                            LegendRow(color: .cyan, text: "\(a.target.name) peak (\(Int(peak * HDRTarget.referenceWhiteNits)) nits)")
                        }
                        if model.hdrLimitStops > 0 {
                            LegendRow(color: .purple, text: "Peak limit (+\(model.hdrLimitStops.formatted(.number.precision(.fractionLength(0...1)))) stops)")
                        }
                        if a.displayHeadroom > 1.01 {
                            // relative to the display's own SDR white, whose brightness varies
                            LegendRow(color: .orange, text: "Limit of this display at current brightness (+\(log2(a.displayHeadroom).formatted(.number.precision(.fractionLength(1)))) stops)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        row("Peak", a.peakText)
                        if a.unlimitedPeak > a.peak * 1.02 {
                            row("Before the limit", "+\(log2(a.unlimitedPeak).formatted(.number.precision(.fractionLength(1)))) stops")
                        }
                        row("Above reference white", percent(a.fractionAboveSDR))
                        row("Beyond this display", percent(a.fractionAboveDisplay), warn: a.fractionAboveDisplay >= HDRAnalysis.beyondDisplayShown)
                        row("Near format peak", percent(a.fractionNearPeak), warn: a.fractionNearPeak > 0.05,
                            help: "Within a third of a stop of the format's peak: highlights the tone mapper is compressing hard")
                        row("Clipped by format", percent(a.fractionClipped), warn: a.fractionClipped > 0.001)
                    }
                    .font(.callout)

                    if a.fractionAboveSDR == 0 {
                        Label("Nothing is brighter than reference white. Raise target white in your tone mapper (sigmoid or filmic) to use the HDR range.",
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, warn: Bool = false, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(warn ? .orange : .primary)
                .help(help ?? "")
        }
    }

    private func percent(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(1))) }

    static func stops(_ s: Double) -> String {
        "+\(s.formatted(.number.precision(.fractionLength(0...1)))) \(s == 1 ? "stop" : "stops")"
    }
}

private struct LegendRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 12, height: 2)
            Text(text)
        }
    }
}
