# WarpCaos

App de video mapping para macOS: **Mesh Warp** + Quad Warp + máscaras, con salida a proyector.
Swift + SwiftUI + Metal. Se compila con las Command Line Tools (no requiere Xcode).

## Uso rápido
1. **Salida → Proyectar en pantalla N** (o *Ventana de prueba*). Esc en la salida la cierra.
2. En el editor, arrastrá los nodos de la malla hasta que calcen con el objeto físico.
3. Para formas simples (círculo, triángulo, estrella…) creá la superficie con el menú del «+» o cambiá la **Forma** en Propiedades:
   se edita con solo 4 esquinas y la forma sigue la perspectiva. Si hace falta, subí la grilla para deformarla como malla.
   *Ajuste*: **Estirar** llena el cuadrilátero; **Cubrir** conserva la proporción del contenido y recorta lo que sobra.
4. Cada superficie tiene su contenido (patrón de calibración, imagen o video), opacidad, grilla y máscaras.

El editor trabaja sobre un **lienzo con la proporción de la pantalla de salida**: lo que ves es lo que se proyecta.

## Atajos
| Acción | Atajo |
|---|---|
| Nuevo / Abrir / Guardar / Guardar como | ⌘N / ⇧⌘O / ⌘S / ⇧⌘S |
| Abrir imagen o video en la superficie activa | ⌘O (o soltar el archivo en la ventana) |
| Nueva / Duplicar / Eliminar superficie | ⇧⌘N / ⌘D / ⌘⌫ |
| Deshacer / Rehacer | ⌘Z / ⇧⌘Z |
| Seleccionar todos los nodos | ⌘A |
| Mover nodos seleccionados | Flechas (Shift = ×10) |
| Siguiente nodo | Tab (Shift+Tab = anterior) |
| Selección múltiple | Shift+clic, o arrastrar en vacío |
| Deseleccionar | Esc |
| Play / pausa (video) | Espacio |
| Overlay / Reset de la malla | H / R |

**Máscaras:** «+» en la sección Máscaras; doble clic en una arista = nuevo vértice; Delete = borra vértices seleccionados.

## Proyectos
Se guardan como `.mapproj` (JSON). Las rutas de media son absolutas y relativas a la carpeta del proyecto.
Hay una copia de recuperación automática en `~/Library/Application Support/WarpCaos/autosave.mapproj`,
que se restaura al abrir la app.

## Compilar
```bash
swift build                  # debug
./scripts/make_app.sh        # build/WarpCaos.app (universal arm64 + x86_64, firma ad-hoc)
./scripts/make_dmg.sh        # build/WarpCaos-<versión>.dmg
./scripts/install.sh         # compila e instala en ~/Applications (Spotlight / Launchpad)
swift scripts/make_icon.swift   # regenera el ícono (luego iconutil, ver historial del proyecto)
```
La versión sale del archivo `VERSION`.

**Distribución:** la app está firmada ad-hoc. En otra Mac, Gatekeeper pedirá clic derecho → Abrir la primera vez.
Para distribuir sin avisos hace falta un Developer ID y notarización (requiere cuenta de Apple Developer).

## Variables de entorno (pruebas)
`WARPCAOS_DEMO=mesh|linear|quad|multi|masks|shapes` (escenas de prueba, sin autosave), `WARPCAOS_FILE=<ruta>` (media inicial),
`WARPCAOS_PROJECT=<ruta>` (abre un proyecto), `WARPCAOS_SAVE_TO=<ruta>` (guarda a los 3 s),
`WARPCAOS_OUTPUT=test|screen` (abre la salida al iniciar).
