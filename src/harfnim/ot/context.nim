## Contextual matching core, ported from harfrust
## `ot/lookup/context.rs` + `ot/apply.rs` (SkippingIterator, match walks).
##
## Simplified: no digests, no syllable cache, no default-ignorable
## special-casing (TODO, mirrors harfrust `MaySkip`/`digest` optimization).
## Skips glyphs failing the lookup props; input matching additionally
## requires the feature mask, backtrack/lookahead ignore it.

import std/options

import ../buffer
import ./coverage
import ./gsub

export coverage
export gsub

proc contextCheckProp*(g: GlyphInfo, props: uint32): bool =
  let flags = uint16(props and 0xFFFFu32)
  if (g.glyphProps() and flags and LookupIgnoreFlags) != 0u16:
    return false
  if (g.glyphProps() and GlyphPropMark) == 0u16:
    return true
  # Marks only: GDEF mark-set and attachment-class filtering.
  if (flags and LookupUseMarkFilteringSet) != 0u16:
    # TODO: GDEF mark glyph sets; without GDEF no mark matches the set.
    return false
  if (flags and LookupMarkAttachmentTypeMask) != 0u16:
    # TODO: GDEF attach classes; unclassified marks carry class 0.
    return (flags and LookupMarkAttachmentTypeMask) ==
      (g.glyphProps() and LookupMarkAttachmentTypeMask)
  true

proc isSkippable*(g: GlyphInfo, props: uint32): bool =
  not contextCheckProp(g, props)

proc inputMatchesValue*(gid, expected: uint32): bool =
  gid == expected

proc classMatchesValue*(classDef: ClassDef, gid, expected: uint32): bool =
  classDef.classOf(gid) == expected

proc coverageMatchesValue*(cov: Coverage, gid: uint32): bool =
  cov.covers(gid)

type
  ValueKind* = enum
    vkGlyph
    vkClass
    vkCoverage

proc valueMatches*(kind: ValueKind, classDef: ClassDef, cov: Coverage,
    gid, expected: uint32): bool =
  case kind
  of vkGlyph:
    gid == expected
  of vkClass:
    classDef.classOf(gid) == expected
  of vkCoverage:
    # `expected` is unused; caller checks the per-position coverage.
    cov.covers(gid)

proc nextForwardPos*(buf: Buffer, props: uint32, start: int): int =
  ## First index >= start that is not skippable, or buf.len if none.
  var j = start
  while j < buf.len and j < buf.info.len:
    if not isSkippable(buf.info[j], props):
      break
    inc j
  j

proc prevBackwardOutPos*(buf: var Buffer, props: uint32,
    start: int): int =
  ## Last output index <= start that is not skippable, or -1 if none.
  ## Scans the output buffer (outInfo when separate).
  var k = start
  while k >= 0:
    let slot =
      if buf.haveOutput:
        buf.outAt(k)
      else:
        if k < buf.info.len: addr buf.info[k] else: nil
    if slot == nil:
      return -1
    if not isSkippable(slot[], props):
      return k
    dec k
  -1

proc matchInputSeq*(buf: Buffer, props, lookupMask: uint32,
    seq: openArray[uint32], kind: ValueKind, classDef: ClassDef,
    coverages: openArray[Coverage],
    anchorSyllable: uint8 = 0u8): Option[
    tuple[positions: seq[int], matchEnd: int]] =
  ## Matches `seq` against input glyphs after the current one, skipping
  ## ignorables per `props`. First glyph (buf.idx) is implied by coverage.
  ## Requires the feature mask on every matched input glyph.
  ## `coverages` holds per-position coverages for format-3 input (same
  ## length as `seq`); otherwise empty. When `anchorSyllable` is
  ## nonzero, consumed glyphs must share that syllable (per-syllable
  ## matching for the Indic-family shapers).
  ## `seq`/`coverages` are openArray to avoid copies on format-3 slices.
  let want =
    if kind == vkCoverage: coverages.len
    else: seq.len
  var positions = @[buf.idx]
  var j = buf.idx + 1
  for si in 0 ..< want:
    j = nextForwardPos(buf, props, j)
    if j >= buf.len or j >= buf.info.len:
      return none(tuple[positions: seq[int], matchEnd: int])
    let g = buf.info[j]
    if anchorSyllable != 0u8 and g.syllable() != anchorSyllable:
      return none(tuple[positions: seq[int], matchEnd: int])
    if (g.mask and lookupMask) == 0u32:
      return none(tuple[positions: seq[int], matchEnd: int])
    let ok =
      case kind
      of vkGlyph:
        g.glyphId == seq[si]
      of vkClass:
        classDef.classOf(g.glyphId) == seq[si]
      of vkCoverage:
        if si < coverages.len: coverages[si].covers(g.glyphId)
        else: false
    if not ok:
      return none(tuple[positions: seq[int], matchEnd: int])
    positions.add(j)
    inc j
  some((positions, positions[^1] + 1))

proc matchLookaheadSeq*(buf: Buffer, props: uint32, seq: openArray[uint32],
    kind: ValueKind, classDef: ClassDef, coverages: openArray[Coverage],
    start: int, anchorSyllable: uint8 = 0u8): Option[int] =
  ## Matches lookahead from `start` (input index after the input match).
  ## Returns the end index on success. Ignores the feature mask.
  ## `anchorSyllable` constrains to one syllable when nonzero.
  let want =
    if kind == vkCoverage: coverages.len
    else: seq.len
  var j = start
  for si in 0 ..< want:
    j = nextForwardPos(buf, props, j)
    if j >= buf.len or j >= buf.info.len:
      return none(int)
    let g = buf.info[j]
    if anchorSyllable != 0u8 and g.syllable() != anchorSyllable:
      return none(int)
    let ok =
      case kind
      of vkGlyph:
        g.glyphId == seq[si]
      of vkClass:
        classDef.classOf(g.glyphId) == seq[si]
      of vkCoverage:
        if si < coverages.len: coverages[si].covers(g.glyphId)
        else: false
    if not ok:
      return none(int)
    inc j
  some(j)

proc matchBacktrackSeq*(buf: var Buffer, props: uint32, seq: openArray[uint32],
    kind: ValueKind, classDef: ClassDef,
    coverages: openArray[Coverage], anchorSyllable: uint8 = 0u8): bool =
  ## Matches backtrack against already-emitted output, nearest first.
  ## `seq[0]` is the glyph immediately before the current one.
  ## Ignores the feature mask. `anchorSyllable` constrains to one
  ## syllable when nonzero.
  let want =
    if kind == vkCoverage: coverages.len
    else: seq.len
  if want == 0:
    return true
  var k =
    if buf.haveOutput: buf.outLen - 1
    else: buf.idx - 1
  for si in 0 ..< want:
    k = prevBackwardOutPos(buf, props, k)
    if k < 0:
      return false
    let slot =
      if buf.haveOutput: buf.outAt(k)
      else:
        if k < buf.info.len: addr buf.info[k] else: nil
    if slot == nil:
      return false
    if anchorSyllable != 0u8 and slot[].syllable() != anchorSyllable:
      return false
    let gid = slot[].glyphId
    let ok =
      case kind
      of vkGlyph:
        gid == seq[si]
      of vkClass:
        classDef.classOf(gid) == seq[si]
      of vkCoverage:
        if si < coverages.len: coverages[si].covers(gid)
        else: false
    if not ok:
      return false
    dec k
  true
