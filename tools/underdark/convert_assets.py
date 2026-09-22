"""Every external CC0 asset -> one self-contained .glb under the map's ext/ folder, plus a manifest
with the true world-space bounds of each piece so the generator can scale, snap and box them."""
import os, json, struct, glob, shutil, sys
import numpy as np
import trimesh

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, '..', 'build', 'mods-unpacked', 'zonda-CoopSync', 'maps', 'underdark', 'ext')
os.makedirs(OUT, exist_ok=True)


def pad4(b, fill=b'\x00'):
    return b + fill * ((4 - len(b) % 4) % 4)


def write_glb(j, bin_data, dst):
    j['buffers'] = [{'byteLength': len(bin_data)}]
    js = pad4(json.dumps(j, separators=(',', ':')).encode(), b' ')
    bd = pad4(bin_data)
    total = 12 + 8 + len(js) + 8 + len(bd)
    with open(dst, 'wb') as f:
        f.write(b'glTF' + struct.pack('<II', 2, total))
        f.write(struct.pack('<II', len(js), 0x4E4F534A) + js)
        f.write(struct.pack('<II', len(bd), 0x004E4942) + bd)


def pack_gltf(src, dst):
    """gltf + .bin + texture files -> glb with everything embedded (keeps the PBR set intact)."""
    d = os.path.dirname(src)
    j = json.load(open(src))
    assert len(j['buffers']) == 1
    bin_data = open(os.path.join(d, j['buffers'][0]['uri']), 'rb').read()
    bin_data = pad4(bin_data)
    for img in j.get('images', []):
        if 'uri' not in img:
            continue
        data = open(os.path.join(d, img['uri']), 'rb').read()
        off = len(bin_data)
        j.setdefault('bufferViews', []).append({'buffer': 0, 'byteOffset': off, 'byteLength': len(data)})
        img['bufferView'] = len(j['bufferViews']) - 1
        img['mimeType'] = 'image/jpeg' if img['uri'].lower().endswith(('.jpg', '.jpeg')) else 'image/png'
        del img['uri']
        bin_data = pad4(bin_data + data)
    write_glb(j, bin_data, dst)


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def node_mat(n):
    if 'matrix' in n:
        return np.array(n['matrix']).reshape(4, 4).T
    M = np.eye(4)
    s = np.array(n.get('scale', [1, 1, 1]))
    r = quat_mat(n.get('rotation', [0, 0, 0, 1]))
    M[:3, :3] = r * s
    M[:3, 3] = n.get('translation', [0, 0, 0])
    return M


def glb_bounds(path):
    d = open(path, 'rb').read()
    ln = struct.unpack('<I', d[12:16])[0]
    j = json.loads(d[20:20 + ln])
    lo = np.full(3, 1e9)
    hi = np.full(3, -1e9)
    tris = [0]

    def walk(i, P):
        nonlocal lo, hi
        n = j['nodes'][i]
        M = P @ node_mat(n)
        if 'mesh' in n:
            for pr in j['meshes'][n['mesh']]['primitives']:
                a = j['accessors'][pr['attributes']['POSITION']]
                mn, mx = np.array(a['min']), np.array(a['max'])
                for c in range(8):
                    p = np.array([mx[0] if c & 1 else mn[0], mx[1] if c & 2 else mn[1], mx[2] if c & 4 else mn[2], 1.0])
                    q = (M @ p)[:3]
                    lo = np.minimum(lo, q)
                    hi = np.maximum(hi, q)
                if 'indices' in pr:
                    tris[0] += j['accessors'][pr['indices']]['count'] // 3
        for k in n.get('children', []):
            walk(k, M)

    sc = j['scenes'][j.get('scene', 0)]
    for i in sc['nodes']:
        walk(i, np.eye(4))
    return lo, hi, tris[0], len(j.get('images', []))


manifest = {}


def add(pack, name, dst):
    lo, hi, tris, imgs = glb_bounds(dst)
    manifest['%s/%s' % (pack, name)] = {'lo': [round(float(x), 3) for x in lo], 'hi': [round(float(x), 3) for x in hi],
                                        'size': [round(float(x), 3) for x in hi - lo], 'tris': tris, 'imgs': imgs,
                                        'bytes': os.path.getsize(dst)}


def embed_glb_images(src, dst, tex_dir):
    """Kenney's glb files point at Textures/colormap.png next to them; Godot's runtime loader
    refuses an external uri from a buffer, so the palette is embedded."""
    d = open(src, 'rb').read()
    ln = struct.unpack('<I', d[12:16])[0]
    j = json.loads(d[20:20 + ln])
    off = 20 + ln
    bin_data = b''
    if off + 8 <= len(d):
        bl = struct.unpack('<I', d[off:off + 4])[0]
        bin_data = d[off + 8:off + 8 + bl]
    bin_data = pad4(bin_data)
    for img in j.get('images', []):
        if 'uri' not in img:
            continue
        data = open(os.path.join(tex_dir, os.path.basename(img['uri'])), 'rb').read()
        j.setdefault('bufferViews', []).append({'buffer': 0, 'byteOffset': len(bin_data), 'byteLength': len(data)})
        img['bufferView'] = len(j['bufferViews']) - 1
        img['mimeType'] = 'image/png' if img['uri'].lower().endswith('.png') else 'image/jpeg'
        del img['uri']
        bin_data = pad4(bin_data + data)
    write_glb(j, bin_data, dst)


# ---- Kenney: glb already, palette texture embedded
import zipfile
for pack, src_dir, zname in [('graveyard', 'kenney_graveyard', 'kenney_graveyard-kit_5.0.zip'), ('dungeon', 'kenney_dungeon', 'kenney_mini-dungeon.zip'), ('nature', 'kenney_nature', 'kenney_nature-kit.zip')]:
    od = os.path.join(OUT, pack)
    os.makedirs(od, exist_ok=True)
    tex_dir = os.path.join(ROOT, src_dir, 'Textures')
    os.makedirs(tex_dir, exist_ok=True)
    zf = zipfile.ZipFile(os.path.join(ROOT, 'dl', zname))
    for n in zf.namelist():
        if 'GLB' in n and n.lower().endswith(('.png', '.jpg')):
            open(os.path.join(tex_dir, os.path.basename(n)), 'wb').write(zf.read(n))
    for p in sorted(glob.glob(os.path.join(ROOT, src_dir, '*.glb'))):
        name = os.path.basename(p)
        dst = os.path.join(od, name)
        embed_glb_images(p, dst, tex_dir)
        add(pack, name, dst)

# ---- Poly Haven: gltf sets -> embedded glb
od = os.path.join(OUT, 'ph')
os.makedirs(od, exist_ok=True)
for p in sorted(glob.glob(os.path.join(ROOT, 'polyhaven', '*', '*_1k.gltf'))):
    name = os.path.basename(os.path.dirname(p)).lower() + '.glb'
    dst = os.path.join(od, name)
    pack_gltf(p, dst)
    add('ph', name, dst)

# ---- Quaternius: obj+mtl -> glb via trimesh (solid colours from the MTL)
od = os.path.join(OUT, 'quat')
os.makedirs(od, exist_ok=True)
bad = []
for p in sorted(glob.glob(os.path.join(ROOT, 'quaternius_ruins', '*.obj'))):
    name = os.path.basename(p)[:-4] + '.glb'
    dst = os.path.join(od, name)
    try:
        sc = trimesh.load(p, force='scene')
        for g in sc.geometry.values():
            vis = g.visual
            mat = getattr(vis, 'material', None)
            col = None
            if mat is not None:
                col = getattr(mat, 'diffuse', None)
                if col is None:
                    col = getattr(mat, 'baseColorFactor', None)
            if col is not None:
                col = np.array(col, dtype=float)
                if col.max() > 1.0:
                    col = col / 255.0
                pbr = trimesh.visual.material.PBRMaterial(
                    baseColorFactor=[float(col[0]), float(col[1]), float(col[2]), 1.0],
                    metallicFactor=0.0, roughnessFactor=0.9, name=getattr(mat, 'name', 'm'))
                g.visual = trimesh.visual.TextureVisuals(material=pbr, uv=getattr(vis, 'uv', None))
        sc.export(dst)
        add('quat', name, dst)
    except Exception as e:
        bad.append((name, str(e)[:120]))

json.dump(manifest, open(os.path.join(OUT, 'manifest.json'), 'w'), indent=0)
json.dump(manifest, open(os.path.join(ROOT, '..', 'underdark', 'ext_manifest.json'), 'w'), indent=0)

with open(os.path.join(OUT, 'LICENSES.txt'), 'w') as f:
    f.write('External models used by the Underdark map. All CC0 (public domain), no attribution required.\n\n')
    f.write('graveyard/  Kenney Graveyard Kit 5.0   https://kenney.nl/assets/graveyard-kit   CC0\n')
    f.write('dungeon/    Kenney Mini Dungeon        https://kenney.nl/assets/mini-dungeon    CC0\n')
    f.write('nature/     Kenney Nature Kit          https://kenney.nl/assets/nature-kit      CC0\n')
    f.write('ph/         Poly Haven models (1k)     https://polyhaven.com/models             CC0\n')
    f.write('quat/       Quaternius Ultimate Modular Ruins  https://quaternius.com/packs/ultimatemodularruins.html  CC0\n')
tot = sum(v['bytes'] for v in manifest.values())
print('assets: %d, %.1f MB, tris total %d' % (len(manifest), tot / 1e6, sum(v['tris'] for v in manifest.values())))
for pk in ['graveyard', 'dungeon', 'nature', 'ph', 'quat']:
    vs = [v for k, v in manifest.items() if k.startswith(pk + '/')]
    print('  %-10s %4d files %6.1f MB' % (pk, len(vs), sum(v['bytes'] for v in vs) / 1e6))
if bad:
    print('FAILED:', bad)
