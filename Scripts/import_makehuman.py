#!/usr/bin/env python3
"""Convert MakeHuman 1.1 CC0 assets (hm08 base mesh, targets, default rig, eyes, face pose units)
into the compact binary container HumanCore loads at runtime (Sources/HumanCore/Resources/hm08.hhd.xz).

Usage: python3 Scripts/import_makehuman.py <makehuman checkout>/makehuman/data

Only CC0 assets are read (base mesh, targets, rig, weights, eyes, pose units). No MakeHuman program
code is used or copied. Container layout (little endian):
  magic "HHD1", then chunks: tag[4] uint32 length payload[length]
Units: meters (MakeHuman decimeters * 0.1), +Y up, the figure faces +Z.
"""
import sys, os, json, glob, struct, lzma, collections
import numpy as np

DATA = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Dev/reference/makehuman/makehuman/data')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Sources', 'HumanCore', 'Resources', 'hm08.hhd.xz')
SCALE = 0.1
Q = 1e-4  # target quantum: 0.1 mm


def p(*a):
    return os.path.join(DATA, *a)


# ---------------------------------------------------------------- base mesh
V, VT, FV, FT, FG = [], [], [], [], []
groups, gidx = [], {}
cur = 0
for line in open(p('3dobjs', 'base.obj')):
    if line.startswith('v '):
        V.append([float(x) for x in line.split()[1:4]])
    elif line.startswith('vt '):
        VT.append([float(x) for x in line.split()[1:3]])
    elif line.startswith('g '):
        name = line.split()[1]
        if name not in gidx:
            gidx[name] = len(groups); groups.append(name)
        cur = gidx[name]
    elif line.startswith('f '):
        c = [t.split('/') for t in line.split()[1:]]
        assert len(c) == 4
        FV.append([int(a[0]) - 1 for a in c]); FT.append([int(a[1]) - 1 for a in c]); FG.append(cur)
V = np.array(V, dtype=np.float64) * SCALE
VT = np.array(VT, dtype=np.float32)
NV = len(V)
print('verts', NV, 'uvs', len(VT), 'faces', len(FV), 'groups', len(groups))

chunks = []


def chunk(tag, payload):
    assert len(tag) == 4
    chunks.append(tag.encode() + struct.pack('<I', len(payload)) + payload)


def js(obj):
    return json.dumps(obj, separators=(',', ':')).encode()


chunk('POSN', V.astype(np.float32).tobytes())
chunk('UVCO', VT.tobytes())
chunk('FVTX', np.array(FV, dtype=np.uint32).tobytes())
chunk('FUVS', np.array(FT, dtype=np.uint32).tobytes())
chunk('FGRP', np.array(FG, dtype=np.uint16).tobytes())
chunk('GRPN', js(groups))

# ---------------------------------------------------------------- skeleton
sk = json.load(open(p('rigs', 'default.mhskel')))
bones = sk['bones']
order = []
def visit(name):
    order.append(name)
    for c in sorted(b for b, d in bones.items() if d['parent'] == name):
        visit(c)
for r in sorted(b for b, d in bones.items() if d['parent'] is None):
    visit(r)
bindex = {b: i for i, b in enumerate(order)}
skel = {
    'bones': [{'name': b, 'parent': bindex[bones[b]['parent']] if bones[b]['parent'] else -1,
               'head': bones[b]['head'], 'tail': bones[b]['tail'], 'plane': bones[b]['rotation_plane']} for b in order],
    'joints': sk['joints'],
    'planes': sk['planes'],
}
chunk('SKEL', js(skel))
print('bones', len(order))

# ---------------------------------------------------------------- weights (top 4, unorm16)
mhw = json.load(open(p('rigs', 'default_weights.mhw')))['weights']
inf = collections.defaultdict(list)
for b, lst in mhw.items():
    for vi, w in lst:
        inf[vi].append((w, bindex[b]))
W = np.zeros((NV, 4), dtype=np.uint16); B = np.zeros((NV, 4), dtype=np.uint16)
missing = 0
for vi in range(NV):
    l = sorted(inf.get(vi, []), reverse=True)[:4]
    if not l:
        missing += 1; continue
    s = sum(w for w, _ in l)
    ws = [w / s for w, _ in l]
    q = [int(round(w * 65535)) for w in ws]
    q[0] += 65535 - sum(q)
    for k, (w, b) in enumerate(l):
        B[vi, k] = b; W[vi, k] = q[k]
print('weightless verts', missing)
chunk('WBON', B.tobytes())
chunk('WGHT', W.tobytes())


# ---------------------------------------------------------------- targets
def load_target(path):
    idx, d = [], []
    for l in open(path):
        if l[0] == '#' or not l.strip():
            continue
        s = l.split(); idx.append(int(s[0])); d.append([float(s[1]), float(s[2]), float(s[3])])
    T = np.zeros((NV, 3))
    if idx:
        T[np.array(idx)] = np.array(d) * SCALE
    return T


def encode(name, T):
    Qt = np.round(T / Q).astype(np.int64)
    assert np.abs(Qt).max(initial=0) < 32767, name
    nz = np.nonzero(np.abs(Qt).sum(1))[0]
    steps = np.diff(np.concatenate([[0], nz]))
    # index steps > 65535 never happen (NV < 65536), keep uint16
    nb = name.encode()
    return (struct.pack('<H', len(nb)) + nb + struct.pack('<I', len(nz)) + steps.astype(np.uint16).tobytes()
            + Qt[nz].astype(np.int16).T.copy().tobytes()), len(nz)


blobs, total = [], 0
macro_names = []
families = collections.defaultdict(list)
macro_files = (sorted(glob.glob(p('targets', 'macrodetails', '*.target'))) + sorted(glob.glob(p('targets', 'macrodetails', 'height', '*.target')))
               + sorted(glob.glob(p('targets', 'macrodetails', 'proportions', '*.target'))) + sorted(glob.glob(p('targets', 'breast', '*cup*.target'))))
macro = {}
for f in macro_files:
    rel = os.path.relpath(f, p('targets'))[:-7]
    T = load_target(f)
    if not np.any(T):
        continue
    macro[rel] = T
    parts = rel.split('/')[-1].split('-')
    if rel.startswith('macrodetails/height/'):
        families['height/' + '-'.join([parts[0], parts[1], parts[-1]])].append(rel)
    elif rel.startswith('macrodetails/proportions/'):
        families['proportions/' + '-'.join([parts[0], parts[1], parts[-1]])].append(rel)
    elif rel.startswith('breast/'):
        families['breast/' + '-'.join([parts[1], parts[-2], parts[-1]])].append(rel)
    else:
        families[rel].append(rel)
# Family mean + residual per member: residuals are small and sparse after quantization.
fam_table = {}
for fam, members in families.items():
    if len(members) == 1:
        b, n = encode(members[0], macro[members[0]]); blobs.append(b); total += n
        fam_table[members[0]] = [members[0]]
        continue
    mean = np.mean([macro[m] for m in members], axis=0)
    b, n = encode('mean:' + fam, mean); blobs.append(b); total += n
    for m in members:
        b, n = encode(m, macro[m] - mean); blobs.append(b); total += n
        fam_table[m] = ['mean:' + fam, m]
print('macro targets', len(macro), 'families', len(families), 'entries', total)

detail_dirs = ['armslegs', 'asym', 'bodyshapes', 'buttocks', 'cheek', 'chin', 'ears', 'eyebrows', 'eyes', 'forehead', 'head', 'hip',
               'measure', 'mouth', 'neck', 'nose', 'pelvis', 'stomach', 'torso']
detail = []
for d in detail_dirs:
    for f in sorted(glob.glob(p('targets', d, '*.target'))):
        rel = os.path.relpath(f, p('targets'))[:-7]
        T = load_target(f)
        if not np.any(T):
            continue
        b, n = encode(rel, T); blobs.append(b); total += n
        detail.append(rel)
for f in sorted(glob.glob(p('targets', 'breast', '*.target'))):
    rel = os.path.relpath(f, p('targets'))[:-7]
    if 'cup' in rel:
        continue
    b, n = encode(rel, load_target(f)); blobs.append(b); total += n; detail.append(rel)
print('detail targets', len(detail), 'total entries', total)
chunk('TGTS', struct.pack('<I', len(blobs)) + b''.join(blobs))
chunk('MFAM', js(fam_table))

# Modifier table: name -> [minTarget|null, maxTarget|null] (slider -1...1), or [target] (0...1).
mods = {}
for fn in ['modeling_modifiers.json', 'measurement_modifiers.json', 'bodyshapes_modifiers.json']:
    for g in json.load(open(p('modifiers', fn))):
        for m in g['modifiers']:
            if 'target' not in m:
                continue
            base = m['target']
            if 'min' in m:
                key = f"{g['group']}/{base}-{m['min']}|{m['max']}"
                lo = f"{g['group']}/{base}-{m['min']}"; hi = f"{g['group']}/{base}-{m['max']}"
                mods[key] = [lo if lo in detail else None, hi if hi in detail else None]
            else:
                t = f"{g['group']}/{base}"
                if t in detail:
                    mods[f"{g['group']}/{base}"] = [t]
mods = {k: v for k, v in mods.items() if any(v)}
chunk('MODS', js(mods))
print('modifiers', len(mods))


# ---------------------------------------------------------------- eyes (high poly) fitted with mhclo
def load_obj(path):
    v, vt, f = [], [], []
    for line in open(path):
        if line.startswith('v '):
            v.append([float(x) for x in line.split()[1:4]])
        elif line.startswith('vt '):
            vt.append([float(x) for x in line.split()[1:3]])
        elif line.startswith('f '):
            c = [t.split('/') for t in line.split()[1:]]
            f.append(([int(a[0]) - 1 for a in c], [int(a[1]) - 1 for a in c]))
    return np.array(v) * SCALE, np.array(vt, dtype=np.float32), f


def load_mhclo(path):
    refs, scales = [], {}
    inverts = False
    for line in open(path):
        s = line.split()
        if not s or s[0].startswith('#'):
            continue
        if s[0] in ('x_scale', 'y_scale', 'z_scale'):
            scales[s[0][0]] = (int(s[1]), int(s[2]), float(s[3]) * SCALE)
        elif s[0] == 'verts':
            inverts = True
        elif inverts and len(s) == 9:
            refs.append([int(s[0]), int(s[1]), int(s[2]), float(s[3]), float(s[4]), float(s[5]),
                         float(s[6]) * SCALE, float(s[7]) * SCALE, float(s[8]) * SCALE])
        elif inverts and len(s) == 1:
            refs.append([int(s[0]), int(s[0]), int(s[0]), 1, 0, 0, 0, 0, 0])
        elif inverts and len(s) not in (1, 9):
            inverts = False
    return refs, scales


ev, evt, ef = load_obj(p('eyes', 'high-poly', 'high-poly.obj'))
refs, scales = load_mhclo(p('eyes', 'high-poly', 'high-poly.mhclo'))
assert len(refs) == len(ev), (len(refs), len(ev))
tris = []
for fv, ft in ef:
    for k in range(1, len(fv) - 1):
        tris.append([fv[0], fv[k], fv[k + 1], ft[0], ft[k], ft[k + 1]])
eye = {'scales': {k: list(v) for k, v in scales.items()}}
chunk('EYEJ', js(eye))
chunk('EYEV', ev.astype(np.float32).tobytes())
chunk('EYET', evt.tobytes())
chunk('EYEF', np.array(tris, dtype=np.uint32).tobytes())
chunk('EYER', np.array(refs, dtype=np.float32).tobytes())
print('eye verts', len(ev), 'tris', len(tris))

# ---------------------------------------------------------------- face pose units (BVH, one frame per unit)
fpu = json.load(open(p('poseunits', 'face-poseunits.json')))
chunk('FPUN', js(fpu['framemapping']))
chunk('FPUB', open(p('poseunits', 'face-poseunits.bvh'), 'rb').read())
chunk('LICN', b'MakeHuman 1.1 assets (hm08 base mesh, targets, default rig and weights, high-poly eyes, face pose units): CC0 1.0. '
      b'Copyright holders at release: Data Collection AB, Joel Palmius, Jonas Hauquier. http://www.makehumancommunity.org')

raw = b'HHD1' + b''.join(chunks)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
data = lzma.compress(raw, format=lzma.FORMAT_XZ, check=lzma.CHECK_NONE, preset=9 | lzma.PRESET_EXTREME)
open(OUT, 'wb').write(data)
print('raw MB', len(raw) / 1e6, 'xz MB', len(data) / 1e6, '->', os.path.normpath(OUT))
