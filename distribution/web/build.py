#!/usr/bin/env python3
"""Render the checked-in Markdown policy and support copy as static, tracker-free HTML."""

from __future__ import annotations

import html
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WEB = ROOT / "distribution" / "web"


def inline(text: str) -> str:
    escaped = html.escape(text.strip())
    escaped = re.sub(
        r"\[([^\]]+)\]\((\.{0,2}/[^)]+)\)",
        lambda match: f'<a href="{html.escape(match.group(2), quote=True)}">{match.group(1)}</a>',
        escaped,
    )
    return escaped.replace("  ", "<br>")


def render_markdown(source: str) -> str:
    blocks: list[str] = []
    paragraph: list[str] = []

    def flush() -> None:
        if paragraph:
            blocks.append("<p>" + "<br>".join(inline(line) for line in paragraph) + "</p>")
            paragraph.clear()

    for line in source.splitlines():
        if not line.strip():
            flush()
            continue
        if line.startswith("### "):
            flush()
            blocks.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("## "):
            flush()
            blocks.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("# "):
            flush()
            blocks.append(f"<h1>{inline(line[2:])}</h1>")
        else:
            paragraph.append(line)
    flush()
    return "\n".join(blocks)


def build(source_file: Path, output_file: Path, description: str) -> None:
    source = source_file.read_text(encoding="utf-8")
    title = source.splitlines()[0].removeprefix("# ")
    body = render_markdown(source)
    document = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="{html.escape(description, quote=True)}">
  <title>{html.escape(title)}</title>
  <style>
    :root {{ color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", sans-serif; }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: #f4f7fc; color: #17243b; line-height: 1.8; }}
    main {{ max-width: 850px; margin: 56px auto; padding: 44px 52px; background: #fff; border: 1px solid #e4eaf5; border-radius: 24px; box-shadow: 0 14px 48px #19346b0a; }}
    h1 {{ margin: 0 0 18px; font-size: 32px; line-height: 1.35; }}
    h2 {{ margin-top: 36px; font-size: 20px; }}
    h3 {{ margin-top: 24px; font-size: 17px; }}
    p {{ margin: 12px 0; }}
    a {{ color: #315bd4; }}
    footer {{ max-width: 850px; margin: 0 auto 56px; padding: 0 12px; color: #64748b; font-size: 14px; }}
    @media (max-width: 620px) {{ main {{ margin: 0; padding: 28px 22px; border-radius: 0; border: 0; }} footer {{ margin: 24px auto; }} }}
    @media (prefers-color-scheme: dark) {{ body {{ background: #0d1424; color: #e4eaf6; }} main {{ background: #151f32; border-color: #26354f; }} a {{ color: #9ab5ff; }} }}
  </style>
</head>
<body>
  <main>{body}</main>
  <footer>ClipHoook · <a href="../privacy/">隐私政策</a> · <a href="../support/">支持</a></footer>
</body>
</html>
"""
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(document, encoding="utf-8")


if __name__ == "__main__":
    build(
        ROOT / "ClipboardShelf" / "Resources" / "PrivacyPolicy.md",
        WEB / "privacy" / "index.html",
        "ClipHoook Mac 剪贴板工具的隐私政策：本机历史记录、数据保存与删除方式。",
    )
    build(WEB / "support.md", WEB / "support" / "index.html", "ClipHoook Mac 应用帮助、常见问题与联系方式。")
