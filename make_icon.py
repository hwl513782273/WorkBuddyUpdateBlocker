from PIL import Image, ImageDraw
import math

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# 圆角背景（squircle 近似：圆角半径比≈0.226）
r = int(S * 0.226)
d.rounded_rectangle([0, 0, S, S], radius=r, fill=(28, 30, 38, 255))

# 禁止符号（白）
cx = cy = S // 2
white = (235, 240, 255, 255)
ring = int(S * 0.30)    # 环半径
lw = int(S * 0.055)     # 线宽
d.ellipse([cx - ring, cy - ring, cx + ring, cy + ring], outline=white, width=lw)

# 斜杠（从左下到右上，45°）
a = math.radians(45)
off = ring * 0.72
x0, y0 = cx - off * math.cos(a), cy + off * math.sin(a)
x1, y1 = cx + off * math.cos(a), cy - off * math.sin(a)
d.line([(x0, y0), (x1, y1)], fill=white, width=lw)

img.save("icon.png")
print("icon.png written", img.size)
