// Los shaders se compilan en runtime (no requiere Xcode / `xcrun metal`).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vtx {
        packed_float2 pos;   // NDC
        packed_float2 uv;
        float w;             // clip-w para interpolación con perspectiva correcta
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vertex_main(uint vid [[vertex_id]],
                                 constant Vtx *verts [[buffer(0)]]) {
        Vtx v = verts[vid];
        VertexOut out;
        out.position = float4(float2(v.pos) * v.w, 0, v.w);
        out.uv = v.uv;
        return out;
    }

    struct FragUniform {
        float2 viewport;   // tamaño del lienzo en píxeles
        float2 origin;     // esquina superior izquierda del lienzo dentro del drawable, en píxeles
        float opacity;
        uint maskCount;
        uint shape;          // 0 = sin recorte (ver ShapeKind.shaderID)
        float shapeFeather;  // suavizado del borde, en unidades del cuadrado normalizado
        float2 uvScale;      // ajuste "Cubrir": rango de UV muestreado del contenido
    };

    struct MaskInfo {
        uint start;
        uint count;
        float feather;     // ancho de transición en píxeles
        uint flags;        // bit0: invertir, bit1: ocultar (en vez de mostrar)
    };

    // Distancia con signo (en píxeles) a un polígono: negativa adentro.
    float polygonSDF(float2 p, constant float2 *pts, uint start, uint n, float2 vp) {
        float d2 = 1e20;
        bool inside = false;
        uint j = n - 1;
        for (uint i = 0; i < n; i++) {
            float2 a = pts[start + i] * vp;
            float2 b = pts[start + j] * vp;
            float2 e = b - a;
            float2 w = p - a;
            float2 q = w - e * clamp(dot(w, e) / max(dot(e, e), 1e-8), 0.0, 1.0);
            d2 = min(d2, dot(q, q));
            bool c1 = p.y >= a.y;
            bool c2 = p.y < b.y;
            bool c3 = e.x * w.y > e.y * w.x;
            if ((c1 && c2 && c3) || (!c1 && !c2 && !c3)) inside = !inside;
            j = i;
        }
        float d = sqrt(d2);
        return inside ? -d : d;
    }

    // Polígono regular con vértice hacia arriba y circunradio 1 (iq).
    float sdRegularPolygon(float2 p, uint n) {
        float an = M_PI_F / float(n);
        float2 acs = float2(cos(an), sin(an));
        float bn = fmod(atan2(p.x, p.y) + 2.0 * M_PI_F, 2.0 * an) - an;
        p = length(p) * float2(cos(bn), abs(sin(bn)));
        p -= acs;
        p.y += clamp(-p.y, 0.0, acs.y);
        return length(p) * sign(p.x);
    }

    // Estrella de 5 puntas, circunradio 1, radio interior 0.5 (iq).
    float sdStar5(float2 p) {
        const float2 k1 = float2(0.809016994375, -0.587785252292);
        const float2 k2 = float2(-k1.x, k1.y);
        p.x = abs(p.x);
        p -= 2.0 * max(dot(k1, p), 0.0) * k1;
        p -= 2.0 * max(dot(k2, p), 0.0) * k2;
        p.x = abs(p.x);
        p.y -= 1.0;
        float2 ba = 0.5 * float2(-k1.y, k1.x) - float2(0.0, 1.0);
        float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, 1.0);
        return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
    }

    // Distancia con signo a la forma, en el cuadrado normalizado q ∈ [-1,1]² (y hacia arriba).
    // Cada forma se ajusta a su caja para que las 4 esquinas del cuadrilátero la abracen.
    float shapeSDF(float2 q, uint shape) {
        switch (shape) {
            case 1: return length(q) - 1.0;
            case 2: return sdRegularPolygon(float2(q.x * 0.866, q.y * 0.75 + 0.25), 3);
            case 3: return sdRegularPolygon(q, 4);
            case 4: return sdRegularPolygon(float2(q.x * 0.951, q.y * 0.9045 + 0.0955), 5);
            case 5: return sdRegularPolygon(float2(q.x * 0.866, q.y), 6);
            case 6: return sdRegularPolygon(q, 8);
            case 7: return sdStar5(float2(q.x * 0.951, q.y * 0.9045 + 0.0955));
            default: return -1.0;
        }
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler smp [[sampler(0)]],
                                  constant FragUniform &u [[buffer(0)]],
                                  constant float2 *maskPts [[buffer(1)]],
                                  constant MaskInfo *masks [[buffer(2)]]) {
        float4 c = tex.sample(smp, (in.uv - 0.5) * u.uvScale + 0.5);

        // Forma: recorte en UV, antes de las máscaras de pantalla.
        float shapeA = 1.0;
        if (u.shape != 0) {
            float2 q = (in.uv - 0.5) * 2.0;
            q.y = -q.y;
            float sd = shapeSDF(q, u.shape);
            float hh = max(u.shapeFeather, fwidth(sd));
            shapeA = 1.0 - smoothstep(-hh, hh, sd);
        }

        // "Mostrar": unión de las máscaras que muestran (si no hay ninguna, todo se muestra).
        // "Ocultar": cada máscara recorta su interior. Invertir da vuelta la cobertura.
        bool hasShow = false;
        float show = 0.0;
        float hide = 1.0;
        for (uint k = 0; k < u.maskCount; k++) {
            MaskInfo m = masks[k];
            float h = max(m.feather, 1.0) * 0.5;
            float sd = polygonSDF(in.position.xy - u.origin, maskPts, m.start, m.count, u.viewport);
            float a = 1.0 - smoothstep(-h, h, sd);
            if (m.flags & 1u) a = 1.0 - a;
            if (m.flags & 2u) {
                hide *= (1.0 - a);
            } else {
                hasShow = true;
                show = max(show, a);
            }
        }
        float visibility = (hasShow ? show : 1.0) * hide;
        return float4(c.rgb, c.a * u.opacity * visibility * shapeA);
    }

    // Overlay (contorno y manijas): posiciones NDC directas, color uniforme.
    vertex float4 overlay_vertex(uint vid [[vertex_id]],
                                 constant float2 *verts [[buffer(0)]]) {
        return float4(verts[vid], 0, 1);
    }

    fragment float4 overlay_fragment(float4 pos [[stage_in]] [[position]],
                                     constant float4 &color [[buffer(0)]]) {
        return color;
    }
    """
}
