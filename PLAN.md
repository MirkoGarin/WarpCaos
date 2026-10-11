# WarpCaos — App de Video Mapping (Mesh Warp) para macOS

## Decisiones tomadas
- **Alcance v1:** Mesh Warp + Quad Warp + máscaras
- **Stack:** Swift + SwiftUI + Metal (nativa), build con SwiftPM/Xcode
- **Contenido:** imágenes y videos locales + generadores internos (grilla, tablero de ajedrez, colores, patrones de calibración)
- **Salida:** un proyector (pantalla secundaria a pantalla completa) + ventana de edición en la pantalla principal
- **Entorno:** Mac Intel x86_64, macOS 15.8, solo Command Line Tools (sin Xcode instalado)

## Base teórica (mapping.pdf, Tirigall)
- Proceso: captura del objeto → plantilla 2D / modelo 3D → proyección y transformación (pintado directo o warping).
- **Quad Warp:** 4 vértices, transformación trapezoidal (homografía/perspectiva).
- **Mesh Warp:** malla de nodos manipulables para adaptarse a superficies no planas (el ejemplo de la esfera con tablero de ajedrez es el caso de prueba).
- Shader Lamps / multi-proyector / normalización de intensidad: **fuera de v1**, se deja la arquitectura preparada.

## Arquitectura
- **Modelo:** `Project` → `[Surface]`. Cada `Surface` tiene: fuente de contenido, tipo de warp (quad | mesh), grilla de puntos de control (N×M, con tangentes opcionales), lista de máscaras, opacidad, visibilidad, orden.
- **Render (Metal):**
  - Contenido → textura (`AVPlayerItemVideoOutput` para video, `MTKTextureLoader` para imágenes, generadores en shader).
  - Warp quad: homografía en el vertex stage con corrección de perspectiva (evita el efecto "doblado" de la interpolación afín en triángulos).
  - Warp mesh: grilla subdividida (Catmull-Rom / bezier por parche) evaluada en CPU o compute; se dibuja como malla de triángulos con UV regulares.
  - Máscaras: polígonos/paths por superficie, renderizados a una textura de máscara con feather y compuestos en el fragment shader (modo add/subtract).
- **Ventanas:** editor SwiftUI (con `MTKView` vía `NSViewRepresentable`) y ventana de salida sin bordes en `NSScreen` secundaria, mismo renderer, sin overlays de edición.
- **Persistencia:** proyecto en JSON (`.mapproj`, `Codable`) con referencias a archivos de media (path + bookmark de seguridad).

## Funcionalidades v1
1. Crear/borrar/reordenar superficies; asignar media o generador.
2. Edición en vivo: arrastrar nodos, selección múltiple, nudge con flechas, snap, undo/redo.
3. Quad Warp (4 esquinas) y Mesh Warp (grilla configurable, ej. 2×2 hasta 16×16, subdividir/aumentar densidad).
4. Máscaras por superficie (polígono, feather, invertir).
5. Generadores de calibración: tablero de ajedrez, grilla, rampas, color sólido, test de bordes.
6. Salida a proyector: selección de pantalla, fullscreen, toggle de overlays, "blackout" y "freeze".
7. Guardar/abrir proyecto; autosave.

## Estado
Fases 0–7 implementadas (verificado el render en pantalla; la interacción con mouse/teclado y el proyector real los prueba el usuario).
Entregables: `build/WarpCaos.app` (universal), `build/WarpCaos-1.0.dmg`, `README.md`.

Decisión de diseño (Fase 6): el editor trabaja sobre un **lienzo con la proporción de la pantalla de salida**
(coordenadas normalizadas 0–1 del lienzo); la salida y el editor dibujan exactamente lo mismo.

## Fases
| Fase | Entregable |
|---|---|
| 0 | Scaffold SwiftPM, ventana SwiftUI, `MTKView` dibujando un quad con textura |
| 1 | Quad warp con corrección de perspectiva + generadores de test |
| 2 | Mesh warp (grilla, edición de nodos, interpolación suave) |
| 3 | Imágenes y video (loop, play/pause) |
| 4 | Múltiples superficies, capas, selección, undo/redo |
| 5 | Máscaras con feather |
| 6 | Salida a segunda pantalla + guardado/carga de proyecto |
| 7 | Pulido, empaquetado `.app`, ícono, pruebas con proyector real |

## Riesgos / puntos a decidir
- **Xcode:** con solo CLT se puede compilar (`swift build`) y empaquetar el `.app` a mano, pero Metal shaders (`.metal`) requieren `xcrun metal`, que en general viene con Xcode. Alternativa: compilar shaders en runtime desde source string (`makeLibrary(source:)`). Recomiendo instalar Xcode si es posible; si no, voy por runtime compile.
- Mac Intel: ojo con GPU integrada si es vieja (verificar soporte Metal y rendimiento de video).
- Nombre: **WarpCaos** (decidido). Identidad visual e ícono: pendiente. Distribución futura como `.app`/`.dmg` sin necesidad de Xcode.

## Software de referencia
MadMapper, Resolume (Warp/Mesh), HeavyM, map.club — se toma de ellos: flujo de edición de nodos, panel de superficies, salida a proyector, modo calibración.
