#!/usr/bin/env bash
# Renders every Claude Buddy screen on the Mac, without the device, to check a layout.
#   tools/buddy_sim/render.sh  -> tools/buddy_sim/out/all.png (corners masked like the real glass)
set -euo pipefail
cd "$(dirname "$0")"
B=../../buddy
mkdir -p out
clang++ -std=c++17 -O1 -Iinc -I$B -include cmath sim.cpp $B/face.cpp $B/meters.cpp $B/day.cpp \
  $B/ui.cpp $B/model.cpp $B/aa.cpp $B/aa_fonts.cpp -o out/sim
(cd out && ./sim)
../../.venv/bin/python - <<'PY'
from PIL import Image
names = ["face_working", "face_waiting", "face_done", "face_idle", "face_lost", "meters", "day"]
ims = [Image.open(f"out/{n}.ppm") for n in names]
sheet = Image.new("RGB", (len(ims) * 250, 300), (255, 255, 255))
for i, im in enumerate(ims):
    sheet.paste(im, (i * 250, 2))
sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save("out/all.png")
print("wrote tools/buddy_sim/out/all.png")
PY
