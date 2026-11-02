## Differential conformance harness: hr-shape vs hb-shape.
##
## Builds hr-shape from this repo, then shapes a font x text x feature
## matrix with both engines and compares exact output. Both sides run
## with numeric glyph ids and UTF-8 byte clusters, so matching lines mean
## identical glyphs, clusters, advances, and offsets.
##
## Usage: conformance [--hr-shape BINARY] [--hb-shape BINARY]
##                    [--font-size N] [--only SUBSTR]

import std/os
import std/osproc
import std/sequtils
import std/strutils

const
  Fonts = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Georgia.ttf",
    "/System/Library/Fonts/Supplemental/Courier New.ttf",
    "/System/Library/Fonts/Supplemental/Verdana.ttf",
    "/System/Library/Fonts/Supplemental/Tahoma.ttf",
    "/System/Library/Fonts/Supplemental/Trebuchet MS.ttf",
    "/System/Library/Fonts/Geneva.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
  ]
  LatinTexts = [
    "To", "AV", "Vo", "Wa", "fi", "ffi", "ffl", "fl",
    "Hello, World!", "AVfiToWe", "12345",
    "e-mail: info@example.com", "(To) \"AV\"",
    "caf\u00E9", "na\u00EFve", "r\u00E9sum\u00E9", "stra\u00DFe",
    "\u00C5ngstr\u00F6m", "e\u0301", "A\u030A",
    "\u201CHello\u201D", "\u2014dash\u2014",
  ]
  ArabicTexts = [
    "مرحبا", "السلام", "العربية", "بِسْمِ", "مُحَمَّد",
    "الْعَرَبِيَّةُ", "السَّلامُ", "الله", "لا", "ل\u200Da", "كـتاب",
  ]
  MiscTexts = [
    "办公", "日本語", "😀", "\u20AC100", "\u2026",
    "1/2", "a\u200Db", "a\u200Cb",
  ]
  LatinFeatures = ["kern,liga", "-kern,-liga"]
  ArabicFeatures = [""]
  MiscFeatures = [""]

  LigaTexts = ["fi", "ffi", "ffl", "fl", "AVfiToWe"]
  MorxFonts = ["Geneva.ttf", "Helvetica.ttc"]

  ArabicMarkTexts = ["بِسْمِ", "مُحَمَّد", "الْعَرَبِيَّةُ", "السَّلامُ"]

  # Arabic mark-fallback differences on fonts without usable Arabic mark
  # positioning: .notdef-only coverage (fallback runs on .notdef extents,
  # with stacking/zeroing differences) plus MarkLig-only or missing GPOS.
  FallbackMarkDiffs = [
    ("Georgia.ttf", "بِسْمِ"), ("Georgia.ttf", "مُحَمَّد"),
    ("Georgia.ttf", "الْعَرَبِيَّةُ"), ("Georgia.ttf", "السَّلامُ"),
    ("Geneva.ttf", "بِسْمِ"), ("Geneva.ttf", "مُحَمَّد"),
    ("Geneva.ttf", "الْعَرَبِيَّةُ"), ("Geneva.ttf", "السَّلامُ"),
    ("Helvetica.ttc", "بِسْمِ"), ("Helvetica.ttc", "مُحَمَّد"),
    ("Helvetica.ttc", "الْعَرَبِيَّةُ"), ("Helvetica.ttc", "السَّلامُ"),
    ("Verdana.ttf", "بِسْمِ"), ("Verdana.ttf", "مُحَمَّد"),
    ("Verdana.ttf", "الْعَرَبِيَّةُ"), ("Verdana.ttf", "السَّلامُ"),
    ("Trebuchet MS.ttf", "بِسْمِ"), ("Trebuchet MS.ttf", "مُحَمَّد"),
    ("Trebuchet MS.ttf", "الْعَرَبِيَّةُ"),
    ("Trebuchet MS.ttf", "السَّلامُ"),
  ]

proc expectedFailure(font, features, text, ours, hb: string): string =
  let base = lastPathPart(font)
  if base in MorxFonts and "liga" in features.replace("-liga", "") and
      text in LigaTexts:
    return "morx-liga"
  if features == "" and text in ArabicMarkTexts and
      (base, text) in FallbackMarkDiffs:
    return "fallback-mark-positioning"
  return ""

proc run(exe: string, args: seq[string],
    workdir: string = ""): tuple[output: string, code: int] =
  var cmd = exe.quoteShell
  for a in args:
    cmd &= " " & a.quoteShell
  let res = execCmdEx(cmd, workingDir = workdir,
    options = {poUsePath, poEvalCommand})
  (res.output, res.exitCode)

proc usage(status: int) =
  stderr.writeLine("Usage: conformance [--hr-shape BINARY] " &
    "[--hb-shape BINARY] [--font-size N] [--only SUBSTR]")
  quit(status)

var
  hrShape = ""
  hbShape = "hb-shape"
  fontSize = "1000"
  only = ""

var i = 1
while i <= paramCount():
  let a = paramStr(i)
  if a == "-h" or a == "--help":
    usage(0)
  elif a == "--hr-shape":
    inc i
    if i > paramCount():
      quit("--hr-shape needs a value")
    hrShape = paramStr(i)
  elif a.startsWith("--hr-shape="):
    hrShape = a.split('=', 1)[1]
  elif a == "--hb-shape":
    inc i
    if i > paramCount():
      quit("--hb-shape needs a value")
    hbShape = paramStr(i)
  elif a.startsWith("--hb-shape="):
    hbShape = a.split('=', 1)[1]
  elif a == "--font-size":
    inc i
    if i > paramCount():
      quit("--font-size needs a value")
    fontSize = paramStr(i)
  elif a.startsWith("--font-size="):
    fontSize = a.split('=', 1)[1]
  elif a == "--only":
    inc i
    if i > paramCount():
      quit("--only needs a value")
    only = paramStr(i)
  elif a.startsWith("--only="):
    only = a.split('=', 1)[1]
  elif a.len > 0 and a[0] == '-':
    quit("unknown option: " & a)
  else:
    quit("unexpected argument: " & a)
  inc i

let repo = parentDir(parentDir(currentSourcePath()))
if hrShape == "":
  let tmp = getTempDir() / ("hr-shape-" & $getCurrentProcessId())
  createDir(tmp)
  hrShape = tmp / "hr-shape"
  echo "building hr-shape -> " & hrShape
  let (buildOut, buildCode) = run("clue",
    @["build", "src/hr_shape.nim", "--out:" & hrShape], repo)
  if buildCode != 0:
    let tail = if buildOut.len > 3000: buildOut[^3000..^1] else: buildOut
    echo "build failed:\n" & tail
    quit(2)

proc short(s: string, n: int): string =
  let t = s.strip()
  if t.len == 0:
    return ""
  t[0..min(n, t.len - 1)]

type Case = tuple[font, text, feats: string]
var cases: seq[Case] = @[]
for font in Fonts:
  if not fileExists(font):
    echo "skip missing font: " & font
    continue
  for text in LatinTexts:
    for feats in LatinFeatures:
      cases.add((font, text, feats))
  for text in ArabicTexts:
    for feats in ArabicFeatures:
      cases.add((font, text, feats))
  for text in MiscTexts:
    for feats in MiscFeatures:
      cases.add((font, text, feats))

if only != "":
  cases = cases.filterIt(only in it.font or only in it.text or
    only in it.feats)

var npass, nxfail, nfail = 0
var failures: seq[Case] = @[]
var failureOuts: seq[tuple[ours, hb: string]] = @[]
for c in cases:
  let hrArgs = if c.feats != "": @[c.font, c.text,
    "--font-size=" & fontSize, "--features=" & c.feats]
    else: @[c.font, c.text, "--font-size=" & fontSize, "--features="]
  let (hrOut, hrCode) = run(hrShape, hrArgs)
  if hrCode != 0:
    echo "HR-CRASH " & lastPathPart(c.font) & " " & c.text.escape &
      " " & c.feats & " " & short(hrOut, 199)
    inc nfail
    failures.add(c)
    failureOuts.add(("<crash>", short(hrOut, 199)))
    continue
  let (hbOut, hbCode) = run(hbShape, @["--no-glyph-names",
    "--utf8-clusters", "--font-size=" & fontSize,
    "--features=" & c.feats, c.font, c.text])
  if hbCode != 0:
    echo "HB-FAIL " & c.font & " " & c.text.escape
    continue
  if hrOut.strip() == hbOut.strip():
    if expectedFailure(c.font, c.feats, c.text, "", "") != "":
      echo "UNEXPECTED-PASS " & lastPathPart(c.font) & " " &
        c.text.escape & " " & c.feats & " (remove from expected failures)"
      inc nfail
    else:
      inc npass
  else:
    let reason = expectedFailure(c.font, c.feats, c.text, hrOut, hbOut)
    if reason != "":
      inc nxfail
    else:
      inc nfail
      failures.add(c)
      failureOuts.add((short(hrOut, 159), short(hbOut, 159)))

echo ""
echo $npass & " pass, " & $nfail & " fail, " & $nxfail &
  " expected-fail (morx-liga, fallback-mark-positioning)"
for k, c in failures:
  echo "FAIL: " & lastPathPart(c.font) & " " & c.text.escape &
    " [" & c.feats & "]"
  echo "  ours: " & failureOuts[k].ours
  echo "  hb:   " & failureOuts[k].hb

quit(if nfail > 0: 1 else: 0)
