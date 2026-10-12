#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
"""Writes the text-import corpus into Tests/corpus/encodings/.

Every file is synthetic and written byte for byte by this script, so the
output is identical from run to run. The .docx, .odt and .doc documents are
the exception: they are produced once from doc.rtf with macOS textutil (pass
--documents), and committed; their zip timestamps change on every run.

    /usr/bin/python3 -I Tests/corpus/scripts/make-encodings.py [--documents]

Afterwards refresh the manifest:

    cd Tests/corpus && find encodings -type f ! -name .DS_Store | sort | xargs shasum -a 256 > encodings.sha256
"""
import os
import struct
import subprocess
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "encodings")

LATIN = "Prism compares text files.\nCafé, naïve, façade, Ångström, smörgåsbord.\nLast line.\n"
JAPANESE = "日本語のテキストです。\r\nカタカナとひらがなと漢字。\r\n最後の行。\r\n"
WIDE = "Prism compares text files.\nUnicode: café, Ελληνικά, 日本語, 한국어.\nLast line.\n"


def write(name, data):
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)


def png():
    """A valid 2x2 RGB PNG."""
    def chunk(kind, body):
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)
    header = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
    rows = b"".join(b"\x00" + b"\xff\x00\x00\x00\xff\x00" for _ in range(2))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def zip_archive(path):
    """A zip with one text member and a fixed timestamp."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo("notes.txt", date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        z.writestr(info, LATIN)


def macho():
    """A 64-bit arm64 Mach-O header with no load commands, padded."""
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
    return header + b"\x00" * 96


def pdf():
    """A one-page PDF with two lines of Helvetica text."""
    stream = b"BT /F1 18 Tf 72 720 Td (Prism reads PDF text.) Tj 0 -28 Td (Second line here.) Tj ET\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return out


RTF = (b"{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Helvetica;}}\n"
       b"\\f0\\fs24 Prism reads {\\b rich} text.\\par\n"
       b"Caf\\'e9 au lait, second paragraph.\\par\n"
       b"Third line}\n")
RTF_TEXT = "Prism reads rich text.\nCafé au lait, second paragraph.\nThird line\n"


# file, kind, format or encoding, bom, line endings (as `prism sniff` reports)
EXPECTED = [
    ("utf8.txt", "text", "utf-8", "no", "lf"),
    ("utf8-bom.txt", "text", "utf-8", "yes", "lf"),
    ("utf16le-bom.txt", "text", "utf-16le", "yes", "lf"),
    ("utf16be-bom.txt", "text", "utf-16be", "yes", "lf"),
    ("utf16le.txt", "text", "utf-16le", "no", "lf"),
    ("latin1.txt", "text", "iso-8859-1", "no", "lf"),
    ("windows1252.txt", "text", "windows-1252", "no", "lf"),
    ("shift-jis.txt", "text", "shift_jis", "no", "crlf"),
    ("crlf.txt", "text", "utf-8", "no", "crlf"),
    ("mixed-crlf.txt", "text", "utf-8", "no", "mixed"),
    ("no-final-newline.txt", "text", "utf-8", "no", "lf"),
    ("empty.txt", "text", "utf-8", "no", "none"),
    ("image-png.bin", "binary", "-", "-", "-"),
    ("archive.zip", "binary", "-", "-", "-"),
    ("macho.bin", "binary", "-", "-", "-"),
    ("random.bin", "binary", "-", "-", "-"),
    ("doc.rtf", "document", "rtf", "-", "lf"),
    ("doc.pdf", "document", "pdf", "-", "lf"),
    ("doc.docx", "document", "docx", "-", "lf"),
    ("doc.odt", "document", "odt", "-", "lf"),
    ("doc.doc", "document", "doc", "-", "lf"),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    write("utf8.txt", WIDE.encode("utf-8"))
    write("utf8-bom.txt", b"\xef\xbb\xbf" + WIDE.encode("utf-8"))
    write("utf16le-bom.txt", b"\xff\xfe" + WIDE.encode("utf-16-le"))
    write("utf16be-bom.txt", b"\xfe\xff" + WIDE.encode("utf-16-be"))
    write("utf16le.txt", LATIN.encode("utf-16-le"))
    write("latin1.txt", LATIN.encode("iso-8859-1"))
    write("windows1252.txt", "“Quoted” – Prism costs €0.\nSecond line.\n".encode("cp1252"))
    write("shift-jis.txt", JAPANESE.encode("shift_jis"))
    write("crlf.txt", LATIN.replace("\n", "\r\n").encode("utf-8"))
    write("mixed-crlf.txt", b"first line\r\nsecond line\nthird line\r\nfourth line\rlast line\n")
    write("no-final-newline.txt", b"one\ntwo")
    write("empty.txt", b"")
    write("image-png.bin", png())
    zip_archive(os.path.join(OUT, "archive.zip"))
    write("macho.bin", macho())
    write("random.bin", bytes((i * 151 + 7) % 256 for i in range(4096)))
    write("doc.rtf", RTF)
    write("doc.pdf", pdf())
    write("doc.rtf.expected", RTF_TEXT.encode("utf-8"))
    write("doc.pdf.expected", b"Prism reads PDF text.\nSecond line here.\n")
    with open(os.path.join(OUT, "expected.tsv"), "w") as f:
        f.write("# file\tkind\tencoding-or-format\tbom\tline-endings\n")
        for row in EXPECTED:
            f.write("\t".join(row) + "\n")
    if "--documents" in sys.argv:
        for ext in ("docx", "odt", "doc"):
            subprocess.run(["textutil", "-convert", ext, os.path.join(OUT, "doc.rtf"),
                            "-output", os.path.join(OUT, "doc." + ext)], check=True)
            write("doc.%s.expected" % ext, RTF_TEXT.encode("utf-8"))


if __name__ == "__main__":
    main()
