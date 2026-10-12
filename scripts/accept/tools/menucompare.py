# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
"""Compares two menu listings (AX style: "## Menu", "- Item [mods:key:code]
(disabled) ✓", "---", two-space indents for submenus).

    python3 -I menucompare.py [--ignore-state TITLE]... [--ignore-key TITLE]...
        <reference listing> <prism listing>

Both are normalised first: the product name (the title of the first menu)
becomes "Prism"; items the
system adds (Services entries, AutoFill, Dictation, Emoji, the window
tiling items, the window list), the Open Recent entries and the items of
features Prism leaves out (registration, update checks) are dropped;
separators are collapsed. The Help menu is not compared. --ignore-state
drops the enabled state of the named items (a documented deviation),
--ignore-key their shortcut (bound only while a window is key). Exit status 0
when the rest is identical, 1 otherwise (a unified diff is printed).
"""
import difflib
import re
import sys

SYSTEM_TOP = {
    "Edit": {"AutoFill", "Start Dictation…", "Emoji & Symbols"},
    "Window": {"Fill", "Center", "Move & Resize", "Full Screen Tile", "Arrange in Front",
               "Remove Window from Set"},
}
LEFT_OUT = {"Registration…", "Check for Updates..."}
SKIPPED_MENUS = {"Help"}


def parse(path):
    menus = []  # [(title, [(depth, text)])]
    raw_lines = open(path, encoding="utf-8").read().split("\n")
    product = next((l[3:] for l in raw_lines if l.startswith("## ")), "Prism")
    for raw in raw_lines:
        if not raw.strip():
            continue
        line = raw.replace(product, "Prism")
        if line.startswith("## "):
            menus.append((line[3:], []))
            continue
        depth = (len(line) - len(line.lstrip(" "))) // 2
        menus[-1][1].append((depth, line.strip()))
    return menus


def title_of(text):
    if text == "---":
        return "---"
    text = text[2:]
    return re.sub(r" \[[^\]]*\]| \(disabled\)| ✓", "", text, flags=re.S).strip()


def normalise(menus):
    out = []
    for title, items in menus:
        if title in SKIPPED_MENUS:
            continue
        kept = []
        skip_depth = None
        window_list = False
        for depth, text in items:
            if skip_depth is not None and depth > skip_depth:
                continue
            skip_depth = None
            name = title_of(text)
            if depth == 0 and (name in SYSTEM_TOP.get(title, set()) or name in LEFT_OUT):
                skip_depth = depth
                continue
            if depth >= 1 and (kept and kept[-1][2] in ("Services", "Open Recent...")):
                # Children of Services and Open Recent (system and history).
                if name != "Clear Menu":
                    continue
                text = "- Clear Menu"
            if title == "Window" and depth == 0 and name == "Bring All to Front":
                window_list = True
            elif title == "Window" and window_list and depth == 0 and name != "---":
                continue
            kept.append((depth, text, name if depth == 0 else kept[-1][2] if kept else name))
        # Collapse separators.
        result = []
        for depth, text, parent in kept:
            if text == "---" and (not result or result[-1][1] == "---"):
                continue
            result.append((depth, text, parent))
        while result and result[-1][1] == "---":
            result.pop()
        lines = ["## " + title]
        for depth, text, _ in result:
            lines.append("  " * depth + text)
        out.extend(lines)
    return out


def strip_state(lines, titles, keys=()):
    out = []
    for line in lines:
        body = line.strip()
        if body.startswith("- ") and title_of(body) in titles:
            line = line.replace(" (disabled)", "")
        if body.startswith("- ") and title_of(body) in keys:
            line = re.sub(r" \[[^\]]*\]", "", line, flags=re.S)
        out.append(line)
    return out


def main():
    args = sys.argv[1:]
    ignored, keys = set(), set()
    while args and args[0] in ("--ignore-state", "--ignore-key"):
        (ignored if args[0] == "--ignore-state" else keys).add(args[1])
        args = args[2:]
    reference, prism = args[0], args[1]
    left = strip_state(normalise(parse(reference)), ignored, keys)
    right = strip_state(normalise(parse(prism)), ignored, keys)
    if left == right:
        print("menus match (%d lines)" % len(left))
        return 0
    sys.stdout.writelines(l + "\n" for l in difflib.unified_diff(left, right, "reference", "prism", lineterm=""))
    return 1


if __name__ == "__main__":
    sys.exit(main())
