# harfnim documentation

This directory documents the entire harfnim library: a pure Nim port of the
HarfBuzz text shaping engine (reference: harfrust).

Start here:

1. [Getting started](getting-started.md) - install, minimal shaping example
2. [Architecture](architecture.md) - pipeline and module map
3. [Buffer](buffer.md) - `Buffer`, `GlyphInfo`, clusters, direction
4. [Fonts](fonts.md) - `SfntFont`, `ShaperFont`, scale, variations, outlines
5. [Shaping](shaping.md) - `shape`, `ShapePlan`, features, shaper dispatch
6. [OpenType layout](opentype.md) - GSUB, GPOS, coverage, context, apply, kern
7. [Complex shapers](shapers.md) - Arabic, Hebrew, Hangul, Thai, Indic, syllabic core
8. [Unicode and normalization](normalize-unicode.md) - properties, normalizer
9. [Tools and testing](tools-testing.md) - hr-shape, conformance, bench, tests
10. [Performance](performance.md) - sharing, lazy parsing, hot path rules

Conventions used across these docs:

* `src/harfnim/<module>.nim:line` references point at the implementation.
* `Option[T]` marks optional values (`std/options`).
* `Tag` is a 4 byte OpenType tag (`src/harfnim/tag.nim`).
* Tests live in `tests/` and use synthetic fonts (no binary fixtures).
* Build and test with `clue` (see `harfnim.nimble`, `clue.lock`).
