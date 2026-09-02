#!/usr/bin/env python3
"""Build the godot-cli documentation site.

Content lives in site/content as Markdown with a small YAML-ish header. Pages
are rendered into site/_build with the templates in site/templates. The command
reference is pulled straight from docs/commands.md, which `zig build docs`
generates from the CLI's own command tree, so the site cannot document a
command the binary does not have.

    python3 tools/build_site.py [--output DIR] [--base-url /godot-cli]
"""

from __future__ import annotations

import argparse
import hashlib
import html
import pathlib
import re
import shutil
import sys

try:
    import markdown
    from pygments.formatters import HtmlFormatter
except ImportError:  # pragma: no cover - the error is the message
    sys.exit("Missing dependencies. Install with: pip install markdown pygments")

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTENT = ROOT / "site" / "content"
TEMPLATES = ROOT / "site" / "templates"
STATIC = ROOT / "site" / "static"

# Sidebar order and grouping. A page missing from here still builds; it just
# does not appear in the navigation.
NAV = [
    (
        "Start here",
        [
            ("index.md", "Overview"),
            ("getting-started.md", "Getting started"),
        ],
    ),
    (
        "How-to guides",
        [
            ("how-to/index.md", "All guides"),
            ("how-to/first-scene.md", "Build a scene"),
            ("how-to/your-own-components.md", "Teach an agent your sub-scenes"),
            ("how-to/instance-and-override.md", "Instance and override"),
            ("how-to/batch-edits.md", "Batch edits with intents and patches"),
            ("how-to/build-ui.md", "Build UI"),
            ("how-to/project-settings.md", "Edit project settings"),
            ("how-to/review-changes.md", "Review and validate changes"),
            ("how-to/run-and-capture.md", "Run the game and capture output"),
            ("how-to/agent-setup.md", "Set up an agent"),
            ("how-to/godot-basics.md", "Godot basics an agent needs"),
            ("how-to/godot-compatibility.md", "Stay byte-compatible with Godot"),
            ("how-to/scripting.md", "Script godot-cli"),
        ],
    ),
    (
        "Reference",
        [
            ("reference.md", "Command reference"),
            ("https://github.com/unabated-games/godot-cli", "GitHub"),
        ],
    ),
]


def parse_header(text: str) -> tuple[dict[str, str], str]:
    """Split a leading `key: value` block delimited by `---` from the body."""
    if not text.startswith("---\n"):
        return {}, text
    end = text.index("\n---\n", 4)
    header = {}
    for line in text[4:end].splitlines():
        if not line.strip():
            continue
        key, _, value = line.partition(":")
        header[key.strip()] = value.strip()
    return header, text[end + 5 :]


def render_markdown(body: str) -> tuple[str, list[tuple[int, str, str]]]:
    converter = markdown.Markdown(
        extensions=["fenced_code", "codehilite", "tables", "toc", "attr_list", "sane_lists"],
        extension_configs={
            "codehilite": {"css_class": "codehilite", "guess_lang": False},
            "toc": {"anchorlink": False, "permalink": False},
        },
    )
    rendered = converter.convert(body)
    # toc_tokens nests h2s under the page's h1; the page contents list wants
    # the h2s themselves.
    headings = []

    def walk(tokens):
        for item in tokens:
            if item["level"] == 2:
                headings.append((item["level"], item["id"], item["name"]))
            walk(item.get("children", []))

    walk(converter.toc_tokens)
    return rendered, headings


def url_for(source: str, base_url: str) -> str:
    """Map a content path to its URL. `index.md` in any directory is that
    directory: how-to/index.md serves /how-to/, not /how-to/index/."""
    if source.startswith("http"):
        return source
    stem = source[: -len(".md")]
    if stem == "index":
        return base_url + "/"
    if stem.endswith("/index"):
        stem = stem[: -len("/index")]
    return base_url + "/" + stem + "/"


def build_nav(current: str, base_url: str) -> str:
    out = ['<nav class="sidebar-nav" aria-label="Documentation">']
    for section, pages in NAV:
        out.append(f"<p class=\"nav-section\">{html.escape(section)}</p><ul>")
        for source, label in pages:
            href = url_for(source, base_url)
            active = ' class="active"' if source == current else ""
            external = ' class="external"' if source.startswith("http") else ""
            out.append(
                f'<li><a href="{href}"{active or external}>{html.escape(label)}</a></li>'
            )
        out.append("</ul>")
    out.append("</nav>")
    return "\n".join(out)


def build_toc(headings: list[tuple[int, str, str]]) -> str:
    if len(headings) < 2:
        return ""
    items = "\n".join(
        f'<li><a href="#{anchor}">{html.escape(name)}</a></li>' for _, anchor, name in headings
    )
    return f'<aside class="page-toc"><p>On this page</p><ul>{items}</ul></aside>'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=str(ROOT / "site" / "_build"))
    parser.add_argument("--base-url", default="", help="Path prefix, e.g. /godot-cli")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    out_root = pathlib.Path(args.output)
    if out_root.exists():
        shutil.rmtree(out_root)
    out_root.mkdir(parents=True)

    base_template = (TEMPLATES / "base.html").read_text()
    landing_template = (TEMPLATES / "landing.html").read_text()

    # GitHub Pages serves assets with a ten-minute cache and browsers hold them
    # longer, so a deploy that changes the stylesheet can leave readers with the
    # old one under the new HTML. Stamping asset URLs with a content hash makes
    # every deploy fetch fresh.
    asset_hash = hashlib.sha256(
        b"".join(sorted(path.read_bytes() for path in STATIC.iterdir()))
    ).hexdigest()[:10]
    for name in ("style.css", "highlight.css", "site.js", "favicon.svg"):
        base_template = base_template.replace(f"/assets/{name}", f"/assets/{name}?v={asset_hash}")
        landing_template = landing_template.replace(f"/assets/{name}", f"/assets/{name}?v={asset_hash}")

    sources = sorted(CONTENT.rglob("*.md"))
    if not sources:
        sys.exit(f"No content found in {CONTENT}")

    for path in sources:
        rel = path.relative_to(CONTENT).as_posix()
        header, body = parse_header(path.read_text())

        # The command reference is generated by the build, not written here.
        if header.get("include"):
            include_path = pathlib.Path(header["include"])
            included = (ROOT / include_path).read_text()
            included = re.sub(r"<!--.*?-->", "", included, flags=re.DOTALL)
            # Links in repo docs are relative to their own directory, which does
            # not survive the move onto the site. Point them at GitHub.
            included = re.sub(
                r"\]\((?!https?:|#)([^)]+\.md)",
                lambda m: f"](https://github.com/unabated-games/godot-cli/blob/main/{(include_path.parent / m.group(1)).as_posix()}",
                included,
            )
            body = body + "\n\n" + included.split("\n", 1)[1]

        rendered, headings = render_markdown(body)
        template = landing_template if header.get("layout") == "landing" else base_template

        page = template.replace("{{ content }}", rendered)
        page = page.replace("{{ nav }}", build_nav(rel, base_url))
        page = page.replace("{{ toc }}", build_toc(headings))
        page = page.replace("{{ title }}", html.escape(header.get("title", "godot-cli")))
        page = page.replace("{{ description }}", html.escape(header.get("description", "")))
        page = page.replace("{{ base_url }}", base_url)
        page = page.replace("{{ source }}", rel)

        stem = rel[: -len(".md")]
        if stem.endswith("/index"):
            stem = stem[: -len("/index")]
        target = out_root / ("index.html" if stem == "index" else stem + "/index.html")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page)

    assets = out_root / "assets"
    assets.mkdir()
    for item in STATIC.iterdir():
        shutil.copy(item, assets / item.name)

    # Syntax highlighting: one dark palette, used in both site themes so code
    # reads the same either way.
    (assets / "highlight.css").write_text(HtmlFormatter(style="github-dark").get_style_defs(".codehilite"))

    # Tell GitHub Pages not to run the output through Jekyll.
    (out_root / ".nojekyll").write_text("")

    broken = check_links(out_root, base_url)
    if broken:
        for line in broken:
            print(f"broken link: {line}", file=sys.stderr)
        sys.exit(f"{len(broken)} broken internal link(s)")

    print(f"built {len(sources)} pages into {out_root}")
    return 0


def check_links(out_root: pathlib.Path, base_url: str) -> list[str]:
    """Every internal href has to resolve to a file that was written. A guide
    linking to a page that was renamed is the failure this catches."""
    broken = []
    for page in sorted(out_root.rglob("*.html")):
        for href in re.findall(r'href="([^"]+)"', page.read_text()):
            if href.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = href.split("#")[0].split("?")[0]
            if base_url and target.startswith(base_url):
                target = target[len(base_url) :]
            candidate = out_root / target.lstrip("/")
            if target.endswith("/"):
                candidate = candidate / "index.html"
            if not candidate.exists():
                broken.append(f"{page.relative_to(out_root)} -> {href}")
    return broken


if __name__ == "__main__":
    raise SystemExit(main())
