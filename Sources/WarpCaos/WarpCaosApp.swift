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
                .frame(minWidth: 1280, minHeight: 600)
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
                Button("Abrir URL…") { state.openURLPanel() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Nueva superficie") { state.addSurface() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Duplicar superficie") { state.duplicateActive() }
                    .keyboardShortcut("d")
                Button("Eliminar superficie") { state.deleteActive() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Detener salida") { state.stopOutput() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!state.outputActive)
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
                .frame(width: 290)
            Divider()
            VStack(spacing: 0) {
                MetalView(state: state)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !urls.isEmpty else { return false }
                        state.openMany(urls)
                        return true
                    }
                Text(state.status ?? "Arrastrá nodos · Shift+clic suma · arrastrá en vacío = selección · clic en una superficie la selecciona · ⌘Z deshacer · Espacio = play/pausa")
                    .font(.caption)
                    .foregroundStyle(state.status == nil ? .secondary : Color.orange)
                    .padding(6)
                    .help("Mensajes y ayuda rápida")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { state.undo() } label: { Label("Deshacer", systemImage: "arrow.uturn.backward") }
                    .disabled(!state.canUndo)
                    .help("Deshacer el último cambio (⌘Z)")
                Button { state.redo() } label: { Label("Rehacer", systemImage: "arrow.uturn.forward") }
                    .disabled(!state.canRedo)
                    .help("Rehacer lo que se deshizo (⇧⌘Z)")
            }
            ToolbarItemGroup(placement: .automatic) {
                Toggle(isOn: $state.showOverlay) {
                    Label("Guías", systemImage: "scope").labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .help("Mostrar u ocultar las guías de edición: nodos, malla y contornos (H). No se ven en la salida.")
                Button { state.resetMesh() } label: {
                    Label("Reset malla", systemImage: "arrow.counterclockwise").labelStyle(.titleAndIcon)
                }
                .help("Devolver la malla de la superficie activa a su forma inicial (R)")

                CanvasMenu(state: state)
                OutputMenu(state: state)
                if state.outputActive {
                    Toggle(isOn: $state.blackout) {
                        Label("Negro", systemImage: "moon.fill").labelStyle(.titleAndIcon)
                    }
                    .toggleStyle(.button)
                    .help("Pantalla de salida en negro (el proyector no emite imagen)")
                    Toggle(isOn: $state.freeze) {
                        Label("Congelar", systemImage: "snowflake").labelStyle(.titleAndIcon)
                    }
                    .toggleStyle(.button)
                    .help("Dejar fija la última imagen en la salida")
                }
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
        Menu {
            ForEach(Self.presets, id: \.0) { p in
                Button(p.0) { state.setCanvasAspect(p.1) }
            }
        } label: {
            Label("Lienzo \(current)", systemImage: "aspectratio").labelStyle(.titleAndIcon)
        }
        .help("Proporción del lienzo. Al proyectar en una pantalla se ajusta a la de esa pantalla.")
    }
}

struct OutputMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Menu {
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
        } label: {
            Label(state.outputActive ? "Salida activa" : "Salida", systemImage: state.outputActive ? "play.display" : "display")
                .labelStyle(.titleAndIcon)
        }
        .help("Enviar la imagen al proyector (pantalla completa) o abrir una ventana de prueba")
    }
}

// MARK: - Componentes del panel

/// Sección plegable del panel de propiedades. Recuerda si estaba abierta o cerrada.
struct PanelSection<Content: View>: View {
    let title: String
    let icon: String
    @AppStorage private var expanded: Bool
    private let content: Content

    init(_ title: String, icon: String, key: String, expanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        _expanded = AppStorage(wrappedValue: expanded, "panel.\(key)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold)).frame(width: 10)
                    Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Ocultar la sección «\(title)»" : "Mostrar la sección «\(title)»")

            if expanded {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.leading, 16)
            }
            Divider()
        }
    }
}

/// Fila «etiqueta + control» con la etiqueta alineada a la izquierda.
struct FieldRow<Control: View>: View {
    let label: String
    private let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            control
        }
    }
}

/// Deslizador con su valor a la derecha.
struct ValueSlider: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range)
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// Contador numérico (− / +) con su valor visible.
struct NumberStepper: View {
    let value: Binding<Int>
    let range: ClosedRange<Int>
    var unit = ""

    var body: some View {
        HStack(spacing: 6) {
            Text("\(value.wrappedValue)\(unit)").monospacedDigit().frame(minWidth: 34, alignment: .trailing)
            Stepper("", value: value, in: range).labelsHidden()
            Spacer(minLength: 0)
        }
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

    private var what: String { target == .content ? "el contenido" : "la forma" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldRow("Orientación") {
                HStack(spacing: 8) {
                    Button { state.rotate(target, by: -90) } label: { Image(systemName: "rotate.left") }
                        .help("Girar \(what) 90° a la izquierda")
                    Button { state.rotate(target, by: 90) } label: { Image(systemName: "rotate.right") }
                        .help("Girar \(what) 90° a la derecha")
                    Toggle(isOn: Binding(get: { flipH }, set: { _ in state.flip(target, horizontal: true) })) {
                        Image(systemName: "arrow.left.and.right")
                    }
                    .toggleStyle(.button).help("Voltear \(what) horizontalmente (espejo izquierda-derecha)")
                    .accessibilityLabel("Voltear horizontalmente")
                    Toggle(isOn: Binding(get: { flipV }, set: { _ in state.flip(target, horizontal: false) })) {
                        Image(systemName: "arrow.up.and.down")
                    }
                    .toggleStyle(.button).help("Voltear \(what) verticalmente (espejo arriba-abajo)")
                    .accessibilityLabel("Voltear verticalmente")
                    Button { state.resetTransform(target) } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Quitar la rotación y el volteo de \(what)")
                        .disabled(angle == 0 && !flipH && !flipV)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
            }
            FieldRow("Ángulo") {
                ValueSlider(value: Binding(get: { Double(angle) }, set: { state.setAngle(target, Float($0)) }),
                            range: -180...180, text: "\(Int(angle.rounded()))°")
                    .help("Rotación de \(what) en grados, sentido horario")
            }
        }
    }
}

// MARK: - Panel lateral

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Superficies", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Menu {
                    ForEach(ShapeKind.allCases) { k in
                        Button(k.rawValue) { state.addSurface(shape: k) }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                    .help("Nueva superficie (elegí su forma) · ⇧⌘N")
                Button { state.duplicateActive() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicar la superficie activa · ⌘D")
                Button { state.moveActive(1) } label: { Image(systemName: "arrow.up") }
                    .help("Subir la capa: se dibuja por encima de las demás")
                Button { state.moveActive(-1) } label: { Image(systemName: "arrow.down") }
                    .help("Bajar la capa: se dibuja por debajo de las demás")
                Button { state.deleteActive() } label: { Image(systemName: "trash") }
                    .help("Eliminar la superficie activa · ⌘⌫")
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
                        .padding(.trailing, 6)
                }
            }
        }
        .padding(12)
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
            .help(surface.visible ? "Ocultar esta superficie" : "Mostrar esta superficie")
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
        .help("Clic para seleccionar y editar esta superficie")
    }
}

struct InspectorView: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldRow("Nombre") {
                TextField("Nombre", text: Binding(get: { surface.name }, set: { state.rename($0) }))
                    .textFieldStyle(.roundedBorder)
                    .help("Nombre de la superficie")
            }
            Divider()

            PanelSection("Contenido", icon: "photo.on.rectangle", key: "content") { ContentSection(state: state, surface: surface) }
            PanelSection("Forma", icon: "hexagon", key: "shape") { ShapeSection(state: state, surface: surface) }
            PanelSection("Malla", icon: "grid", key: "mesh") { MeshSection(state: state, surface: surface) }
            PanelSection("Capa", icon: "circle.lefthalf.filled", key: "layer") { LayerSection(state: state, surface: surface) }
            PanelSection("Máscaras", icon: "circle.dashed", key: "masks") { MasksView(state: state, surface: surface) }
        }
    }
}

struct ContentSection: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        FieldRow("Fuente") {
            Menu {
                ForEach(Pattern.allCases) { p in
                    Button(p.rawValue) { state.useCalibration(p) }
                }
                Divider()
                Button("Abrir imagen o video…") { state.openPanel() }
                Button("Abrir URL…") { state.openURLPanel() }
            } label: {
                Text(surface.source.displayName).lineLimit(1)
            }
            .help("Qué se muestra en la superficie: un patrón de calibración, una imagen, un video o una URL. Reemplaza toda la lista de reproducción.")
        }

        PlaylistView(state: state, surface: surface)

        FieldRow("Ajuste") {
            Picker("", selection: Binding(get: { surface.fit }, set: { state.setFit($0) })) {
                Text("Estirar").tag(FitMode.stretch)
                Text("Cubrir").tag(FitMode.cover)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Estirar: el contenido llena toda la forma (puede deformarse). Cubrir: conserva su proporción y recorta lo que sobra.")
        }

        TransformControls(state: state, title: "Contenido", target: .content, angle: surface.contentRotation,
                          flipH: surface.contentFlipH, flipV: surface.contentFlipV)

        if surface.isVideo {
            FieldRow("Video") {
                HStack(spacing: 10) {
                    Button { state.setPlaying(!surface.playing) } label: {
                        Image(systemName: surface.playing ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .help(surface.playing ? "Pausar el video (Espacio)" : "Reanudar el video (Espacio)")
                    .accessibilityLabel(surface.playing ? "Pausar el video" : "Reanudar el video")
                    Toggle(isOn: Binding(get: { surface.muted }, set: { state.setMuted($0) })) {
                        Image(systemName: surface.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                    }
                    .toggleStyle(.button)
                    .help(surface.muted ? "Activar el audio del video" : "Silenciar el audio del video")
                    .accessibilityLabel(surface.muted ? "Activar el audio" : "Silenciar el audio")
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct ShapeSection: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        FieldRow("Forma") {
            Picker("", selection: Binding(get: { surface.shape }, set: { state.setShape($0) })) {
                ForEach(ShapeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help("Forma de la superficie dentro de su cuadrilátero de 4 esquinas. Se edita moviendo las esquinas.")
        }
        if surface.shape != .rectangle {
            FieldRow("Borde suave") {
                ValueSlider(value: Binding(get: { Double(surface.shapeFeather) }, set: { state.setShapeFeather(Float($0)) }),
                            range: 0...0.5, text: String(format: "%.2f", surface.shapeFeather))
                    .help("Difumina el borde de la forma")
            }
            TransformControls(state: state, title: "Forma", target: .shape, angle: surface.shapeRotation,
                              flipH: surface.shapeFlipH, flipV: surface.shapeFlipV)
        } else {
            Text("Rectángulo: sin recorte. Elegí otra forma para recortar el contenido.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct MeshSection: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        FieldRow("Columnas") {
            NumberStepper(value: Binding(get: { surface.cols }, set: { state.setGrid(cols: $0, rows: surface.rows) }), range: 2...16)
                .help("Nodos de la malla en horizontal (de 2 a 16). Con 2×2 es un Quad Warp de 4 esquinas.")
        }
        FieldRow("Filas") {
            NumberStepper(value: Binding(get: { surface.rows }, set: { state.setGrid(cols: surface.cols, rows: $0) }), range: 2...16)
                .help("Nodos de la malla en vertical (de 2 a 16)")
        }
        FieldRow("Curvas") {
            Picker("", selection: Binding(get: { surface.smooth }, set: { state.setSmooth($0) })) {
                Text("Lineal").tag(false)
                Text("Suave").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Cómo se une la malla entre nodos: Lineal (tramos rectos) o Suave (curvas)")
        }
    }
}

struct LayerSection: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    var body: some View {
        FieldRow("Opacidad") {
            ValueSlider(value: Binding(get: { Double(surface.opacity) }, set: { state.setOpacity(Float($0)) }),
                        range: 0...1, text: "\(Int((surface.opacity * 100).rounded()))%")
                .help("Transparencia de la superficie: 0 % no se ve, 100 % es opaca")
        }
    }
}

/// Lista de reproducción de la superficie: varios contenidos que se suceden con fundido.
struct PlaylistView: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    /// 75 → «1:15»; 3725 → «1:02:05».
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var body: some View {
        let items = surface.items
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(items.count > 1 ? "Lista de reproducción (\(items.count))" : "Lista de reproducción")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Archivos…") { state.addItemFilesPanel() }
                    Button("URL…") { state.openURLPanel(append: true) }
                    Divider()
                    ForEach(Pattern.allCases) { p in
                        Button("Patrón: \(p.rawValue)") { state.addItemPatterns(p) }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                    .help("Agregar contenido a la lista (archivos, una URL o un patrón). Con varios contenidos pasan de a uno, con fundido.")
            }

            if items.count > 1 {
                itemList(items)
                options
            } else {
                Text("Con un solo contenido se repite sin fin. Agregá más con «+» para armar una lista con fundido.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func itemList(_ items: [Source]) -> some View {
        let info = state.playback[surface.id]
        return VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, src in
                let isCurrent = info?.index == idx
                HStack(spacing: 4) {
                    if isCurrent {
                        Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor).frame(width: 16)
                    } else {
                        Text("\(idx + 1)").font(.caption2).foregroundStyle(.secondary).frame(width: 16)
                    }
                    Text(src.displayName).font(.caption).lineLimit(1)
                        .fontWeight(isCurrent ? .semibold : .regular)
                    Spacer()
                    if isCurrent {
                        Text(info?.remaining.map(Self.clock) ?? "…")
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                            .help("Tiempo que le queda a este contenido")
                    }
                    Button { state.moveItem(at: idx, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(idx == 0).help("Subir en la lista").accessibilityLabel("Subir en la lista")
                    Button { state.moveItem(at: idx, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(idx == items.count - 1).help("Bajar en la lista").accessibilityLabel("Bajar en la lista")
                    Button { state.removeItem(at: idx) } label: { Image(systemName: "xmark") }
                        .help("Quitar de la lista")
                        .accessibilityLabel("Quitar de la lista")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var options: some View {
        Picker("", selection: Binding(get: { surface.playlistMode }, set: { state.setPlaylistMode($0) })) {
            Text("Por repeticiones").tag(PlaylistMode.loops)
            Text("Por tiempo").tag(PlaylistMode.time)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Cómo se decide cuánto dura cada contenido: repitiendo cada video N veces, o con un tiempo fijo para todos")

        if surface.playlistMode == .loops {
            FieldRow("Repetir") {
                NumberStepper(value: Binding(get: { surface.playlistLoops }, set: { state.setPlaylistLoops($0) }),
                              range: 1...99, unit: surface.playlistLoops == 1 ? " vez" : " veces")
                    .help("Veces que se repite cada video antes de pasar al siguiente")
            }
            FieldRow("Imágenes") {
                NumberStepper(value: Binding(get: { Int(surface.playlistStillSeconds) }, set: { state.setPlaylistStillSeconds($0) }),
                              range: 1...600, unit: " s")
                    .help("Segundos que se muestra cada imagen o patrón")
            }
        } else {
            FieldRow("Duración") {
                NumberStepper(value: Binding(get: { Int(surface.playlistSeconds) }, set: { state.setPlaylistSeconds($0) }),
                              range: 1...3600, unit: " s")
                    .help("Cuánto dura cada contenido. Los videos más cortos se repiten hasta completar el tiempo; los más largos se cortan.")
            }
            Text("Los videos más cortos se repiten; los más largos se cortan. El tiempo incluye el fundido.")
                .font(.caption2).foregroundStyle(.secondary)
        }

        FieldRow("Fundido") {
            ValueSlider(value: Binding(get: { Double(surface.playlistFade) }, set: { state.setPlaylistFade(Float($0)) }),
                        range: 0...3, text: surface.playlistFade < 0.05 ? "corte" : String(format: "%.1f s", surface.playlistFade))
                .help("Duración del fundido entre un contenido y el siguiente. En 0 es un corte directo.")
        }
        FieldRow("Orden") {
            Toggle("Aleatorio", isOn: Binding(get: { surface.playlistShuffle }, set: { state.setPlaylistShuffle($0) }))
                .help("Orden aleatorio, sin repetir el mismo contenido dos veces seguidas")
        }
    }
}

struct MasksView: View {
    @ObservedObject var state: AppState
    let surface: SurfaceModel

    private var selected: Mask? { surface.masks.first { $0.id == state.selectedMaskID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(surface.masks.isEmpty ? "Sin máscaras" : "\(surface.masks.count) máscara(s)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if state.selectedMaskID != nil {
                    Button("Volver a malla") { state.selectMask(nil) }
                        .help("Dejar de editar la máscara y volver a editar la malla")
                }
                Button { state.addMask() } label: { Image(systemName: "plus") }
                    .help("Nueva máscara poligonal sobre la superficie")
            }
            .buttonStyle(.borderless)

            ForEach(surface.masks) { m in
                HStack {
                    Image(systemName: m.hides ? "circle.slash" : "circle.dashed")
                    Text(m.name).lineLimit(1)
                    Spacer()
                    Button { state.deleteMask(m.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Eliminar esta máscara")
                        .accessibilityLabel("Eliminar esta máscara")
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(m.id == state.selectedMaskID ? Color.green.opacity(0.3) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { state.selectMask(m.id) }
                .help("Clic para editar los vértices de esta máscara en el lienzo")
            }

            if let m = selected {
                FieldRow("Nombre") {
                    TextField("Nombre", text: Binding(get: { m.name }, set: { state.renameMask($0) }))
                        .textFieldStyle(.roundedBorder)
                        .help("Nombre de la máscara")
                }
                FieldRow("Modo") {
                    Picker("", selection: Binding(get: { m.hides }, set: { state.setMaskHides($0) })) {
                        Text("Mostrar").tag(false)
                        Text("Ocultar").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Mostrar: el contenido se ve solo dentro de la máscara. Ocultar: se recorta lo que está adentro.")
                }
                FieldRow("Invertir") {
                    Toggle("", isOn: Binding(get: { m.inverted }, set: { state.setMaskInverted($0) }))
                        .labelsHidden()
                        .help("Invierte el área de la máscara: lo de adentro pasa a afuera")
                    Spacer(minLength: 0)
                }
                FieldRow("Borde suave") {
                    ValueSlider(value: Binding(get: { Double(m.feather) }, set: { state.setMaskFeather(Float($0)) }),
                                range: 0...120, text: "\(Int(m.feather))")
                        .help("Difumina el borde de la máscara (en puntos)")
                }
                Text("Doble clic en una arista = nuevo vértice · Delete = borra vértices seleccionados · clic dentro = mover")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if surface.masks.isEmpty {
                Text("«+» crea un polígono sobre la superficie para mostrar u ocultar partes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
