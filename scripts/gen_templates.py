#!/usr/bin/env python3
"""生成空白文档模板（docx/pptx/xlsx/pdf/rtf）。
文件的类型显示由「自定义图标」机制负责（见 seticon/），模板本身保持空白。
pages/numbers/key 模板来自 MacNewFile 仓库（二进制 iWork 格式），为仓库静态文件。"""
import pathlib

from docx import Document

ROOT = pathlib.Path(__file__).resolve().parent.parent
T = ROOT / "templates"

# ---------- docx ----------
Document().save(T / "未命名.docx")
print("docx ok")

# ---------- pptx ----------
from pptx import Presentation

Presentation().save(T / "未命名.pptx")  # 默认含一张空白版式幻灯片
print("pptx ok")

# ---------- xlsx ----------
from openpyxl import Workbook

wb = Workbook()
wb.active.title = "Sheet1"
wb.save(T / "未命名.xlsx")
print("xlsx ok")

# ---------- pdf（手工构造的最小空白 PDF，A4）----------
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] "
    b"/Resources << >> /Contents 4 0 R >>",
]
content = b""
objs.append(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content))
out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = []
for i, o in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n" % (len(objs) + 1)
out += b"0000000000 65535 f \n"
for off in offsets:
    out += b"%010d 00000 n \n" % off
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
(T / "未命名.pdf").write_bytes(bytes(out))
print("pdf ok")

# ---------- rtf ----------
rtf = ("{\\rtf1\\ansi\\deff0\n"
       "{\\fonttbl{\\f0\\fswiss Helvetica;}}\n"
       "\\f0\\fs24\n\\par\n}\n")
(T / "未命名.rtf").write_text(rtf, encoding="ascii")
print("rtf ok")
