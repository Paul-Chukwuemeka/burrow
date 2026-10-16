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


def _raw_xhtml(title: str, body: str) -> bytes:
    """Like `_xhtml` but the body markup is taken verbatim (no wrapping `<p>`),
    so a fixture can carry malformed or scripted content."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        f"<head><title>{title}</title></head>\n"
        f"<body>{body}</body>\n"
        "</html>\n"
    ).encode("utf-8")


def _write_chapter_epub(
    name: str,
    title: str,
    chapters: list[tuple[str, str, bytes]],
) -> None:
    """Writes a minimal EPUB3 with `(id, href, xhtml_bytes)` chapters under
    `OEBPS/`, in spine order. Used by the XHTML/block-tree fixtures."""
    items = "\n".join(
        f'    <item id="{cid}" href="{href}" '
        'media-type="application/xhtml+xml"/>'
        for cid, href, _ in chapters
    )
    refs = "\n".join(f'    <itemref idref="{cid}"/>' for cid, _, _ in chapters)
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f"    <dc:title>{title}</dc:title>\n"
        "    <dc:creator>T. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        f'    <dc:identifier id="BookId">urn:uuid:{name}</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        f"{items}\n"
        "  </manifest>\n"
        "  <spine>\n"
        f"{refs}\n"
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    entries: list[tuple[str, bytes, bool]] = [
        ("mimetype", b"application/epub+zip", False),
        ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
        ("OEBPS/content.opf", opf, True),
    ]
    entries.extend((f"OEBPS/{href}", data, True) for _, href, data in chapters)
    _write_epub(HERE / name, entries)



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


def build_malformed() -> None:
    # ch1 leaves `<div>` and both `<p>`s unclosed; the HTML5 parser must
    # recover and keep "Chapter one body". ch2 is well-formed and must be
    # unaffected (Review Focus #4).
    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head><title>One</title></head>\n"
        "<body>\n"
        '  <div class="wrap">\n'
        "    <h1>Chapter one</h1>\n"
        "    <p>Chapter one body\n"
        "    <p>Chapter one second paragraph\n"
        "  </div>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")
    _write_chapter_epub(
        "malformed.epub",
        "Malformed",
        [
            ("ch1", "ch1.xhtml", ch1),
            ("ch2", "ch2.xhtml", _xhtml("Two", "Chapter two body")),
        ],
    )


def build_nonbmp() -> None:
    # `A😀B` is four UTF-16 code units (`A` + surrogate pair + `B`); the
    # paragraph's text_range must be (0, 4), not (0, 1 + 4 bytes + 1). A second
    # paragraph exercises an astral CJK-ish char beyond the surrogate block.
    body = (
        "<p>A\U0001F600B</p>\n"
        "<p>\U00010348 tail</p>\n"
        # Inline-sibling spaces must survive: this paragraph's children are all
        # inline, so the spaces are rendered content, not inter-block layout.
        "<p>a <em>b</em> <em>c</em></p>\n"
    )
    _write_chapter_epub(
        "nonbmp.epub",
        "Non BMP",
        [("ch1", "ch1.xhtml", _raw_xhtml("One", body))],
    )


def build_scripted() -> None:
    # Contains scripted content and absolute URLs. The parser must drop the
    # `<script>` subtree and never fetch the remote `<img>`/`<a>` targets
    # (spec criterion 8 / D9).
    body = (
        "<h1>Scripted</h1>\n"
        "<p>Safe body text.</p>\n"
        "<script>alert('boom')</script>\n"
        '<p><img src="https://example.com/tracker.png" alt="remote"/></p>\n'
        '<p><a href="https://example.com/x">external</a></p>\n'
    )
    _write_chapter_epub(
        "scripted.epub",
        "Scripted",
        [("ch1", "ch1.xhtml", _raw_xhtml("One", body))],
    )


def build_repeated_paragraphs() -> None:
    # Two identical `<p class="note">` elements styled by an inline `<style>`
    # rule. The Dart substring-mapping cascade styles the first twice; the Rust
    # selector cascade must style both (Review Focus #2). The inline `<style>`
    # also exercises the in-document stylesheet path.
    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head>\n"
        "<title>Repeated</title>\n"
        "<style>\n"
        ".note { font-size: 14px; color: #333333; }\n"
        "p { margin-top: 2px; margin-bottom: 2px; }\n"
        "</style>\n"
        "</head>\n"
        "<body>\n"
        "<h1>Repeated</h1>\n"
        '<p class="note">Same text.</p>\n'
        '<p class="note">Same text.</p>\n'
        "<p>Plain.</p>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Repeated Paragraphs</dc:title>\n"
        "    <dc:creator>R. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:repeated</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "repeated-paragraphs.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
        ],
    )


def build_css_only_runs() -> None:
    # Regression fixture for the reader "laying out pages" freeze: every styled
    # node here is class-styled and the chapter has no emphasis markup at all,
    # so the projected run list carries CSS runs only — nested node ranges,
    # including a parent/child pair with identical extents. Those runs must come
    # out sorted, disjoint and in-bounds; when they overlap, the Dart paginator
    # re-emits covered text while measuring, line offsets run past the chapter
    # body and the first pagination pass dies on a RangeError (silently, in
    # release builds).
    css = (
        ".wrap { color: #111111; }\n"
        ".para { font-size: 15px; }\n"
        ".em { font-weight: 700; }\n"
        ".outer { color: #222222; }\n"
        ".inner { font-size: 14px; }\n"
        ".tail { font-size: 16px; }\n"
    )

    filler = (
        "Nested class styling must not corrupt run offsets. An overlapping "
        "run makes the paginator measure text that is not there, so every "
        "line offset past the duplicated span lands out of range. "
    )

    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head>\n"
        "<title>CSS Only</title>\n"
        "<style>\n" + css + "</style>\n"
        "</head>\n"
        "<body>\n"
        "<h1>CSS Only</h1>\n"
        '<div class="wrap">\n'
        f'<p class="para">{filler}<span class="em">{filler}</span>{filler}</p>\n'
        f'<div class="outer"><p class="inner">{filler}</p></div>\n'
        f'<p class="tail">{filler}</p>\n'
        "</div>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>CSS Only Runs</dc:title>\n"
        "    <dc:creator>C. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:css-only-runs</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "css-only-runs.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
        ],
    )


def build_external_css() -> None:
    # External stylesheet with an `@font-face`, a tag rule, a class rule (to pin
    # specificity), a descendant combinator, and an `align` presentational hint.
    # The font `src` is relative to `styles/`, so it must resolve against the
    # CSS file's own directory (Review Focus #2 / cascade href resolution).
    # `url()` uses double quotes: the Dart font-src regex only recognises
    # straight/curly double quotes, so a single-quoted `url()` would make the
    # Dart and Rust srcs diverge (Rust strips the quotes; Dart keeps them).
    # Single-quote handling is unit-tested on the Rust side instead.
    css = (
        "@font-face {\n"
        "  font-family: 'Burrow Serif';\n"
        '  src: url("../fonts/burrow.woff2") format("woff2");\n'
        "}\n"
        "body { font-family: 'Burrow Serif', serif; }\n"
        "p { font-size: 12px; margin-top: 1em; margin-bottom: 1em; }\n"
        ".note { font-size: 14px; color: #336699; }\n"
        ".title { font-size: 24px; }\n"
        ".box p { text-align: justify; }\n"
    ).encode("utf-8")

    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head>\n"
        "<title>Styled</title>\n"
        '<link rel="stylesheet" type="text/css" href="styles/main.css"/>\n'
        "</head>\n"
        "<body>\n"
        '<h1 class="title">Styled Chapter</h1>\n'
        '<p class="note">First note.</p>\n'
        '<p class="note">Second note.</p>\n'
        '<div class="box"><p>Nested paragraph.</p></div>\n'
        '<p align="right">Hinted paragraph.</p>\n'
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>External CSS</dc:title>\n"
        "    <dc:creator>C. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:external-css</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="css1" href="styles/main.css" media-type="text/css"/>\n'
        '    <item id="font1" href="fonts/burrow.woff2" '
        'media-type="font/woff2"/>\n'
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "external-css.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
            ("OEBPS/styles/main.css", css, True),
            # A placeholder font file so the resolved src points at a real
            # entry (the cascade stores the reference; Task 8 loads the bytes).
            ("OEBPS/fonts/burrow.woff2", b"wOF2\x00\x01\x00\x00dummy", True),
        ],
    )


def build_projection() -> None:
    # Task 7 fixture for the flat-run projection. One chapter exercises every
    # projection contract at once: a non-BMP emoji inside an `<em>` run (UTF-16
    # offsets), an inline `<img>` that resolves to a real archive entry (a
    # single `\uFFFC` placeholder + intrinsic size), an inline `<style>` with a
    # class rule whose `max-width: 100%` must stay symbolic, and a blockquote
    # (quote runs). The `<img>` also carries numeric width/height attributes.
    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head>\n"
        "<title>Projection</title>\n"
        "<style>\n"
        ".note { color: #336699; font-size: 14px; }\n"
        ".wide { max-width: 100%; }\n"
        "</style>\n"
        "</head>\n"
        "<body>\n"
        "<h1>Projection</h1>\n"
        "<p>Intro <em>emoji \U0001F600 run</em> tail</p>\n"
        '<p class="note">Styled note.</p>\n'
        "<blockquote><p>Quoted text.</p></blockquote>\n"
        '<p><img src="Images/pic.png" alt="tiny" width="8" height="4" '
        'class="wide"/></p>\n'
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Projection</dc:title>\n"
        "    <dc:creator>P. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:projection</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="img1" href="Images/pic.png" media-type="image/png"/>\n'
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "projection.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/Images/pic.png", _png(8, 4, (10, 200, 40)), True),
            ("OEBPS/ch1.xhtml", ch1, True),
        ],
    )


def build_missing_image() -> None:
    # Task 8 fixture: `ch1.xhtml` references `Images/ghost.png`, which is
    # deliberately NOT in the archive. The projection must keep a sized
    # placeholder (an `ImageRun` with `source_key=None`) instead of failing
    # the book; `read_resource` for the missing key must error so the Dart
    # lazy loader skips it.
    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head><title>Missing</title></head>\n"
        "<body>\n"
        "<h1>Missing</h1>\n"
        "<p>Before <img src=\"Images/ghost.png\" alt=\"ghost\"/> after.</p>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Missing Image</dc:title>\n"
        "    <dc:creator>M. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:missing-image</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "missing-image.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
        ],
    )


def build_embedded_font() -> None:
    # Task 8 fixture: an external stylesheet declaring one `@font-face`
    # whose file exists in the archive. `font_faces` must expose the family
    # with a resolvable `src` key; `read_resource` materialises its bytes.
    css = (
        "@font-face {\n"
        "  font-family: 'Burrow Serif';\n"
        '  src: url("../fonts/burrow.woff2") format("woff2");\n'
        "}\n"
        "p { font-family: 'Burrow Serif', serif; }\n"
    ).encode("utf-8")

    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head>\n"
        "<title>Fonts</title>\n"
        '<link rel="stylesheet" type="text/css" href="styles/main.css"/>\n'
        "</head>\n"
        "<body>\n"
        "<h1>Fonts</h1>\n"
        "<p>Set in Burrow Serif.</p>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Embedded Font</dc:title>\n"
        "    <dc:creator>F. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:embedded-font</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="css1" href="styles/main.css" media-type="text/css"/>\n'
        '    <item id="font1" href="fonts/burrow.woff2" '
        'media-type="font/woff2"/>\n'
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "embedded-font.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
            ("OEBPS/styles/main.css", css, True),
            # A placeholder font file so the resolved src points at a real
            # entry (the cascade stores the reference; Task 8 loads the bytes).
            ("OEBPS/fonts/burrow.woff2", b"wOF2\x00\x01\x00\x00dummy", True),
        ],
    )


def build_anchor_split() -> None:    # Task 7 fix fixture: a SINGLE spine document holding three chapters,
    # distinguished only by TOC `#fragment` anchors (the anchor-split case the
    # per-spine projection regressed on). Each section opens with the heading
    # its TOC entry names, so the heading strip fires; the second section
    # carries an `<em>` run (run rebasing), the third an `<img>` (image
    # rebasing). The third anchor id contains a space while the TOC fragment
    # is percent-encoded (`sec%202`), pinning the anchor-offset tolerance.
    ch = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head><title>Split Book</title></head>\n"
        "<body>\n"
        '<h2 id="part1">Part One</h2>\n'
        "<p>First body.</p>\n"
        '<h2 id="part2">Part Two</h2>\n'
        "<p>Second body with <em>emphasis</em>.</p>\n"
        '<h2 id="sec 2">Part Three</h2>\n'
        '<p>Third body <img src="../Images/pic.png" alt="tiny"/></p>\n'
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    nav = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops">\n'
        "<head><title>Contents</title></head>\n"
        "<body>\n"
        '  <nav epub:type="toc">\n'
        "    <ol>\n"
        '      <li><a href="Text/all.xhtml#part1">Part One</a></li>\n'
        '      <li><a href="Text/all.xhtml#part2">Part Two</a></li>\n'
        '      <li><a href="Text/all.xhtml#sec%202">Part Three</a></li>\n'
        "    </ol>\n"
        "  </nav>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")

    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Split Book</dc:title>\n"
        "    <dc:creator>S. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:anchor-split</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>\n'
        '    <item id="img1" href="Images/pic.png" media-type="image/png"/>\n'
        '    <item id="all" href="Text/all.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="all"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "anchor-split.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/nav.xhtml", nav, True),
            ("OEBPS/Images/pic.png", _png(8, 4, (10, 200, 40)), True),
            ("OEBPS/Text/all.xhtml", ch, True),
        ],
    )


def build_dual_toc() -> None:
    # Task 9 parity fixture: BOTH an EPUB3 nav (`properties="nav"`) and an
    # EPUB2 NCX (`spine toc="ncx"`), with DIFFERENT titles for the same
    # documents. Dart reads the NCX first; Rust prefers the nav (the EPUB3
    # canonical TOC). Bodies are identical, so only the chapter titles differ.
    nav = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops">\n'
        "<head><title>Contents</title></head>\n"
        "<body>\n"
        '  <nav epub:type="toc">\n'
        "    <ol>\n"
        '      <li><a href="Text/ch1.xhtml">Nav One</a></li>\n'
        '      <li><a href="Text/ch2.xhtml">Nav Two</a></li>\n'
        "    </ol>\n"
        "  </nav>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")
    ncx = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        '  <head><meta name="dtb:uid" content="urn:uuid:dual-toc"/></head>\n'
        "  <docTitle><text>Dual Toc</text></docTitle>\n"
        "  <navMap>\n"
        '    <navPoint id="n1" playOrder="1">\n'
        "      <navLabel><text>Ncx One</text></navLabel>\n"
        '      <content src="Text/ch1.xhtml"/>\n'
        "    </navPoint>\n"
        '    <navPoint id="n2" playOrder="2">\n'
        "      <navLabel><text>Ncx Two</text></navLabel>\n"
        '      <content src="Text/ch2.xhtml"/>\n'
        "    </navPoint>\n"
        "  </navMap>\n"
        "</ncx>\n"
    ).encode("utf-8")
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Dual Toc</dc:title>\n"
        "    <dc:creator>D. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:dual-toc</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>\n'
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
        HERE / "dual-toc.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/nav.xhtml", nav, True),
            ("OEBPS/toc.ncx", ncx, True),
            ("OEBPS/Text/ch1.xhtml", _xhtml("One", "First."), True),
            ("OEBPS/Text/ch2.xhtml", _xhtml("Two", "Second."), True),
        ],
    )


def build_dangling_spine() -> None:
    # Task 9 parity fixture: every spine `idref` misses the manifest. Dart
    # keeps only manifest hits (none) and throws "no readable text"; Rust
    # falls back to the natural-sorted manifest XHTML list. Manifest order
    # matches natural order here so only the fallback itself is exercised
    # (ordering is pinned by `no-spine.epub`).
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Dangling Spine</dc:title>\n"
        "    <dc:creator>D. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:dangling-spine</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch1" href="Text/ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        '    <item id="ch2" href="Text/ch2.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ghost1"/>\n'
        '    <itemref idref="ghost2"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "dangling-spine.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/Text/ch1.xhtml", _xhtml("One", "First."), True),
            ("OEBPS/Text/ch2.xhtml", _xhtml("Two", "Second."), True),
        ],
    )


def build_svg_image() -> None:
    # SVG fixture: an `<img>` whose file is a valid SVG. The Rust engine keeps
    # a placeholder with the archive key and sniffs the intrinsics (300x150)
    # from the SVG root's width/height (viewBox fallback) — pinned by
    # `rust_parse_parity_test.dart` ("SVG image as a placeholder").
    svg = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="0 0 300 150" width="300" height="150">\n'
        '  <rect width="300" height="150" fill="#336699"/>\n'
        "</svg>\n"
    ).encode("utf-8")
    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head><title>Svg</title></head>\n"
        "<body>\n"
        "<h1>Svg</h1>\n"
        '<p>Before <img src="Images/pic.svg" alt="diagram"/> after.</p>\n'
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Svg Image</dc:title>\n"
        "    <dc:creator>S. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:svg-image</dc:identifier>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="img1" href="Images/pic.svg" media-type="image/svg+xml"/>\n'
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "svg-image.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
            ("OEBPS/Images/pic.svg", svg, True),
        ],
    )


def build_rich_meta() -> None:
    # Task 9 parity fixture: the OPF description carries ESCAPED block markup.
    # `innerText` unescapes it, so Dart's `htmlToText` emits paragraph breaks
    # ("First para.\n\nSecond para."); the Rust `html_to_text` port must match
    # (it is fixed, not ledgered, in this task).
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Rich Meta</dc:title>\n"
        "    <dc:creator>R. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:rich-meta</dc:identifier>\n'
        "    <dc:description>&lt;p&gt;First para.&lt;/p&gt;"
        "&lt;p&gt;Second para.&lt;/p&gt;</dc:description>\n"
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "rich-meta.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", _xhtml("One", "First."), True),
        ],
    )


def build_cover_inline() -> None:
    # Cover-inline fixture: an inline `<img>` whose file is the OPF-declared
    # cover (`meta name="cover"`), though neither its `id` nor its filename
    # contains "cover". Resolution goes through the OPF declaration, and the
    # inline image IS marked `fullWidth` with real intrinsics (8x4) — pinned
    # by `rust_parse_parity_test.dart` ("OPF-declared cover image
    # full-width").
    ch1 = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        "<head><title>Cover Inline</title></head>\n"
        "<body>\n"
        "<h1>Cover Inline</h1>\n"
        '<p>See <img id="fig1" src="Images/front.png" alt="front"/> '
        "here.</p>\n"
        "</body>\n"
        "</html>\n"
    ).encode("utf-8")
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">\n'
        "    <dc:title>Cover Inline</dc:title>\n"
        "    <dc:creator>C. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:cover-inline</dc:identifier>\n'
        '    <meta name="cover" content="cv"/>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="cv" href="Images/front.png" media-type="image/png"/>\n'
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "cover-inline.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", ch1, True),
            ("OEBPS/Images/front.png", _png(8, 4, (30, 120, 30)), True),
        ],
    )


def build_annotated_meta() -> None:
    # Final-fix parity fixture: the OPF carries `calibre:annotation`,
    # `dc:type` and `dc:source`. The parity differ compares these fields, but
    # no earlier fixture set them, so the gate passed vacuously while the Rust
    # DTO dropped them (and the library worker overwrote them with null).
    # This fixture keeps the gate honest: both engines must agree here.
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="BookId">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <dc:title>Annotated Meta</dc:title>\n"
        "    <dc:creator>A. Author</dc:creator>\n"
        "    <dc:language>en</dc:language>\n"
        '    <dc:identifier id="BookId">urn:uuid:annotated-meta</dc:identifier>\n'
        "    <dc:type>Text</dc:type>\n"
        "    <dc:source>https://example.com/annotated-meta</dc:source>\n"
        '    <meta name="calibre:annotation" content="A Calibre annotation '
        'for parity."/>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="ch1" href="ch1.xhtml" '
        'media-type="application/xhtml+xml"/>\n'
        "  </manifest>\n"
        "  <spine>\n"
        '    <itemref idref="ch1"/>\n'
        "  </spine>\n"
        "</package>\n"
    ).encode("utf-8")

    _write_epub(
        HERE / "annotated-meta.epub",
        [
            ("mimetype", b"application/epub+zip", False),
            ("META-INF/container.xml", _container("OEBPS/content.opf"), True),
            ("OEBPS/content.opf", opf, True),
            ("OEBPS/ch1.xhtml", _xhtml("One", "First."), True),
        ],
    )


def _write_cbz(path: Path, entries: list[tuple[str, bytes]]) -> None:
    """Writes a deterministic CBZ (plain ZIP of images). Entries are stored
    in the given order, which the tests deliberately scramble so only a
    natural sort yields `page1, page2, page10`."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=_FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)


def build_mini_cbz() -> None:
    # Task 2 (retire-dart-engine) fixture: three PNG pages with distinct
    # intrinsic sizes, archived out of order (`page10` first) so the expected
    # `page1, page2, page10` order only holds under a natural sort (Dart's
    # `_naturalCompare`, Review Focus #3). `notes.txt` pins the image-entry
    # filter: it must not become a chapter.
    _write_cbz(
        HERE / "mini.cbz",
        [
            ("page10.png", _png(6, 8, (30, 30, 200)),),
            ("notes.txt", b"Not a page.\n",),
            ("page2.png", _png(8, 6, (30, 120, 30)),),
            ("page1.png", _png(4, 4, (200, 30, 30)),),
        ],
    )


def main() -> None:
    build_minimal()
    build_percent_path()
    build_opaque_cover()
    build_no_spine()
    build_nav()
    build_ncx()
    build_malformed()
    build_nonbmp()
    build_scripted()
    build_repeated_paragraphs()
    build_css_only_runs()
    build_external_css()
    build_projection()
    build_anchor_split()
    build_missing_image()
    build_embedded_font()
    build_dual_toc()
    build_dangling_spine()
    build_svg_image()
    build_rich_meta()
    build_cover_inline()
    build_annotated_meta()
    build_mini_cbz()
    print("wrote fixtures to", HERE)


if __name__ == "__main__":
    main()
