#!/usr/bin/env python3
"""Generate the committed synthetic mini-EPUBs for the Rust engine tests.

These fixtures are deliberately tiny and hand-built so they can be committed
(real books live under `assets/` and stay out of git). Each archive is a valid
OCF container:

* `mimetype` is the FIRST entry and stored uncompressed (EPUB requires this);
* `META-INF/container.xml` points at the OPF rootfile;
* the OPF carries Dublin Core metadata plus Calibre series/cover hints;
* every referenced image/font entry actually exists.

Run from anywhere:

    python3 test/fixtures/epub/generate.py

Regenerating must be byte-for-byte deterministic (fixed timestamps) so the
checked-in `.epub` files only change when the content does.
"""
from __future__ import annotations

import struct
import zlib
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Fixed DOS timestamp (2000-01-01 00:00:00) for reproducible archives.
_FIXED_DATE = (2000, 1, 1, 0, 0, 0)


def _png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """A minimal, valid RGB PNG (no external deps)."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def _xhtml(title: str, body: str) -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        f"<head><title>{title}</title></head>\n"
        f"<body><h1>{title}</h1><p>{body}</p></body>\n"
        "</html>\n"
    ).encode("utf-8")


def _container(rootfile: str) -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
        "  <rootfiles>\n"
        f'    <rootfile full-path="{rootfile}" '
        'media-type="application/oebps-package+xml"/>\n'
        "  </rootfiles>\n"
        "</container>\n"
    ).encode("utf-8")


def _write_epub(path: Path, entries: list[tuple[str, bytes, bool]]) -> None:
    """`entries` is a list of (name, data, compress). The mimetype is inserted
    first, stored uncompressed, as the OCF spec requires."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, data, compress in entries:
            info = zipfile.ZipInfo(name, date_time=_FIXED_DATE)
            info.compress_type = (
                zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
            )
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)


def build_minimal() -> None:
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">\n'
        '    <dc:title opf:file-as="Book, Minimal">Minimal Book</dc:title>\n'
        '    <dc:creator opf:file-as="Author, A.">A. Author</dc:creator>\n'
        "    <dc:description>A tiny synthetic book for Rust engine "
        "tests.</dc:description>\n"
        "    <dc:language>en</dc:language>\n"
        "    <dc:publisher>Burrow Test Press</dc:publisher>\n"
        "    <dc:date>2026-01-02</dc:date>\n"
        "    <dc:rights>Public Domain</dc:rights>\n"
        "    <dc:subject>Fiction</dc:subject>\n"
        "    <dc:subject>Testing</dc:subject>\n"
        '    <dc:identifier id="BookId" opf:scheme="ISBN">'
        "978-0-306-40615-7</dc:identifier>\n"
        '    <meta name="calibre:series" content="Burrow Chronicles"/>\n'
        '    <meta name="calibre:series_index" content="2"/>\n'
        '    <meta name="cover" content="cover-img"/>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="cover-img" href="Images/cover.png" '
        'media-type="image/png"/>\n'
        '    <item id="ch1" href="Text/ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        '    <item id="ch2" href="Text/ch2.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        '    <itemref idref="ch2"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "minimal.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/Images/cover.png", _png(4, 4, (200, 30, 30)), True),
            (
                "OEBPS/Text/ch1.xhtml",
                _xhtml("One", "The first chapter."),
                True,
            ),
            (
                "OEBPS/Text/ch2.xhtml",
                _xhtml("Two", "The second chapter."),
                True,
            ),
        ],
    )


def build_percent_path() -> None:
    # Cover href is percent-encoded (`%20`), the chapter href is a bare `%`
    # that must not throw, and one entry is referenced with a different case.
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">\n'
        "    <dc:title>Percent Paths</dc:title>\n"
        "    <dc:creator>P. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId" opf:scheme="ISBN">'
        "9780306406157</dc:identifier>\n"
        '    <meta name="cover" content="cv"/>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="cv" href="Images/Cover%20Art.png" '
        'media-type="image/png"/>\n'
        '    <item id="c1" href="Text/100%25_cover.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        '    <item id="c2" href="Text/CH2.XHTML" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="c1"/>\n'
        '    <itemref idref="c2"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "percent-path.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/Images/Cover Art.png", _png(4, 4, (30, 30, 200)), True),
            (
                "OEBPS/Text/100%_cover.xhtml",
                _xhtml("One", "Bare percent path."),
                True,
            ),
            ("OEBPS/Text/ch2.xhtml", _xhtml("Two", "Second."), True),
        ],
    )


def build_opaque_cover() -> None:
    # The cover filename deliberately does NOT contain "cover", so the
    # reader's last-resort filename scan cannot be what finds it. Cover
    # resolution must go through `meta name="cover"` -> manifest href.
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">\n'
        "    <dc:title>Opaque Cover</dc:title>\n"
        "    <dc:creator>O. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId" opf:scheme="ISBN">'
        "9780306406157</dc:identifier>\n"
        '    <meta name="cover" content="cv"/>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="cv" href="Images/front.png" media-type="image/png"/>\n'
        '    <item id="ch1" href="Text/ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "opaque-cover.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/Images/front.png", _png(4, 4, (30, 120, 30)), True),
            ("OEBPS/Text/ch1.xhtml", _xhtml("One", "Front cover."), True),
        ],
    )


def build_no_spine() -> None:
    # An empty `<spine/>`: the chapter list falls back to every XHTML manifest
    # entry. The manifest lists `ch10` before `ch2` so the expected order only
    # holds if the fallback sorts naturally (ch2 before ch10), not by manifest
    # order.
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>No Spine</dc:title>\n"
        "    <dc:creator>N. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:no-spine</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch10" href="Text/ch10.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        '    <item id="ch2" href="Text/ch2.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine/>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "no-spine.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/Text/ch10.xhtml", _xhtml("Ten", "Tenth."), True),
            ("OEBPS/Text/ch2.xhtml", _xhtml("Two", "Second."), True),
        ],
    )


def _nav_xhtml() -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops">\n'
        "<head><title>Contents</title></head>\n"
        "<body>\n"
        '  <nav epub:type="toc">\n'
        "    <ol>\n"
        '      <li><a href="Text/ch1.xhtml"><span>1</span> One</a></li>\n'
        '      <li><a href="Text/ch2.xhtml#sec%202">Two</a></li>\n'
        "    </ol>\n"
        "  </nav>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")


def build_nav() -> None:
    # EPUB3: the TOC lives in the `properties="nav"` document and there is no
    # NCX, so the nav path must supply the titles. The first label is mixed
    # content (`<span>1</span> One`) to pin document-order text concatenation.
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Nav Book</dc:title>\n"
        "    <dc:creator>N. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:nav-book</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>\n'
        '    <item id="ch1" href="Text/ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        '    <item id="ch2" href="Text/ch2.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        '    <itemref idref="ch2"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "nav.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/nav.xhtml", _nav_xhtml(), True),
            ("OEBPS/Text/ch1.xhtml", _xhtml("One", "First."), True),
            ("OEBPS/Text/ch2.xhtml", _xhtml("Two", "Second."), True),
        ],
    )


def _ncx() -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        '  <head><meta name="dtb:uid" content="urn:uuid:ncx-book"/></head>\n'
        "  <docTitle><text>Ncx Book</text></docTitle>\n"
        "  <navMap>\n"
        '    <navPoint id="n1" playOrder="1">\n'
        "      <navLabel><text>One</text></navLabel>\n"
        '      <content src="Text/ch1.xhtml"/>\n'
        "    </navPoint>\n"
        '    <navPoint id="n2" playOrder="2">\n'
        "      <navLabel><text>Two</text></navLabel>\n"
        '      <content src="Text/ch2.xhtml"/>\n'
        "    </navPoint>\n"
        "  </navMap>\n"
        "</ncx>\n"
    ).encode("utf-8")


def build_ncx() -> None:
    # EPUB2: no nav document, so the spine's `toc="ncx"` attribute points at the
    # NCX, which supplies the titles.
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">\n'
        "    <dc:title>Ncx Book</dc:title>\n"
        "    <dc:creator>N. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:ncx-book</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ncx" href="toc.ncx" '
        'media-type="application/x-dtbncx+xml"/>\n'
        '    <item id="ch1" href="Text/ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        '    <item id="ch2" href="Text/ch2.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        '  <spine toc="ncx">\n'
        '    <itemref idref="ch1"/>\n'
        '    <itemref idref="ch2"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "ncx.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/toc.ncx", _ncx(), True),
            ("OEBPS/Text/ch1.xhtml", _xhtml("One", "First."), True),
            ("OEBPS/Text/ch2.xhtml", _xhtml("Two", "Second."), True),
        ],
    )


def main() -> None:
    build_minimal()
    build_percent_path()
    build_opaque_cover()
    build_no_spine()
    build_nav()
    build_ncx()
    print("wrote fixtures to", HERE)


if __name__ == "__main__":
    main()
