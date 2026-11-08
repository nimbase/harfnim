# Architecture

harfnim is a module for module port of harfrust into `src/harfnim/`,
with a flat layout plus an `ot/` subdirectory.

## Shaping pipeline

`shape` in `src/harfnim/shape.nim` runs these stages:

1. Guess segment properties (script, direction, language).
2. Fetch cached GSUB, GPOS, kern tables from the shaper.
3. Pick a shaper (`src/harfnim/ot/shaper.nim`, `categorizeShaper`).
4. Preprocessing on codepoints (Hangul jamo, Thai SARA AM and PUA,
   Indic vowel constraints, Arabic joining masks).
5. Normalization (`src/harfnim/normalize.nim`) with shaper hooks
   (Hebrew compose, Indic decompose and compose).
6. Glyph mapping (`mapGlyphsFast`), glyph class synthesis, mark
   recategorization.
7. GSUB application: default, Arabic, Hangul, or Indic staged path.
8. Default ignorable hiding, position init, base advances.
9. GPOS application (mark, cursive, pair, contextual), legacy `kern`,
   mark zeroing, fallback mark positioning for scripts that allow it.
10. Direction reversal for RTL and buffer cleanup.

`shapeWithPlan` takes a prebuilt `ShapePlan` (script tag, language tag,
features) so callers can reuse plans across buffers.

## Module map

Top level (`src/harfnim/`):

* `buffer.nim`: `Buffer`, `GlyphInfo`, `GlyphPosition`, clusters, masks.
* `sfnt.nim`: `SfntFont`, table directory, cmap, metrics, names.
* `font.nim`: `ShaperFont`, layout table cache, scale, advances, outlines.
* `shape.nim`: orchestration, Arabic and default GPOS helpers.
* `normalize.nim`: three round normalizer with font callbacks.
* `unicode.nim`, `ucd_table.nim`, `emoji_table.nim`: properties, compose.
* `tag.nim`, `script.nim`, `language.nim`, `direction.nim`, `feature.nim`.
* `scale.nim`: integer font scaling.
* `draw.nim`, `glyf.nim`, `cff.nim`, `gvar.nim`: outlines and variations.
* `varstore.nim`, `variations.nim`: variation store and coordinates.
* `error.nim`: `FontError` (parse time only).
* `subset.nim`: subsetting support.

OpenType (`src/harfnim/ot/`):

* `gsub.nim`, `gpos.nim`: table types, parsers, lazy lookup getters.
* `coverage.nim`: `Coverage`, `ClassDef`, raw index fast path.
* `context.nim`: input, lookahead, and backtrack matchers.
* `apply.nim`: substitution and positioning application.
* `map.nim`: script and language resolution, feature application.
* `maskbits.nim`: shared feature mask allocator.
* `kern.nim`: legacy `kern` table.
* `shaper.nim`: shaper kinds and dispatch, `gposHasMark`.
* `arabic.nim`, `arabic_table.nim`: joining and fallback forms.
* `hebrew.nim`, `hangul.nim`, `thai.nim`: dedicated shapers.
* `indic.nim`, `indic_table.nim`, `indic_machine.nim`,
  `indic_machine_data.nim`: Indic shaper and syllable finder.
* `syllabic.nim`, `vowel_constraints.nim`: shared syllabic core.

Entry point `src/harfnim.nim` reexports the public modules.

## Reference implementations

* HarfBuzz (Behdad Esfahbod and developers), MIT licensed.
* harfrust (Yevhenii Reizner), MIT licensed, used as the direct porting
  reference including module structure and shaping stages.

## Scope status

Done: buffer, Unicode, normalize, SFNT, GSUB 1 to 8, GPOS single, pair,
mark, cursive, contextual and chained, wide 24 bit formats, Arabic,
Hebrew, Hangul, Thai and Lao, Indic, legacy kern, outlines, CFF and CFF2,
variations (fvar, avar, gvar, HVAR, VVAR, GDEF deltas), cmap 14, win1256
fallback, hr-shape CLI, conformance harness.

Open: Khmer, Myanmar, USE shapers (syllabic core is shared), MVAR
metrics, AAT morx, stch stretching.
