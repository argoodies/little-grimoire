#!/usr/bin/env python3
# 解析 GLB（二进制 glTF）→ 取世界空间三角形 → 体素化 → 导出占据网格 crystal.json。
# 仅用 numpy。占据判定：对每个 (x,y) 列沿 +Z 射线数三角形交点，成对区间填实。
import json, struct, numpy as np

SRC = "/root/.cc-connect/attachments/blue crystal block 3d model.glb"
RES = 40                      # 最长轴体素数

def parse_glb(path):
    b = open(path, "rb").read()
    assert b[:4] == b"glTF"
    ln = struct.unpack("<I", b[8:12])[0]
    off = 12
    js = None; bins = b""
    while off < ln:
        clen, ctype = struct.unpack("<II", b[off:off+8])
        data = b[off+8:off+8+clen]
        if ctype == 0x4E4F534A:      # JSON
            js = json.loads(data.decode("utf-8"))
        elif ctype == 0x004E4942:    # BIN
            bins = data
        off += 8 + clen
    return js, bins

CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

def accessor(gltf, bins, i):
    acc = gltf["accessors"][i]
    bv = gltf["bufferViews"][acc["bufferView"]]
    comp, size = CT[acc["componentType"]]
    n = NC[acc["type"]]
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride", size * n)
    out = np.empty((acc["count"], n), dtype=np.float64)
    for k in range(acc["count"]):
        o = base + k * stride
        vals = struct.unpack("<" + comp * n, bins[o:o + size * n])
        out[k] = vals
    return out

def node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T  # 列主 → 行主
    m = np.eye(4)
    if "scale" in node:
        m = np.diag(node["scale"] + [1.0]) @ m
    if "rotation" in node:
        x, y, z, w = node["rotation"]
        r = np.array([
            [1-2*(y*y+z*z), 2*(x*y-z*w),   2*(x*z+y*w),   0],
            [2*(x*y+z*w),   1-2*(x*x+z*z), 2*(y*z-x*w),   0],
            [2*(x*z-y*w),   2*(y*z+x*w),   1-2*(x*x+y*y), 0],
            [0, 0, 0, 1]])
        m = r @ m
    if "translation" in node:
        t = np.eye(4); t[:3, 3] = node["translation"]; m = t @ m
    return m

gltf, bins = parse_glb(SRC)
tris = []

def walk(ni, parent):
    node = gltf["nodes"][ni]
    world = parent @ node_matrix(node)
    if "mesh" in node:
        for prim in gltf["meshes"][node["mesh"]]["primitives"]:
            pos = accessor(gltf, bins, prim["attributes"]["POSITION"])
            ph = np.hstack([pos, np.ones((len(pos), 1))])
            wp = (world @ ph.T).T[:, :3]
            if "indices" in prim:
                idx = accessor(gltf, bins, prim["indices"]).astype(int).ravel()
            else:
                idx = np.arange(len(pos))
            tri = wp[idx].reshape(-1, 3, 3)
            tris.append(tri)
    for c in node.get("children", []):
        walk(c, world)

scene = gltf.get("scene", 0)
for ni in gltf["scenes"][scene]["nodes"]:
    walk(ni, np.eye(4))

T = np.concatenate(tris, axis=0)
print("三角形", len(T))
mn = T.reshape(-1, 3).min(0); mx = T.reshape(-1, 3).max(0)
ext = mx - mn
pitch = ext.max() / RES
nx, ny, nz = np.maximum(1, np.ceil(ext / pitch).astype(int) + 1)
print("dims", nx, ny, nz, "pitch", round(pitch, 4))

# 体素中心网格坐标
xs = mn[0] + (np.arange(nx) + 0.5) * pitch
ys = mn[1] + (np.arange(ny) + 0.5) * pitch
zs = mn[2] + (np.arange(nz) + 0.5) * pitch

# 三角形 XY 投影 + z
A = T[:, 0]; B = T[:, 1]; C = T[:, 2]
ax, ay = A[:, 0], A[:, 1]; bx, by = B[:, 0], B[:, 1]; cx, cy = C[:, 0], C[:, 1]
det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
valid = np.abs(det) > 1e-12

occ = np.zeros((nx, ny, nz), dtype=bool)
for ix in range(nx):
    px = xs[ix]
    for iy in range(ny):
        py = ys[iy]
        l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy))
        l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy))
        with np.errstate(divide="ignore", invalid="ignore"):
            a = l1 / det; b = l2 / det; c = 1 - a - b
        inside = valid & (a >= 0) & (b >= 0) & (c >= 0)
        if not inside.any():
            continue
        zc = a[inside] * A[inside, 2] + b[inside] * B[inside, 2] + c[inside] * C[inside, 2]
        zc = np.sort(zc)
        # 成对区间填实
        for k in range(0, len(zc) - 1, 2):
            lo, hi = zc[k], zc[k + 1]
            sel = (zs >= lo) & (zs <= hi)
            occ[ix, iy, sel] = True

vox = np.argwhere(occ)
print("占据体素", len(vox))
flat = (vox[:, 2] * (nx * ny) + vox[:, 1] * nx + vox[:, 0]).tolist()
json.dump({"nx": int(nx), "ny": int(ny), "nz": int(nz), "voxels": flat}, open("crystal.json", "w"))
print("写出 crystal.json")
