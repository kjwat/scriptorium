#!/usr/bin/env python3
"""Small static integrity check for generated site pages and local references."""

from __future__ import annotations

import argparse
import html.parser
import re
from pathlib import Path
from urllib.parse import unquote, urlparse


DYNAMIC_PATHS = {"/shop/recover", "/shop/recover/"}


class References(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.values: list[tuple[str, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag in {"a", "link", "script", "img", "source"}:
            for attr in ("href", "src"):
                if values.get(attr):
                    self.values.append((attr, values[attr] or ""))


def target_for(reference: str, root: Path) -> Path | None:
    parsed = urlparse(reference)
    if parsed.scheme or parsed.netloc or reference.startswith(("#", "mailto:", "tel:")):
        return None
    path = unquote(parsed.path)
    if not path.startswith("/"):
        return None
    if path in DYNAMIC_PATHS:
        return None
    candidate = root / path.lstrip("/")
    if path.endswith("/") or candidate.is_dir():
        candidate = candidate / "index.html"
    return candidate


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.site_root.resolve()

    errors: list[str] = []
    pages = sorted(
        path
        for path in root.glob("**/*.html")
        if path.relative_to(root).parts[0] != "editions"
    )
    for page in pages:
        text = page.read_text(encoding="utf-8")
        parser = References()
        parser.feed(text)
        relative = page.relative_to(root)
        is_legacy_redirect = relative.parts[0] == "139215173350"
        if ("<main" not in text or "<title>" not in text) and not is_legacy_redirect:
            errors.append(f"{relative}: missing main or title")
        for _attr, reference in parser.values:
            target = target_for(reference, root)
            if target is not None and not target.exists():
                errors.append(f"{relative}: missing {reference}")
        ids = set(re.findall(r'\bid="([^"]+)"', text))
        for fragment in re.findall(r'href="#([^"]+)"', text):
            if fragment not in ids:
                errors.append(f"{relative}: missing fragment #{fragment}")

    blog_posts = [path for path in (root / "blog").glob("*/index.html") if path.parent.name != "page"]
    archive_pages = [root / "blog" / "index.html"] + sorted((root / "blog" / "page").glob("*/index.html"))
    indexed_posts = sum(page.read_text(encoding="utf-8").count("data-post data-category=") for page in archive_pages)
    if len(blog_posts) != indexed_posts:
        errors.append(f"blog mismatch: {len(blog_posts)} post pages and {indexed_posts} archive entries")
    for page in archive_pages:
        entry_count = page.read_text(encoding="utf-8").count("data-post data-category=")
        if entry_count > 15:
            errors.append(f"{page.relative_to(root)}: {entry_count} entries exceeds page size 15")
    if errors:
        print("\n".join(errors))
        raise SystemExit(1)
    print(f"verified {len(pages)} HTML pages, {len(blog_posts)} blog posts, {len(archive_pages)} archive pages, and all internal references")


if __name__ == "__main__":
    main()
