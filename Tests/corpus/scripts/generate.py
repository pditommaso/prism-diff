#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
"""Generate the large, synthetic diff inputs of the test corpus.

The outputs are too big to commit, so they are rebuilt on demand into
Tests/corpus/generated/ (git-ignored). Generation is deterministic: the
same Python version always produces byte-identical files, which the
committed manifest Tests/corpus/generated.sha256 pins down.

Cases (each is a pair NAME_a / NAME_b):
  diff20k      20,000 lines each, no line in common, shared vocabulary
  m1           1,000,000 lines with 10 scattered edits
  min          ~5 MB single-line minified JSON with 20 in-line edits
  crlf         fixtures/text/big_a.txt (LF) vs the same text with CRLF
  crlf100k     the same 100k lines, CRLF on the left and LF on the right
  ind          big_a.txt vs a copy with indentation-only changes

Usage (run with an isolated interpreter):
  /usr/bin/python3 -I Tests/corpus/scripts/generate.py            generate
  /usr/bin/python3 -I Tests/corpus/scripts/generate.py --check    generate, then
                                                                  verify against the manifest
  /usr/bin/python3 -I Tests/corpus/scripts/generate.py --write-manifest
                                                                  generate, then rewrite the manifest
Options:
  --out DIR   write into DIR instead of Tests/corpus/generated
"""

import argparse
import hashlib
import os
import random
import sys

CORPUS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BIG_A = os.path.join(CORPUS, "fixtures", "text", "big_a.txt")
DEFAULT_OUT = os.path.join(CORPUS, "generated")
MANIFEST = os.path.join(CORPUS, "generated.sha256")

WORDS = (
    "alpha beta gamma delta eps zeta eta theta iota kappa lambda mu nu xi "
    "omicron pi rho sigma tau"
).split()


class Writer:
    """Writes case files into one directory and remembers their names."""

    def __init__(self, out_dir):
        self.out_dir = out_dir
        self.names = []
        os.makedirs(out_dir, exist_ok=True)

    def write(self, name, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        with open(os.path.join(self.out_dir, name), "wb") as handle:
            handle.write(data)
        self.names.append(name)


def random_line(rng):
    return " ".join(rng.choice(WORDS) for _ in range(8))


def gen_diff20k(rng, out):
    out.write("diff20k_a.txt", "".join("a%d %s\n" % (i, random_line(rng)) for i in range(20000)))
    out.write("diff20k_b.txt", "".join("b%d %s\n" % (i, random_line(rng)) for i in range(20000)))


def gen_m1(rng, out):
    left = ["row %d: %s\n" % (i, random_line(rng)) for i in range(1000000)]
    right = list(left)
    for k in range(10):
        i = rng.randrange(len(right))
        op = k % 3
        if op == 0:
            right[i] = right[i].replace(":", ": edited", 1)
        elif op == 1:
            right.insert(i, "inserted line\n")
        else:
            del right[i]
    out.write("m1_a.txt", "".join(left))
    out.write("m1_b.txt", "".join(right))


def gen_minified_json(rng, out):
    tokens = []
    size = 0
    i = 0
    while size < 5000000:
        token = '{"id":%d,"name":"%s","v":[%d,%d]},' % (
            i, rng.choice(WORDS), rng.randrange(1000), rng.randrange(1000))
        tokens.append(token)
        size += len(token)
        i += 1
    edited = list(tokens)
    for _ in range(20):
        j = rng.randrange(len(edited))
        edited[j] = edited[j].replace('"name":"', '"name":"X', 1)
    out.write("min_a.json", "[" + "".join(tokens) + "]")
    out.write("min_b.json", "[" + "".join(edited) + "]")


def gen_line_endings(big, out):
    crlf = big.replace(b"\n", b"\r\n")
    out.write("crlf_a.txt", big)
    out.write("crlf_b.txt", crlf)
    out.write("crlf100k_a.txt", crlf)
    out.write("crlf100k_b.txt", big)


def gen_indentation(big, out):
    def reindent(k, line):
        if not line:
            return line
        prefix = b"\t" * (k % 3) + b"  " * (k % 2)
        suffix = b" " if k % 5 == 0 else b""
        return prefix + line + suffix

    lines = big.split(b"\n")
    out.write("ind_a.txt", big)
    out.write("ind_b.txt", b"\n".join(reindent(k, line) for k, line in enumerate(lines)))


def generate(out_dir):
    """Writes every case into out_dir and returns the file names written."""
    out = Writer(out_dir)
    rng = random.Random(1)
    # The order matters: the random cases share one generator.
    gen_diff20k(rng, out)
    gen_m1(rng, out)
    gen_minified_json(rng, out)
    with open(BIG_A, "rb") as handle:
        big = handle.read()
    gen_line_endings(big, out)
    gen_indentation(big, out)
    return sorted(out.names)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_manifest():
    """Returns {name: hex digest} from the manifest (shasum format)."""
    entries = {}
    with open(MANIFEST, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            digest, name = line.split("  ", 1)
            entries[name] = digest
    return entries


def write_manifest(out_dir, names):
    with open(MANIFEST, "w", encoding="utf-8") as handle:
        for name in names:
            handle.write("%s  %s\n" % (sha256_of(os.path.join(out_dir, name)), name))
    print("generate: wrote %s (%d files)" % (os.path.relpath(MANIFEST, CORPUS), len(names)))


def check(out_dir, names):
    """Compares generated files with the manifest. Returns True on success."""
    try:
        expected = read_manifest()
    except FileNotFoundError:
        print("generate: FAIL missing manifest %s" % MANIFEST)
        return False
    ok = True
    for name in sorted(set(expected) | set(names)):
        if name not in expected:
            print("FAIL %s: not listed in the manifest" % name)
            ok = False
        elif name not in names:
            print("FAIL %s: listed in the manifest but not generated" % name)
            ok = False
        else:
            actual = sha256_of(os.path.join(out_dir, name))
            if actual == expected[name]:
                print("ok   %s" % name)
            else:
                print("FAIL %s: sha256 %s, expected %s" % (name, actual, expected[name]))
                ok = False
    print("generate: check %s" % ("OK" if ok else "FAILED"))
    return ok


def main(argv):
    parser = argparse.ArgumentParser(description="Generate the large synthetic corpus files.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="verify the generated files against generated.sha256")
    mode.add_argument("--write-manifest", action="store_true",
                      help="rewrite generated.sha256 from the generated files")
    parser.add_argument("--out", default=DEFAULT_OUT, help="output directory")
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    names = generate(out_dir)
    print("generate: wrote %d files to %s" % (len(names), out_dir))
    if args.write_manifest:
        write_manifest(out_dir, names)
    elif args.check:
        return 0 if check(out_dir, names) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
