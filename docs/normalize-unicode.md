# Unicode and normalization

## Unicode properties

`src/harfnim/unicode.nim`:

* `GeneralCategory` (control, format, marks, letters, numbers,
  punctuation, symbols, separators), `isMark`, `isLetter`,
  `inRangeInclusive`, flag helpers.
* Combining class constants (`CcNotReordered`, `CcVirama`, above and
  below attachments, and others).
* `generalCategoryFor`, `composeImpl`, `decomposeImpl`,
  `isMarkCodepoint`, Hangul composition helpers.
* Data comes from `src/harfnim/ucd_table.nim` (UCD 18.0) and
  `src/harfnim/emoji_table.nim`.

Related small modules: `script.nim` (ISO 15924 scripts),
`language.nim`, `direction.nim` (horizontal, vertical, forward,
backward), `tag.nim` (OpenType tags, case conversion, DFLT and dflt
defaults).

## Normalizer

`src/harfnim/normalize.nim` implements the three round normalizer with
injected font callbacks:

* `NormalizationMode`: none, decomposed, composed diacritics, composed
  without short circuit, auto.
* `NormalizeContext`: nominal glyph, bulk nominal glyphs, variation
  glyph, decompose, compose, and optional mark reorder callbacks.
* `ShaperFont.normalizeContextFor` binds the real font callbacks.
* Shaper hooks: Hebrew compose and mark reorder; Indic decompose
  exclusions (for example RRA) and compose exceptions (for example YDDV).

## Buffer integration

* `allocateUnicodeVars` attaches codepoints before normalization.
* `initUnicodeProps` records category, combining class, ignorable, and
  continuation state per glyph.
* `formClusters` and `reorderMarksArabic` / `reorderMarksHebrew` run on
  codepoints where required.
* Syllabic categories attach before glyph mapping for Indic shaping.

## Tests

`tests/test_unicode.nim` covers properties and Hangul algorithms.
`tests/test_normalize.nim` covers the three round pipeline with stub
fonts. `tests/test_ot_syllabic.nim` covers the shared syllabic
machinery used by Indic shaping tests.
