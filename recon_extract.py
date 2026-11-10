#!/usr/bin/env python3
"""Recon: compare Rust EPUB extraction against ebooklib/BS4 visible text.

Reports word tokens present in the reference but absent (or less frequent) in
the Rust output, plus a short context snippet from the source.
"""
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup, Comment

DUMP = Path(os.environ.get(
    "DUMP",
    "/home/paul/.cache/burrow-worktrees/recon-epub-main/rust/target/release/examples/dump_text",
))

WORD = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)
SKIP_TAGS = {"script", "style", "rt", "rp", "rtc", "template", "head", "title"}
BLOCK = {"p","div","h1","h2","h3","h4","h5","h6","li","tr","br","section",
         "article","blockquote","pre","table","caption","thead","tbody","tfoot",
         "td","th","dl","dt","dd","figure","figcaption","hr","nav","aside",
         "header","footer","main","center","address","details","summary",
         "fieldset","form","menu","ul","ol"}


def rust_text(path):
    out = subprocess.run([str(DUMP), str(path)], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr[-2000:])
    chapters = []
    for line in out.stdout.splitlines():
        parts = line.split("\x1f")
        if len(parts) == 3:
            chapters.append((parts[1], json.loads('"' + parts[2] + '"')))
    return chapters


def visible_text(item):
    soup = BeautifulSoup(item.get_content(), "lxml")
    for tag in soup.find_all(SKIP_TAGS):
        tag.decompose()
    for tag in soup.find_all(True):
        if tag.attrs is None:
            continue
        if "hidden" in tag.attrs:
            tag.decompose()
            continue
        style = (tag.get("style") or "").replace(" ", "").lower()
        if "display:none" in style or "visibility:hidden" in style:
            tag.decompose()
    # Ruby annotations are removed by the Rust engine; keep base text.
    # Do NOT use get_text(separator): it splits inline siblings (drop caps
    # become "T HE"), inventing missing tokens. Walk the tree instead and add
    # a break only at block boundaries.
    def render(node):
        if isinstance(node, Comment):
            return ""
        if getattr(node, "name", None) in SKIP_TAGS:
            return ""
        if getattr(node, "name", None) in BLOCK:
            return "\n" + "".join(render(c) for c in node.children) + "\n"
        if getattr(node, "name", None) is None:
            return str(node)
        return "".join(render(c) for c in node.children)

    root = soup.body or soup
    return re.sub(r"[ \t\r\f\v]+", " ", render(root))


def tokens(text):
    return [m.group(0).lower() for m in WORD.finditer(text)]


def decode_name(name):
    return name.replace("_", " ")


def analyse(path, verbose=False):
    book = epub.read_epub(str(path), options={"ignore_ncx": False})
    ref_parts = []
    for idref, _linear in book.spine:
        item = book.get_item_with_id(idref)
        if item is None or item.get_type() != ebooklib.ITEM_DOCUMENT:
            continue
        ref_parts.append(visible_text(item))
    ref_text = "\n".join(ref_parts)
    try:
        chapters = rust_text(path)
    except Exception as e:
        return {"path": str(path), "error": str(e)}
    out_text = "\n".join(body for _, body in chapters)
    ref_words, out_words = tokens(ref_text), tokens(out_text)
    ref_counts, out_counts = Counter(ref_words), Counter(out_words)
    missing = []
    for word, count in ref_counts.items():
        got = out_counts.get(word, 0)
        if got < count:
            missing.append((count - got, word))
    missing.sort(reverse=True)
    return {
        "path": str(path),
        "chapters": len(chapters),
        "ref_words": len(ref_words),
        "out_words": len(out_words),
        "missing_total": sum(n for n, _ in missing),
        "missing_distinct": len(missing),
        "missing": missing[:40],
        "ref_text": ref_text,
        "out_text": out_text,
    }


def contexts(text, word, limit=3):
    out = []
    for m in re.finditer(re.escape(word), text, re.IGNORECASE):
        a, b = max(0, m.start() - 60), min(len(text), m.end() + 60)
        out.append(re.sub(r"\s+", " ", text[a:b]))
        if len(out) >= limit:
            break
    return out


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: recon_extract.py <epub>...", file=sys.stderr)
        sys.exit(2)
    for arg in args:
        path = Path(arg)
        r = analyse(path)
        print("=" * 100)
        print(r["path"])
        if "error" in r:
            print("  ERROR:", r["error"])
            continue
        print(f"  chapters={r['chapters']} ref_words={r['ref_words']} out_words={r['out_words']} "
              f"missing={r['missing_total']} ({r['missing_distinct']} distinct)")
        for n, w in r["missing"]:
            ctx = contexts(r["ref_text"], w, 2)
            print(f"  - {n:4d}x {w!r}")
            for c in ctx:
                print(f"        …{c}…")


if __name__ == "__main__":
    main()
