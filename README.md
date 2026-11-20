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

## Example posters

`examples/` holds Nim programs that shape real text and draw the
result as fixed size SVG guides with big stroked glyphs. Regenerate
them with `clue task examples` (see `examples/README.md`).

| Description | Preview |
|---|---|
| **Anatomy of shaped text.** "AV" at 560px: baseline, hhea ascender and descender, origins, advance arrows, scaled extents, byte clusters. | <img src="examples/out/ex01_anatomy.svg" width="640"> |
| **Kerning.** "AV" and "To" with kern off vs on, measured kern deltas on the first advance. | <img src="examples/out/ex02_kerning.svg" width="640"> |
| **Ligature.** Synthetic font: "fi" with liga off (two glyphs) vs on (one gid, merged cluster). | <img src="examples/out/ex03_ligature.svg" width="640"> |
| **Marks.** Beh plus fatha positioned by GPOS with a zero advance; a plus acute composed by ccmp. | <img src="examples/out/ex04_marks.svg" width="640"> |
| **Bidirectional runs.** `visualRuns` over mixed Hebrew: logical order, one band per level run, map connectors. | <img src="examples/out/ex05_bidi.svg" width="640"> |
| **Arabic joining.** "مرحبا": logical codepoints vs visual glyphs, clusters 8 6 4 2 0. | <img src="examples/out/ex06_arabic.svg" width="640"> |
| **Hebrew marks.** Shalom: vowels ride consonants, RTL reversal, GPOS offsets onto each base. | <img src="examples/out/ex07_hebrew.svg" width="640"> |
| **Russian.** Precomposed vs decomposed YO shape to one gid; "Привет" kerned. | <img src="examples/out/ex08_russian.svg" width="640"> |
| **Greek.** Precomposed vs decomposed alpha with tonos; "logos" kerned with final sigma. | <img src="examples/out/ex11_greek.svg" width="640"> |
| **Thai.** Precomposed SARA AM vs NIKHAHIT plus SARA A give identical gid streams. | <img src="examples/out/ex09_thai.svg" width="640"> |
| **Hangul.** Three conjoining jamo compose to the gid of precomposed han. | <img src="examples/out/ex10_hangul.svg" width="640"> |
| **Khmer.** AE leaps before KHA; COENG plus MO fuse below; RO keeps cluster 12. | <img src="examples/out/ex12_khmer.svg" width="640"> |
| **Myanmar.** The reph sinks below the base; both glyphs share cluster 0. | <img src="examples/out/ex13_myanmar.svg" width="640"> |
| **USE.** One Sinhala syllable shapes to two ligatures, clusters 0 and 6. | <img src="examples/out/ex14_use.svg" width="640"> |
| **Japanese.** Dakuten equivalence; kanji plus hiragana word in full ems. | <img src="examples/out/ex15_japanese.svg" width="640"> |
| **Chinese.** Four full em han; Latin around han with byte clusters. | <img src="examples/out/ex16_chinese.svg" width="640"> |

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
* [x] Hebrew shaper (presentation-form composition, mark reorder) and shaper dispatch
* [x] Hangul shaper (LV/LVT composition, jamo features, tone reorder)
* [x] Thai/Lao shaper (SARA AM split, PUA fallback shaping)
* [x] Indic consonant-syllable shaper (reordering, staged features)
* [x] Khmer shaper (Coeng/Ro pref, left matras, split matras)
* [x] Myanmar shaper (reph positioning, pre-base matras; mym2)
* [x] USE shaper (reph/pref recording, post-base reordering)
* [x] MVAR metrics (hhea/vhea ascender, descender, line gap)
* [x] AAT morx (chains, state machines, noncontextual, contextual,
  ligature, rearrangement, insertion; feat flag compilation; DUMBER
  downgrade; deleted glyph compaction)
* [x] stch stretching (record multiplied tiles, expand repeating
  tiles to fill the word after the visual reorder)

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
(fallback mark positioning on fonts without usable
Arabic mark data).

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/harfnim/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/harfnim/fork)

### 🎩 License

harfnim is MIT licensed — see [LICENSE](LICENSE) for the full text.

Copyright (c) 2026 nimbase

### 🙏 Acknowledgements

harfnim is a Nim port of [HarfBuzz](https://github.com/harfbuzz/harfbuzz)
(Behdad Esfahbod and the HarfBuzz developers), developed against
[harfrust](https://github.com/harfbuzz/harfrust) (Copyright (c)
HarfBuzz developers, Copyright (c) 2020 Yevhenii Reizner) as the
reference implementation. Both upstream projects are MIT licensed.
