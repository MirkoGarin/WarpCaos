import Foundation

/// Convierte el link de una página de video (YouTube, Vimeo…) en la URL directa del stream usando `yt-dlp`,
/// sin descargar el archivo. Las URL resultantes están firmadas y vencen a las pocas horas, por eso el proyecto
/// guarda el link de página y se vuelve a resolver al abrirlo.
enum PageResolver {
    struct Resolved {
        let stream: URL
        let title: String
    }

    enum Failure: Error {
        case notInstalled
        case blocked(String)   // el sitio entrega una URL que solo yt-dlp puede abrir (p. ej. YouTube)
        case failed(String)
    }

    static let pageHosts = ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com"]

    /// true para un link de página (no de un archivo): se resuelve con yt-dlp en vez de reproducirse directo.
    static func isPageLink(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard pageHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        return !["mp4", "mov", "m3u8", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// Fuente que corresponde a una URL: link de página (se resuelve) o archivo/stream directo.
    static func source(for url: URL) -> Source { isPageLink(url) ? .page(url) : .url(url) }

    static func locate() -> URL? {
        // WARPCAOS_YTDLP fuerza una ruta concreta (útil si yt-dlp está en otro lado, o para pruebas).
        if let forced = ProcessInfo.processInfo.environment["WARPCAOS_YTDLP"] {
            return FileManager.default.isExecutableFile(atPath: forced) ? URL(fileURLWithPath: forced) : nil
        }
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Resuelve en segundo plano; `completion` se llama fuera del hilo principal.
    static func resolve(_ page: URL, completion: @escaping (Result<Resolved, Failure>) -> Void) {
        guard let exe = locate() else { completion(.failure(.notInstalled)); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = exe
            // Un solo archivo con audio y video (hasta 1080p): AVPlayer necesita una única URL.
            p.arguments = ["--no-warnings", "--no-playlist",
                           "-f", "b[ext=mp4][height<=1080]/b[ext=mp4]/b",
                           "--print", "%(title)s", "--print", "%(url)s", page.absoluteString]
            // Una app abierta desde Finder no hereda el PATH del shell: yt-dlp necesita encontrar deno/node para YouTube.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            do { try p.run() } catch {
                completion(.failure(.failed(error.localizedDescription)))
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()

            let lines = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard p.terminationStatus == 0, let urlLine = lines.last(where: { $0.hasPrefix("http") }),
                  let stream = URL(string: urlLine) else {
                let why = lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.last ?? "sin respuesta (¿tiempo agotado?)"
                completion(.failure(.failed(why.replacingOccurrences(of: "ERROR: ", with: ""))))
                return
            }
            // La CDN de YouTube (googlevideo.com) responde 403 a cualquier cliente que no sea yt-dlp, AVPlayer incluido.
            if (stream.host ?? "").contains("googlevideo.com") {
                completion(.failure(.blocked("YouTube")))
                return
            }
            let title = lines.first { !$0.hasPrefix("http") } ?? page.host ?? "video"
            completion(.success(Resolved(stream: stream, title: title)))
        }
    }
}
