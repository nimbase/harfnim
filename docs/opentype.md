# OpenType layout

## Tables

* `src/harfnim/ot/gsub.nim`: `GsubData` (scripts, features, lookups),
  lookup types 1 to 8, extension flattening, `parseGsubTable` (eager raw
  bytes) and `parseGsub` (lazy font path), `getGsubLookup`,
  `gsubLookupCount`, `emptyLookup`, `singleSubstitute`.
* `src/harfnim/ot/gpos.nim`: `GposData`, single, pair, cursive, mark to
  base, mark to ligature, mark to mark, contextual and chained,
  extension flattening, wide formats, `getGposLookup`,
  `gposLookupCount`, `emptyPosLookup`.
* Both tables are `ref` objects so shaping passes pointers instead of
  deep copying parsed lookups. Lookup bodies parse on first use and the
  cache fills through value copies.

## Coverage and classes

`src/harfnim/ot/coverage.nim`:

* `Coverage` (glyph list or ranges, formats 1 to 4 including 24 bit).
* `ClassDef` (formats 1 to 4).
* `coverageIndexRaw`: hot path returning an `int` index or -1.
* `coverageIndex`: `Option` wrapper for compat.
* `covers`, `classOf`.

The raw index avoids `Option` overhead in per glyph matching.

## Context matching

`src/harfnim/ot/context.nim`:

* `ValueKind`: glyph, class, or coverage matching.
* `matchInputSeq`, `matchLookaheadSeq`, `matchBacktrackSeq`.
* Sequences take `openArray` so format 3 slices use `toOpenArray`
  without copying; empty `[]` means no values.
* Input matching requires the feature mask; backtrack and lookahead
  ignore it. Indic matching adds an anchor syllable (0 disables it).
* `lookupCovers` tests the first glyph before scanning.

## Apply paths

`src/harfnim/ot/apply.nim`:

* Substitution: single, multiple, alternate, ligature, context, chain,
  reverse chain, nesting with depth limit, per syllable threading.
* Positioning: single, pair, cursive, mark attachment, contextual and
  chained, plus `applyPosLookup` and `applyPosLookups`.
* Reverse chain runs backward in place without an output buffer.
* `lookupProps` and `checkGlyphProperty` enforce ignore flags, mark
  filtering sets, and attachment types.

## Script and feature resolution

`src/harfnim/ot/map.nim`:

* `findScript`, `findScriptGpos` (exact script else DFLT).
* `resolveLangSys`, `gsubLangSys`, `gposLangSys`.
* `gsubLookupsForLang`, `gposLookupsForLang`, plus tag wrappers.
* `gsubFeaturesFor`, `gposFeaturesFor` remain for compat but are off
  the hot path.
* `applyGsubFeatures` and `applyGposFeatures` resolve once per shape,
  then look up each feature directly.

## Legacy kern

`src/harfnim/ot/kern.nim`: format 0 tables in MS and Apple layouts,
single walk per subtable, cross stream entries skipped.

## Conventions

* Malformed tables skip the subtable and keep feature indices aligned.
* `FontError` is raised only at parse time, not during shaping.
* Parsers take `openArray[uint8]` and bounds check every read.
