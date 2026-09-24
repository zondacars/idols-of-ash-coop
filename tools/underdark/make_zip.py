import os, sys, zipfile
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build')
ver = sys.argv[1]
dst = os.path.join(sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'), 'ZondaCoopSync_%s_GreatRift.zip' % ver)
n = 0
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for dp, dn, fn in os.walk(root):
        for f in fn:
            if f.endswith('.flag') or f.endswith('.pyc'):
                continue
            full = os.path.join(dp, f)
            z.write(full, os.path.relpath(full, root))
            n += 1
print(dst, n, 'files', '%.1f MB' % (os.path.getsize(dst) / 1e6))
