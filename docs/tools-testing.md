# Tools and testing

## hr-shape

`tools/hr_shape.nim` is an hb-shape compatible CLI for manual checks:

```sh
clue build tools/hr_shape.nim --out:/tmp/hr-shape
/tmp/hr-shape Arial.ttf "مرحبا" --font-size=1000
/tmp/hr-shape Arial.ttf "AVfi" --font-size=1000 --features=kern,liga
```

Output matches `hb-shape --no-glyph-names --utf8-clusters`:
`[gid=cluster@dx,dy+ax,ay|...]` with numeric ids and UTF-8 byte clusters.
Like hb-shape, it enables the default feature set unless a feature is
mentioned explicitly.

## Conformance

`tools/conformance.nim` shapes a font, text, and feature matrix with
both hr-shape and the system hb-shape and compares exact output:

```sh
clue build tools/conformance.nim --out:/tmp/conformance
/tmp/conformance --hr-shape /tmp/hr-shape
/tmp/conformance --hr-shape /tmp/hr-shape --only "مرحبا"
```

Current status: 474 pass, 0 fail, 30 expected fail (morx ligatures and
fallback mark positioning on fonts without usable Arabic mark data).

## Bench

`tools/bench_shape.nim` is a synthetic micro benchmark with no external
fonts:

* 500k coverage raw lookups per second.
* 5k ASCII shapes.
* 200 lookup GSUB probe: header only parse, first lookup cost, and full
  touch cost, showing what lazy parsing skips.

```sh
clue build tools/bench_shape.nim --out:/tmp/bench-shape
/tmp/bench-shape
```

Recent numbers on this machine: about 24 to 25M coverage lookups per
second, about 14 to 15k ASCII shapes per second, header only GSUB parse
44us for 200 lookups versus 494us to touch all of them.

## Tests

`clue test` runs all suites (18 suites, all green):

* `test_buffer`, `test_unicode`, `test_normalize`, `test_font`.
* `test_ot_gsub`, `test_ot_gpos`, `test_ot_kern`, `test_ot_wide`.
* `test_ot_arabic`, `test_ot_syllabic`, `test_shape`.
* `test_shaper_hebrew`, `test_shaper_hangul`, `test_shaper_thai`,
  `test_shaper_indic`.
* `test_outline`, `test_variations`, `test_subset`, `test1`.

Conventions: synthetic fonts built in code (`putU16`, `buildCmap`,
`baseTables`, `buildFontRaw`, `shapeGids` are duplicated per test file
by convention), no binary fixtures, malformed tables are skipped, and
`FontError` is raised only at parse time.
