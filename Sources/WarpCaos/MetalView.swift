import SwiftUI
import MetalKit

/// MTKView que reenvía mouse y teclado al estado de edición.
final class EditorView: MTKView {
    weak var state: AppState?
    override var acceptsFirstResponder: Bool { true }

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.clickCount == 2 { state?.doubleClick(point(e), size: bounds.size) }
        state?.mouseDown(point(e), size: bounds.size, shift: e.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with e: NSEvent) { state?.mouseDragged(point(e), size: bounds.size) }
    override func mouseUp(with e: NSEvent) { state?.mouseUp() }

    override func selectAll(_ sender: Any?) { state?.selectAll() }

    override func keyDown(with e: NSEvent) {
        let handled = state?.keyDown(keyCode: e.keyCode, chars: e.charactersIgnoringModifiers ?? "",
                                     shift: e.modifierFlags.contains(.shift), size: bounds.size) ?? false
        if !handled { super.keyDown(with: e) }
    }
}

struct MetalView: NSViewRepresentable {
    let state: AppState

    func makeCoordinator() -> Renderer {
        let r = Renderer(state: state)
        state.renderer = r
        return r
    }

    func makeNSView(context: Context) -> EditorView {
        let view = EditorView()
        view.state = state
        view.device = context.coordinator.device
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = Renderer.sampleCount
        view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: EditorView, context: Context) {}
}
