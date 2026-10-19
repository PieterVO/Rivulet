"""flow_map.py <front.png> <flow.png> <glow.png>: the welcome animation's maps, from the app icon's front layer.
Requires numpy and Pillow.

The R sits in the middle half of a canvas twice its size, so its glow can spread past it.
flow.png: R = coarse and B = fine distance along the R from its top stroke (phase = (R*255 + B) / 256),
G = the R's brightness, blurred. glow.png: the same brightness blurred wide, for color spilling across the screen.
Distances are geodesic (through the strands, dearer through empty space), so color follows the curve.
"""
import heapq, sys
import numpy as np
from PIL import Image, ImageFilter

RW, RH = 480, 288
W, H = RW * 2, RH * 2
src = Image.open(sys.argv[1]).convert("RGBA").resize((RW, RH), Image.LANCZOS)
rgba = np.asarray(src).astype(np.float32) / 255
luma_r = (rgba[..., 0] * 0.3 + rgba[..., 1] * 0.59 + rgba[..., 2] * 0.11) * rgba[..., 3]
luma = np.zeros((H, W), np.float32)
luma[RH // 2:RH // 2 + RH, RW // 2:RW // 2 + RW] = luma_r

def blurred(a, radius):
    img = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(img).astype(np.float32) / 255

inside = blurred(luma * 4, 4) > 0.16
seed = (RH // 2 + int(RH * 0.19), RW // 2 + int(RW * 0.31))  # start of the R's top stroke
cost = np.where(inside, 1.0, 8.0)
dist = np.full((H, W), np.inf)
dist[seed] = 0
heap = [(0.0, seed)]
steps = [(-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1), (-1, -1, 1.414), (-1, 1, 1.414), (1, -1, 1.414), (1, 1, 1.414)]
while heap:
    d, (y, x) = heapq.heappop(heap)
    if d > dist[y, x]:
        continue
    for dy, dx, w in steps:
        ny, nx = y + dy, x + dx
        if 0 <= ny < H and 0 <= nx < W:
            nd = d + w * (cost[y, x] + cost[ny, nx]) / 2
            if nd < dist[ny, nx]:
                dist[ny, nx] = nd
                heapq.heappush(heap, (nd, (ny, nx)))

# Phase off the R comes from the nearest stretch of it, smoothed so the spill has no seams.
phase = np.clip(dist / dist[inside].max(), 0, 1)
phase = blurred(phase, 6) * 0.5 + phase * 0.5
# The tails trail on past the R: smear each side's ends outward along the way it was heading.
def centroid(m, w):
    ys, xs = np.nonzero(m)
    return np.array([(xs * w[m]).sum(), (ys * w[m]).sum()]) / w[m].sum()
trail = np.zeros_like(luma)
mid_x = W / 2
for left in (True, False):
    side = (np.arange(W)[None, :] < mid_x) if left else (np.arange(W)[None, :] >= mid_x)
    early = inside & side & (phase > 0.62) & (phase < 0.78)
    late = inside & side & (phase > 0.88)
    if early.sum() < 20 or late.sum() < 20:
        continue
    step = centroid(late, luma + 1e-3) - centroid(early, luma + 1e-3)
    step = step / np.linalg.norm(step) * 3
    ends = luma * (inside & side & (phase > 0.8))
    img = Image.fromarray((np.clip(ends, 0, 1) * 255).astype(np.uint8))
    for k in range(1, 90):
        shifted = np.asarray(img.transform(img.size, Image.AFFINE, (1, 0, -step[0] * k, 0, 1, -step[1] * k))).astype(np.float32) / 255
        trail = np.maximum(trail, shifted * 0.95 ** k)
luma = np.maximum(luma, trail * 0.45)

coarse = np.floor(phase * 255)
fine = np.round((phase * 255 - coarse) * 255)
body = blurred(luma * 1.6, 6) * 255
Image.fromarray(np.dstack([coarse, body, fine]).astype(np.uint8)).save(sys.argv[2])
glow = blurred(luma * 3, 40) * 0.6 + blurred(luma * 3, 90) * 0.4
glow = glow / max(glow.max(), 1e-6)
Image.fromarray((glow * 255).astype(np.uint8)).save(sys.argv[3])
