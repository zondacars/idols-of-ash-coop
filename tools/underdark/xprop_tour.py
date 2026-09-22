"""Add 'xprop' tour stops that look at one placement of each external model (game-folder layout only)."""
import json, math, sys, random
import numpy as np
src = 'out/layout.json'
dst = sys.argv[1]
only = sys.argv[2].split(',') if len(sys.argv) > 2 else None
L = json.load(open(src))
BI = ["MOUTH", "OSSUARY", "FUNGAL", "ROOTS", "DROWNED", "VILLAGE", "CRYSTAL", "FOUNDRY", "NEST", "BURROWS"]
st = [(np.array(s['pos']), s['biome']) for s in L['stations']]
man = json.load(open('ext_manifest.json'))
rng = random.Random(5)
seen = {}
props = [p for p in L['props'] if p['scene'].startswith('ext/')]
rng.shuffle(props)
stops = []
for p in props:
    key = p['scene']
    if key in seen or (only and not any(o in key for o in only)):
        continue
    pos = np.array(p['pos'])
    near = min(st, key=lambda s: np.linalg.norm(s[0] - pos))
    d = near[0] - pos
    d[1] = 0
    if np.linalg.norm(d) < 0.5:
        d = np.array([1.0, 0, 0])
    d = d / np.linalg.norm(d)
    info = man[key[4:]]
    h = info['size'][1] * p['scale']
    dist = max(4.0, 1.6 * max(info['size'][0], info['size'][2]) * p['scale'] + 2.5)
    eye = pos + d * dist + np.array([0, max(1.6, h * 0.6), 0])
    look = pos + np.array([0, h * 0.5, 0])
    seen[key] = True
    stops.append({"pos": [round(float(v), 3) for v in eye], "look": [round(float(v), 3) for v in look],
                  "label": "xprop %s %s" % (BI[near[1]], key[4:]), "air": True})
L['tour'] += stops
json.dump(L, open(dst, 'w'), separators=(',', ':'))
print(len(stops), 'xprop stops appended ->', dst)
