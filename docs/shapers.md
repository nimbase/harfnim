# Complex shapers

## Arabic

* `src/harfnim/ot/arabic.nim`: joining aware GSUB order (stch, ccmp,
  locl, isol and friends, rlig, calt, liga, clig, mset), Unicode and
  win1256 fallback singles and ligatures, lam alef first.
* `src/harfnim/ot/arabic_table.nim`: joining types and fallback data.
* `shape.nim` helpers: `prepareArabicMasks`, `applyArabicGsub`,
  `applyArabicFallback`, plus Arabic aware default GPOS selection.
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

* `src/harfnim/ot/syllabic.nim`: dotted circle insertion, syllable reset.
* `src/harfnim/ot/vowel_constraints.nim`: splits for 9 Indic scripts.
* `src/harfnim/ot/indic_table.nim`: categories, positions, packed trie.
* `src/harfnim/ot/indic_machine.nim` plus `indic_machine_data.nim`:
  Ragel syllable finder interpreter and tables.
* Khmer, Myanmar, and USE reuse this core; their full shapers are open.

## Status

Done: Arabic, Hebrew, Hangul, Thai and Lao, Indic.
Open: Khmer, Myanmar, USE (machines and tables staged, shaper wiring
remains), plus stch stretching.
