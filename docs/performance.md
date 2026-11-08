# Performance

These are the rules that keep shaping fast, plus the current numbers.

## Sharing instead of copying

* `SfntFont` and `ShaperFont` are `ref` objects sharing table bytes,
  layout caches, and outline caches. Nim `seq` assignment copies, so
  large tables must not live in value objects on hot paths.
* `GsubData` and `GposData` are `ref` objects for the same reason.
  Passing them copies a pointer, not megabytes of lookups.
* Layout tables parse once per shaper (`cachedGsub`, `cachedGpos`,
  `cachedKern`) and ride along through copies.

## Lazy lookup parsing

* `parseGsub` and `parseGpos` (font path) parse scripts and features
  eagerly but defer lookup bodies.
* `getGsubLookup` and `getGposLookup` parse and cache on first use;
  `FontError` yields an empty placeholder so indices stay aligned.
* `parseGsubTable` and `parseGposTable` (raw bytes path) stay eager.
* Direct `.lookups[]` indexing bypasses the cache; shaping code uses
  the getters. Bounds use `gsubLookupCount` and `gposLookupCount`.

Measured effect (`tools/bench_shape.nim`, 200 lookup synthetic GSUB):
header only parse 44us, first lookup 22us, all lookups 494us. Shaping
that touches one script lookup skips most parse work.

## Hot path rules

* Coverage uses `coverageIndexRaw` (`int`, -1 on miss) instead of
  `Option` in per glyph matching.
* Context matchers take `openArray` for ids and coverages; format 3
  slices use `toOpenArray` and empty `[]`, with no dummy seq or slice
  copies.
* Indic would substitute probing takes `openArray` and uses stack
  arrays (`[virama, consonant]`) instead of per glyph `@[]`.
* LangSys resolves once per shape (`gsubLangSys`, `gposLangSys`);
  per feature lookups reuse it instead of rebuilding feature lists.
* Feature masks share `allocMaskBit` (`src/harfnim/ot/maskbits.nim`).
* `Buffer.enlarge` grows geometrically under `maxLen`; parsers use
  `newSeqOfCap` where counts are known.
* `FontError` stays on the parse path; shaping avoids exceptions and
  per glyph allocations (`positions` is the necessary exception on
  match attempts).

## Current baseline

From `tools/bench_shape.nim` on this machine:

* Coverage raw: about 24 to 25M lookups per second.
* ASCII shaping: about 14 to 15k shapes per second.
* Conformance: 474 pass, 0 fail, 30 expected fail.

## When adding code

* Pass large tables as `ref` (already the case) or `lent`; do not add
  `seq` fields to hot value objects.
* New matchers take `openArray`; new probes avoid `@[]` in loops.
* New features resolve LangSys once, then reuse it.
* New lookup access goes through the lazy getters.
* Add or extend a `bench_shape` probe when changing parse or match code.
