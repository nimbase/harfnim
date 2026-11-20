# Complex shapers

## Arabic

* `src/harfnim/ot/arabic.nim`: joining aware GSUB order (stch, ccmp,
  locl, isol and friends, rlig, calt, liga, clig, mset), Unicode and
  win1256 fallback singles and ligatures, lam alef first.
* `src/harfnim/ot/arabic_table.nim`: joining types and fallback data.
* `shape.nim` helpers: `prepareArabicMasks`, `applyArabicGsub`,
  `applyArabicFallback`, plus Arabic aware default GPOS selection.
* `recordStch` marks glyphs multiplied by stch as fixed or repeating
  tiles; `applyStch` runs after the visual reorder and repeats the
  repeating tiles to fill the preceding word, mirroring harfrust
  `record_stch`, `apply_stch`, and `postprocess_glyphs_arabic`.
* Horizontal layout only; vertical text uses the default shaper.

## Hebrew

* `src/harfnim/ot/hebrew.nim`: presentation form composition gated on
  GPOS mark support, plus mark reordering wired through the normalize
  context in `shape.nim`.

## Hangul

* `src/harfnim/ot/hangul.nim`: LV and LVT composition, jamo masks
  (`prepareHangulMasks`, `setupMasksHangul`), ljmo, vjmo, tjmo, and calt
  handling with calt kept away from jamo, tone reorder firewall.
* Preprocessing happens on codepoints before normalization.

## Thai and Lao

* `src/harfnim/ot/thai.nim`: SARA AM split plus PUA fallback shaping for
  Thai fonts without Thai GSUB. Only exact `thai` GSUB script records
  count for the PUA gate; DFLT fallback does not.
* Thai opts out of fallback mark positioning.

## Indic

* `src/harfnim/ot/indic.nim`: full consonant syllable shaper.
* Stages: vowel constraint splits, matra hooks, category setup, syllable
  discovery, consonant position detection via would substitute probing,
  initial reordering, 17 staged features, final reordering, user
  features, syllable cleanup.
* Per syllable matching threads an anchor syllable through the GSUB
  apply path so multi glyph matches stay inside one syllable.
* Special cases: Kannada Ra H ZWJ order, Malayalam unformed forms and
  Tamil half form rules, old spec halant moves, eyelash Ra, pref scan,
  ZWJ and ZWNJ effects, word start INIT.
* `lookupWouldSubstitute` and `featureWouldSubstitute` mirror HarfBuzz
  arity (single, multiple, alternate, and reverse need exactly one
  glyph) and take `openArray` to avoid per glyph allocations.

## Shared syllabic core

* `src/harfnim/ot/syllabic.nim`: dotted circle insertion, over-long
  syllable cut recording, syllable reset.
* `src/harfnim/ot/vowel_constraints.nim`: splits for 9 Indic scripts
  plus Sinhala, Brahmi, Khojki, Khudawadi, Tirhuta, Modi, Takri, with
  default-ignorable transparency.
* `src/harfnim/ot/indic_table.nim`: categories, positions, packed trie.
* `src/harfnim/ot/indic_machine.nim` plus `indic_machine_data.nim`:
  Ragel syllable finder interpreter and tables.
* `src/harfnim/ot/khmer_machine.nim` plus `khmer_machine_data.nim`:
  Khmer syllable finder with the linear-time joiner-run guard.
* `src/harfnim/ot/myanmar_machine.nim` plus
  `myanmar_machine_data.nim`: Myanmar syllable finder.
* `src/harfnim/ot/use_machine.nim` plus `use_machine_data.nim` and
  `src/harfnim/ot/use_table.nim`: USE syllable finder and categories.

## Khmer

* `src/harfnim/ot/khmer.nim`: Coeng+Ro pref moves with cfar marking,
  left-matra moves, split-matra decompose/compose hooks, locl/ccmp/
  clig, five basic stages, four other stages after clearing syllables.
  `liga` is disabled per the Khmer override.

## Myanmar

* `src/harfnim/ot/myanmar.nim`: Ra+As+H reph handling, pre-base matra
  positioning, four basic features in order, four other features after
  clearing syllables. Legacy `mymr` fonts stay on the default path;
  the shaper engages for `mym2`.

## USE

* `src/harfnim/ot/use.nim`: rphf and topographical mask setup, locl/
  ccmp/nukt/akhn, rphf with repha recording, pref with VPre
  recording, seven basic features, repha and pre-base reordering,
  topographical and other features after clearing syllables.

## AAT morx

* `src/harfnim/aat/morx.nim`: morx table and chain parsing, extended
  state tables, AAT lookup formats 0/2/4/6/8/10, feat table parsing
  with OpenType feature to AAT flag compilation, and drivers for the
  noncontextual, contextual, ligature, rearrangement, and insertion
  subtables. Glyph 0xFFFF always maps to the deleted class, per
  read-fonts. Substitution writes through `replaceInPlace` so deleted
  slots are flagged for the post pass `removeDeletedGlyphs`
  compaction.
* `shape.nim` wiring: when morx is present and text is horizontal (or
  the font has no GSUB), complex shapers stand down to the default
  shaper and morx replaces GSUB. This mirrors the harfrust DUMBER
  downgrade: no mark advance zeroing and no fallback mark
  positioning on the morx path, and the feat table supplies flags
  while `hr-shape` keeps explicit feature disables (value 0) so flag
  compilation sees them. Verified exact against hb-shape on Geneva,
  Helvetica, Khmer, Myanmar, and Sinhala system fonts.

## Status

Done: Arabic (including stch stretching), Hebrew, Hangul, Thai and
Lao, Indic, Khmer, Myanmar, USE, AAT morx.
