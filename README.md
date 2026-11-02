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
* Font parsing: TTF, OTF, TTC, cmap 0/4/6/10/12/13, hmtx/vmtx, glyf bounds
* GSUB substitutions: single, multiple, alternate, ligature, contextual, chained, extension, reverse chain
* GPOS positioning: single, pair kern, mark to base, mark to ligature, mark to mark, cursive
* Arabic joining, presentation form fallback, mark reordering, RTL reversal
* Scaled advances, extents, anchor attachment, fallback mark positioning

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
* [x] Arabic joining, fallback, RTL
* [ ] Indic, Thai, Hangul, Hebrew, Khmer, Myanmar, USE, syllabic shapers
* [ ] GPOS contextual positioning and 24 bit formats
* [ ] cmap 14, name table, caches, variations
* [ ] hr-shape CLI and conformance harness
* [ ] AAT morx
* [ ] stch stretching and win1256 legacy fallback

## Tools
`hr-shape` is a small `hb-shape` compatible CLI (numeric glyph ids and
UTF-8 byte clusters):

```
clue build src/hr_shape.nim --out:/tmp/hr-shape
/tmp/hr-shape Arial.ttf "مرحبا" --font-size=1000
/tmp/hr-shape Arial.ttf "AVfi" --font-size=1000 --features=kern,liga
```

`tools/conformance.py` shapes a font, text, and feature matrix with both
`hr-shape` and the system `hb-shape` and compares exact output:

```
python3 tools/conformance.py
python3 tools/conformance.py --only "مرحبا"
```

Known gaps are tracked as expected failures in the script
(morx ligatures, legacy `kern` table, fallback mark positioning on fonts
without usable Arabic mark data).

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/harfnim/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/harfnim/fork)

### 🎩 License
MIT license | Nim Community.
