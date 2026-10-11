import SwiftUI
import MetalKit
import Combine

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OutputView: MTKView {
    var onEscape: (() -> Void)?
    /// Oculta el puntero solo mientras está sobre esta vista (NSCursor.hide() lo ocultaría en toda la app, también en el editor).
    var hidesCursor = false

    private static let blankCursor: NSCursor = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        if hidesCursor { Self.blankCursor.set() } else { super.cursorUpdate(with: event) }
    }
}

/// Ventana de salida: pantalla completa sin bordes en el proyector (o una ventana de prueba).
/// Usa el mismo Renderer que el editor, sin overlays.
final class OutputController: NSObject, MTKViewDelegate, NSWindowDelegate {
    private let renderer: Renderer
    private unowned let state: AppState
    private var window: NSWindow?
    private var view: OutputView?
    private var displayID: CGDirectDisplayID?
    private var freezeCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    init(renderer: Renderer, state: AppState) {
        self.renderer = renderer
        self.state = state
        super.init()
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == id }
    }

    func show(on screen: NSScreen?) {
        let v = OutputView()
        v.device = renderer.device
        v.colorPixelFormat = .bgra8Unorm
        v.sampleCount = Renderer.sampleCount
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.delegate = self
        v.onEscape = { [weak self] in self?.state.stopOutput() }

        let w: NSWindow
        if let screen {
            // Con `screen:` el contentRect se interpreta RELATIVO a esa pantalla: se crea en su origen y después se
            // coloca con el frame absoluto. (Pasar `screen.frame` directamente corría la ventana fuera de las
            // pantallas con cualquier monitor que no esté en el origen.)
            w = OutputWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                             backing: .buffered, defer: false, screen: screen)
            w.setFrame(screen.frame, display: true)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            v.hidesCursor = true
            displayID = Self.displayID(of: screen)

            // Si la pantalla se desconecta (AirPlay, cable) se cierra la salida; si cambia de lugar o resolución, se reacomoda.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let id = self.displayID else { return }
                if let s = self.screen(for: id) {
                    self.window?.setFrame(s.frame, display: true)
                } else {
                    self.state.stopOutput()
                    self.state.status = "La pantalla de salida se desconectó: se cerró la salida."
                }
            }
        } else {
            w = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "WarpCaos — Salida (prueba)"
            w.center()
        }
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        window = w
        view = v

        // Congelar = dejar de redibujar; la última imagen queda en pantalla.
        freezeCancellable = state.$freeze.sink { [weak self] frozen in self?.view?.isPaused = frozen }
    }

    private func cleanUp() {
        freezeCancellable = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        window = nil
        view = nil
    }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        cleanUp()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        cleanUp()
        state.outputDidClose()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) { renderer.render(view, editor: false) }
}
