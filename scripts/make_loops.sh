#!/bin/zsh
# Genera loops psicodélicos sin cortes (8 s, 1280x720, 30 fps) en Loops/ usando ffmpeg + geq.
# Cada patrón depende del tiempo solo a través de A = 2π·T/8 con múltiplos enteros, así el último frame empalma con el primero.
# Uso: ./scripts/make_loops.sh [nombre ...]   (sin argumentos genera todos)
cd "$(dirname "$0")/.."
mkdir -p Loops

A="(2*PI*T/8)"
CX="(X-W/2)"; CY="(Y-H/2)"
RAD="(hypot($CX,$CY)/H)"
ANG="atan2($CY,$CX)"

gen() {  # nombre R G B
    local out="Loops/$1.mp4"
    echo "→ $out"
    ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=1280x720:r=30:d=8,format=gbrp,geq=r='$2':g='$3':b='$4'" \
        -c:v libx264 -crf 17 -preset medium -pix_fmt yuv420p -movflags +faststart "$out"
}

run() { [[ ${#ONLY[@]} -eq 0 || " ${ONLY[*]} " == *" $1 "* ]] }
ONLY=("$@")

# 1. Plasma clásico con colores que giran.
X1="(X/H)"; Y1="(Y/H)"
V="(sin($X1*9+$A)+sin($Y1*7+$A)+sin(($X1+$Y1)*6-$A)+sin(hypot($X1-0.89,$Y1-0.5)*10-2*$A))"
run plasma && gen plasma "128+127*sin($V*1.2)" "128+127*sin($V*1.2+2.094)" "128+127*sin($V*1.2+4.188)"

# 2. Espiral hipnótica: brazos oscuros y colores que viajan hacia afuera.
S="(0.5+0.5*sin(5*$ANG+$RAD*20-$A))"
B="pow($S,2)"
run espiral && gen espiral "255*$B*(0.5+0.5*sin($RAD*10-$A))" "255*$B*(0.5+0.5*sin($RAD*10-$A+2.094))" "255*$B*(0.5+0.5*sin($RAD*10-$A+4.188))"

# 3. Anillos neón que se expanden sobre fondo negro.
R1="pow(abs(sin($RAD*25-$A)),12)*(0.6+0.4*sin(6*$ANG+$A))"
R2="pow(abs(sin($RAD*40+2*$A)),20)"
run anillos && gen anillos "255*clip($R1+0.2*$R2,0,1)" "255*clip(0.2*$R1+0.9*$R2,0,1)" "255*clip(0.9*$R1+0.9*$R2,0,1)"

# 4. Interferencia (moiré): dos fuentes que giran una alrededor de la otra.
D1="(hypot(X-W/2-0.18*H*cos($A),Y-H/2-0.18*H*sin($A))/H)"
D2="(hypot(X-W/2+0.18*H*cos($A),Y-H/2+0.18*H*sin($A))/H)"
IV="(sin($D1*70)+sin($D2*70))"
IB="clip(pow(0.5+0.25*$IV,2)*2,0,1)"
run interferencia && gen interferencia "255*$IB*(0.5+0.5*sin($IV*2+$A))" "255*$IB*(0.5+0.5*sin($IV*2+$A+2.094))" "255*$IB*(0.5+0.5*sin($IV*2+$A+4.188))"

# 5. Caleidoscopio de 6 pliegues girando.
F="abs(mod($ANG+PI+$A,PI/3)-PI/6)"
KU="($RAD*cos($F))"; KW="($RAD*sin($F))"
KV="(sin($KU*14+$A)+sin($KW*12-$A)+sin(($KU+$KW)*9+2*$A))"
run caleidoscopio && gen caleidoscopio "128+127*sin($KV*1.5)" "128+127*sin($KV*1.5+2.094)" "128+127*sin($KV*1.5+4.188)"

# 6. Túnel de rayas con profundidad.
DEPTH="(0.25/($RAD+0.02))"
TS="(sin($DEPTH*12-2*$A)*sin(6*$ANG+$A))"
TB="(clip($TS*4,0,1)*clip($RAD*4,0,1))"
run tunel && gen tunel "$TB*(128+127*sin($DEPTH*2+$A))" "$TB*(128+127*sin($DEPTH*2+$A+2.094))" "$TB*(128+127*sin($DEPTH*2+$A+4.188))"
