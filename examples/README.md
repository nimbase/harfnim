# Shaping example posters

Sixteen Nim programs that shape real text with harfnim and draw the
result as fixed size SVG guides with big stroked glyph outlines. Each
poster uses an explicit canvas width and height, a big pixel size,
stroked outlines, and labeled guides (baselines, origins, advances,
clusters, run bands) plus a short info panel.

## The posters

| Program | SVG | What it shows |
|---|---|---|
| `ex01_anatomy.nim` | `out/ex01_anatomy.svg` (1280x780) | Shaped "AV": origins, advance arrows, scaled extents, byte clusters |
| `ex02_kerning.nim` | `out/ex02_kerning.svg` (1280x760) | "AV" and "To" with kern off vs on, measured kern deltas |
| `ex03_ligature.nim` | `out/ex03_ligature.svg` (1280x780) | "fi" with liga off vs on in a synthetic font, cluster merge |
| `ex04_marks.nim` | `out/ex04_marks.svg` (1280x820) | Mark to base offset with zero advance; ccmp composition |
| `ex05_bidi.nim` | `out/ex05_bidi.svg` (1280x1020) | `visualRuns` logical vs visual order with map connectors |
| `ex06_arabic.nim` | `out/ex06_arabic.svg` (1280x820) | "مرحبا" joining: clusters reversed, forms applied |
| `ex07_hebrew.nim` | `out/ex07_hebrew.svg` (1280x920) | Shalom: vowels ride consonants, RTL reversal, mark offsets |
| `ex08_russian.nim` | `out/ex08_russian.svg` (1280x960) | YO equivalence; "Привет" kerned |
| `ex09_thai.nim` | `out/ex09_thai.svg` (1280x880) | SARA AM split; identical gid streams |
| `ex10_hangul.nim` | `out/ex10_hangul.svg` (1280x800) | Jamo compose to precomposed gid |
| `ex11_greek.nim` | `out/ex11_greek.svg` (1280x960) | Tonos equivalence; "logos" kerned with final sigma |
| `ex12_khmer.nim` | `out/ex12_khmer.svg` (1280x920) | Khmer vowel leap; Coeng plus Mo fuse below |
| `ex13_myanmar.nim` | `out/ex13_myanmar.svg` (1280x880) | Myanmar reph sinks below the base |
| `ex14_use.nim` | `out/ex14_use.svg` (1280x880) | USE Sinhala syllable in two ligatures |
| `ex15_japanese.nim` | `out/ex15_japanese.svg` (1280x1000) | Dakuten equivalence; kanji plus hiragana word |
| `ex16_chinese.nim` | `out/ex16_chinese.svg` (1280x1040) | Four full em han; Latin around han |

`support.nim` holds the shared pieces: host font discovery, shaping
shortcuts, font unit to pixel transforms, outline to SVG path
conversion, and the canvas builder.

## Fonts

Most posters shape with a host font. `findDemoFont` picks
the first usable file from a candidate list (Arial preferred, then
Times New Roman, Geneva, DejaVu, Liberation). All numbers on the
posters (advances, deltas, offsets, glyph ids) are measured at
generation time, so they stay correct if the host font version
changes. Posters 3 builds a tiny synthetic TTF in memory (blocky f, i,
and fi glyphs with a GSUB type 4 ligature lookup), following the same
no binary fixtures rule as the test suite. Poster 9 needs Ayuthaya,
poster 10 AppleGothic or AppleMyungjo, poster 12 Khmer Sangam MN,
poster 13 Myanmar Sangam MN, poster 14 Sinhala Sangam MN, poster 15
Hiragino Sans GB, and poster 16 Songti SC; the rest
shape with the `findDemoFont` host font.

## Regenerate

Build and run each poster (output lands in `examples/out/`):

```sh
nim c --out:/tmp/ex01 examples/ex01_anatomy.nim && /tmp/ex01
```

Or regenerate all sixteen at once with the nimble task:

```sh
clue task examples
```

## Reading a poster

* Red solid line: baseline. Every glyph origin sits on it.
* Teal dashed lines: hhea ascender and descender.
* Blue dots and dashed verticals: glyph origins and pen stops.
* Green arrows: advances. The next origin equals origin plus advance.
* Purple dashed boxes: scaled glyph extents from `glyphExtents`.
* Orange tags and connectors: UTF-8 byte clusters from `buf.info`,
  or `VisualText.map` in the bidi poster.
* Run bands (posters 5 and 6): maximal level runs with their resolved
  direction. Each run shapes with an explicit direction.
