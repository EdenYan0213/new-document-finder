#!/usr/bin/env python3
"""重新生成 docx/pptx/xlsx/pdf/rtf 模板（含浅灰占位文字，避免 QuickLook 缩略图空白）。
pages/numbers/key 模板来自 MacNewFile 仓库（二进制 iWork 格式），保持仓库静态文件。"""
import pathlib

from docx import Document
from docx.shared import Pt, RGBColor

ROOT = pathlib.Path(__file__).resolve().parent.parent
T = ROOT / "templates"
GRAY = RGBColor(0xB0, 0xB0, 0xB0)

# ---------- docx ----------
d = Document()
p = d.add_paragraph()
r = p.add_run("未命名文档")
r.font.size = Pt(14)
r.font.color.rgb = GRAY
r.italic = True
d.save(T / "未命名.docx")
print("docx ok")

# ---------- pptx ----------
from pptx import Presentation
from pptx.dml.color import RGBColor as PRGB
from pptx.util import Inches as PInches, Pt as PPt

prs = Presentation()
slide = prs.slides.add_slide(prs.slide_layouts[6])  # 空白版式
box = slide.shapes.add_textbox(PInches(4.2), PInches(3.1), PInches(5.6), PInches(0.8))
tf = box.text_frame
tf.text = "未命名演示文稿"
para = tf.paragraphs[0]
para.font.size = PPt(24)
para.font.color.rgb = PRGB(0xB0, 0xB0, 0xB0)
prs.save(T / "未命名.pptx")
print("pptx ok")

# ---------- xlsx ----------
from openpyxl import Workbook
from openpyxl.styles import Font as XFont

wb = Workbook()
ws = wb.active
ws["A1"] = "未命名表格"
ws["A1"].font = XFont(color="FFAAAAAA", italic=True)
wb.save(T / "未命名.xlsx")
print("xlsx ok")

# ---------- pdf（手工构造，含居中灰字）----------
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] "
    b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
]
content = (b"BT /F1 40 Tf 0.72 0.72 0.72 rg 1 0 0 1 168 430 Tm "
           b"(Untitled PDF Document) Tj ET")
objs.append(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content))
objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
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

# ---------- rtf（中文用 RTF unicode 转义）----------
def rtf_escape(s: str) -> str:
    return "".join(ch if ord(ch) < 128 else "\\u%d?" % ord(ch) for ch in s)

rtf = ("{\\rtf1\\ansi\\deff0\n"
       "{\\fonttbl{\\f0\\fswiss PingFang SC;}}\n"
       "\\f0\\fs48\\cf7 " + rtf_escape("未命名文档") + "\\par\n}\n")
(T / "未命名.rtf").write_text(rtf, encoding="ascii")
print("rtf ok")
