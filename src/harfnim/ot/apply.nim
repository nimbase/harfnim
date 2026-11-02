import std/bitops
import std/options

import ../buffer
import ../direction
import ../scale
import ../unicode
import ./context
import ./gpos
import ./gsub

export gsub
export context
export gpos

proc checkGlyphProperty*(info: GlyphInfo, props: uint32): bool =
  let flags = uint16(props and 0xFFFFu32)
  if (info.glyphProps() and flags and LookupIgnoreFlags) != 0u16:
    return false
  if (flags and LookupUseMarkFilteringSet) != 0u16:
    # TODO: GDEF mark glyph sets
    return false
  # TODO: mark attachment type filtering (needs GDEF attach classes)
  true

proc lookupProps*(lookup: Lookup): uint32 =
  var props = uint32(lookup.lookupFlag)
  if (lookup.lookupFlag and LookupUseMarkFilteringSet) != 0u16:
    props = props or (uint32(lookup.markFilteringSet) shl 16)
  props

proc replaceWithSubstituted*(buf: var Buffer, gid: uint32) =
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

proc lookupCovers(lookup: Lookup, gid: uint32): bool =
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
      if sub.format == 1u16 or sub.format == 2u16:
        if sub.coverage.covers(gid):
          return true
      elif sub.format == 3u16:
        if sub.coverages.len > 0 and sub.coverages[0].covers(gid):
          return true
    of lkChain:
      let sub = lookup.chainSubsts[e.index]
      if sub.format == 1u16 or sub.format == 2u16:
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
  mask: uint32, nestingLeft: int = MaxNestingLevel): bool
proc applyNestedAt(buf: var Buffer, gsub: GsubData, lookupIndex: int,
  parentMask: uint32, nestingLeft: int): bool
proc applyRecords(buf: var Buffer, gsub: GsubData,
  records: seq[LookupRecord], positions: seq[int], matchEnd: int,
  parentMask: uint32, nestingLeft: int): bool
proc applyContextSubst(buf: var Buffer, gsub: GsubData, sub: ContextSubst,
  props, lookupMask: uint32, nestingLeft: int): bool
proc applyChainSubst(buf: var Buffer, gsub: GsubData, sub: ChainContextSubst,
  props, lookupMask: uint32, nestingLeft: int): bool
proc applyReverseSubst(buf: var Buffer, sub: ReverseChainSubst,
  props, lookupMask: uint32): bool
proc applyLookupBackward*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
  mask: uint32): bool

proc outputGlyphForComponent(buf: var Buffer, gid: uint32, classGuess: uint16) =
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return
  var props = cur[].glyphProps() or GlyphPropSubstituted or GlyphPropMultiplied
  props = (props and GlyphPropPreserve) or classGuess
  cur[].setGlyphProps(props)
  buf.outputGlyph(gid)

proc applyMultiple(buf: var Buffer, sub: MultipleSubst, index: int): bool =
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
    props: uint32): Option[tuple[positions: seq[int], matchEnd: int,
    totalComps: int]] =
  type MatchResult = tuple[positions: seq[int], matchEnd: int, totalComps: int]
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
  if isLigature:
    props = (props or GlyphPropLigated) and not GlyphPropMultiplied
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
    props: uint32): bool =
  for lig in set:
    if lig.components.len == 0:
      replaceWithSubstituted(buf, lig.ligGlyph)
      return true
    let m = matchComponents(buf, lig.components, props)
    if m.isNone:
      continue
    ligateInput(buf, m.get.positions, m.get.matchEnd, m.get.totalComps,
      lig.ligGlyph)
    return true
  false

proc applyContextSubst(buf: var Buffer, gsub: GsubData, sub: ContextSubst,
    props, lookupMask: uint32, nestingLeft: int): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  if sub.format == 1u16:
    let ci = sub.coverage.coverageIndex(gid)
    if ci.isNone or int(ci.get) >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[int(ci.get)]:
      let m = matchInputSeq(buf, props, lookupMask, rule.input, vkGlyph,
        noClassDef(), @[])
      if m.isNone:
        continue
      if applyRecords(buf, gsub, rule.records, m.get.positions,
          m.get.matchEnd, lookupMask, nestingLeft):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 2u16:
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
      if applyRecords(buf, gsub, rule.records, m.get.positions,
          m.get.matchEnd, lookupMask, nestingLeft):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 3u16:
    if sub.coverages.len == 0:
      return false
    if not sub.coverages[0].covers(gid):
      return false
    let rest =
      if sub.coverages.len > 1: sub.coverages[1 .. ^1]
      else: @[]
    let dummy = newSeq[uint32](rest.len)
    let m = matchInputSeq(buf, props, lookupMask, dummy, vkCoverage,
      noClassDef(), rest)
    if m.isNone:
      return false
    if applyRecords(buf, gsub, sub.records, m.get.positions,
        m.get.matchEnd, lookupMask, nestingLeft):
      return true
    if not buf.successful:
      return false
    true
  else:
    false

proc applyChainSubst(buf: var Buffer, gsub: GsubData, sub: ChainContextSubst,
    props, lookupMask: uint32, nestingLeft: int): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  if sub.format == 1u16:
    let ci = sub.coverage.coverageIndex(gid)
    if ci.isNone or int(ci.get) >= sub.ruleSets.len:
      return false
    for rule in sub.ruleSets[int(ci.get)]:
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
      if applyRecords(buf, gsub, rule.records, mi.get.positions,
          mi.get.matchEnd, lookupMask, nestingLeft):
        return true
      if not buf.successful:
        return false
      return true
    false
  elif sub.format == 2u16:
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
      if applyRecords(buf, gsub, rule.records, mi.get.positions,
          mi.get.matchEnd, lookupMask, nestingLeft):
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
    let restInput =
      if sub.inputCoverages.len > 1: sub.inputCoverages[1 .. ^1]
      else: @[]
    let dummyIn = newSeq[uint32](restInput.len)
    let mi = matchInputSeq(buf, props, lookupMask, dummyIn, vkCoverage,
      noClassDef(), restInput)
    if mi.isNone:
      return false
    let dummyLa = newSeq[uint32](sub.lookaheadCoverages.len)
    let la = matchLookaheadSeq(buf, props, dummyLa, vkCoverage, noClassDef(),
      sub.lookaheadCoverages, mi.get.matchEnd)
    if la.isNone:
      return false
    let dummyBack = newSeq[uint32](sub.backtrackCoverages.len)
    # Silence unused warning: backtrack length drives the walk below.
    discard dummyBack
    if not matchBacktrackSeq(buf, props, dummyBack, vkCoverage, noClassDef(),
        sub.backtrackCoverages):
      return false
    if applyRecords(buf, gsub, sub.records, mi.get.positions,
        mi.get.matchEnd, lookupMask, nestingLeft):
      return true
    if not buf.successful:
      return false
    true
  else:
    false

proc applyReverseSubst(buf: var Buffer, sub: ReverseChainSubst,
    props, lookupMask: uint32): bool =
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
  let ci = sub.coverage.coverageIndex(gid)
  if ci.isNone or int(ci.get) >= sub.substitutes.len:
    return false
  let dummyBack = newSeq[uint32](sub.backtrackCoverages.len)
  if not matchBacktrackSeq(buf, props, dummyBack, vkCoverage, noClassDef(),
      sub.backtrackCoverages):
    # TODO: unsafe_to_concat_from_outbuffer marking
    return false
  let dummyLook = newSeq[uint32](sub.lookaheadCoverages.len)
  let laEnd = matchLookaheadSeq(buf, props, dummyLook, vkCoverage,
    noClassDef(), sub.lookaheadCoverages, buf.idx + 1)
  if laEnd.isNone:
    return false
  # TODO: unsafe_to_break_from_outbuffer marking
  replaceWithSubstitutedInplace(buf, sub.substitutes[int(ci.get)])
  buf.successful

proc applyLookupBackward*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
    mask: uint32): bool =
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
      if applyReverseSubst(buf, lookup.reverseSubsts[e.index], props, mask):
        done = true
        break
    if done:
      result = true
    if candidate == 0:
      break
    buf.idx = candidate - 1

proc applyRecords(buf: var Buffer, gsub: GsubData,
    records: seq[LookupRecord], positions: seq[int], matchEnd: int,
    parentMask: uint32, nestingLeft: int): bool =
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
      nestingLeft - 1)
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
    parentMask: uint32, nestingLeft: int): bool =
  if nestingLeft <= 0:
    buf.indexFailed()
    return false
  if lookupIndex < 0 or lookupIndex >= gsub.lookups.len:
    return false
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let lookup = gsub.lookups[lookupIndex]
  if lookup.order.len == 0:
    return false
  let nestedProps = lookup.lookupProps()
  let gid = buf.info[buf.idx].glyphId
  for e in lookup.order:
    case e.kind
    of lkSingle:
      let sub = lookup.singleSubsts[e.index]
      let ci = sub.coverage.coverageIndex(gid)
      if ci.isNone:
        continue
      let rep = sub.singleSubstitute(gid, ci.get)
      if rep.isNone:
        continue
      replaceWithSubstituted(buf, rep.get)
      return true
    of lkMultiple:
      let sub = lookup.multipleSubsts[e.index]
      let ci = sub.coverage.coverageIndex(gid)
      if ci.isNone:
        continue
      if applyMultiple(buf, sub, int(ci.get)):
        return true
    of lkAlternate:
      let sub = lookup.alternateSubsts[e.index]
      let ci = sub.coverage.coverageIndex(gid)
      if ci.isNone:
        continue
      if applyAlternate(buf, sub, int(ci.get), parentMask):
        return true
    of lkLigature:
      let sub = lookup.ligatureSubsts[e.index]
      let ci = sub.coverage.coverageIndex(gid)
      if ci.isNone or int(ci.get) >= sub.sets.len:
        continue
      if applyLigature(buf, sub.sets[int(ci.get)], nestedProps):
        return true
    of lkContext:
      if applyContextSubst(buf, gsub, lookup.contextSubsts[e.index],
          nestedProps, parentMask, nestingLeft):
        return true
    of lkChain:
      if applyChainSubst(buf, gsub, lookup.chainSubsts[e.index],
          nestedProps, parentMask, nestingLeft):
        return true
    of lkReverse:
      # Reverse chaining lookups can't be nested.
      continue
    of lkOther:
      continue
  false

proc applyLookup*(buf: var Buffer, gsub: GsubData, lookup: Lookup,
  mask: uint32, nestingLeft: int = MaxNestingLevel): bool =
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
        let ci = sub.coverage.coverageIndex(gid)
        if ci.isNone:
          continue
        let rep = sub.singleSubstitute(gid, ci.get)
        if rep.isNone:
          continue
        replaceWithSubstituted(buf, rep.get)
        done = true
        break
      of lkMultiple:
        let sub = lookup.multipleSubsts[e.index]
        let ci = sub.coverage.coverageIndex(gid)
        if ci.isNone:
          continue
        if applyMultiple(buf, sub, int(ci.get)):
          done = true
          break
      of lkAlternate:
        let sub = lookup.alternateSubsts[e.index]
        let ci = sub.coverage.coverageIndex(gid)
        if ci.isNone:
          continue
        if applyAlternate(buf, sub, int(ci.get), mask):
          done = true
          break
      of lkLigature:
        let sub = lookup.ligatureSubsts[e.index]
        let ci = sub.coverage.coverageIndex(gid)
        if ci.isNone or int(ci.get) >= sub.sets.len:
          continue
        if applyLigature(buf, sub.sets[int(ci.get)], props):
          done = true
          break
      of lkContext:
        if applyContextSubst(buf, gsub, lookup.contextSubsts[e.index],
            props, mask, nestingLeft):
          done = true
          break
      of lkChain:
        if applyChainSubst(buf, gsub, lookup.chainSubsts[e.index],
            props, mask, nestingLeft):
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
    lookupIndices: openArray[uint16], mask: uint32) =
  if buf.isEmpty() or mask == 0u32:
    return
  for li in lookupIndices:
    if int(li) >= gsub.lookups.len:
      continue
    let lookup = gsub.lookups[int(li)]
    if lookup.order.len == 0:
      continue
    if lookup.isReverse:
      # In-place backward substitution, no output buffer.
      if buf.haveOutput:
        discard buf.sync()
      if buf.isEmpty():
        continue
      buf.idx = buf.len - 1
      discard applyLookupBackward(buf, gsub, lookup, mask)
    else:
      buf.clearOutput()
      buf.idx = 0
      discard applyLookup(buf, gsub, lookup, mask)
      discard buf.sync()

# --------------------------------------------------------------------------
# GPOS positioning (mirrors harfrust ot/lookup/gpos.rs, static fonts only)
# --------------------------------------------------------------------------

proc saturatingAddI32(a, b: int32): int32 =
  let s = int64(a) + int64(b)
  if s > int64(high(int32)):
    high(int32)
  elif s < int64(low(int32)):
    low(int32)
  else:
    int32(s)

proc saturatingSubI32(a, b: int32): int32 =
  saturatingAddI32(a, -b)

proc lookupProps*(lookup: PosLookup): uint32 =
  var props = uint32(lookup.lookupFlag)
  if (lookup.lookupFlag and LookupUseMarkFilteringSet) != 0u16:
    props = props or (uint32(lookup.markFilteringSet) shl 16)
  props

proc posLookupCovers(lookup: PosLookup, gid: uint32): bool =
  for e in lookup.order:
    case e.kind
    of pkSingle:
      if lookup.singlePos[e.index].coverage.covers(gid):
        return true
    of pkPair:
      if lookup.pairPos[e.index].coverage.covers(gid):
        return true
    of pkOther:
      discard
  false

proc applyValueRecord(buf: var Buffer, posIdx: int, value: ValueRecord,
    scale: Scale, isHorizontal: bool): bool =
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
  # TODO: device tables and variation deltas (hinting/variable fonts only).

proc findSecondGlyph(buf: Buffer, props, mask: uint32): Option[int] =
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
    isHorizontal: bool): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let gid = buf.info[buf.idx].glyphId
  let ci = sub.coverage.coverageIndex(gid)
  if ci.isNone:
    return false
  let idx = int(ci.get)
  if idx >= sub.values.len:
    return false
  discard applyValueRecord(buf, buf.idx, sub.values[idx], scale, isHorizontal)
  buf.nextGlyph()
  true

proc applyPairPos(buf: var Buffer, sub: PairPos, props, mask: uint32,
    scale: Scale, isHorizontal: bool): bool =
  if buf.idx < 0 or buf.idx >= buf.len or buf.idx >= buf.info.len:
    return false
  let first = buf.info[buf.idx].glyphId
  if sub.coverage.coverageIndex(first).isNone:
    return false
  let secondOpt = findSecondGlyph(buf, props, mask)
  if secondOpt.isNone:
    return false
  let secondIdx = secondOpt.get
  let second = buf.info[secondIdx].glyphId
  if sub.format == 1u16:
    let covIdx = sub.coverage.coverageIndex(first).get
    if int(covIdx) >= sub.pairSets.len:
      return false
    let set = sub.pairSets[int(covIdx)]
    for i, s in set.seconds:
      if uint32(s) == second:
        let (v1, v2) = set.values[i]
        discard applyValueRecord(buf, buf.idx, v1, scale, isHorizontal)
        discard applyValueRecord(buf, secondIdx, v2, scale, isHorizontal)
        if sub.format2 != 0u16:
          buf.idx = secondIdx + 1
        else:
          buf.idx = secondIdx
        return true
    # TODO: unsafe_to_concat marking on pair miss.
    false
  elif sub.format == 2u16:
    let class1 = sub.classDef1.classOf(first)
    let class2 = sub.classDef2.classOf(second)
    if class1 >= uint32(sub.class1Count) or class2 >= uint32(sub.class2Count):
      return false
    let recIdx = int(class1) * int(sub.class2Count) + int(class2)
    if recIdx < 0 or recIdx >= sub.matrix.len:
      return false
    let (v1, v2) = sub.matrix[recIdx]
    discard applyValueRecord(buf, buf.idx, v1, scale, isHorizontal)
    discard applyValueRecord(buf, secondIdx, v2, scale, isHorizontal)
    if sub.format2 != 0u16:
      buf.idx = secondIdx + 1
    else:
      buf.idx = secondIdx
    true
  else:
    false

proc applyPosLookup*(buf: var Buffer, gpos: GposData, lookup: PosLookup,
    mask: uint32, scale: Scale): bool =
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
            isHorizontal):
          done = true
          break
      of pkPair:
        if applyPairPos(buf, lookup.pairPos[e.index], props, mask, scale,
            isHorizontal):
          done = true
          break
      of pkOther:
        continue
    if done:
      result = true
    else:
      buf.nextGlyph()

proc applyPosLookups*(buf: var Buffer, gpos: GposData,
    lookupIndices: openArray[uint16], mask: uint32, scale: Scale) =
  if buf.isEmpty() or mask == 0u32:
    return
  if not buf.havePositions:
    buf.clearPositions()
  for li in lookupIndices:
    if int(li) >= gpos.lookups.len:
      continue
    let lookup = gpos.lookups[int(li)]
    if lookup.order.len == 0:
      continue
    buf.idx = 0
    discard applyPosLookup(buf, gpos, lookup, mask, scale)

proc mapGlyphsFast*(buf: var Buffer) =
  for i in 0 ..< buf.len:
    if i >= buf.info.len:
      break
    buf.info[i].glyphId = buf.info[i].normalizerGlyphIndex()
  if buf.haveSeparateOutput:
    for i in 0 ..< min(buf.len, buf.outInfo.len):
      buf.outInfo[i].glyphId = buf.outInfo[i].normalizerGlyphIndex()
