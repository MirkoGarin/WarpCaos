import SwiftUI
import MetalKit
import Combine

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OutputView: MTKView {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) }
    }
}

/// Ventana de salida: pantalla completa sin bordes en el proyector (o una ventana de prueba).
/// Usa el mismo Renderer que el editor, sin overlays.
final class OutputController: NSObject, MTKViewDelegate, NSWindowDelegate {
    private let renderer: Renderer
    private unowned let state: AppState
    private var window: NSWindow?
    private var view: OutputView?
    private var cursorHidden = false
    private var freezeCancellable: AnyCancellable?

    init(renderer: Renderer, state: AppState) {
        self.renderer = renderer
        self.state = state
        super.init()
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
            w = OutputWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                             defer: false, screen: screen)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            NSCursor.hide()
            cursorHidden = true
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

    func close() {
        freezeCancellable = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        view = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        view = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        state.outputDidClose()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) { renderer.render(view, editor: false) }
}
