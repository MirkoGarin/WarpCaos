import SwiftUI

/// Doble clic en un .mapproj (o arrastrarlo al ícono) abre el proyecto en la ventana existente.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if url.pathExtension.lowercased() == "mapproj" { AppState.shared.load(from: url) }
        else { AppState.shared.open(url: url) }
    }
}

@main
struct WarpCaosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("WarpCaos", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 1250, minHeight: 560)
                .navigationTitle("WarpCaos — \(state.projectName)")
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuevo proyecto") { state.newProject() }
                    .keyboardShortcut("n")
                Button("Abrir proyecto…") { state.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Guardar") { state.saveProject() }
                    .keyboardShortcut("s")
                Button("Guardar como…") { state.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Abrir imagen o video…") { state.openPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("Nueva superficie") { state.addSurface() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Duplicar superficie") { state.duplicateActive() }
                    .keyboardShortcut("d")
                Button("Eliminar superficie") { state.deleteActive() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Deshacer") { state.undo() }
                    .keyboardShortcut("z")
                    .disabled(!state.canUndo)
                Button("Rehacer") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(state: state)
                .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Button("Deshacer") { state.undo() }.disabled(!state.canUndo)
                    Button("Rehacer") { state.redo() }.disabled(!state.canRedo)
                    Toggle("Overlay (H)", isOn: $state.showOverlay)
                    Button("Reset malla (R)") { state.resetMesh() }
                    Spacer()
                    CanvasMenu(state: state)
                    OutputMenu(state: state)
                    if state.outputActive {
                        Toggle("Negro", isOn: $state.blackout)
                        Toggle("Congelar", isOn: $state.freeze)
                    }
                }
                .padding(8)
                MetalView(state: state)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        state.open(url: url)
                        return true
                    }
                Text(state.status ?? "Arrastrá nodos · Shift+clic suma · arrastrá en vacío = selección · clic en una superficie la selecciona · ⌘Z deshacer · Espacio = play/pausa")
                    .font(.caption)
                    .foregroundStyle(state.status == nil ? .secondary : Color.orange)
                    .padding(6)
            }
        }
    }
}

struct CanvasMenu: View {
    @ObservedObject var state: AppState

    private static let presets: [(String, Float)] = [
        ("16:9", 16.0 / 9), ("16:10", 16.0 / 10), ("4:3", 4.0 / 3), ("21:9", 21.0 / 9), ("1:1", 1), ("9:16", 9.0 / 16),
    ]

    private var current: String {
        Self.presets.first { abs($0.1 - state.canvasAspect) < 0.005 }?.0 ?? String(format: "%.2f:1", state.canvasAspect)
    }

    var body: some View {
        Menu("Lienzo \(current)") {
            ForEach(Self.presets, id: \.0) { p in
                Button(p.0) { state.setCanvasAspect(p.1) }
            }
        }
        .frame(width: 130)
        .help("Proporción del lienzo. Al proyectar en una pantalla se ajusta a la de esa pantalla.")
    }
}

struct OutputMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Menu(state.outputActive ? "Salida: activa" : "Salida") {
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, s in
                Button("Proyectar en pantalla \(i + 1): \(s.localizedName) (\(Int(s.frame.width))×\(Int(s.frame.height)))") {
                    state.startOutput(on: s)
                }
            }
            Button("Ventana de prueba") { state.startOutput(on: nil) }
            if state.outputActive {
                Divider()
                Button("Detener salida (Esc en la salida)") { state.stopOutput() }
            }
        }
        .frame(width: 130)
    }
}

/// Rotar (±90° y ángulo libre) y voltear (H/V) el contenido o la forma de la superficie activa.
struct TransformControls: View {
    @ObservedObject var state: AppState
    let title: String
    let target: AppState.TransformTarget
    let angle: Float
    let flipH: Bool
    let flipV: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                Button { state.rotate(target, by: -90) } label: { Image(systemName: "rotate.left") }
                    .help("Girar 90° a la izquierda")
                Button { state.rotate(target, by: 90) } label: { Image(systemName: "rotate.right") }
                    .help("Girar 90° a la derecha")
                Toggle(isOn: Binding(get: { flipH }, set: { _ in state.flip(target, horizontal: true) })) {
                    Image(systemName: "arrow.left.and.right")
                }
                .toggleStyle(.button).help("Voltear horizontalmente")
                Toggle(isOn: Binding(get: { flipV }, set: { _ in state.flip(target, horizontal: false) })) {
                    Image(systemName: "arrow.up.and.down")
                }
                .toggleStyle(.button).help("Voltear verticalmente")
                Button { state.resetTransform(target) } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Restablecer")
                    .disabled(angle == 0 && !flipH && !flipV)
            }
            .buttonStyle(.borderless)
            HStack {
                Slider(value: Binding(get: { Double(angle) }, set: { state.setAngle(target, Float($0)) }), in: -180...180)
                Text("\(Int(angle.rounded()))°").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Superficies").font(.headline)
                Spacer()
                Menu {
                    ForEach(ShapeKind.allCases) { k in
                        Button(k.rawValue) { state.addSurface(shape: k) }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .help("Nueva superficie (elegí la forma)")
                Button { state.duplicateActive() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicar")
                Button { state.moveActive(1) } label: { Image(systemName: "arrow.up") }
                    .help("Subir capa")
                Button { state.moveActive(-1) } label: { Image(systemName: "arrow.down") }
                    .help("Bajar capa")
                Button { state.deleteActive() } label: { Image(systemName: "trash") }
                    .help("Eliminar")
                    .disabled(state.surfaces.count < 2)
            }
            .buttonStyle(.borderless)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.surfaces.reversed()) { s in
                        SurfaceRow(state: state, surface: s)
                    }
                }
            }
            .frame(maxHeight: 150)

            Divider()
            ScrollView {
                if let s = state.active {
                    InspectorView(state: state, surface: s)
                }
            }
        }
        .padding(10)
    }
}

struct SurfaceRow: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        let selected = surface.id == state.selectedID
        HStack(spacing: 8) {
            Button { state.toggleVisible(surface.id) } label: {
                Image(systemName: surface.visible ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(surface.name).lineLimit(1)
                Text(surface.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { state.select(surface.id) }
        .opacity(surface.visible ? 1 : 0.5)
    }
}

struct InspectorView: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Propiedades").font(.headline)

            TextField("Nombre", text: Binding(get: { surface.name }, set: { state.rename($0) }))
                .textFieldStyle(.roundedBorder)

            Menu {
                ForEach(Pattern.allCases) { p in
                    Button(p.rawValue) { state.useCalibration(p) }
                }
                Divider()
                Button("Abrir imagen o video…") { state.openPanel() }
            } label: {
                Text(surface.source.displayName).lineLimit(1)
            }

            Picker("Forma", selection: Binding(get: { surface.shape }, set: { state.setShape($0) })) {
                ForEach(ShapeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            if surface.shape != .rectangle {
                HStack {
                    Text("Borde suave")
                    Slider(value: Binding(get: { Double(surface.shapeFeather) },
                                          set: { state.setShapeFeather(Float($0)) }), in: 0...0.5)
                }
            }
            Picker("Ajuste", selection: Binding(get: { surface.fit }, set: { state.setFit($0) })) {
                Text("Estirar").tag(FitMode.stretch)
                Text("Cubrir").tag(FitMode.cover)
            }
            .pickerStyle(.segmented)

            TransformControls(state: state, title: "Contenido", target: .content, angle: surface.contentRotation,
                              flipH: surface.contentFlipH, flipV: surface.contentFlipV)
            if surface.shape != .rectangle {
                TransformControls(state: state, title: "Forma", target: .shape, angle: surface.shapeRotation,
                                  flipH: surface.shapeFlipH, flipV: surface.shapeFlipV)
            }

            if surface.isVideo {
                HStack {
                    Button(surface.playing ? "Pausa" : "Play") { state.setPlaying(!surface.playing) }
                    Toggle("Silencio", isOn: Binding(get: { surface.muted }, set: { state.setMuted($0) }))
                }
            }

            HStack {
                Text("Opacidad")
                Slider(value: Binding(get: { Double(surface.opacity) }, set: { state.setOpacity(Float($0)) }), in: 0...1)
            }

            Stepper("Columnas \(surface.cols)", value: Binding(
                get: { surface.cols }, set: { state.setGrid(cols: $0, rows: surface.rows) }), in: 2...16)
            Stepper("Filas \(surface.rows)", value: Binding(
                get: { surface.rows }, set: { state.setGrid(cols: surface.cols, rows: $0) }), in: 2...16)

            Picker("", selection: Binding(get: { surface.smooth }, set: { state.setSmooth($0) })) {
                Text("Lineal").tag(false)
                Text("Suave").tag(true)
            }
            .pickerStyle(.segmented)

            Divider()
            MasksView(state: state, surface: surface)
        }
    }
}

struct MasksView: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    private var selected: Mask? { surface.masks.first { $0.id == state.selectedMaskID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Máscaras").font(.headline)
                Spacer()
                if state.selectedMaskID != nil {
                    Button("Volver a malla") { state.selectMask(nil) }
                }
                Button { state.addMask() } label: { Image(systemName: "plus") }
                    .help("Nueva máscara poligonal")
            }
            .buttonStyle(.borderless)

            ForEach(surface.masks) { m in
                HStack {
                    Image(systemName: m.hides ? "circle.slash" : "circle.dashed")
                    Text(m.name).lineLimit(1)
                    Spacer()
                    Button { state.deleteMask(m.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(m.id == state.selectedMaskID ? Color.green.opacity(0.3) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { state.selectMask(m.id) }
            }

            if let m = selected {
                TextField("Nombre", text: Binding(get: { m.name }, set: { state.renameMask($0) }))
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: Binding(get: { m.hides }, set: { state.setMaskHides($0) })) {
                    Text("Mostrar").tag(false)
                    Text("Ocultar").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Invertir", isOn: Binding(get: { m.inverted }, set: { state.setMaskInverted($0) }))
                HStack {
                    Text("Feather")
                    Slider(value: Binding(get: { Double(m.feather) }, set: { state.setMaskFeather(Float($0)) }), in: 0...120)
                    Text("\(Int(m.feather))").monospacedDigit().frame(width: 28)
                }
                Text("Doble clic en una arista = nuevo vértice · Delete = borra vértices seleccionados · clic dentro = mover")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if surface.masks.isEmpty {
                Text("Sin máscaras. «+» crea un polígono sobre la superficie.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
