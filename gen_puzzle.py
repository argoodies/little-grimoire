#!/usr/bin/env python3
# 参数化生成 3x3 互锁拼图：输出每片多边形轮廓 + UV (puzzle.json) 和每片贴图 (textures/piece_N.png)。
# 相邻片共享同一条带凹凸的边，凹凸方向按固定世界方向计算，保证一凸一凹刚好咬合。
import json, math, random
from PIL import Image, ImageDraw, ImageFilter

random.seed(20260710)
N = 3                     # 3x3
P = 0.16                  # 凸起幅度（单元格比例）
NARC = 16                 # 每个凸起采样点
CREAM = (247, 244, 236, 255)
BLUE = (28, 104, 190, 255)
BLUE_HI = (96, 168, 232, 255)
PX = 240                  # 每单元格像素

# 内部边凸凹符号：竖线 x=1,2（按行），横线 y=1,2（按列）。±1 随机。
Vs = {(r, vx): random.choice((1, -1)) for r in range(N) for vx in (1, 2)}
Hs = {(c, hy): random.choice((1, -1)) for c in range(N) for hy in (1, 2)}

def edge(p0, p1, bump):
    # bump: 世界方向凸起向量或 None（直边）。返回从 p0 起（含）到 p1 前的点列。
    if bump is None:
        return [p0]
    (x0, y0), (x1, y1) = p0, p1
    L = math.hypot(x1 - x0, y1 - y0)
    dx, dy = (x1 - x0) / L, (y1 - y0) / L
    t0, t1 = 0.38, 0.62
    A = (x0 + dx * t0 * L, y0 + dy * t0 * L)
    B = (x0 + dx * t1 * L, y0 + dy * t1 * L)
    M = ((A[0] + B[0]) / 2, (A[1] + B[1]) / 2)
    r = math.hypot(B[0] - A[0], B[1] - A[1]) / 2
    bl = math.hypot(*bump)
    nx, ny = bump[0] / bl, bump[1] / bl
    a0 = math.atan2(A[1] - M[1], A[0] - M[0])
    # 选择让弧顶朝 bump 方向的旋转方向
    apex = (math.cos(a0 + math.pi / 2), math.sin(a0 + math.pi / 2))
    sgn = 1.0 if (apex[0] * nx + apex[1] * ny) > 0 else -1.0
    pts = [p0]
    for k in range(NARC + 1):
        ang = a0 + sgn * math.pi * k / NARC
        pts.append((M[0] + r * math.cos(ang), M[1] + r * math.sin(ang)))
    return pts

def piece_poly(r, c):
    x0, y0, x1, y1 = c, r, c + 1, r + 1
    BL, BR, TR, TL = (x0, y0), (x1, y0), (x1, y1), (x0, y1)
    # 底边 y=r
    b_bot = (0, Hs[(c, r)] * P) if r >= 1 else None
    # 右边 x=c+1
    b_rgt = (Vs[(r, c + 1)] * P, 0) if c <= 1 else None
    # 顶边 y=r+1
    b_top = (0, Hs[(c, r + 1)] * P) if r <= 1 else None
    # 左边 x=c
    b_lft = (Vs[(r, c)] * P, 0) if c >= 1 else None
    pts = []
    pts += edge(BL, BR, b_bot)
    pts += edge(BR, TR, b_rgt)
    pts += edge(TR, TL, b_top)
    pts += edge(TL, BL, b_lft)
    return pts

data = {"scale_hint": 1.0, "pieces": []}
CENTER = (N / 2.0, N / 2.0)

for r in range(N):
    for c in range(N):
        poly = piece_poly(r, c)
        xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
        minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
        bw, bh = maxx - minx, maxy - miny
        cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
        pad = 6                       # 像素留边
        W = int(bw * PX) + pad * 2
        H = int(bh * PX) + pad * 2

        def to_px(pt):
            return (pad + (pt[0] - minx) * PX, pad + (maxy - pt[1]) * PX)  # y 翻转（上为正）

        ppx = [to_px(p) for p in poly]
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.polygon(ppx, fill=CREAM)
        # 蓝色描边：外粗 + 内细高光，营造发光边
        d.line(ppx + [ppx[0]], fill=BLUE, width=int(0.05 * PX), joint="curve")
        d.line(ppx + [ppx[0]], fill=BLUE_HI, width=int(0.018 * PX), joint="curve")
        img = img.filter(ImageFilter.SMOOTH_MORE)
        idx = r * N + c
        img.save(f"textures/piece_{idx}.png")

        # 相对片中心的世界坐标 + UV（像素/尺寸）
        verts = [[p[0] - cx, p[1] - cy] for p in poly]
        uvs = [[px[0] / W, px[1] / H] for px in ppx]
        data["pieces"].append({
            "verts": verts,
            "uvs": uvs,
            "pos": [cx - CENTER[0], cy - CENTER[1]],   # 相对拼图中心
            "size": [bw, bh],
            "tex": f"res://textures/piece_{idx}.png",
        })

with open("puzzle.json", "w") as f:
    json.dump(data, f)
print("生成 9 片：puzzle.json + textures/piece_0..8.png")

# 预览：把 9 片贴图按位置合成，确认互锁
prev = Image.new("RGBA", (int(N * PX) + 40, int(N * PX) + 40), (20, 14, 28, 255))
for idx, pc in enumerate(data["pieces"]):
    im = Image.open(f"textures/piece_{idx}.png")
    px = 20 + int((pc["pos"][0] + CENTER[0] - pc["size"][0] / 2) * PX) - 6
    py = 20 + int((CENTER[1] - pc["pos"][1] - CENTER[1] - pc["size"][1] / 2) * PX) - 6
    prev.alpha_composite(im, (px, py))
prev.convert("RGB").save("/tmp/puzzle_preview.png")
print("预览 /tmp/puzzle_preview.png")
