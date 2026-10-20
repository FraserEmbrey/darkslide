import AppKit
import SwiftUI

/// Full screen editing, as Aperture's: the photo on black filling the screen,
/// the adjustments in a floating HUD that can be dragged anywhere (H shows and
/// hides it), the filmstrip sliding up from the bottom edge and a bar of
/// controls down from the top. F goes in and out; Escape comes out.
struct FullScreenEditor: View {
    @Environment(EditorModel.self) private var model
    @State private var pointer: CGPoint?
    @AppStorage("HUDOffsetX") private var hudX = 0.0
    @AppStorage("HUDOffsetY") private var hudY = 0.0
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                CanvasView()
                    .padding(.vertical, 8)

                // the bar of controls, from the top edge
                VStack {
                    if showsTop(in: geo.size) { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                    Spacer()
                    if showsFilmstrip(in: geo.size) {
                        Filmstrip()
                            .frame(height: 90)
                            .background(.black.opacity(0.75))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if model.showHUD { hud(in: geo.size) }
            }
            .animation(.easeOut(duration: 0.18), value: showsTop(in: geo.size))
            .animation(.easeOut(duration: 0.18), value: showsFilmstrip(in: geo.size))
            .onContinuousHover { phase in
                if case .active(let p) = phase { pointer = p } else { pointer = nil }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func showsTop(in size: CGSize) -> Bool { (pointer?.y ?? .infinity) < 60 }
    private func showsFilmstrip(in size: CGSize) -> Bool {
        model.library.items.count > 1 && (pointer.map { $0.y > size.height - 110 } ?? false)
    }

    private var topBar: some View {
        @Bindable var model = model
        return HStack(spacing: 14) {
            Text(model.url.map { LibraryItem(url: $0, hasEdit: false, version: $0.versionNumber).name } ?? "")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Picker("Preview", selection: $model.viewHDR) {
                Text("SDR").tag(false)
                Text("HDR").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("Loupe", systemImage: "magnifyingglass.circle", isOn: $model.showLoupe)
                .help("The loupe (`)")
            Toggle("Compare", systemImage: "square.split.2x1", isOn: $model.comparing)
                .help("Compare with the photo as it was when opened (⇧⌘B)")
            Toggle("Adjustments", systemImage: "slider.horizontal.3", isOn: $model.showHUD)
                .help("The adjustments HUD (H)")
            Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") { model.isFullScreenEditor = false }
                .help("Back to the window (F or Escape)")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    /// the adjustments in a floating panel, dragged by its title
    private func hud(in size: CGSize) -> some View {
        let height = min(size.height - 80, 820)
        return VStack(spacing: 0) {
            HStack {
                Text("Adjustments").font(.headline)
                Spacer()
                Button { model.showHUD = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide the HUD (H)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { g in
                    if dragStart == nil { dragStart = CGSize(width: hudX, height: hudY) }
                    hudX = dragStart!.width + g.translation.width
                    hudY = dragStart!.height + g.translation.height
                }
                .onEnded { _ in dragStart = nil })
            Divider()
            InspectorView()
        }
        .frame(width: 340, height: height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        // to the right to start with, kept on the screen wherever it's dragged
        .position(x: min(max(size.width - 200 + hudX, 180), size.width - 180),
                  y: min(max(size.height / 2 + hudY, height / 2 + 20), size.height - height / 2 - 20))
    }
}

/// Puts the window into macOS full screen when the editor goes full screen
/// and back, and follows the window out if it leaves full screen another way.
struct FullScreenWindowSync: ViewModifier {
    @Environment(EditorModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isFullScreenEditor) { _, on in
                guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                // macOS takes only the active app into full screen
                if on { NSApp.activate() }
                if window.styleMask.contains(.fullScreen) != on { window.toggleFullScreen(nil) }
            }
            // the library has its own window layout
            .onChange(of: model.showingLibrary) { _, library in if library { model.isFullScreenEditor = false } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                if model.isFullScreenEditor { model.isFullScreenEditor = false }
            }
    }
}
