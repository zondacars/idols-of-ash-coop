import json, struct, sys, glob, os
import numpy as np
def quat_mat(q):
    x,y,z,w=q
    return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
def node_mat(n):
    if 'matrix' in n: return np.array(n['matrix']).reshape(4,4).T
    M=np.eye(4)
    s=np.array(n.get('scale',[1,1,1])); r=quat_mat(n.get('rotation',[0,0,0,1]))
    M[:3,:3]=r*s; M[:3,3]=n.get('translation',[0,0,0]); return M
def bounds(path):
    d=open(path,'rb').read()
    if d[:4]!=b'glTF': return None
    L=struct.unpack('<I',d[12:16])[0]; j=json.loads(d[20:20+L])
    lo=np.full(3,1e9); hi=np.full(3,-1e9); has_col=False
    def walk(i,P):
        nonlocal lo,hi,has_col
        n=j['nodes'][i]; M=P@node_mat(n)
        nm=n.get('name','').lower()
        if '-col' in nm or 'colonly' in nm or 'collision' in nm: has_col=True
        if 'mesh' in n:
            for pr in j['meshes'][n['mesh']]['primitives']:
                a=j['accessors'][pr['attributes']['POSITION']]
                mn,mx=np.array(a['min']),np.array(a['max'])
                for c in range(8):
                    p=np.array([mx[0] if c&1 else mn[0],mx[1] if c&2 else mn[1],mx[2] if c&4 else mn[2],1.0])
                    q=(M@p)[:3]; lo=np.minimum(lo,q); hi=np.maximum(hi,q)
        for k in n.get('children',[]): walk(k,M)
    sc=j['scenes'][j.get('scene',0)]
    for i in sc['nodes']: walk(i,np.eye(4))
    return lo,hi,has_col
art=sys.argv[1]
for f in sorted(glob.glob(os.path.join(art,'*.glb'))):
    b=bounds(f)
    if b: lo,hi,c=b; print(f"{os.path.basename(f):34s} min {np.round(lo,2)} max {np.round(hi,2)} col={c}")
