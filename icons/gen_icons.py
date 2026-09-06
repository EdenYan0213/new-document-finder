#!/usr/bin/env python3
"""生成「新建文档」各类型的文件图标（PNG → icns 一条龙）。

图标设计：白色页面 + 右上折角 + 类型色带 + 缩写标签。
产物：icons/icon-<ext>.icns（供宿主 App UTI 声明与 seticon 运行时使用）。
依赖：Pillow（pip install pillow）、macOS 自带 sips / iconutil。
"""
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
PNG_DIR = ROOT / "png"
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


def render(ext: str, label: str, color_hex: str) -> Path:
    color = tuple(int(color_hex[i:i + 2], 16) for i in (1, 3, 5))
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    margin, radius = 128, 96
    page = (margin, margin // 2, SIZE - margin, SIZE - margin // 2)
    d.rounded_rectangle(page, radius=radius, fill=(255, 255, 255, 255),
                        outline=(205, 205, 210, 255), width=6)

    fold = 200
    x1, y1, x2, y2 = page
    d.polygon([(x2 - fold, y1), (x2, y1 + fold), (x2 - fold, y1 + fold)],
              fill=(229, 229, 234, 255))
    d.line([(x2 - fold, y1), (x2 - fold, y1 + fold), (x2, y1 + fold)],
           fill=(180, 180, 186, 255), width=8)

    band_h = 230
    band = (x1 + 96, y2 - band_h - 128, x2 - 96, y2 - 128)
    d.rounded_rectangle(band, radius=48, fill=color + (255,))

    font = load_font(190)
    bbox = d.textbbox((0, 0), label, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cx, cy = (band[0] + band[2]) // 2, (band[1] + band[3]) // 2
    d.text((cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]), label,
           font=font, fill=(255, 255, 255, 255))

    out = PNG_DIR / f"icon-{ext}.png"
    img.save(out)
    return out


def to_icns(png: Path, ext: str):
    iconset = PNG_DIR / f"icon-{ext}.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for s in (16, 32, 64, 128, 256, 512):
        subprocess.run(["sips", "-z", str(s), str(s), str(png),
                        "--out", str(iconset / f"icon_{s}x{s}.png")],
                       check=True, capture_output=True)
        d = s * 2
        subprocess.run(["sips", "-z", str(d), str(d), str(png),
                        "--out", str(iconset / f"icon_{s}x{s}@2x.png")],
                       check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(ROOT / f"icon-{ext}.icns")],
                   check=True, capture_output=True)


if __name__ == "__main__":
    PNG_DIR.mkdir(parents=True, exist_ok=True)
    for ext, (label, color) in TYPES.items():
        to_icns(render(ext, label, color), ext)
        print(f"icon-{ext}.icns")
    print(f"完成：{len(TYPES)} 个图标 → {ROOT}")
