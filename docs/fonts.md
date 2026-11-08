# Fonts

## SfntFont (`src/harfnim/sfnt.nim`)

`SfntFont` is a `ref` holding the raw bytes plus parsed directory data:

* Table directory (`TableEntry` list), `unitsPerEm`, glyph and metrics counts.
* `cmap` offsets including format 14, names, fvar axes, avar maps.
* HVAR, VVAR, and GDEF variation stores and delta maps.
* `locaCache` for glyph offsets.

Parsing raises only `FontError` (`src/harfnim/error.nim`). Malformed
subtables generally skip the subtable instead of failing the table.

Key procs: `parseFont`, `tableData`, `mapUnicode`, `mapUnicodeVariant`,
`hAdvance`, `vAdvance`, advance deltas, `glyphBoundsUnscaled`,
`drawGlyph`.

## ShaperFont (`src/harfnim/font.nim`)

`ShaperFont` is the shaping handle (HarfBuzz `hb_font_t` equivalent):

* `font`: parsed `SfntFont`.
* `scale`: integer scale from `src/harfnim/scale.nim`.
* `varCoords`: normalized variation coordinates.
* `outlineCache`: bounded, shared through copies.
* `layout`: `LayoutTables` ref caching parsed GSUB, GPOS, and kern.

Sharing is observable: `setScale`, `setScaleSeparate`, and
`setVariations` mutate the shared object. Callers needing isolation
create separate shapers with `newShaperFont`.

Key procs:

* `newShaperFont`, `cachedGsub`, `cachedGpos`, `cachedKern`.
* `nominalGlyph`, `nominalGlyphs`, `variationGlyph`, `hasGlyph`.
* `hAdvance`, `vAdvance`, `glyphExtents`, `glyphBoundsComputedCached`.
* `drawGlyph`, `glyphOutline` (cached), `normalizeContextFor`.
* `isVaried`, `normalizedCoords`.

## Scale (`src/harfnim/scale.nim`)

Integer scaling of advances, offsets, and extents from font units.
Includes clamping helpers used by the positioning path.

## Variations

* `variations.nim`: fvar axes plus avar remapping, coordinate normalization.
* `varstore.nim`: item variation store, `DeltaSetIndexMap`, scalar support.
* `gvar.nim`: glyph outline deltas with phantom handling.
* HVAR and VVAR advance deltas; GDEF store deltas for GPOS `ValueRecord`.
* `setVariations` replaces the outline cache handle so copies keep
  correct per location caches.

## Outlines

* `glyf.nim`: simple and composite TrueType outlines.
* `cff.nim`: CFF Top, INDEX, DICT, private, FDSelect, Type 2 interpreter
  (subrs, flex, CID, seac, CFF2 blend).
* `draw.nim`: `DrawOp` builder, bounded cache, bounds computation.
* Outlines are cached unscaled by glyph id; malformed results are cached
  too so failures stay cheap.
* `glyphExtents` prefers header bounds, falling back to decoded outline
  bounds for composites, CFF, and varied locations.
