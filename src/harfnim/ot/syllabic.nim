## Shared syllabic-shaper helpers: dotted-circle insertion for broken
## syllables and syllable-var cleanup.
##
## Ported from harfrust `ot/shaper/syllabic.rs`. Used by the
## Indic-family shapers after final reordering.

import std/options

import ../buffer
import ../font

proc insertDottedCircles*(buf: var Buffer, sf: ShaperFont,
    brokenType, dottedCategory: uint8, rephaCategory: Option[uint8],
    dottedPosition: Option[uint8]): bool =
  ## Inserts a dotted circle into every broken syllable
  ## (`syllable & 0x0F == brokenType`). The circle takes the current
  ## glyph's mask, cluster, and syllable, plus `dottedCategory` (and
  ## `dottedPosition` when given). When the broken syllable starts
  ## with a repha, the circle goes after it. Returns false when
  ## skipped or when the font lacks U+25CC.
  if buf.flags.contains(DoNotInsertDottedCircle):
    return false
  if (buf.scratchFlags and ScratchFlagHasBrokenSyllable) == 0u32:
    return false
  let dotted = sf.nominalGlyph(0x25CCu32)
  if dotted.isNone:
    return false
  var circle = GlyphInfo(glyphId: 0x25CCu32, cluster: 0u32)
  circle.setOtShaperCategory(dottedCategory)
  if dottedPosition.isSome:
    circle.setOtShaperAuxiliary(dottedPosition.get)
  circle.glyphId = dotted.get.value
  buf.clearOutput()
  buf.idx = 0
  var lastSyllable = 0u8
  while buf.idx < buf.len and buf.successful:
    if buf.idx >= buf.info.len:
      buf.indexFailed()
      return false
    let syllable = buf.info[buf.idx].syllable()
    if lastSyllable == syllable or (syllable and 0x0Fu8) != brokenType:
      buf.nextGlyph()
      continue
    lastSyllable = syllable
    var ginfo = circle
    if buf.idx < buf.info.len:
      ginfo.cluster = buf.info[buf.idx].cluster
      ginfo.mask = buf.info[buf.idx].mask
      ginfo.setSyllable(buf.info[buf.idx].syllable())
    # Insert the circle after a possible repha.
    if rephaCategory.isSome:
      let rc = rephaCategory.get
      while buf.idx < buf.len and buf.idx < buf.info.len and
          lastSyllable == buf.info[buf.idx].syllable() and
          buf.info[buf.idx].otShaperCategory() == rc:
        buf.nextGlyph()
    buf.outputInfo(ginfo)
  discard buf.sync()
  buf.successful

proc clearSyllables*(buf: var Buffer) =
  ## Resets the syllable byte on every glyph. Runs after shaping no
  ## longer needs syllables (harfrust also deallocates the var; the
  ## harfnim var storage is static, so resetting suffices).
  for i in 0 ..< buf.info.len:
    buf.info[i].setSyllable(0u8)
