#!/usr/bin/env python3
"""检查 Markdown 中的相对链接/图片是否真实存在。

用法：
    python3 tools/check-links.py [根目录，默认当前目录]

忽略 http(s) 与 mailto 链接、纯锚点链接。
发现失效链接时以非零状态退出（可直接用于 CI）。
"""

from __future__ import annotations

import pathlib
import re
import sys

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
REF_RE = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)", re.MULTILINE)
SKIP_PREFIX = ("http://", "https://", "mailto:", "#", "tel:")


def targets(text: str) -> list[str]:
    found = [m.group(1) for m in LINK_RE.finditer(text)]
    found += [m.group(1) for m in REF_RE.finditer(text)]
    return found


def normalize(target: str) -> str:
    target = target.split("#", 1)[0].strip()
    return target.strip("<>")


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1] if len(argv) > 1 else ".")
    bad: list[str] = []
    checked = 0

    for md in sorted(root.rglob("*.md")):
        if ".git" in md.parts:
            continue
        text = md.read_text(encoding="utf-8")
        for raw in targets(text):
            if raw.startswith(SKIP_PREFIX):
                continue
            target = normalize(raw)
            if not target:
                continue
            checked += 1
            if not (md.parent / target).exists():
                bad.append(f"{md}: {raw}")

    if bad:
        print("发现失效的相对链接：")
        for item in bad:
            print("  -", item)
        return 1

    print(f"检查了 {checked} 个相对链接，全部有效 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
