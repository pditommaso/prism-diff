# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
"""String half of the clean-room audit; run by scripts/ci/cleanroom-audit.sh,
which documents the checks and the normalisation.

  cleanroom_audit.py hash                 plaintext lines on stdin -> hash list
  cleanroom_audit.py check HASHFILE       NUL-separated paths on stdin -> matches

Exit status of `check`: 0 with no match, 1 on a match, 2 on a bad hash file.
"""

import hashlib
import os
import re
import sys
import unicodedata

APOSTROPHES = re.compile("['‘’`]")
WORD = re.compile(r"[a-z0-9]+")
# "...", '...' and `...` on one line, with backslash escapes.
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'|`[^`\n]*`')


def tokens(text):
    text = unicodedata.normalize("NFKC", text).lower()
    return WORD.findall(APOSTROPHES.sub("", text))


def digest(words):
    return hashlib.sha256(" ".join(words).encode()).hexdigest()


def build():
    longest = 0
    for line in sys.stdin:
        words = tokens(line)
        if words:
            longest = max(longest, len(words))
            print(digest(words))
    print("max-words", longest)
    return 0


def load(path):
    hashes, longest = set(), 0
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("max-words "):
                longest = int(line.split()[1])
            elif re.fullmatch(r"[0-9a-f]{64}", line):
                hashes.add(line)
            else:
                raise ValueError("unexpected line: " + line[:24])
    if not hashes or longest < 1:
        raise ValueError("empty hash list")
    return hashes, longest


def scan(path, text, hashes, longest):
    """Yields (line, kind) for every listed string found in `text`."""
    found = set()
    for match in LITERAL.finditer(text):
        words = tokens(match.group(0))
        if words and len(words) <= longest and digest(words) in hashes:
            found.add((text.count("\n", 0, match.start()) + 1, "string literal"))
    stream, lines = [], []
    for number, line in enumerate(text.split("\n"), 1):
        for word in tokens(line):
            stream.append(word)
            lines.append(number)
    for start in range(len(stream)):
        for size in range(1, min(longest, len(stream) - start) + 1):
            if digest(stream[start:start + size]) in hashes:
                found.add((lines[start], f"run of {size} words"))
    return sorted(found)


def check(hash_file):
    try:
        hashes, longest = load(hash_file)
    except (OSError, ValueError) as error:
        print(f"cleanroom-audit: {hash_file}: {error}", file=sys.stderr)
        return 2
    own = os.path.realpath(hash_file)
    files = matches = 0
    for path in sys.stdin.buffer.read().decode().split("\0"):
        if not path or not os.path.isfile(path) or os.path.realpath(path) == own:
            continue
        with open(path, "rb") as handle:
            raw = handle.read()
        if b"\0" in raw[:8192]:
            continue
        files += 1
        for line, kind in scan(path, raw.decode("utf-8", "replace"), hashes, longest):
            print(f"{path}:{line}: matches a listed original string ({kind})")
            matches += 1
    print(f"cleanroom-audit: strings: {files} files, {len(hashes)} listed hashes, "
          f"runs of up to {longest} words, {matches} matches")
    return 1 if matches else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["hash"]:
        sys.exit(build())
    if len(sys.argv) == 3 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2]))
    print(__doc__, file=sys.stderr)
    sys.exit(2)
