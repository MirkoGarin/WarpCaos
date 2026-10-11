#!/bin/zsh
# Convierte los videos de una carpeta que no sean H.264/HEVC (p. ej. Motion-JPEG, ProRes, DXV) a MP4 H.264,
# el formato que WarpCaos reproduce con menos carga de CPU. Los originales no se tocan:
# los convertidos van a <carpeta>/h264/<nombre>.mp4 (los que ya existen se saltean).
# Uso: ./scripts/convert_to_h264.sh [carpeta]   (por defecto: Loops)
setopt null_glob
DIR="${1:-$(dirname "$0")/../Loops}"
OUT="$DIR/h264"
mkdir -p "$OUT"
total=0; done_n=0; skipped=0; failed=0

for f in "$DIR"/*.mov "$DIR"/*.mp4 "$DIR"/*.m4v "$DIR"/*.avi "$DIR"/*.mkv "$DIR"/*.webm; do
    [[ -f "$f" ]] || continue
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null | head -1)
    [[ "$codec" == "h264" || "$codec" == "hevc" ]] && continue
    total=$((total + 1))
    name="${f:t:r}"
    dest="$OUT/$name.mp4"
    if [[ -s "$dest" ]]; then skipped=$((skipped + 1)); continue; fi
    echo "→ $name ($codec)"
    # JPEG es rango completo y BT.601: se pasa a rango limitado y BT.709, y se etiqueta para que el reproductor no adivine.
    if ffmpeg -y -loglevel error -i "$f" \
        -vf "scale=in_range=pc:out_range=tv:in_color_matrix=bt601:out_color_matrix=bt709,format=yuv420p" \
        -c:v libx264 -crf 18 -preset medium -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
        -c:a aac -b:a 160k -f mp4 -movflags +faststart "$dest.part" && mv "$dest.part" "$dest"; then
        done_n=$((done_n + 1))
    else
        failed=$((failed + 1)); rm -f "$dest.part"; echo "   ✗ falló: $name"
    fi
done
echo "Listo: $done_n convertidos, $skipped ya existían, $failed con error (de $total a convertir). Salida: $OUT"
