#!/usr/bin/env python3
"""Differential conformance harness: hr-shape vs hb-shape.

Builds hr-shape from this repo, then shapes a matrix of fonts x texts x
feature sets with both engines and compares exact output. Both sides run
with numeric glyph ids and UTF-8 byte clusters, so matching lines mean
identical glyphs, clusters, advances, and offsets.

Usage:
  tools/conformance.py [--hr-shape BINARY] [--hb-shape BINARY]
                       [--font-size N] [--only SUBSTR]

Known AAT morx-only fonts (no GSUB/GPOS) are expected to fail ligature
cases; they are tracked in EXPECTED_FAILURES.
"""

import argparse
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FONTS = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Georgia.ttf",
    "/System/Library/Fonts/Supplemental/Courier New.ttf",
    "/System/Library/Fonts/Supplemental/Verdana.ttf",
    "/System/Library/Fonts/Supplemental/Tahoma.ttf",
    "/System/Library/Fonts/Supplemental/Trebuchet MS.ttf",
    "/System/Library/Fonts/Geneva.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]

LATIN_TEXTS = [
    "To", "AV", "Vo", "Wa", "fi", "ffi", "ffl", "fl",
    "Hello, World!", "AVfiToWe", "12345",
    "e-mail: info@example.com", "(To) \"AV\"",
]

ARABIC_TEXTS = [
    "مرحبا", "السلام", "العربية", "بِسْمِ", "مُحَمَّد",
]

LATIN_FEATURES = ["kern,liga", "-kern,-liga"]
ARABIC_FEATURES = [""]

# (font basename, feature set, text): AAT morx has no GSUB, so hb-shape
# ligates via morx while harfnim (out of scope) does not.
LIGA_TEXTS = {"fi", "ffi", "ffl", "fl", "AVfiToWe"}
MORX_FONTS = {"Geneva.ttf", "Helvetica.ttc"}

ARABIC_MARK_TEXTS = {"بِسْمِ", "مُحَمَّد"}

# Arabic mark-fallback differences on fonts without usable Arabic mark
# positioning: .notdef-only coverage (fallback runs on .notdef extents)
# plus Tahoma, whose MarkLig-only GPOS attaches nothing and whose
# fallback result hb-shape leaves at zero.
FALLBACK_MARK_DIFFS = {
    ("Georgia.ttf", "بِسْمِ"), ("Georgia.ttf", "مُحَمَّد"),
    ("Geneva.ttf", "بِسْمِ"), ("Geneva.ttf", "مُحَمَّد"),
    ("Helvetica.ttc", "بِسْمِ"), ("Helvetica.ttc", "مُحَمَّد"),
    ("Verdana.ttf", "بِسْمِ"), ("Verdana.ttf", "مُحَمَّد"),
    ("Trebuchet MS.ttf", "بِسْمِ"), ("Trebuchet MS.ttf", "مُحَمَّد"),
    ("Tahoma.ttf", "بِسْمِ"), ("Tahoma.ttf", "مُحَمَّد"),
}


def expected_failure(font, features, text, ours, hb):
    base = os.path.basename(font)
    if base in MORX_FONTS and "liga" in features.replace("-liga", "") \
            and text in LIGA_TEXTS:
        return "morx-liga"
    if features == "" and text in ARABIC_MARK_TEXTS \
            and (base, text) in FALLBACK_MARK_DIFFS:
        return "fallback-mark-positioning"
    return ""


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    return p, None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--hr-shape", default=None,
                    help="hr-shape binary (default: build to temp dir)")
    ap.add_argument("--hb-shape", default="hb-shape")
    ap.add_argument("--font-size", default="1000")
    ap.add_argument("--only", default=None,
                    help="only run cases containing SUBSTR")
    args = ap.parse_args()

    hr_shape = args.hr_shape
    built = None
    if hr_shape is None:
        import tempfile
        built = os.path.join(tempfile.mkdtemp(prefix="hr-shape-"),
                             "hr-shape")
        print(f"building hr-shape -> {built}")
        p = subprocess.run(
            ["clue", "build", "src/hr_shape.nim", "--out:" + built],
            capture_output=True, text=True, cwd=REPO)
        if p.returncode != 0:
            print("build failed:\n" + p.stderr[-3000:])
            return 2
        hr_shape = built

    cases = []
    for font in FONTS:
        if not os.path.exists(font):
            print(f"skip missing font: {font}")
            continue
        for text in LATIN_TEXTS:
            for feats in LATIN_FEATURES:
                cases.append((font, text, feats))
        for text in ARABIC_TEXTS:
            for feats in ARABIC_FEATURES:
                cases.append((font, text, feats))

    if args.only:
        cases = [c for c in cases if args.only in c[0] or
                 args.only in c[1] or args.only in c[2]]

    npass = nxfail = nfail = 0
    failures = []
    for font, text, feats in cases:
        hr_cmd = [hr_shape, font, text, "--font-size=" + args.font_size,
                  "--features=" + feats] if feats else \
            [hr_shape, font, text, "--font-size=" + args.font_size]
        hb_cmd = [args.hb_shape, "--no-glyph-names", "--utf8-clusters",
                  "--font-size=" + args.font_size,
                  "--features=" + feats if feats else "--features=",
                  font, text]
        hr, err = run(hr_cmd)
        if err or hr.returncode != 0:
            print(f"HR-CRASH {os.path.basename(font)} {text!r} "
                  f"{feats} {(hr.stderr if hr else err)[:200]}")
            nfail += 1
            failures.append((font, text, feats, "<crash>",
                             (hr.stderr if hr else err)[:200]))
            continue
        hb, err = run(hb_cmd)
        if err or hb.returncode != 0:
            print(f"HB-FAIL {font} {text!r} "
                  f"{(hb.stderr if hb else err)[:100]}")
            continue
        if hr.stdout.strip() == hb.stdout.strip():
            if expected_failure(font, feats, text, "", ""):
                print(f"UNEXPECTED-PASS {os.path.basename(font)} "
                      f"{text!r} {feats} (remove from expected failures)")
                nfail += 1
            else:
                npass += 1
        else:
            reason = expected_failure(font, feats, text, hr.stdout, hb.stdout)
            if reason:
                nxfail += 1
            else:
                nfail += 1
                failures.append((font, text, feats,
                                 hr.stdout.strip()[:160],
                                 hb.stdout.strip()[:160]))

    print(f"\n{npass} pass, {nfail} fail, {nxfail} expected-fail "
          f"(morx-liga, fallback-mark-positioning)")
    for font, text, feats, ours, hb in failures:
        print(f"FAIL: {os.path.basename(font)} {text!r} [{feats}]")
        print(f"  ours: {ours}")
        print(f"  hb:   {hb}")
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
