#!/usr/bin/env python3
"""生成 1024x1024 应用图标"""
from PIL import Image, ImageDraw, ImageFilter
import math

S = 1024

# 背景渐变（深蓝 → 近黑）
img = Image.new("RGB", (S, S), (10, 12, 20))
d = ImageDraw.Draw(img)
top = (26, 36, 78)
bottom = (8, 10, 18)
for y in range(S):
    t = y / (S - 1)
    r = int(top[0] + (bottom[0] - top[0]) * t)
    g = int(top[1] + (bottom[1] - top[1]) * t)
    b = int(top[2] + (bottom[2] - top[2]) * t)
    d.line([(0, y), (S, y)], fill=(r, g, b))

# 左上角光晕
glow = Image.new("RGB", (S, S), (0, 0, 0))
gd = ImageDraw.Draw(glow)
for i in range(26, 0, -1):
    rr = 380 * i / 26
    alpha = int(40 * (1 - i / 26))
    gd.ellipse([300 - rr, 250 - rr, 300 + rr, 250 + rr], fill=(60, 100, 255))
glow = glow.filter(ImageFilter.GaussianBlur(90))
img = Image.blend(img, Image.blend(img, glow, 0.55), 0.55)
d = ImageDraw.Draw(img)

cx, cy = 512, 470
R = 268

# 地球外环
for w, col in [(30, (110, 150, 255)), (14, (170, 200, 255))]:
    d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=col, width=w)

# 经线（三条竖椭圆）
for k in (0.35, 0.68, 1.0):
    rx = int(R * k)
    d.ellipse([cx - rx, cy - R, cx + rx, cy + R], outline=(110, 150, 255), width=12)

# 纬线
for k in (-0.55, 0.0, 0.55):
    ry = int(R * 0.26)
    yy = int(cy + R * k)
    d.ellipse([cx - R, yy - ry, cx + R, yy + ry], outline=(110, 150, 255), width=12)
    # 只保留圆内部分：用遮罩裁掉外部
mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)
md.ellipse([cx - R, cy - R, cx + R, cy + R], fill=255)
inner = img.copy()
img = Image.composite(inner, img, mask)
# 把地球内的线条重新画一遍（简单起见重绘并在圆内裁剪）
earth = Image.new("RGB", (S, S), (0, 0, 0))
ed = ImageDraw.Draw(earth)
for k in (-0.55, 0.0, 0.55):
    ry = int(R * 0.26)
    yy = int(cy + R * k)
    ed.ellipse([cx - R, yy - ry, cx + R, yy + ry], outline=(110, 150, 255), width=12)
earth = earth.filter(ImageFilter.GaussianBlur(0.5))
img = Image.composite(earth, img, mask)
d = ImageDraw.Draw(img)

# 代码符号 </> 放在地球中心
def chevron(px, py, size, flip, color, width=22):
    if not flip:
        d.line([(px + size, py - size), (px, py), (px + size, py + size)], fill=color, width=width, joint="curve")
    else:
        d.line([(px, py - size), (px + size, py), (px, py + size)], fill=color, width=width, joint="curve")

chevron(cx - 96, cy, 54, False, (74, 222, 128))
chevron(cx + 96, cy, 54, True, (74, 222, 128))
# 斜杠
d.line([(cx + 26, cy - 66), (cx - 26, cy + 66)], fill=(74, 222, 128), width=22)

# 底部小圆点（脚本运行指示灯）
for i, col in enumerate([(74, 222, 128), (110, 150, 255), (255, 190, 90)]):
    x = cx - 60 + i * 60
    d.ellipse([x - 9, 812 - 9, x + 9, 812 + 9], fill=col)

# 边缘轻微暗角
vignette = Image.new("L", (S, S), 0)
vd = ImageDraw.Draw(vignette)
vd.ellipse([-200, -200, S + 200, S + 200], fill=255)
vignette = vignette.filter(ImageFilter.GaussianBlur(120))
dark = Image.new("RGB", (S, S), (5, 6, 12))
img = Image.composite(img, dark, vignette)

img.save("Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png", "PNG")
print("icon written")
