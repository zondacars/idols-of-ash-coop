"""Normal + roughness maps from the game's own albedo textures (tileable Sobel on luminance)."""
import glob, os, sys
import numpy as np
from PIL import Image
from scipy import ndimage

GS = sys.argv[1]
OUT = sys.argv[2]
SKIP = ("Knight_", "Fog_Cloud", "Test", "Black", "Sand_Decal", "Shrub", "Bush", "Grass")
srcs = [f for f in glob.glob(os.path.join(GS, "Art", "Textures", "*.png")) if not os.path.basename(f).startswith(SKIP)]
extra = ["Ancient_Kiln_BaseColor.png", "Broken_Kiln_Ancient_Kiln_BaseColor.png", "Ancient_Kiln_Deco_Ancient_Kiln_BaseColor.png"]
srcs += [os.path.join(GS, "Art", e) for e in extra if os.path.exists(os.path.join(GS, "Art", e))]
tga = os.path.join(GS, "Art", "Structure_01.tga")
if os.path.exists(tga):
    srcs.append(tga)

names = []
for f in sorted(srcs):
    key = os.path.splitext(os.path.basename(f))[0]
    src = Image.open(f).convert("RGB")
    if src.size[0] > 256:
        src = src.resize((256, 256), Image.LANCZOS)
    im = np.asarray(src, dtype=np.float64) / 255.0
    lum = im @ np.array([0.299, 0.587, 0.114])
    # height: broad shapes plus a little fine grain, wrap so the map still tiles
    h = ndimage.gaussian_filter(lum, 1.1, mode="wrap") * 0.75 + lum * 0.25
    h = (h - h.min()) / max(h.max() - h.min(), 1e-6)
    strength = 3.2
    dx = ndimage.sobel(h, axis=1, mode="wrap") * strength
    dy = ndimage.sobel(h, axis=0, mode="wrap") * strength
    n = np.stack([-dx, dy, np.ones_like(h)], axis=-1)      # OpenGL convention (Godot)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    # Godot rebuilds Z from X and Y, so blue is constant; 5-bit X/Y is plenty at this size
    nrm = ((n * 0.5 + 0.5) * 255)
    nrm = (np.round(nrm / 8.0) * 8.0).clip(0, 255).astype(np.uint8)
    nrm[..., 2] = 255
    Image.fromarray(nrm, "RGB").save(os.path.join(OUT, key + "_n.png"), optimize=True)
    # roughness: stone stays rough, crevices a touch rougher, raised faces slightly smoother
    local = h - ndimage.gaussian_filter(h, 6, mode="wrap")
    r = np.clip(0.88 - local * 0.9, 0.62, 1.0)
    rr = Image.fromarray((r * 255).astype(np.uint8), "L").resize((128, 128), Image.BILINEAR)
    rr = rr.quantize(16).convert("L")
    rr.save(os.path.join(OUT, key + "_r.png"), optimize=True)
    names.append(key)
open(os.path.join(OUT, "index.txt"), "w").write("\n".join(names) + "\n")
print(len(names), "maps:", ", ".join(names))
