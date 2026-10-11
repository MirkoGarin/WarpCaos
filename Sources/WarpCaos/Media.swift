import AVFoundation
import MetalKit

/// Fuente de video: AVPlayer con loop que entrega cada frame como textura Metal.
final class VideoSource {
    let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var cache: CVMetalTextureCache?
    private var keepAlive: CVMetalTexture?
    private var endObserver: NSObjectProtocol?
    private(set) var texture: MTLTexture?

    init?(url: URL, device: MTLDevice) {
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else { return nil }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Videos grabados con celular traen la rotación como transformación del track: sin una
        // composición, AVPlayerItemVideoOutput entregaría los frames sin rotar.
        if url.isFileURL {
            if let track = asset.tracks(withMediaType: .video).first, !track.preferredTransform.isIdentity {
                item.videoComposition = AVMutableVideoComposition(propertiesOf: asset)
            }
        } else {
            // En la red se resuelve sin bloquear: la composición se aplica cuando el track está disponible.
            Task { @MainActor in
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let t = try? await track.load(.preferredTransform), !t.isIdentity,
                   let comp = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) {
                    item.videoComposition = comp
                }
            }
        }
        item.add(output)
        player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    /// El reproductor terminó de preparar el video (puede reproducirse).
    var isReady: Bool { player.currentItem?.status == .readyToPlay }

    /// Mensaje de error si el video no pudo abrirse o se cortó (red caída, formato no soportado…).
    var errorMessage: String? {
        guard let item = player.currentItem, item.status == .failed else { return nil }
        guard let error = item.error as NSError? else { return "error desconocido" }
        // -11850 "Operation Stopped": típico cuando el servidor no permite pedir el archivo por rangos.
        if error.code == -11850 { return "el servidor no permite streaming de ese archivo (¿es un link directo al video? probá con .m3u8 o descargalo)" }
        if error.domain == NSURLErrorDomain { return "no se pudo conectar (\(error.localizedDescription))" }
        return error.localizedDescription
    }

    deinit {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Actualiza `texture` con el frame más reciente. Devuelve true si llegó un frame nuevo.
    @discardableResult
    func update() -> Bool {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let cache else { return false }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return false }
        keepAlive = cvTex
        texture = tex
        return true
    }
}

enum MediaKind {
    case image, video

    /// Para una URL de red: se asume video salvo que la extensión sea de imagen (cubre mp4, mov, m3u8 y enlaces sin extensión).
    static func forRemote(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "webp"].contains(ext) ? .image : .video
    }

    static func of(_ url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }
}

import UniformTypeIdentifiers
