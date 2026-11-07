<p align="center">
  Pure Nim port of the HarfBuzz text shaping engine<br>
</p>

<p align="center">
  <code>nimble install harfnim</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/harfnim/">API reference</a><br>
  <img src="https://github.com/nimbase/harfnim/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/harfnim/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
Pure Nim shaping without C bindings.

* Text buffers with clusters, directions, scripts, and languages
* Unicode properties, Hangul algorithms, compose and decompose
* Three round normalizer with font callbacks
* Font parsing: TTF, OTF, TTC, cmap 0/4/6/10/12/13, hmtx/vmtx, glyf outlines, CFF/Type 2 charstrings
* GSUB substitutions: single, multiple, alternate, ligature, contextual, chained, extension, reverse chain (including 24-bit beyond-64K formats 3/4)
* GPOS positioning: single, pair kern, mark to base, mark to ligature, mark to mark, cursive, contextual, chained, plus legacy kern table (including 24-bit formats)
* Arabic joining, presentation form fallback, mark reordering, RTL reversal
* Scaled advances, extents, anchor attachment, fallback mark positioning
* Cached glyph outlines with draw-callback iteration (move/line/quadratic/cubic/close)
* Differential conformance against hb-shape across Latin, Arabic, CJK, emoji, and control characters

## Examples
Shape Latin text with kerning and ligatures:

```nim
import harfnim

proc readBytes(path: string): seq[uint8] =
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  for i, c in s:
    result[i] = uint8(c)

let font = parseFont(readBytes("Arial.ttf"))
var shaper = newShaperFont(font)
shaper.setScale(1000)

var buf = newBuffer()
buf.pushStr("AVfi")
shaper.shape(buf, @[globalFeature(tagFromStr("kern"), 1),
  globalFeature(tagFromStr("liga"), 1)])

for i in 0 ..< buf.len:
  echo buf.info[i].glyphId, " adv=", buf.pos[i].xAdvance
```

Shape Arabic text (joining and marks are automatic):

```nim
import harfnim

let font = parseFont(readBytes("Arial.ttf"))
var shaper = newShaperFont(font)
shaper.setScale(1000)

var buf = newBuffer()
buf.pushStr("مرحبا")
shaper.shape(buf)

for i in 0 ..< buf.len:
  echo buf.info[i].glyphId, " adv=", buf.pos[i].xAdvance,
    " off=", buf.pos[i].xOffset, ",", buf.pos[i].yOffset
```

## Roadmap
* [x] Buffer, Unicode, normalize pipeline
* [x] SFNT, scale, ShaperFont
* [x] GSUB types 1 to 8
* [x] GPOS single, pair, extension
* [x] GPOS mark attachment and cursive
* [x] GPOS contextual positioning (types 7/8, including extension)
* [x] Wide 24-bit formats (Coverage/ClassDef 3/4, GSUB/GPOS 3/4, contextual 4/5/6)
* [x] Arabic joining, fallback, RTL
* [x] Legacy kern table (format 0, MS and Apple layouts)
* [x] hr-shape CLI and conformance harness
* [x] glyf outlines (simple + composite) with draw callbacks and extents fallback
* [x] CFF / Type 2 charstrings (subrs, flex, CID FDSelect, seac) with bounded outline cache
* [x] cmap format 14 variation sequences, name table
* [x] Variable font coordinates (fvar/avar) and gvar outline variations
* [x] HVAR/VVAR advance variation and CFF2 outlines with blend
* [x] GPOS variation deltas from the GDEF item variation store
* [x] Windows-1256 legacy Arabic fallback (signature, presents, ligatures)
* [ ] Indic, Thai, Hangul, Hebrew, Khmer, Myanmar, USE, syllabic shapers
* [ ] MVAR metrics
* [ ] AAT morx
* [ ] stch stretching

## Tools
`hr-shape` is a small `hb-shape` compatible CLI (numeric glyph ids and
UTF-8 byte clusters). Like `hb-shape`, it enables the default feature
set unless a feature is mentioned explicitly:

```
clue build tools/hr_shape.nim --out:/tmp/hr-shape
/tmp/hr-shape Arial.ttf "مرحبا" --font-size=1000
/tmp/hr-shape Arial.ttf "AVfi" --font-size=1000 --features=kern,liga
```

`tools/conformance.nim` shapes a font, text, and feature matrix with both
`hr-shape` and the system `hb-shape` and compares exact output:

```
clue build tools/conformance.nim --out:/tmp/conformance
/tmp/conformance --hr-shape /tmp/hr-shape
/tmp/conformance --hr-shape /tmp/hr-shape --only "مرحبا"
```

Known gaps are tracked as expected failures in the script
(morx ligatures, fallback mark positioning on fonts without usable
Arabic mark data).

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/harfnim/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/harfnim/fork)

### 🎩 License
MIT license | Nim Community.
