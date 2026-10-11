# WarpCaos

**[English](#english) · [Español](#español)**

---

## English

**WarpCaos** is a projection-mapping app for macOS. Warp images and video onto real surfaces with a **Mesh Warp** (and exact-perspective **Quad Warp**), shape them with **masks and soft edges**, and send the result to a projector in fullscreen. What you see in the editor is what the projector shows.

Built with Swift, SwiftUI and Metal. It compiles with the Xcode Command Line Tools — **no Xcode required**.

### Features

- **Mesh Warp** — from 2×2 up to 16×16 control nodes, with linear or smooth (Catmull-Rom) interpolation.
- **Quad Warp** — a 2×2 mesh renders with exact perspective correction.
- **Shaped surfaces** — circle/ellipse, triangle, diamond, pentagon, hexagon, octagon and star. A shape lives inside a 4-corner quad, so it follows the perspective and is easy to edit; raise the grid to bend it like a mesh. Optional soft edge.
- **Masks** — polygon masks per surface with *Show / Hide*, *Invert* and feathered edges (exact distance-based, no blur passes).
- **Flip & rotate** — flip horizontally/vertically and rotate (±90° steps or any angle) the content and, independently, the shape of each surface. Rotated shapes shrink automatically to stay inside their quad.
- **Playlists** — a surface can hold several contents (videos, images, patterns, URLs) that play one after another with a **crossfade** (0–3 s, or a straight cut). Each video repeats *N* times before moving on, images and patterns last a set number of seconds, and the order can be **shuffled** (no immediate repeats). With a single content it simply loops forever. Select several files in *Open…* or drop them on the window to build a list; each item fits its container with the surface's *Stretch/Cover* setting.
- **Open URL** — stream a video (`.mp4`, `.mov`, HLS `.m3u8`) or load an image from a direct link, without downloading it first. Links to **Vimeo** pages are resolved to a direct stream with [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) (`brew install yt-dlp`) — still streaming, no file is saved. **YouTube** blocks external players, so WarpCaos explains how to download the video instead.
- **Content** — images and video (looping, mute, rotation metadata respected) plus built-in calibration patterns: checkerboard, grid, UV, color bars, white.
- **Multiple surfaces** — layers with order, opacity and visibility; each surface has its own content, grid and masks.
- **Projector output** — borderless fullscreen on the chosen screen, **Blackout** and **Freeze**, `Esc` to close. The canvas takes the output screen's aspect ratio, and the display is kept awake while projecting.
- **Editing workflow** — multi-select (click, Shift+click, marquee), arrow-key nudging, undo/redo (100 steps), drag-and-drop media.
- **Projects** — saved as readable JSON (`.mapproj`) with absolute and project-relative media paths; automatic recovery copy.
- **Rendering** — 4× MSAA, mipmapped textures, alpha-blended layers.

### Requirements

- macOS 13 or later, a Metal-capable Mac.
- To build from source: Xcode Command Line Tools (`xcode-select --install`), Swift 5.9+. Developed with Swift 6.1.
- Optional: `ffmpeg`, only to generate the sample loops.

### Quick start

1. Open WarpCaos. Choose **Output → Project on screen N** (or *Test window* on a single-screen setup). `Esc` closes the output.
2. In the editor, drag the nodes until the content fits the physical object.
3. For simple shapes, create the surface from the **+** menu, or change **Shape** in *Properties*.
   *Fit* **Stretch** fills the quad; **Cover** keeps the content's proportions and crops the rest.
4. Assign content (pattern, image or video), set opacity, grid and masks per surface.

### Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New / Open / Save / Save as | ⌘N / ⇧⌘O / ⌘S / ⇧⌘S |
| Open image or video on the active surface | ⌘O (or drop a file on the window) |
| Open a video or image URL | ⇧⌘U |
| New / Duplicate / Delete surface | ⇧⌘N / ⌘D / ⌘⌫ |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Select all nodes | ⌘A |
| Nudge selected nodes | Arrow keys (Shift = ×10) |
| Next / previous node | Tab / ⇧Tab |
| Multi-select | Shift+click, or drag on empty space |
| Deselect | Esc |
| Play / pause video | Space |
| Toggle overlay / Reset mesh | H / R |

**Masks:** use **+** in the *Masks* section · double-click an edge to add a vertex · `Delete` removes the selected vertices.

### Build

```bash
swift build                      # debug build
./scripts/make_app.sh            # build/WarpCaos.app — universal (arm64 + x86_64), ad-hoc signed
./scripts/make_dmg.sh            # build/WarpCaos-<version>.dmg
./scripts/install.sh             # build and install into ~/Applications
swift scripts/make_icon.swift    # regenerate the app icon source (Resources/AppIcon-1024.png)
```

The version comes from the `VERSION` file. Shaders are compiled at runtime, so no `.metal` toolchain is needed. The universal binary is produced by building each architecture separately and merging with `lipo`, which works without Xcode.

> **Distribution:** the app is ad-hoc signed. On another Mac, Gatekeeper will ask you to right-click → *Open* the first time. Distributing without that prompt requires a Developer ID and notarization (an Apple Developer account).

### Sample loops

Video files are large, so the `Loops/` folder is **git-ignored** and not part of the repository. Generate seamless psychedelic sample loops (8 s, 1280×720, 30 fps) with:

```bash
./scripts/make_loops.sh              # all of them
./scripts/make_loops.sh plasma tunel # only some
```

Available: `plasma`, `espiral`, `anillos`, `interferencia`, `caleidoscopio`, `tunel`. Requires `ffmpeg`. You can also drop your own videos into the window.

### Project layout

```
Sources/WarpCaos/   app source (SwiftUI UI, Metal renderer, mesh/shape/mask models)
scripts/            build, packaging, icon and loop-generation scripts
Resources/          app icon
VERSION             current version
```

### Development & testing

Environment variables used for testing without the UI:

| Variable | Effect |
|---|---|
| `WARPCAOS_DEMO=mesh\|linear\|quad\|multi\|masks\|shapes` | Load a test scene (disables autosave) |
| `WARPCAOS_FILE=<path>` | Initial media for the first surface |
| `WARPCAOS_URL=<url>` | Initial video/image URL (or Vimeo page link) for the first surface (disables autosave) |
| `WARPCAOS_YTDLP=<path>` | Force a specific `yt-dlp` binary |
| `WARPCAOS_PLAYLIST=<a,b,c>` | Comma-separated files/URLs for the first surface's playlist (with `WARPCAOS_FADE`, `WARPCAOS_LOOPS`, `WARPCAOS_STILL`, `WARPCAOS_SHUFFLE`; disables autosave) |
| `WARPCAOS_LOG=1` | Print playlist events (preload, fade, switch) to stdout |
| `WARPCAOS_PROJECT=<path>` | Open a project at launch |
| `WARPCAOS_SAVE_TO=<path>` | Save the project after 3 s |
| `WARPCAOS_OUTPUT=test\|screen` | Open the output window at launch |

Recovery copies are written to `~/Library/Application Support/WarpCaos/autosave.mapproj` and restored on launch. The previous version is kept in `backups/` (at most one every 10 minutes, last 10), so a mistaken *New project* never destroys earlier work.

### Status

Version 1.4. Pre-built installers (`.dmg`) are available on the [Releases](https://github.com/MirkoGarin/WarpCaos/releases) page. Developed and tested on an Intel Mac with macOS 15; the Apple Silicon slice is built but has not been run on that hardware. Fullscreen output on external projectors depends on your display setup — use a direct wired connection (HDMI/DisplayPort) rather than AirPlay for accurate, low-latency mapping.

### Credits

The mapping concepts (quad warp, mesh warp, shader lamps) follow J. J. M. Tirigall, *Video Mapping sobre objetos complejos en pequeña y mediana escala*, Universidad Nacional de las Artes (Buenos Aires). The regular-polygon and star distance functions in the shape shader are adapted from Inigo Quilez's 2D distance functions (iquilezles.org). Reference tools: MadMapper, Resolume, HeavyM.

### License

Copyright (C) 2026 Mirko Garin.

WarpCaos is free software, licensed under the **GNU General Public License v3.0** (GPL-3.0). You may use, study, modify and share it; derivative works that you distribute must also be released under the GPL-3.0 with their source code. See [`LICENSE`](LICENSE) for the full text.

---

## Español

**WarpCaos** es una app de video mapping para macOS. Deformá imágenes y video sobre superficies reales con un **Mesh Warp** (y un **Quad Warp** con perspectiva exacta), recortalos con **máscaras y bordes suaves**, y enviá el resultado a un proyector a pantalla completa. Lo que ves en el editor es lo que proyecta el proyector.

Hecha con Swift, SwiftUI y Metal. Se compila con las Command Line Tools de Xcode: **no requiere Xcode**.

### Características

- **Mesh Warp** — de 2×2 hasta 16×16 nodos de control, con interpolación lineal o suave (Catmull-Rom).
- **Quad Warp** — una malla 2×2 se dibuja con corrección de perspectiva exacta.
- **Superficies con forma** — círculo/elipse, triángulo, rombo, pentágono, hexágono, octágono y estrella. La forma vive dentro de un cuadrilátero de 4 esquinas, así que sigue la perspectiva y es fácil de editar; subiendo la grilla se deforma como una malla. Borde suave opcional.
- **Máscaras** — máscaras poligonales por superficie con *Mostrar / Ocultar*, *Invertir* y bordes difuminados (por distancia exacta, sin pasadas de blur).
- **Voltear y rotar** — voltear horizontal/verticalmente y rotar (de a 90° o con cualquier ángulo) el contenido y, por separado, la forma de cada superficie. Las formas rotadas se achican solas para seguir dentro del cuadrilátero.
- **Listas de reproducción** — una superficie puede tener varios contenidos (videos, imágenes, patrones, URLs) que se suceden con **fundido** (de 0 a 3 s, o corte directo). Cada video se repite *N* veces antes de pasar al siguiente, las imágenes y patrones duran una cantidad de segundos, y el orden puede ser **aleatorio** (sin repetir el mismo seguido). Con un solo contenido se repite sin fin. Elegí varios archivos en *Abrir…* o soltalos en la ventana para armar la lista; cada uno se acomoda en su contenedor con el ajuste *Estirar/Cubrir* de la superficie.
- **Abrir URL** — reproducí por streaming un video (`.mp4`, `.mov`, HLS `.m3u8`) o cargá una imagen desde un link directo, sin descargarlo antes. Los links de páginas de **Vimeo** se resuelven a un stream directo con [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) (`brew install yt-dlp`): sigue siendo streaming y no se guarda ningún archivo. **YouTube** bloquea a los reproductores externos, así que WarpCaos explica cómo descargar el video.
- **Contenido** — imágenes y video (con loop, silencio y rotación de metadatos respetada), más patrones de calibración: tablero, grilla, UV, barras de color y blanco.
- **Varias superficies** — capas con orden, opacidad y visibilidad; cada superficie tiene su propio contenido, grilla y máscaras.
- **Salida a proyector** — pantalla completa sin bordes en la pantalla elegida, **Negro** y **Congelar**, y `Esc` para cerrar. El lienzo toma la proporción de la pantalla de salida y se evita que la pantalla se apague mientras se proyecta.
- **Flujo de edición** — selección múltiple (clic, Shift+clic, rectángulo), movimiento con flechas, deshacer/rehacer (100 pasos), arrastrar y soltar archivos.
- **Proyectos** — se guardan como JSON legible (`.mapproj`) con rutas de media absolutas y relativas al proyecto; copia de recuperación automática.
- **Render** — MSAA 4×, texturas con mipmaps, capas con mezcla alfa.

### Requisitos

- macOS 13 o superior, una Mac compatible con Metal.
- Para compilar desde el código: Command Line Tools de Xcode (`xcode-select --install`), Swift 5.9+. Desarrollada con Swift 6.1.
- Opcional: `ffmpeg`, solo para generar los loops de ejemplo.

### Inicio rápido

1. Abrí WarpCaos. Elegí **Salida → Proyectar en pantalla N** (o *Ventana de prueba* si tenés una sola pantalla). `Esc` cierra la salida.
2. En el editor, arrastrá los nodos hasta que el contenido calce con el objeto físico.
3. Para formas simples, creá la superficie desde el menú **+**, o cambiá la **Forma** en *Propiedades*.
   El ajuste **Estirar** llena el cuadrilátero; **Cubrir** conserva la proporción del contenido y recorta lo que sobra.
4. Asigná contenido (patrón, imagen o video) y definí opacidad, grilla y máscaras por superficie.

### Atajos de teclado

| Acción | Atajo |
|---|---|
| Nuevo / Abrir / Guardar / Guardar como | ⌘N / ⇧⌘O / ⌘S / ⇧⌘S |
| Abrir imagen o video en la superficie activa | ⌘O (o soltar el archivo en la ventana) |
| Abrir la URL de un video o imagen | ⇧⌘U |
| Nueva / Duplicar / Eliminar superficie | ⇧⌘N / ⌘D / ⌘⌫ |
| Deshacer / Rehacer | ⌘Z / ⇧⌘Z |
| Seleccionar todos los nodos | ⌘A |
| Mover nodos seleccionados | Flechas (Shift = ×10) |
| Siguiente / anterior nodo | Tab / ⇧Tab |
| Selección múltiple | Shift+clic, o arrastrar en vacío |
| Deseleccionar | Esc |
| Play / pausa del video | Espacio |
| Overlay / Reset de la malla | H / R |

**Máscaras:** «+» en la sección *Máscaras* · doble clic en una arista agrega un vértice · `Delete` borra los vértices seleccionados.

### Compilar

```bash
swift build                      # compilación de debug
./scripts/make_app.sh            # build/WarpCaos.app — universal (arm64 + x86_64), firma ad-hoc
./scripts/make_dmg.sh            # build/WarpCaos-<versión>.dmg
./scripts/install.sh             # compila e instala en ~/Applications
swift scripts/make_icon.swift    # regenera la imagen base del ícono (Resources/AppIcon-1024.png)
```

La versión sale del archivo `VERSION`. Los shaders se compilan en tiempo de ejecución, así que no hace falta el toolchain de `.metal`. El binario universal se arma compilando cada arquitectura por separado y uniéndolas con `lipo`, lo que funciona sin Xcode.

> **Distribución:** la app está firmada ad-hoc. En otra Mac, Gatekeeper pedirá clic derecho → *Abrir* la primera vez. Para distribuir sin ese aviso hace falta un Developer ID y notarización (cuenta de Apple Developer).

### Loops de ejemplo

Los videos pesan mucho, así que la carpeta `Loops/` está en el **`.gitignore`** y no forma parte del repositorio. Generá loops psicodélicos sin cortes (8 s, 1280×720, 30 fps) con:

```bash
./scripts/make_loops.sh              # todos
./scripts/make_loops.sh plasma tunel # solo algunos
```

Disponibles: `plasma`, `espiral`, `anillos`, `interferencia`, `caleidoscopio`, `tunel`. Requiere `ffmpeg`. También podés soltar tus propios videos en la ventana.

### Estructura del proyecto

```
Sources/WarpCaos/   código de la app (UI SwiftUI, renderer Metal, modelos de malla/forma/máscara)
scripts/            scripts de compilación, empaquetado, ícono y generación de loops
Resources/          ícono de la app
VERSION             versión actual
```

### Desarrollo y pruebas

Variables de entorno para probar sin usar la interfaz:

| Variable | Efecto |
|---|---|
| `WARPCAOS_DEMO=mesh\|linear\|quad\|multi\|masks\|shapes` | Carga una escena de prueba (desactiva el autosave) |
| `WARPCAOS_FILE=<ruta>` | Media inicial de la primera superficie |
| `WARPCAOS_URL=<url>` | URL de video o imagen (o link de página de Vimeo) inicial de la primera superficie (desactiva el autosave) |
| `WARPCAOS_YTDLP=<ruta>` | Fuerza un binario concreto de `yt-dlp` |
| `WARPCAOS_PLAYLIST=<a,b,c>` | Archivos/URLs separados por coma para la lista de la primera superficie (con `WARPCAOS_FADE`, `WARPCAOS_LOOPS`, `WARPCAOS_STILL`, `WARPCAOS_SHUFFLE`; desactiva el autosave) |
| `WARPCAOS_LOG=1` | Imprime los eventos de la lista (precarga, fundido, cambio) por stdout |
| `WARPCAOS_PROJECT=<ruta>` | Abre un proyecto al iniciar |
| `WARPCAOS_SAVE_TO=<ruta>` | Guarda el proyecto a los 3 s |
| `WARPCAOS_OUTPUT=test\|screen` | Abre la ventana de salida al iniciar |

Las copias de recuperación se escriben en `~/Library/Application Support/WarpCaos/autosave.mapproj` y se restauran al abrir la app. La versión anterior se conserva en `backups/` (como mucho una cada 10 minutos, las últimas 10), así un *Nuevo proyecto* por error no destruye el trabajo previo.

### Estado

Versión 1.4. Los instaladores ya compilados (`.dmg`) están en la página de [Releases](https://github.com/MirkoGarin/WarpCaos/releases). Desarrollada y probada en una Mac Intel con macOS 15; la versión para Apple Silicon se compila pero no se ejecutó en ese hardware. La salida a pantalla completa en proyectores externos depende de tu configuración: usá una conexión directa por cable (HDMI/DisplayPort) y no AirPlay para un mapeo preciso y de baja latencia.

### Créditos

Los conceptos de mapeo (quad warp, mesh warp, shader lamps) siguen a J. J. M. Tirigall, *Video Mapping sobre objetos complejos en pequeña y mediana escala*, Universidad Nacional de las Artes (Buenos Aires). Las funciones de distancia de polígono regular y estrella del shader de formas están adaptadas de las funciones de distancia 2D de Inigo Quilez (iquilezles.org). Herramientas de referencia: MadMapper, Resolume, HeavyM.

### Licencia

Copyright (C) 2026 Mirko Garin.

WarpCaos es software libre, publicado bajo la **Licencia Pública General de GNU v3.0** (GPL-3.0). Podés usarlo, estudiarlo, modificarlo y compartirlo; las obras derivadas que distribuyas también deben publicarse bajo la GPL-3.0, con su código fuente. El texto completo está en [`LICENSE`](LICENSE).
