# Buffer

`src/harfnim/buffer.nim` holds the text under shaping.

## Core types

* `GlyphId`: distinct `uint32` with `newGlyphId`, `value`, borrowed `==`.
* `Mask`: `uint32`. Low bits are glyph flags, higher bits are feature masks.
* `GlyphInfo`: `glyphId`, `mask`, `cluster`, plus two packed var words
  (`infoVars`) carrying glyph props, Unicode props, ligature state,
  syllable, category, and position data.
* `GlyphPosition`: `xAdvance`, `yAdvance`, `xOffset`, `yOffset`, plus
  attachment chain and type packed in `posVar`.
* `Buffer`: input infos, output staging, positions, direction, script,
  language, flags, cluster level, length and capacity, operation budget.

## Content lifecycle

1. Unicode phase: `push`, `pushStr`, `pushCodepoints` append codepoints.
   `contentType` is Unicode.
2. Mapping: `mapGlyphsFast` rewrites ids to glyphs.
3. GSUB phase: substitutions run with output staging (`haveOutput`).
4. GPOS phase: `havePositions`, advances, offsets, attachments.

`setContentType(some(contentGlyphs))` marks the mapped stage.
`allocateUnicodeVars`, `deallocateUnicodeVars`, `allocateGsubGposVars`,
and `deallocateGsubGposVars` manage the packed var words per phase.

## Clusters and direction

* `cluster` tracks the source index (UTF-8 byte clusters in hr-shape).
* `formClusters` (in `shape.nim`) merges grapheme clusters so marks
  share their base cluster.
* `mergeClusters`, `mergeGraphemeClusters`, `unsafeToBreakRange`,
  and `unsafeToConcatRange` record break restrictions.
* `direction` (`src/harfnim/direction.nim`) drives horizontal versus
  vertical advances and final RTL `reverse`.

## Masks and properties

* `setMasks(value, mask, start, stop)` tags feature bits per cluster range.
* `glyphProps`, `generalCategory`, `modifiedCombiningClass`,
  `isMarkGlyph`, `isBaseGlyph`, `ligated`, `multiplied`, syllable,
  Indic category and position accessors live on `GlyphInfo`.
* `synthesizeGlyphClasses` (in `shape.nim`) supplies a fallback GDEF:
  nonspacing marks become marks, everything else becomes a base.
* `recategorizeMarks` adjusts selected combining classes to above or below.

## Growth and limits

* `ensure` and `reserve` check capacity; `enlarge` grows geometrically
  (capped by `maxLen`) to amortize repeated pushes.
* `maxOps` bounds shaping work; exhaustion sets `successful` to false.
* `Flags`: `DoNotInsertDottedCircle`, `PreserveDefaultIgnorables`,
  `RemoveDefaultIgnorables`, plus scratch flags for continuations,
  ignorables, GPOS attachment, and broken syllables.

## Key entry points

* `newBuffer`, `clear`, `reset`, `length`, `isEmpty`.
* `push`, `pushStr`, `pushCodepoints`, `pushGlyphInfos`.
* `ensure`, `enlarge`, `setLength`, `reserve`.
* `nextGlyph`, `nextGlyphs`, `outputGlyph`, `replaceGlyph`,
  `replaceGlyphs`, `deleteGlyphsInplace`.
* `setMasks`, `mergeClusters`, `reverse`, `reverseRange`.
