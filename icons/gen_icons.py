#!/usr/bin/env python3
"""生成「新建文档」各类型的文件图标：白色页面 + 折角 + 类型色带 + 缩写标签。
输出 PNG 到 icons/png/，随后由 build_icons.sh 转 .icns。"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "png"
OUT.mkdir(parents=True, exist_ok=True)

SIZE = 1024

# 类型 → (标签, 色带颜色)
TYPES = {
    "docx":    ("DOC",  "#2B579A"),
    "xlsx":    ("XLS",  "#217346"),
    "pptx":    ("PPT",  "#D24726"),
    "pdf":     ("PDF",  "#C41E3A"),
    "md":      ("MD",   "#7B4FA6"),
    "csv":     ("CSV",  "#0E7C7B"),
    "txt":     ("TXT",  "#5A6B7A"),
    "rtf":     ("RTF",  "#3D6B9E"),
    "pages":   ("PGS",  "#E67E22"),
    "numbers": ("NUM",  "#27AE60"),
    "key":     ("KEY",  "#8E44AD"),
}

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Menlo.ttc",
]


def load_font(size: int):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def rounded_rect(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def render(ext: str, label: str, color_hex: str):
    color = tuple(int(color_hex[i:i + 2], 16) for i in (1, 3, 5))
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    margin, radius = 128, 96
    page = (margin, margin // 2, SIZE - margin, SIZE - margin // 2)
    # 页面（白色圆角矩形 + 浅灰描边）
    rounded_rect(d, page, radius, (255, 255, 255, 255), (205, 205, 210, 255), 6)

    # 右上角折角
    fold = 200
    x1, y1, x2, y2 = page
    d.polygon([(x2 - fold, y1), (x2, y1 + fold), (x2 - fold, y1 + fold)],
              fill=(229, 229, 234, 255))
    d.line([(x2 - fold, y1), (x2 - fold, y1 + fold), (x2, y1 + fold)],
           fill=(180, 180, 186, 255), width=8)

    # 底部色带（圆角）
    band_h = 230
    band = (x1 + 96, y2 - band_h - 128, x2 - 96, y2 - 128)
    rounded_rect(d, band, 48, color + (255,))

    # 色带文字
    font = load_font(190)
    text = label
    bbox = d.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cx, cy = (band[0] + band[2]) // 2, (band[1] + band[3]) // 2
    d.text((cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]), text,
           font=font, fill=(255, 255, 255, 255))

    img.save(OUT / f"icon-{ext}.png")
    print(f"icon-{ext}.png")


if __name__ == "__main__":
    for ext, (label, color) in TYPES.items():
        render(ext, label, color)
    print(f"完成：{len(TYPES)} 个图标 → {OUT}")
