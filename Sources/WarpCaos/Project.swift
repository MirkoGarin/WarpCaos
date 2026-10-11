import SwiftUI
import Combine
import UniformTypeIdentifiers

extension CodingUserInfoKey {
    static let projectDir = CodingUserInfoKey(rawValue: "projectDir")!
}

/// Las rutas de media se guardan absolutas y relativas a la carpeta del proyecto,
/// para poder mover proyecto + media juntos a otra máquina.
extension Source: Codable {
    private enum CodingKeys: String, CodingKey { case pattern, path, relative, url, page }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try c.decodeIfPresent(Pattern.self, forKey: .pattern) {
            self = .pattern(p)
            return
        }
        if let page = try c.decodeIfPresent(URL.self, forKey: .page) {
            self = .page(page)
            return
        }
        if let remote = try c.decodeIfPresent(URL.self, forKey: .url) {
            self = .url(remote)
            return
        }
        let path = try c.decode(String.self, forKey: .path)
        var url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path),
           let rel = try c.decodeIfPresent(String.self, forKey: .relative),
           let dir = decoder.userInfo[.projectDir] as? URL {
            let alt = URL(fileURLWithPath: rel, relativeTo: dir).standardizedFileURL
            if FileManager.default.fileExists(atPath: alt.path) { url = alt }
        }
        self = .file(url)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pattern(let p):
            try c.encode(p, forKey: .pattern)
        case .page(let url):
            try c.encode(url, forKey: .page)
        case .url(let url):
            try c.encode(url, forKey: .url)
        case .file(let url):
            try c.encode(url.path, forKey: .path)
            if let dir = encoder.userInfo[.projectDir] as? URL {
                try c.encode(Self.relativePath(from: dir, to: url), forKey: .relative)
            }
        }
    }

    private static func relativePath(from dir: URL, to file: URL) -> String {
        let d = dir.standardizedFileURL.pathComponents, f = file.standardizedFileURL.pathComponents
        var i = 0
        while i < d.count, i < f.count, d[i] == f[i] { i += 1 }
        return (Array(repeating: "..", count: d.count - i) + f[i...]).joined(separator: "/")
    }
}

struct ProjectFile: Codable {
    var version = 1
    var canvasAspect: Float
    var surfaces: [SurfaceModel]
}

extension AppState {
    static let projectType = UTType(filenameExtension: "mapproj", conformingTo: .json) ?? .json

    static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WarpCaos/autosave.mapproj")
    }

    var projectName: String { projectURL?.deletingPathExtension().lastPathComponent ?? "Sin título" }

    // MARK: Serialización

    func projectData(baseDir: URL?) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let baseDir { enc.userInfo[.projectDir] = baseDir }
        return try enc.encode(ProjectFile(canvasAspect: canvasAspect, surfaces: surfaces))
    }

    private func apply(_ data: Data, baseDir: URL?) throws {
        let dec = JSONDecoder()
        if let baseDir { dec.userInfo[.projectDir] = baseDir }
        let file = try dec.decode(ProjectFile.self, from: data)
        guard !file.surfaces.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        registerUndo()
        canvasAspect = file.canvasAspect
        surfaces = file.surfaces
        selectedID = file.surfaces.first?.id
        selectedMaskID = nil
        selection = []
        surfaceCounter = file.surfaces.count
    }

    // MARK: Guardar / abrir

    func save(to url: URL) {
        do {
            try projectData(baseDir: url.deletingLastPathComponent()).write(to: url, options: .atomic)
            projectURL = url
            status = "Proyecto guardado: \(url.lastPathComponent)"
        } catch {
            status = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    func saveProject() {
        if let url = projectURL { save(to: url) } else { saveProjectAs() }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "\(projectName).mapproj"
        panel.message = "Guardar proyecto de WarpCaos"
        if panel.runModal() == .OK, let url = panel.url { save(to: url) }
    }

    func load(from url: URL) {
        do {
            try apply(Data(contentsOf: url), baseDir: url.deletingLastPathComponent())
            projectURL = url
            status = "Proyecto abierto: \(url.lastPathComponent)"
        } catch {
            status = "No se pudo abrir el proyecto: \(error.localizedDescription)"
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.allowsMultipleSelection = false
        panel.message = "Abrir proyecto de WarpCaos"
        if panel.runModal() == .OK, let url = panel.url { load(from: url) }
    }

    func newProject() {
        registerUndo()
        surfaceCounter = 0
        var s = SurfaceModel(id: UUID(), name: "Superficie 1")
        surfaceCounter = 1
        s.cols = 4; s.rows = 4
        surfaces = [s]
        selectedID = s.id
        selectedMaskID = nil
        selection = []
        projectURL = nil
    }

    // MARK: Autosave / opciones de entorno (pruebas)

    /// Guarda una copia de recuperación 2 s después del último cambio y la restaura al abrir.
    func configurePersistence(env: [String: String], demo: String?) {
        let testing = demo != nil || env["WARPCAOS_FILE"] != nil || env["WARPCAOS_URL"] != nil || env["WARPCAOS_PLAYLIST"] != nil
        if let path = env["WARPCAOS_PROJECT"] {
            load(from: URL(fileURLWithPath: path))
        } else if !testing, let data = try? Data(contentsOf: Self.autosaveURL) {
            try? apply(data, baseDir: nil)
            undoReset()
            status = "Se restauró la copia automática del último trabajo"
        }

        if let path = env["WARPCAOS_SAVE_TO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.save(to: URL(fileURLWithPath: path)) }
        }
        if let mode = env["WARPCAOS_OUTPUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.startOutput(on: mode == "screen" ? NSScreen.screens.last : nil)
            }
        }

        guard !testing else { return }
        autosaveCancellable = Publishers.Merge($surfaces.map { _ in () }, $canvasAspect.map { _ in () })
            .dropFirst(2)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.autosave() }
    }

    private func autosave() {
        let url = Self.autosaveURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        Self.backupPreviousAutosave(url)
        if let data = try? projectData(baseDir: nil) { try? data.write(to: url, options: .atomic) }
    }

    /// Antes de pisar el autosave se conserva la versión anterior en `backups/` (como mucho una cada 10 minutos,
    /// las últimas 10). Así un «Nuevo proyecto» o un cambio por error no destruye el trabajo previo.
    static func backupPreviousAutosave(_ url: URL, minInterval: TimeInterval = 600, keep: Int = 10) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let existing = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "mapproj" }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        if let newest = existing.first, Date().timeIntervalSince(newest.1) < minInterval { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        try? fm.copyItem(at: url, to: dir.appendingPathComponent("autosave-\(f.string(from: Date())).mapproj"))
        for old in existing.dropFirst(keep - 1) { try? fm.removeItem(at: old.0) }
    }

    // MARK: Lienzo y salida

    func setCanvasAspect(_ a: Float) { canvasAspect = a }

    func startOutput(on screen: NSScreen?) {
        guard let renderer else { return }
        stopOutput()
        if let screen { canvasAspect = Float(screen.frame.width / screen.frame.height) }
        let controller = OutputController(renderer: renderer, state: self)
        controller.show(on: screen)
        output = controller
        outputActive = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Proyectando con WarpCaos")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    func stopOutput() {
        output?.close()
        output = nil
        endActivity()
        outputActive = false
        blackout = false
        freeze = false
    }

    /// Lo llama el controlador cuando el usuario cierra la ventana de salida por su cuenta.
    func outputDidClose() {
        output = nil
        endActivity()
        outputActive = false
        blackout = false
        freeze = false
    }
}
