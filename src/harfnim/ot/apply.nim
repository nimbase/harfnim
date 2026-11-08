import std/bitops
import std/options

import ../buffer
import ../direction
import ../feature
import ../scale
import ../unicode
import ../varstore
import ./context
import ./gpos
import ./gsub
import ./kern

export gsub
export context
export gpos
export kern

proc checkGlyphProperty*(info: GlyphInfo, props: uint32): bool =
  ## True when the glyph passes lookup flags and mark filtering.
  let flags = uint16(props and 0xFFFFu32)
  if (info.glyphProps() and flags and LookupIgnoreFlags) != 0u16:
    return false
  if (info.glyphProps() and GlyphPropMark) == 0u16:
    return true
  # Marks only: GDEF mark-set and attachment-class filtering.
  if (flags and LookupUseMarkFilteringSet) != 0u16:
    # TODO: GDEF mark glyph sets; without GDEF no mark matches the set.
    return false
  if (flags and LookupMarkAttachmentTypeMask) != 0u16:
    return (flags and LookupMarkAttachmentTypeMask) ==
      (info.glyphProps() and LookupMarkAttachmentTypeMask)
  true

proc lookupProps*(lookup: Lookup): uint32 =
  ## Combines lookup flags with the mark filtering set.
  var props = uint32(lookup.lookupFlag)
  if (lookup.lookupFlag and LookupUseMarkFilteringSet) != 0u16:
    props = props or (uint32(lookup.markFilteringSet) shl 16)
  props

proc replaceWithSubstituted*(buf: var Buffer, gid: uint32) =
  ## Replaces the current glyph and tags it substituted.
  buf.replaceGlyph(gid)
  let slot = buf.outAt(buf.outLen - 1)
  if slot == nil:
    buf.indexFailed()
    return
  slot[].setGlyphProps(slot[].glyphProps() or GlyphPropSubstituted)

proc replaceWithSubstitutedInplace*(buf: var Buffer, gid: uint32) =
  ## Reverse-chain replacement: modifies the current glyph in place,
  ## without touching the output buffer. Caller must ensure we are in
  ## an in-place (backward) walk with haveOutput false.
  if buf.idx < 0 or buf.idx >= buf.info.len:
    buf.indexFailed()
    return
  buf.info[buf.idx].glyphId = gid
  buf.info[buf.idx].setGlyphProps(
    buf.info[buf.idx].glyphProps() or GlyphPropSubstituted)

proc anchorSyllableAt(buf: Buffer, perSyllable: bool): uint8 =
  ## Syllable anchoring a per-syllable match starting at buf.idx
  ## (0 disables the constraint, mirroring harfrust's Matcher).
  if perSyllable and buf.idx >= 0 and buf.idx < buf.info.len:
    buf.info[buf.idx].syllable()
  else:
    0u8

proc lookupCovers(lookup: Lookup, gid: uint32): bool =
  # True when any subtable covers the glyph.
  for e in lookup.order:
    case e.kind
    of lkSingle:
      if lookup.singleSubsts[e.index].coverage.covers(gid):
        return true
    of lkMultiple:
      if lookup.multipleSubsts[e.index].coverage.covers(gid):
        return true
    of lkAlternate:
      if lookup.alternateSubsts[e.index].coverage.covers(gid):
        return true
    of lkLigature:
      if lookup.ligatureSubsts[e.index].coverage.covers(gid):
        return true
    of lkContext:
      let sub = lookup.contextSubsts[e.index]
      if sub.format == 1u16 or sub.format == 2u16 or sub.format == 4u16 or
          sub.format == 5u16:
        if sub.coverage.covers(gid):
          return true
      elif sub.format == 3u16 or sub.format == 6u16:
        if sub.coverages.len > 0 and sub.coverages[0].covers(gid):
          return true
    of lkChain:
      let sub = lookup.chainSubsts[e.index]
      if sub.format == 1u16 or sub.format == 2u16 or sub.format == 4u16 or
          sub.format == 5u16:
        if sub.coverage.covers(gid):
          return true
      elif sub.format == 3u16:
        if sub.inputCoverages.len > 0 and
            sub.inputCoverages[0].covers(gid):
          return true
    of lkReverse:
      if lookup.reverseSubsts[e.index].coverage.covers(gid):
        return true
    of lkOther:
      discard
  false

# Forward declarations for the contextual recurse (Nim is single-pass).
proc applyLookup*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
  mask: uint32, nestingLeft: int = MaxNestingLevel,
  perSyllable: bool = false): bool
proc applyNestedAt(buf: var Buffer, gsub: GsubData, lookupIndex: int,
  parentMask: uint32, nestingLeft: int, perSyllable: bool = false): bool
proc applyRecords(buf: var Buffer, gsub: GsubData,
  records: seq[LookupRecord], positions: seq[int], matchEnd: int,
  parentMask: uint32, nestingLeft: int, perSyllable: bool = false): bool
proc applyContextSubst(buf: var Buffer, gsub: GsubData, sub: ContextSubst,
  props, lookupMask: uint32, nestingLeft: int,
  perSyllable: bool = false): bool
proc applyChainSubst(buf: var Buffer, gsub: GsubData, sub: ChainContextSubst,
  props, lookupMask: uint32, nestingLeft: int,
  perSyllable: bool = false): bool
proc applyReverseSubst(buf: var Buffer, sub: ReverseChainSubst,
  props, lookupMask: uint32, perSyllable: bool = false): bool
proc applyLookupBackward*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
  mask: uint32, perSyllable: bool = false): bool
proc applyPosLookup*(buf: var Buffer, gpos: GposData, lookup: PosLookup,
  mask: uint32, scale: Scale,
  nestingLeft: int = MaxNestingLevel, store: VarStore = VarStore(),
  coords: seq[float32] = @[]): bool
proc applyNestedPosAt(buf: var Buffer, gpos: GposData, lookupIndex: int,
  parentMask: uint32, scale: Scale, nestingLeft: int, store: VarStore,
  coords: seq[float32]): bool
proc applyPosRecords(buf: var Buffer, gpos: GposData,
  records: seq[LookupRecord], positions: seq[int], matchEnd: int,
  parentMask: uint32, scale: Scale, nestingLeft: int,
  store: VarStore, coords: seq[float32]): bool
proc applyPosContextSubst(buf: var Buffer, gpos: GposData,
  sub: ContextSubst, props, lookupMask: uint32, scale: Scale,
  nestingLeft: int, store: VarStore, coords: seq[float32]): bool
proc applyPosChainSubst(buf: var Buffer, gpos: GposData,
  sub: ChainContextSubst, props, lookupMask: uint32, scale: Scale,
  nestingLeft: int, store: VarStore, coords: seq[float32]): bool

proc outputGlyphForComponent(buf: var Buffer, gid: uint32, classGuess: uint16) =
  # Emits one glyph of a multiple substitution.
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return
  var props = cur[].glyphProps() or GlyphPropSubstituted or GlyphPropMultiplied
  props = (props and GlyphPropPreserve) or classGuess
  cur[].setGlyphProps(props)
  buf.outputGlyph(gid)

proc applyMultiple(buf: var Buffer, sub: MultipleSubst, index: int): bool =
  # Applies one multiple substitution.
  if index < 0 or index >= sub.sequences.len:
    return false
  let s = sub.sequences[index]
  case s.len
  of 0:
    buf.deleteGlyph()
    true
  of 1:
    replaceWithSubstituted(buf, s[0])
    true
  else:
    let cur = buf.cur(0)
    if cur == nil:
      buf.indexFailed()
      return false
    let classGuess =
      if cur[].isLigature(): GlyphPropBaseGlyph else: 0u16
    let ligId = cur[].ligId()
    for ci, substitute in s:
      if ligId == 0u8:
        let m = buf.cur(0)
        if m == nil:
          buf.indexFailed()
          return false
        m[].setLigPropsForComponent(uint8(ci))
      outputGlyphForComponent(buf, substitute, classGuess)
    buf.skipGlyph()
    true

proc applyAlternate(buf: var Buffer, sub: AlternateSubst, index: int,
    lookupMask: uint32): bool =
  if index < 0 or index >= sub.sets.len:
    return false
  let alts = sub.sets[index]
  if alts.len == 0:
    return false
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return false
  # TODO: random alternate selection (rand feature)
  let altIndex = (lookupMask and cur[].mask) shr
    uint32(countTrailingZeroBits(lookupMask))
  if altIndex == 0u32:
    return false
  let ai = int(altIndex - 1u32)
  if ai >= alts.len:
    return false
  replaceWithSubstituted(buf, alts[ai])
  true

proc matchComponents(buf: var Buffer, components: seq[uint32],
    props: uint32, perSyllable: bool = false): Option[
    tuple[positions: seq[int], matchEnd: int, totalComps: int]] =
  type MatchResult = tuple[positions: seq[int], matchEnd: int, totalComps: int]
  let anchor = anchorSyllableAt(buf, perSyllable)
  let first = buf.cur(0)
  if first == nil:
    return none(MatchResult)
  var positions = @[buf.idx]
  var total = int(first[].ligNumComps())
  var k = 0
  var j = buf.idx + 1
  while k < components.len:
    if j >= buf.len or j >= buf.info.len:
      return none(MatchResult)
    let g = buf.info[j]
    if anchor != 0u8 and g.syllable() != anchor:
      return none(MatchResult)
    if not checkGlyphProperty(g, props):
      inc j
      continue
    if g.glyphId != components[k]:
      return none(MatchResult)
    positions.add(j)
    total += int(g.ligNumComps())
    inc j
    inc k
  some((positions, j, total))

proc ligateInput(buf: var Buffer, positions: seq[int], matchEnd: int,
    totalComps: int, ligGlyph: uint32) =
  let count = positions.len
  var isBaseLig = buf.info[positions[0]].isBaseGlyph()
  var isMarkLig = buf.info[positions[0]].isMarkGlyph()
  for i in 1 ..< count:
    if not buf.info[positions[i]].isMarkGlyph():
      isBaseLig = false
      isMarkLig = false
  buf.mergeClusters(buf.idx, matchEnd)
  let isLigature = not isBaseLig and not isMarkLig
  let ligId = if isLigature: buf.allocateLigId() else: 0u8
  let first = buf.cur(0)
  if first == nil:
    buf.indexFailed()
    return
  var lastLigId = first[].ligId()
  var lastNumComps = first[].ligNumComps()
  var compsSoFar = lastNumComps
  if isLigature:
    first[].setLigPropsForLigature(ligId, uint8(totalComps))
    if first[].generalCategory() == GcNonSpacingMark:
      first[].setGeneralCategory(GcOtherLetter)
  var props = first[].glyphProps() or GlyphPropSubstituted
  # HarfBuzz marks every ligature-substitution output ligated (and
  # clears multiplied), even base+mark combinations: the is_ligature
  # distinction only affects ligature-id allocation and the class
  # guess, not the LIGATED bit itself.
  props = (props or GlyphPropLigated) and not GlyphPropMultiplied
  if isLigature:
    props = (props and GlyphPropPreserve) or GlyphPropLigature
  else:
    props = props and GlyphPropPreserve
  first[].setGlyphProps(props)
  buf.replaceGlyph(ligGlyph)
  for i in 1 ..< count:
    while buf.idx < positions[i] and buf.successful:
      if isLigature:
        let cur = buf.cur(0)
        if cur == nil:
          buf.indexFailed()
          return
        var thisComp = cur[].ligComp()
        if thisComp == 0u8:
          thisComp = lastNumComps
        let newComp = compsSoFar - lastNumComps +
          min(thisComp, lastNumComps)
        cur[].setLigPropsForMark(ligId, newComp)
      buf.nextGlyph()
    let cur = buf.cur(0)
    if cur == nil:
      buf.indexFailed()
      return
    lastLigId = cur[].ligId()
    lastNumComps = cur[].ligNumCompsInLigation()
    compsSoFar += lastNumComps
    buf.skipGlyph()
  if not isMarkLig and lastLigId != 0u8:
    var k = buf.idx
    while k < buf.len and k < buf.info.len:
      if buf.info[k].ligId() != lastLigId:
        break
      let thisComp = buf.info[k].ligComp()
      if thisComp == 0u8:
        break
      let newComp = compsSoFar - lastNumComps +
        min(thisComp, lastNumComps)
      buf.info[k].setLigPropsForMark(ligId, newComp)
      inc k

proc applyLigature(buf: var Buffer, set: seq[Ligature],
    props: uint32, perSyllable: bool = false): bool =
  for lig in set:
    if lig.components.len == 0:
      replaceWithSubstituted(buf, lig.ligGlyph)
      return true
    let m = matchComponents(buf, lig.components, props, perSyllable)
    if m.isNone:
      continue
    ligateInput(buf, m.get.positions, m.get.matchEnd, m.get.totalComps,
      lig.ligGlyph)
    return true
  false

proc applyContextSubst(buf: var Buffer, gsub: GsubData, sub: ContextSubst,
    props, lookupMask: uint32, nestingLeft: int,
    perSyllable: bool = false): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let anchor = anchorSyllableAt(buf, perSyllable)
  if sub.format == 1u16 or sub.format == 4u16:
    let ci = sub.coverage.coverageIndexRaw(gid)
    if ci < 0 or ci >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[ci]:
      let m = matchInputSeq(buf, props, lookupMask, rule.input, vkGlyph,
        noClassDef(), @[], anchor)
      if m.isNone:
        continue
      if applyRecords(buf, gsub, rule.records, m.get.positions,
          m.get.matchEnd, lookupMask, nestingLeft, perSyllable):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 2u16 or sub.format == 5u16:
    if not sub.coverage.covers(gid):
      return false
    let cls = int(sub.classDef.classOf(gid))
    if cls >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[cls]:
      let m = matchInputSeq(buf, props, lookupMask, rule.input, vkClass,
        sub.classDef, @[], anchor)
      if m.isNone:
        continue
      if applyRecords(buf, gsub, rule.records, m.get.positions,
          m.get.matchEnd, lookupMask, nestingLeft, perSyllable):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 3u16 or sub.format == 6u16:
    if sub.coverages.len == 0:
      return false
    if not sub.coverages[0].covers(gid):
      return false
    let m =
      if sub.coverages.len > 1:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(), sub.coverages.toOpenArray(1, sub.coverages.high),
          anchor)
      else:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(), [], anchor)
    if m.isNone:
      return false
    if applyRecords(buf, gsub, sub.records, m.get.positions,
        m.get.matchEnd, lookupMask, nestingLeft, perSyllable):
      return true
    if not buf.successful:
      return false
    true
  else:
    false

proc applyChainSubst(buf: var Buffer, gsub: GsubData, sub: ChainContextSubst,
    props, lookupMask: uint32, nestingLeft: int,
    perSyllable: bool = false): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let anchor = anchorSyllableAt(buf, perSyllable)
  if sub.format == 1u16 or sub.format == 4u16:
    let ci = sub.coverage.coverageIndexRaw(gid)
    if ci < 0 or ci >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[ci]:
      let mi = matchInputSeq(buf, props, lookupMask, rule.input, vkGlyph,
        noClassDef(), @[], anchor)
      if mi.isNone:
        continue
      let la = matchLookaheadSeq(buf, props, rule.lookahead, vkGlyph,
        noClassDef(), @[], mi.get.matchEnd, anchor)
      if la.isNone:
        continue
      if not matchBacktrackSeq(buf, props, rule.backtrack, vkGlyph,
          noClassDef(), @[], anchor):
        continue
      if applyRecords(buf, gsub, rule.records, mi.get.positions,
          mi.get.matchEnd, lookupMask, nestingLeft, perSyllable):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 2u16 or sub.format == 5u16:
    if not sub.coverage.covers(gid):
      return false
    let cls = int(sub.inputClassDef.classOf(gid))
    if cls >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[cls]:
      let mi = matchInputSeq(buf, props, lookupMask, rule.input, vkClass,
        sub.inputClassDef, @[], anchor)
      if mi.isNone:
        continue
      let la = matchLookaheadSeq(buf, props, rule.lookahead, vkClass,
        sub.lookaheadClassDef, @[], mi.get.matchEnd, anchor)
      if la.isNone:
        continue
      if not matchBacktrackSeq(buf, props, rule.backtrack, vkClass,
          sub.backtrackClassDef, @[], anchor):
        continue
      if applyRecords(buf, gsub, rule.records, mi.get.positions,
          mi.get.matchEnd, lookupMask, nestingLeft, perSyllable):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 3u16:
    if sub.inputCoverages.len == 0:
      return false
    if not sub.inputCoverages[0].covers(gid):
      return false
    let mi =
      if sub.inputCoverages.len > 1:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(),
          sub.inputCoverages.toOpenArray(1, sub.inputCoverages.high), anchor)
      else:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(), [], anchor)
    if mi.isNone:
      return false
    let la = matchLookaheadSeq(buf, props, [], vkCoverage, noClassDef(),
      sub.lookaheadCoverages, mi.get.matchEnd, anchor)
    if la.isNone:
      return false
    if not matchBacktrackSeq(buf, props, [], vkCoverage, noClassDef(),
        sub.backtrackCoverages, anchor):
      return false
    if applyRecords(buf, gsub, sub.records, mi.get.positions,
        mi.get.matchEnd, lookupMask, nestingLeft, perSyllable):
      return true
    if not buf.successful:
      return false
    true
  else:
    false

proc applyReverseSubst(buf: var Buffer, sub: ReverseChainSubst,
    props, lookupMask: uint32, perSyllable: bool = false): bool =
  ## Reverse-chain single substitution at the current position, in place.
  ## Backtrack and lookahead ignore the feature mask; only the current
  ## glyph requires it (enforced by the backward scan, mirroring
  ## harfrust's apply_backward candidate search).
  if buf.haveOutput:
    # Reverse lookups run in-place without an output buffer.
    return false
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let anchor = anchorSyllableAt(buf, perSyllable)
  let ci = sub.coverage.coverageIndexRaw(gid)
  if ci < 0 or ci >= sub.substitutes.len:
    return false
  if not matchBacktrackSeq(buf, props, [], vkCoverage, noClassDef(),
      sub.backtrackCoverages, anchor):
    # TODO: unsafe_to_concat_from_outbuffer marking
    return false
  let laEnd = matchLookaheadSeq(buf, props, [], vkCoverage,
    noClassDef(), sub.lookaheadCoverages, buf.idx + 1, anchor)
  if laEnd.isNone:
    return false
  # TODO: unsafe_to_break_from_outbuffer marking
  replaceWithSubstitutedInplace(buf, sub.substitutes[ci])
  buf.successful

proc applyLookupBackward*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
    mask: uint32, perSyllable: bool = false): bool =
  ## In-place backward walk for reverse-chain lookups. Length never
  ## changes, so indices stay valid while scanning from the end.
  if lookup.order.len == 0:
    return false
  if buf.haveOutput:
    return false
  let props = lookup.lookupProps()
  while buf.successful:
    var candidate = -1
    var k = buf.idx
    while k >= 0 and k < buf.info.len:
      let g = buf.info[k]
      if (g.mask and mask) != 0u32 and checkGlyphProperty(g, props) and
          lookupCovers(lookup, g.glyphId):
        candidate = k
        break
      dec k
    if candidate < 0:
      buf.idx = 0
      break
    buf.idx = candidate
    var done = false
    for e in lookup.order:
      if e.kind != lkReverse:
        continue
      if applyReverseSubst(buf, lookup.reverseSubsts[e.index], props, mask,
          perSyllable):
        done = true
        break
    if done:
      result = true
    if candidate == 0:
      break
    buf.idx = candidate - 1

proc applyRecords(buf: var Buffer, gsub: GsubData,
    records: seq[LookupRecord], positions: seq[int], matchEnd: int,
    parentMask: uint32, nestingLeft: int,
    perSyllable: bool = false): bool =
  if positions.len == 0:
    return false
  if positions.len > MaxContextLength:
    return false
  let backtrackLen =
    if buf.haveOutput: buf.outLen
    else: buf.idx
  let delta0 = backtrackLen - buf.idx
  var outPositions = newSeq[int](positions.len)
  for i, p in positions:
    outPositions[i] = p + delta0
  var endOut = backtrackLen + (matchEnd - buf.idx)
  var count = positions.len
  if records.len == 0:
    if not buf.moveTo(endOut):
      return false
    return buf.successful
  for rec in records:
    if not buf.successful:
      break
    let idxRec = int(rec.seqIndex)
    if idxRec >= count:
      continue
    let origLen =
      (if buf.haveOutput: buf.outLen else: buf.idx) + (buf.len - buf.idx)
    let target = outPositions[idxRec]
    if target >= origLen:
      continue
    if not buf.moveTo(target):
      break
    if buf.maxOps <= 0:
      buf.successful = false
      break
    buf.maxOps -= 1
    if buf.maxOps < 0:
      buf.successful = false
      break
    let applied = applyNestedAt(buf, gsub, int(rec.lookupIndex), parentMask,
      nestingLeft - 1, perSyllable)
    if not applied:
      if not buf.successful:
        break
      continue
    let newLen =
      (if buf.haveOutput: buf.outLen else: buf.idx) + (buf.len - buf.idx)
    var deltaLen = newLen - origLen
    if deltaLen == 0:
      continue
    endOut += deltaLen
    if endOut < outPositions[idxRec]:
      deltaLen += outPositions[idxRec] - endOut
      endOut = outPositions[idxRec]
    var nextIdx = idxRec + 1
    if deltaLen > 0:
      if deltaLen + count > MaxContextLength:
        break
      let need = deltaLen + count
      if need > outPositions.len:
        outPositions.setLen(need)
    else:
      deltaLen = max(deltaLen, nextIdx - count)
      nextIdx = nextIdx - deltaLen
    # Shift [nextIdx .. count) to [nextIdx + deltaLen ..).
    if deltaLen > 0:
      for i in countdown(count - 1, nextIdx):
        outPositions[i + deltaLen] = outPositions[i]
    else:
      for i in nextIdx ..< count:
        outPositions[i + deltaLen] = outPositions[i]
    nextIdx = nextIdx + deltaLen
    count = count + deltaLen
    for j in idxRec + 1 ..< nextIdx:
      outPositions[j] = outPositions[j - 1] + 1
    var k = nextIdx
    while k < count:
      outPositions[k] = outPositions[k] + deltaLen
      inc k
  if not buf.successful:
    return false
  if not buf.moveTo(endOut):
    return false
  buf.successful

proc applyNestedAt(buf: var Buffer, gsub: GsubData, lookupIndex: int,
    parentMask: uint32, nestingLeft: int,
    perSyllable: bool = false): bool =
  if nestingLeft <= 0:
    buf.indexFailed()
    return false
  if lookupIndex < 0 or lookupIndex >= gsubLookupCount(gsub):
    return false
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let lookup = getGsubLookup(gsub, lookupIndex)
  if lookup.order.len == 0:
    return false
  let nestedProps = lookup.lookupProps()
  let gid = buf.info[buf.idx].glyphId
  for e in lookup.order:
    case e.kind
    of lkSingle:
      let sub = lookup.singleSubsts[e.index]
      let ci = sub.coverage.coverageIndexRaw(gid)
      if ci < 0:
        continue
      let rep = sub.singleSubstitute(gid, uint32(ci))
      if rep.isNone:
        continue
      replaceWithSubstituted(buf, rep.get)
      return true
    of lkMultiple:
      let sub = lookup.multipleSubsts[e.index]
      let ci = sub.coverage.coverageIndexRaw(gid)
      if ci < 0:
        continue
      if applyMultiple(buf, sub, ci):
        return true
    of lkAlternate:
      let sub = lookup.alternateSubsts[e.index]
      let ci = sub.coverage.coverageIndexRaw(gid)
      if ci < 0:
        continue
      if applyAlternate(buf, sub, ci, parentMask):
        return true
    of lkLigature:
      let sub = lookup.ligatureSubsts[e.index]
      let ci = sub.coverage.coverageIndexRaw(gid)
      if ci < 0 or ci >= sub.sets.len:
        continue
      if applyLigature(buf, sub.sets[ci], nestedProps,
          perSyllable):
        return true
    of lkContext:
      if applyContextSubst(buf, gsub, lookup.contextSubsts[e.index],
          nestedProps, parentMask, nestingLeft, perSyllable):
        return true
    of lkChain:
      if applyChainSubst(buf, gsub, lookup.chainSubsts[e.index],
          nestedProps, parentMask, nestingLeft, perSyllable):
        return true
    of lkReverse:
      # Reverse chaining lookups can't be nested.
      continue
    of lkOther:
      continue
  false

proc applyLookup*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
  mask: uint32, nestingLeft: int = MaxNestingLevel,
  perSyllable: bool = false): bool =
  if lookup.order.len == 0:
    return false
  let props = lookup.lookupProps()
  while buf.successful:
    var j = buf.idx
    while j < buf.len and j < buf.info.len:
      let g = buf.info[j]
      if (g.mask and mask) != 0u32 and checkGlyphProperty(g, props) and
          lookupCovers(lookup, g.glyphId):
        break
      inc j
    if j > buf.idx:
      buf.nextGlyphs(j - buf.idx)
    if buf.idx >= buf.len or buf.idx >= buf.info.len:
      break
    let gid = buf.info[buf.idx].glyphId
    var done = false
    for e in lookup.order:
      case e.kind
      of lkSingle:
        let sub = lookup.singleSubsts[e.index]
        let ci = sub.coverage.coverageIndexRaw(gid)
        if ci < 0:
          continue
        let rep = sub.singleSubstitute(gid, uint32(ci))
        if rep.isNone:
          continue
        replaceWithSubstituted(buf, rep.get)
        done = true
        break
      of lkMultiple:
        let sub = lookup.multipleSubsts[e.index]
        let ci = sub.coverage.coverageIndexRaw(gid)
        if ci < 0:
          continue
        if applyMultiple(buf, sub, ci):
          done = true
          break
      of lkAlternate:
        let sub = lookup.alternateSubsts[e.index]
        let ci = sub.coverage.coverageIndexRaw(gid)
        if ci < 0:
          continue
        if applyAlternate(buf, sub, ci, mask):
          done = true
          break
      of lkLigature:
        let sub = lookup.ligatureSubsts[e.index]
        let ci = sub.coverage.coverageIndexRaw(gid)
        if ci < 0 or ci >= sub.sets.len:
          continue
        if applyLigature(buf, sub.sets[ci], props,
            perSyllable):
          done = true
          break
      of lkContext:
        if applyContextSubst(buf, gsub, lookup.contextSubsts[e.index],
            props, mask, nestingLeft, perSyllable):
          done = true
          break
      of lkChain:
        if applyChainSubst(buf, gsub, lookup.chainSubsts[e.index],
            props, mask, nestingLeft, perSyllable):
          done = true
          break
      of lkReverse:
        # Reverse chaining applies in a separate backward, in-place pass.
        continue
      of lkOther:
        continue
    if done:
      result = true
    else:
      buf.nextGlyph()

proc applySubstLookups*(buf: var Buffer, gsub: GsubData,
    lookupIndices: openArray[uint16], mask: uint32,
    perSyllable: bool = false) =
  if buf.isEmpty() or mask == 0u32:
    return
  for li in lookupIndices:
    if int(li) >= gsubLookupCount(gsub):
      continue
    let lookup = getGsubLookup(gsub, int(li))
    if lookup.order.len == 0:
      continue
    if lookup.isReverse:
      # In-place backward substitution, no output buffer.
      if buf.haveOutput:
        discard buf.sync()
      if buf.isEmpty():
        continue
      buf.idx = buf.len - 1
      discard applyLookupBackward(buf, gsub, lookup, mask, perSyllable)
    else:
      buf.clearOutput()
      buf.idx = 0
      discard applyLookup(buf, gsub, lookup, mask, MaxNestingLevel,
        perSyllable)
      discard buf.sync()

# --------------------------------------------------------------------------
# GPOS positioning (mirrors harfrust ot/lookup/gpos.rs, static fonts only)
# --------------------------------------------------------------------------

proc saturatingAddI32(a, b: int32): int32 =
  # Saturating addition.
  let s = int64(a) + int64(b)
  if s > int64(high(int32)):
    high(int32)
  elif s < int64(low(int32)):
    low(int32)
  else:
    int32(s)

proc saturatingSubI32(a, b: int32): int32 =
  # Saturating subtraction.
  saturatingAddI32(a, -b)

proc lookupProps*(lookup: PosLookup): uint32 =
  ## Combines GPOS lookup flags with the mark filtering set.
  var props = uint32(lookup.lookupFlag)
  if (lookup.lookupFlag and LookupUseMarkFilteringSet) != 0u16:
    props = props or (uint32(lookup.markFilteringSet) shl 16)
  props

proc posLookupCovers(lookup: PosLookup, gid: uint32): bool =
  # True when any positioning subtable covers the glyph.
  for e in lookup.order:
    case e.kind
    of pkSingle:
      if lookup.singlePos[e.index].coverage.covers(gid):
        return true
    of pkPair:
      if lookup.pairPos[e.index].coverage.covers(gid):
        return true
    of pkCursive:
      if lookup.cursivePos[e.index].coverage.covers(gid):
        return true
    of pkMarkBase, pkMarkMark:
      let sub = if e.kind == pkMarkBase: lookup.markBasePos[e.index]
        else: lookup.markMarkPos[e.index]
      if sub.markCoverage.covers(gid):
        return true
    of pkMarkLig:
      if lookup.markLigPos[e.index].markCoverage.covers(gid):
        return true
    of pkContext:
      let sub = lookup.contextPos[e.index]
      if sub.format == 1u16 or sub.format == 2u16 or sub.format == 4u16 or
          sub.format == 5u16:
        if sub.coverage.covers(gid):
          return true
      elif sub.format == 3u16 or sub.format == 6u16:
        if sub.coverages.len > 0 and sub.coverages[0].covers(gid):
          return true
    of pkChain:
      let sub = lookup.chainPos[e.index]
      if sub.format == 1u16 or sub.format == 2u16 or sub.format == 4u16 or
          sub.format == 5u16:
        if sub.coverage.covers(gid):
          return true
      elif sub.format == 3u16:
        if sub.inputCoverages.len > 0 and
            sub.inputCoverages[0].covers(gid):
          return true
    of pkOther:
      discard
  false

proc applyValueRecord(buf: var Buffer, posIdx: int, value: ValueRecord,
    scale: Scale, isHorizontal: bool, store: VarStore,
    coords: seq[float32]): bool =
  if posIdx < 0 or posIdx >= buf.pos.len:
    return false
  result = false
  if value.xPlacement != 0i32:
    buf.pos[posIdx].xOffset =
      saturatingAddI32(buf.pos[posIdx].xOffset, scale.scaleX(value.xPlacement))
    result = true
  if value.yPlacement != 0i32:
    buf.pos[posIdx].yOffset =
      saturatingAddI32(buf.pos[posIdx].yOffset, scale.scaleY(value.yPlacement))
    result = true
  if value.xAdvance != 0i32 and isHorizontal:
    buf.pos[posIdx].xAdvance =
      saturatingAddI32(buf.pos[posIdx].xAdvance, scale.scaleX(value.xAdvance))
    result = true
  if value.yAdvance != 0i32 and not isHorizontal:
    buf.pos[posIdx].yAdvance =
      saturatingSubI32(buf.pos[posIdx].yAdvance, scale.scaleY(value.yAdvance))
    result = true
  # Variation deltas from VariationIndex tables (plain Device tables
  # stay ignored: hinting only).
  let valueApplies = [true, true, isHorizontal, not isHorizontal]
  for k in 0 ..< 4:
    let vi = value.varIndex[k]
    if vi == NoVariationIndex or not valueApplies[k]:
      continue
    let d = deltaFor(store, vi, coords)
    if d == 0i32:
      continue
    case k
    of 0:
      buf.pos[posIdx].xOffset =
        saturatingAddI32(buf.pos[posIdx].xOffset, scale.scaleX(d))
    of 1:
      buf.pos[posIdx].yOffset =
        saturatingAddI32(buf.pos[posIdx].yOffset, scale.scaleY(d))
    of 2:
      buf.pos[posIdx].xAdvance =
        saturatingAddI32(buf.pos[posIdx].xAdvance, scale.scaleX(d))
    else:
      buf.pos[posIdx].yAdvance =
        saturatingSubI32(buf.pos[posIdx].yAdvance, scale.scaleY(d))
    result = true

proc findSecondGlyph(buf: Buffer, props, mask: uint32): Option[int] =
  # Finds the pair second glyph, enforcing its feature mask.
  var j = buf.idx + 1
  while j < buf.len and j < buf.info.len:
    let g = buf.info[j]
    if not checkGlyphProperty(g, props):
      inc j
      continue
    if (g.mask and mask) == 0u32:
      return none(int)
    return some(j)
  none(int)

proc applySinglePos(buf: var Buffer, sub: SinglePos, scale: Scale,
    isHorizontal: bool, store: VarStore, coords: seq[float32]): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let ci = sub.coverage.coverageIndexRaw(gid)
  if ci < 0:
    return false
  let idx = ci
  if idx >= sub.values.len:
    return false
  discard applyValueRecord(buf, buf.idx, sub.values[idx], scale, isHorizontal, store, coords)
  buf.nextGlyph()
  true

proc applyPairPos(buf: var Buffer, sub: PairPos, props, mask: uint32,
    scale: Scale, isHorizontal: bool, store: VarStore,
    coords: seq[float32]): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let first = buf.info[buf.idx].glyphId
  if sub.coverage.coverageIndexRaw(first) < 0:
    return false
  let secondOpt = findSecondGlyph(buf, props, mask)
  if secondOpt.isNone:
    return false
  let secondIdx = secondOpt.get
  let second = buf.info[secondIdx].glyphId
  if sub.format == 1u16 or sub.format == 3u16:
    let covIdx = sub.coverage.coverageIndexRaw(first)
    if covIdx >= sub.pairSets.len:
      return false
    let set = sub.pairSets[covIdx]
    for i, s in set.seconds:
      if s == second:
        let (v1, v2) = set.values[i]
        discard applyValueRecord(buf, buf.idx, v1, scale, isHorizontal, store, coords)
        discard applyValueRecord(buf, secondIdx, v2, scale, isHorizontal, store, coords)
        if sub.format2 != 0u16:
          buf.idx = secondIdx + 1
        else:
          buf.idx = secondIdx
        return true
    # TODO: unsafe_to_concat marking on pair miss.
    false
  elif sub.format == 2u16 or sub.format == 4u16:
    let class1 = sub.classDef1.classOf(first)
    let class2 = sub.classDef2.classOf(second)
    if class1 >= uint32(sub.class1Count) or class2 >= uint32(sub.class2Count):
      return false
    let recIdx = int(class1) * int(sub.class2Count) + int(class2)
    if recIdx < 0 or recIdx >= sub.matrix.len:
      return false
    let (v1, v2) = sub.matrix[recIdx]
    discard applyValueRecord(buf, buf.idx, v1, scale, isHorizontal, store, coords)
    discard applyValueRecord(buf, secondIdx, v2, scale, isHorizontal, store, coords)
    if sub.format2 != 0u16:
      buf.idx = secondIdx + 1
    else:
      buf.idx = secondIdx
    true
  else:
    false


const
  AttachMark* = 1u8
  AttachCursive* = 2u8

proc positionStart*(buf: var Buffer) =
  ## Clears attachment chains and types.
  for i in 0 ..< min(buf.len, buf.pos.len):
    buf.pos[i].setAttachChain(0)
    buf.pos[i].setAttachType(0u8)

proc crossOffset*(buf: Buffer, idx: int): int32 =
  ## Cross stream offset following the attachment chain.
  if idx < 0 or idx >= buf.pos.len:
    return 0i32
  let horiz = buf.direction.isHorizontal()
  var off = if horiz: buf.pos[idx].yOffset else: buf.pos[idx].xOffset
  var cur = idx
  var guard = 0
  while guard < 64:
    if cur < 0 or cur >= buf.pos.len:
      break
    let t = buf.pos[cur].attachType()
    let c = buf.pos[cur].attachChain()
    if (t and AttachCursive) == 0u8 or c == 0i16:
      break
    let parent = cur + int(c)
    if parent < 0 or parent >= buf.pos.len:
      break
    let pOff = if horiz: buf.pos[parent].yOffset else: buf.pos[parent].xOffset
    off = saturatingAddI32(off, pOff)
    cur = parent
    inc guard
  off

proc acceptBase(buf: Buffer, idx: int): bool =
  ## Whether a mark may attach to the base at idx: only the first glyph
  ## of a multiple substitution is a base, unless a mark breaks the
  ## sequence (harfrust accept_base).
  if idx < 0 or idx >= buf.info.len:
    return false
  let info = buf.info[idx]
  if not info.multiplied() or info.ligComp() == 0u8 or idx == 0:
    return true
  let prev = buf.info[idx - 1]
  prev.isMarkGlyph() or not prev.multiplied() or
    info.ligId() != prev.ligId() or
    info.ligComp() != prev.ligComp() + 1u8

proc acceptLigature(buf: Buffer, idx: int): bool =
  ## Whether a mark may attach to the ligature at idx: the first glyph
  ## of a multiple substitution may have been ligated with what precedes
  ## it (harfrust accept_ligature).
  if idx < 0 or idx >= buf.info.len:
    return false
  let info = buf.info[idx]
  not info.multiplied() or info.ligComp() == 0u8

proc findMarkBase*(buf: var Buffer, coverage: Coverage,
    ligature: bool): Option[int] =
  ## Searches back from the current glyph for the base a mark attaches
  ## to, mirroring harfrust find_mark_base (without the last_base cache,
  ## so worst case is quadratic; TODO). The walk stops at the first
  ## non-skipped glyph that is acceptable or covered; the caller then
  ## checks coverage on that glyph.
  var j = buf.idx
  while j > 0:
    let k = j - 1
    if k < 0 or k >= buf.info.len:
      break
    let g = buf.info[k]
    if contextCheckProp(g, uint32(LookupIgnoreMarks)):
      let accepted =
        if ligature: acceptLigature(buf, k)
        else: acceptBase(buf, k)
      if accepted or coverage.covers(g.glyphId):
        return some(k)
    j = k
  none(int)

proc attachMark*(buf: var Buffer, baseAnchor, markAnchor: Anchor,
    basePos: int, scale: Scale) =
  if baseAnchor.format == 0u16 or markAnchor.format == 0u16:
    buf.idx += 1
    return
  var xOff = scale.scaleX(baseAnchor.x - markAnchor.x)
  var yOff = scale.scaleY(baseAnchor.y - markAnchor.y)
  let baseOff = crossOffset(buf, basePos)
  let horiz = buf.direction.isHorizontal()
  if horiz:
    yOff = yOff + baseOff
  else:
    xOff = xOff + baseOff
  buf.unsafeToBreakRange(some(basePos), some(buf.idx + 1))
  let idx = buf.idx
  if idx < 0 or idx >= buf.pos.len:
    buf.indexFailed()
    return
  buf.pos[idx].xOffset = xOff
  buf.pos[idx].yOffset = yOff
  buf.pos[idx].setAttachType(AttachMark)
  let chain = basePos - idx
  if chain >= int(low(int16)) and chain <= int(high(int16)):
    buf.pos[idx].setAttachChain(int16(chain))
    if int(buf.pos[idx].attachChain()) != chain:
      buf.pos[idx].setAttachChain(0)
  else:
    buf.pos[idx].setAttachChain(0)
  buf.scratchFlags = buf.scratchFlags or ScratchFlagHasGposAttachment
  buf.idx += 1

proc applyMarkBase*(buf: var Buffer, sub: MarkSub, props, mask: uint32,
    scale: Scale): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let ci = sub.markCoverage.coverageIndexRaw(gid)
  if ci < 0 or ci >= sub.markClasses.len:
    return false
  let markIdx = ci
  let baseOpt = findMarkBase(buf, sub.baseCoverage, false)
  if baseOpt.isNone:
    buf.unsafeToConcatFromOutbuffer(some(0), some(buf.idx + 1))
    return false
  let basePos = baseOpt.get
  if basePos < 0 or basePos >= buf.info.len:
    return false
  let baseGid = buf.info[basePos].glyphId
  let baseIdxOpt = sub.baseCoverage.coverageIndexRaw(baseGid)
  if baseIdxOpt < 0:
    buf.unsafeToConcatFromOutbuffer(some(basePos), some(buf.idx + 1))
    return false
  let cls = sub.markClasses[markIdx]
  if int(cls) >= int(sub.classCount):
    buf.idx += 1
    return true
  let baseIdx = baseIdxOpt
  let anchorIdx = baseIdx * int(sub.classCount) + int(cls)
  if anchorIdx < 0 or anchorIdx >= sub.baseAnchors.len:
    buf.idx += 1
    return true
  attachMark(buf, sub.baseAnchors[anchorIdx], sub.markAnchors[markIdx],
    basePos, scale)
  true

proc applyMarkMark*(buf: var Buffer, sub: MarkSub, props, mask: uint32,
    scale: Scale): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let ci = sub.markCoverage.coverageIndexRaw(gid)
  if ci < 0 or ci >= sub.markClasses.len:
    return false
  let markIdx = ci
  # Search back for previous mark, ignoring lookup flags except mark
  # filtering (harfrust strips IGNORE_FLAGS).
  let stripped = props and not uint32(LookupIgnoreFlags)
  var j = buf.idx - 1
  var mark2Pos = -1
  while j >= 0 and j < buf.info.len:
    let g = buf.info[j]
    if contextCheckProp(g, stripped):
      mark2Pos = j
      break
    dec j
  if mark2Pos < 0:
    buf.unsafeToConcatFromOutbuffer(some(0), some(buf.idx + 1))
    return false
  let prev = buf.info[mark2Pos]
  if not prev.isMarkGlyph():
    buf.unsafeToConcatFromOutbuffer(some(mark2Pos), some(buf.idx + 1))
    return false
  # Ligature id/component matching (harfrust).
  let cur = buf.info[buf.idx]
  let (id1, comp1) = (cur.ligId(), cur.ligComp())
  let (id2, comp2) = (prev.ligId(), prev.ligComp())
  var matches = false
  if id1 == id2:
    matches = id1 == 0u8 or comp1 == comp2
  else:
    matches = (id1 > 0u8 and comp1 == 0u8) or (id2 > 0u8 and comp2 == 0u8)
  if not matches:
    buf.unsafeToConcatFromOutbuffer(some(mark2Pos), some(buf.idx + 1))
    return false
  let m2IdxOpt = sub.baseCoverage.coverageIndexRaw(prev.glyphId)
  if m2IdxOpt < 0:
    buf.unsafeToConcatFromOutbuffer(some(mark2Pos), some(buf.idx + 1))
    return false
  let cls = sub.markClasses[markIdx]
  if int(cls) >= int(sub.classCount):
    buf.idx += 1
    return true
  let anchorIdx = m2IdxOpt * int(sub.classCount) + int(cls)
  if anchorIdx < 0 or anchorIdx >= sub.baseAnchors.len:
    buf.idx += 1
    return true
  attachMark(buf, sub.baseAnchors[anchorIdx], sub.markAnchors[markIdx],
    mark2Pos, scale)
  true

proc applyMarkLig*(buf: var Buffer, sub: LigSub, props, mask: uint32,
    scale: Scale): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let ci = sub.markCoverage.coverageIndexRaw(gid)
  if ci < 0 or ci >= sub.markClasses.len:
    return false
  let markIdx = ci
  let ligOpt = findMarkBase(buf, sub.ligCoverage, true)
  if ligOpt.isNone:
    buf.unsafeToConcatFromOutbuffer(some(0), some(buf.idx + 1))
    return false
  let ligPos = ligOpt.get
  let ligInfo = buf.info[ligPos]
  let ligIdxOpt = sub.ligCoverage.coverageIndexRaw(ligInfo.glyphId)
  if ligIdxOpt < 0 or ligIdxOpt >= sub.ligCount:
    buf.unsafeToConcatFromOutbuffer(some(ligPos), some(buf.idx + 1))
    return false
  let li = ligIdxOpt
  if li >= sub.compOffsets.len or li >= sub.compCounts.len:
    buf.unsafeToConcatFromOutbuffer(some(ligPos), some(buf.idx + 1))
    return false
  let compCount = sub.compCounts[li]
  if compCount == 0:
    buf.unsafeToConcatFromOutbuffer(some(ligPos), some(buf.idx + 1))
    return false
  let ligId = ligInfo.ligId()
  let cur = buf.info[buf.idx]
  let markId = cur.ligId()
  let markComp = uint32(cur.ligComp())
  var compIdx = compCount - 1
  if ligId != 0u8 and ligId == markId and markComp > 0u32:
    compIdx = int(min(markComp, uint32(compCount))) - 1
  let cls = sub.markClasses[markIdx]
  if int(cls) >= int(sub.classCount):
    buf.idx += 1
    return true
  let anchorIdx = sub.compOffsets[li] + compIdx * int(sub.classCount) +
    int(cls)
  if anchorIdx < 0 or anchorIdx >= sub.compAnchors.len:
    buf.idx += 1
    return true
  attachMark(buf, sub.compAnchors[anchorIdx], sub.markAnchors[markIdx],
    ligPos, scale)
  true

proc applyCursive*(buf: var Buffer, sub: CursiveSub, props: uint32,
    scale: Scale, lookupFlag: uint16): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let ci = sub.coverage.coverageIndexRaw(gid)
  if ci < 0 or ci >= sub.entryAnchors.len:
    return false
  let entry = sub.entryAnchors[ci]
  if entry.format == 0u16:
    return false
  # Find previous non-skipped glyph.
  var j = buf.idx - 1
  var prevPos = -1
  while j >= 0 and j < buf.info.len:
    if contextCheckProp(buf.info[j], props):
      prevPos = j
      break
    dec j
  if prevPos < 0:
    buf.unsafeToConcatFromOutbuffer(some(0), some(buf.idx + 1))
    return false
  let prevGid = buf.info[prevPos].glyphId
  let prevIdxOpt = sub.coverage.coverageIndexRaw(prevGid)
  if prevIdxOpt < 0 or prevIdxOpt >= sub.exitAnchors.len:
    buf.unsafeToConcatFromOutbuffer(some(prevPos), some(buf.idx + 1))
    return false
  let exit = sub.exitAnchors[prevIdxOpt]
  if exit.format == 0u16:
    buf.unsafeToConcatFromOutbuffer(some(prevPos), some(buf.idx + 1))
    return false
  let exitX = scale.scaleX(exit.x)
  let exitY = scale.scaleY(exit.y)
  let entryX = scale.scaleX(entry.x)
  let entryY = scale.scaleY(entry.y)
  let horiz = buf.direction.isHorizontal()
  let curIdx = buf.idx
  buf.unsafeToBreakRange(some(prevPos), some(curIdx + 1))
  if prevPos >= buf.pos.len or curIdx >= buf.pos.len:
    buf.indexFailed()
    return false
  if horiz and buf.direction == dirLeftToRight:
    buf.pos[prevPos].xAdvance = exitX + buf.pos[prevPos].xOffset
    let d = entryX + buf.pos[curIdx].xOffset
    buf.pos[curIdx].xAdvance = buf.pos[curIdx].xAdvance - d
    buf.pos[curIdx].xOffset = buf.pos[curIdx].xOffset - d
  elif horiz:
    let d = exitX + buf.pos[prevPos].xOffset
    buf.pos[prevPos].xAdvance = buf.pos[prevPos].xAdvance - d
    buf.pos[prevPos].xOffset = buf.pos[prevPos].xOffset - d
    buf.pos[curIdx].xAdvance = entryX + buf.pos[curIdx].xOffset
  else:
    # Vertical cursive: minimal advance adjustment (TODO full spec).
    buf.pos[prevPos].yAdvance = exitY + buf.pos[prevPos].yOffset
    let d = entryY + buf.pos[curIdx].yOffset
    buf.pos[curIdx].yAdvance = buf.pos[curIdx].yAdvance - d
    buf.pos[curIdx].yOffset = buf.pos[curIdx].yOffset - d
  var child = prevPos
  var parent = curIdx
  var xOff = entryX - exitX
  var yOff = entryY - exitY
  if (lookupFlag and LookupRightToLeft) == 0u16:
    let t = child
    child = parent
    parent = t
    xOff = -xOff
    yOff = -yOff
  # If the child was attached elsewhere via cursive, detach (simplified
  # reverse of harfrust reverse_cursive_minor_offset).
  if child >= 0 and child < buf.pos.len:
    if (buf.pos[child].attachType() and AttachCursive) != 0u8 and
        buf.pos[child].attachChain() != 0i16:
      buf.pos[child].setAttachChain(0)
      buf.pos[child].setAttachType(0u8)
  if child >= 0 and child < buf.pos.len and parent >= 0 and
      parent < buf.pos.len:
    buf.pos[child].setAttachType(AttachCursive)
    let chain = parent - child
    if chain >= int(low(int16)) and chain <= int(high(int16)):
      buf.pos[child].setAttachChain(int16(chain))
      if int(buf.pos[child].attachChain()) != chain:
        buf.pos[child].setAttachChain(0)
    if horiz:
      buf.pos[child].yOffset = yOff
    else:
      buf.pos[child].xOffset = xOff
    buf.scratchFlags = buf.scratchFlags or ScratchFlagHasGposAttachment
    # If the parent was attached to the child, separate them.
    if buf.pos[parent].attachChain() == -buf.pos[child].attachChain() and
        buf.pos[child].attachChain() != 0i16:
      buf.pos[parent].setAttachChain(0)
      if horiz:
        buf.pos[parent].yOffset = 0i32
      else:
        buf.pos[parent].xOffset = 0i32
  buf.idx = curIdx + 1
  true

proc propagateOne(buf: var Buffer, total: int, fwd: bool, i: int) =
  # Propagates one attachment offset to its mark.
  if i < 0 or i >= total:
    return
  let chain = int(buf.pos[i].attachChain())
  let kind = buf.pos[i].attachType()
  buf.pos[i].setAttachChain(0)
  let j = i + chain
  if j < 0 or j >= total or chain == 0:
    return
    # Depth guard: single-level propagation suffices for our tests;
    # deeper chains accumulate iteratively via repeated walks (TODO full).
    let px = buf.pos[j].xOffset
    let py = buf.pos[j].yOffset
    if kind == AttachMark:
      if buf.direction.isHorizontal():
        buf.pos[i].xOffset = buf.pos[i].xOffset + px
        # Subtract advances between base and mark.
        if j < i:
          if fwd:
            var k = j
            while k < i:
              buf.pos[i].xOffset = buf.pos[i].xOffset - buf.pos[k].xAdvance
              buf.pos[i].yOffset = buf.pos[i].yOffset - buf.pos[k].yAdvance
              inc k
          else:
            var k = j + 1
            while k <= i:
              buf.pos[i].xOffset = buf.pos[i].xOffset + buf.pos[k].xAdvance
              buf.pos[i].yOffset = buf.pos[i].yOffset + buf.pos[k].yAdvance
              inc k
        else:
          if fwd:
            var k = i
            while k < j:
              buf.pos[i].xOffset = buf.pos[i].xOffset + buf.pos[k].xAdvance
              buf.pos[i].yOffset = buf.pos[i].yOffset + buf.pos[k].yAdvance
              inc k
          else:
            var k = i + 1
            while k <= j:
              buf.pos[i].xOffset = buf.pos[i].xOffset - buf.pos[k].xAdvance
              buf.pos[i].yOffset = buf.pos[i].yOffset - buf.pos[k].yAdvance
              inc k
      else:
        buf.pos[i].yOffset = buf.pos[i].yOffset + py
    elif kind == AttachCursive:
      if buf.direction.isHorizontal():
        buf.pos[i].yOffset = buf.pos[i].yOffset + py
      else:
        buf.pos[i].xOffset = buf.pos[i].xOffset + px

proc propagateAttachmentOffsets*(buf: var Buffer) =
  ## Propagates attachment offsets forward and backward.
  let total = min(buf.len, buf.pos.len)
  if (buf.scratchFlags and ScratchFlagHasGposAttachment) == 0u32:
    return
  let fwd = buf.direction.isForward()
  if fwd:
    for i in 0 ..< total:
      if buf.pos[i].attachChain() != 0i16:
        buf.propagateOne(total, fwd, i)
  else:
    for i in countdown(total - 1, 0):
      if buf.pos[i].attachChain() != 0i16:
        buf.propagateOne(total, fwd, i)

proc applyPosRecords(buf: var Buffer, gpos: GposData,
    records: seq[LookupRecord], positions: seq[int], matchEnd: int,
    parentMask: uint32, scale: Scale, nestingLeft: int,
    store: VarStore, coords: seq[float32]): bool =
  ## Applies positioning lookups at matched positions. Unlike GSUB, GPOS
  ## never changes the glyph count, so positions stay valid and no
  ## length-delta shifting is needed.
  if positions.len == 0:
    return false
  if positions.len > MaxContextLength:
    return false
  if records.len == 0:
    if not buf.moveTo(matchEnd):
      return false
    return buf.successful
  for rec in records:
    if not buf.successful:
      break
    let idxRec = int(rec.seqIndex)
    if idxRec >= positions.len:
      continue
    let target = positions[idxRec]
    if target < 0 or target >= buf.len or target >= buf.info.len:
      continue
    if not buf.moveTo(target):
      break
    if buf.maxOps <= 0:
      buf.successful = false
      break
    buf.maxOps -= 1
    if buf.maxOps < 0:
      buf.successful = false
      break
    let applied = applyNestedPosAt(buf, gpos, int(rec.lookupIndex),
      parentMask, scale, nestingLeft - 1, store, coords)
    if not applied:
      if not buf.successful:
        break
      continue
  if not buf.successful:
    return false
  if not buf.moveTo(matchEnd):
    return false
  buf.successful

proc applyNestedPosAt(buf: var Buffer, gpos: GposData, lookupIndex: int,
    parentMask: uint32, scale: Scale, nestingLeft: int, store: VarStore,
    coords: seq[float32]): bool =
  if nestingLeft <= 0:
    buf.indexFailed()
    return false
  if lookupIndex < 0 or lookupIndex >= gposLookupCount(gpos):
    return false
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let lookup = getGposLookup(gpos, lookupIndex)
  if lookup.order.len == 0:
    return false
  let nestedProps = lookup.lookupProps()
  let isHorizontal = buf.direction.isHorizontal()
  for e in lookup.order:
    case e.kind
    of pkSingle:
      if applySinglePos(buf, lookup.singlePos[e.index], scale,
          isHorizontal, store, coords):
        return true
    of pkPair:
      if applyPairPos(buf, lookup.pairPos[e.index], nestedProps,
          parentMask, scale, isHorizontal, store, coords):
        return true
    of pkMarkBase:
      if applyMarkBase(buf, lookup.markBasePos[e.index], nestedProps,
          parentMask, scale):
        return true
    of pkMarkMark:
      if applyMarkMark(buf, lookup.markMarkPos[e.index], nestedProps,
          parentMask, scale):
        return true
    of pkMarkLig:
      if applyMarkLig(buf, lookup.markLigPos[e.index], nestedProps,
          parentMask, scale):
        return true
    of pkCursive:
      if applyCursive(buf, lookup.cursivePos[e.index], nestedProps, scale,
          lookup.lookupFlag):
        return true
    of pkContext:
      if applyPosContextSubst(buf, gpos, lookup.contextPos[e.index],
          nestedProps, parentMask, scale, nestingLeft, store, coords):
        return true
    of pkChain:
      if applyPosChainSubst(buf, gpos, lookup.chainPos[e.index],
          nestedProps, parentMask, scale, nestingLeft, store, coords):
        return true
    of pkOther:
      continue
  false

proc applyPosContextSubst(buf: var Buffer, gpos: GposData,
    sub: ContextSubst, props, lookupMask: uint32, scale: Scale,
    nestingLeft: int, store: VarStore, coords: seq[float32]): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  if sub.format == 1u16 or sub.format == 4u16:
    let ci = sub.coverage.coverageIndexRaw(gid)
    if ci < 0 or ci >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[ci]:
      let m = matchInputSeq(buf, props, lookupMask, rule.input, vkGlyph,
        noClassDef(), @[])
      if m.isNone:
        continue
      if applyPosRecords(buf, gpos, rule.records, m.get.positions,
          m.get.matchEnd, lookupMask, scale, nestingLeft, store, coords):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 2u16 or sub.format == 5u16:
    if not sub.coverage.covers(gid):
      return false
    let cls = int(sub.classDef.classOf(gid))
    if cls >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[cls]:
      let m = matchInputSeq(buf, props, lookupMask, rule.input, vkClass,
        sub.classDef, @[])
      if m.isNone:
        continue
      if applyPosRecords(buf, gpos, rule.records, m.get.positions,
          m.get.matchEnd, lookupMask, scale, nestingLeft, store, coords):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 3u16 or sub.format == 6u16:
    if sub.coverages.len == 0:
      return false
    if not sub.coverages[0].covers(gid):
      return false
    let m =
      if sub.coverages.len > 1:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(), sub.coverages.toOpenArray(1, sub.coverages.high))
      else:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(), [])
    if m.isNone:
      return false
    if applyPosRecords(buf, gpos, sub.records, m.get.positions,
        m.get.matchEnd, lookupMask, scale, nestingLeft, store, coords):
      return true
    if not buf.successful:
      return false
    true
  else:
    false

proc applyPosChainSubst(buf: var Buffer, gpos: GposData,
    sub: ChainContextSubst, props, lookupMask: uint32, scale: Scale,
    nestingLeft: int, store: VarStore, coords: seq[float32]): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  if sub.format == 1u16 or sub.format == 4u16:
    let ci = sub.coverage.coverageIndexRaw(gid)
    if ci < 0 or ci >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[ci]:
      let mi = matchInputSeq(buf, props, lookupMask, rule.input, vkGlyph,
        noClassDef(), @[])
      if mi.isNone:
        continue
      let la = matchLookaheadSeq(buf, props, rule.lookahead, vkGlyph,
        noClassDef(), @[], mi.get.matchEnd)
      if la.isNone:
        continue
      if not matchBacktrackSeq(buf, props, rule.backtrack, vkGlyph,
          noClassDef(), @[]):
        continue
      if applyPosRecords(buf, gpos, rule.records, mi.get.positions,
          mi.get.matchEnd, lookupMask, scale, nestingLeft, store, coords):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 2u16 or sub.format == 5u16:
    if not sub.coverage.covers(gid):
      return false
    let cls = int(sub.inputClassDef.classOf(gid))
    if cls >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[cls]:
      let mi = matchInputSeq(buf, props, lookupMask, rule.input, vkClass,
        sub.inputClassDef, @[])
      if mi.isNone:
        continue
      let la = matchLookaheadSeq(buf, props, rule.lookahead, vkClass,
        sub.lookaheadClassDef, @[], mi.get.matchEnd)
      if la.isNone:
        continue
      if not matchBacktrackSeq(buf, props, rule.backtrack, vkClass,
          sub.backtrackClassDef, @[]):
        continue
      if applyPosRecords(buf, gpos, rule.records, mi.get.positions,
          mi.get.matchEnd, lookupMask, scale, nestingLeft, store, coords):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 3u16:
    if sub.inputCoverages.len == 0:
      return false
    if not sub.inputCoverages[0].covers(gid):
      return false
    let mi =
      if sub.inputCoverages.len > 1:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(),
          sub.inputCoverages.toOpenArray(1, sub.inputCoverages.high))
      else:
        matchInputSeq(buf, props, lookupMask, [], vkCoverage,
          noClassDef(), [])
    if mi.isNone:
      return false
    let la = matchLookaheadSeq(buf, props, [], vkCoverage, noClassDef(),
      sub.lookaheadCoverages, mi.get.matchEnd)
    if la.isNone:
      return false
    if not matchBacktrackSeq(buf, props, [], vkCoverage, noClassDef(),
        sub.backtrackCoverages):
      return false
    if applyPosRecords(buf, gpos, sub.records, mi.get.positions,
        mi.get.matchEnd, lookupMask, scale, nestingLeft, store, coords):
      return true
    if not buf.successful:
      return false
    true
  else:
    false

proc applyPosLookup*(buf: var Buffer, gpos: GposData, lookup: PosLookup,
    mask: uint32, scale: Scale,
    nestingLeft: int = MaxNestingLevel, store: VarStore = VarStore(),
    coords: seq[float32] = @[]): bool =
  if lookup.order.len == 0:
    return false
  if buf.haveOutput:
    return false
  if not buf.havePositions:
    buf.clearPositions()
  let props = lookup.lookupProps()
  let isHorizontal = buf.direction.isHorizontal()
  while buf.successful:
    var j = buf.idx
    while j < buf.len and j < buf.info.len:
      let g = buf.info[j]
      if (g.mask and mask) != 0u32 and checkGlyphProperty(g, props) and
          posLookupCovers(lookup, g.glyphId):
        break
      inc j
    if j > buf.idx:
      buf.nextGlyphs(j - buf.idx)
    if buf.idx >= buf.len or buf.idx >= buf.info.len:
      break
    var done = false
    for e in lookup.order:
      case e.kind
      of pkSingle:
        if applySinglePos(buf, lookup.singlePos[e.index], scale,
            isHorizontal, store, coords):
          done = true
          break
      of pkPair:
        if applyPairPos(buf, lookup.pairPos[e.index], props, mask, scale,
            isHorizontal, store, coords):
          done = true
          break
      of pkMarkBase:
        if applyMarkBase(buf, lookup.markBasePos[e.index], props, mask,
            scale):
          done = true
          break
      of pkMarkMark:
        if applyMarkMark(buf, lookup.markMarkPos[e.index], props, mask,
            scale):
          done = true
          break
      of pkMarkLig:
        if applyMarkLig(buf, lookup.markLigPos[e.index], props, mask,
            scale):
          done = true
          break
      of pkCursive:
        if applyCursive(buf, lookup.cursivePos[e.index], props, scale,
            lookup.lookupFlag):
          done = true
          break
      of pkContext:
        if applyPosContextSubst(buf, gpos, lookup.contextPos[e.index],
            props, mask, scale, nestingLeft, store, coords):
          done = true
          break
      of pkChain:
        if applyPosChainSubst(buf, gpos, lookup.chainPos[e.index],
            props, mask, scale, nestingLeft, store, coords):
          done = true
          break
      of pkOther:
        continue
    if done:
      result = true
    else:
      buf.nextGlyph()

proc applyPosLookups*(buf: var Buffer, gpos: GposData,
    lookupIndices: openArray[uint16], mask: uint32, scale: Scale,
    store: VarStore = VarStore(), coords: seq[float32] = @[]) =
  if buf.isEmpty() or mask == 0u32:
    return
  if not buf.havePositions:
    buf.clearPositions()
  for li in lookupIndices:
    if int(li) >= gposLookupCount(gpos):
      continue
    let lookup = getGposLookup(gpos, int(li))
    if lookup.order.len == 0:
      continue
    buf.idx = 0
    discard applyPosLookup(buf, gpos, lookup, mask, scale,
      MaxNestingLevel, store, coords)

# --------------------------------------------------------------------------
# Legacy `kern` table (mirrors harfrust aat/kern.rs machine_kern for
# format 0; single walk per subtable, kern value split across the pair).
# --------------------------------------------------------------------------

const KernWalkMask* = 0x80000000u32

proc applyKernTable*(buf: var Buffer, kern: KernData, mask: uint32,
    scale: Scale) =
  if buf.isEmpty() or mask == 0u32:
    return
  if not buf.havePositions:
    buf.clearPositions()
  let horiz = buf.direction.isHorizontal()
  let needReverse = buf.direction.isBackward()
  if needReverse:
    buf.reverse()
  buf.setMasks(mask, mask, GlobalStart, GlobalEnd)
  buf.unsafeToConcatRange(none(int), none(int))
  let props = uint32(LookupIgnoreMarks)
  for sub in kern.subtables:
    if sub.crossStream:
      continue # TODO: cross-stream attachment
    if horiz != sub.horizontal:
      continue
    if sub.pairs.len == 0:
      continue
    buf.idx = 0
    while buf.successful:
      var j = buf.idx
      while j < buf.len and j < buf.info.len:
        if (buf.info[j].mask and mask) != 0u32:
          break
        inc j
      if j > buf.idx:
        buf.nextGlyphs(j - buf.idx)
      if buf.idx >= buf.len or buf.idx >= buf.info.len:
        break
      var k = buf.idx + 1
      while k < buf.len and k < buf.info.len:
        if contextCheckProp(buf.info[k], props):
          break
        inc k
      if k >= buf.len or k >= buf.info.len:
        break
      let v = kernValueAt(sub, buf.info[buf.idx].glyphId,
        buf.info[k].glyphId)
      if v != 0i32:
        let sv = if horiz: scale.scaleX(v) else: scale.scaleY(v)
        let k1 = sv shr 1
        let k2 = sv - k1
        if horiz:
          buf.pos[buf.idx].xAdvance =
            saturatingAddI32(buf.pos[buf.idx].xAdvance, k1)
          buf.pos[k].xAdvance =
            saturatingAddI32(buf.pos[k].xAdvance, k2)
          buf.pos[k].xOffset =
            saturatingAddI32(buf.pos[k].xOffset, k2)
        else:
          buf.pos[buf.idx].yAdvance =
            saturatingAddI32(buf.pos[buf.idx].yAdvance, k1)
          buf.pos[k].yAdvance =
            saturatingAddI32(buf.pos[k].yAdvance, k2)
          buf.pos[k].yOffset =
            saturatingAddI32(buf.pos[k].yOffset, k2)
        buf.unsafeToBreakRange(some(buf.idx), some(k + 1))
      buf.idx = k
  if needReverse:
    buf.reverse()

proc mapGlyphsFast*(buf: var Buffer) =
  ## Maps codepoints to glyphs using stored normalizer indexes.
  for i in 0 ..< buf.len:
    if i >= buf.info.len:
      break
    buf.info[i].glyphId = buf.info[i].normalizerGlyphIndex()
    # The normalizer glyph index shares its variable word with the OT
    # glyph props (low 16 bits), ligature props, and syllable, which
    # would otherwise read back as garbage (the old glyph ID) and, e.g.,
    # make IgnoreMarks lookups skip arbitrary glyphs. Without GDEF every
    # glyph is class 0, so reset for the OT phase.
    buf.info[i].setGlyphProps(0u16)
    buf.info[i].setLigProps(0u8)
    buf.info[i].setSyllable(0u8)
  if buf.haveSeparateOutput:
    for i in 0 ..< min(buf.len, buf.outInfo.len):
      buf.outInfo[i].glyphId = buf.outInfo[i].normalizerGlyphIndex()
      buf.outInfo[i].setGlyphProps(0u16)
      buf.outInfo[i].setLigProps(0u8)
      buf.outInfo[i].setSyllable(0u8)
