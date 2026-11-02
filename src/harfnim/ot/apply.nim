import std/options

import ../buffer
import ../unicode
import ./gsub

export gsub

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

proc lookupCovers(lookup: Lookup, gid: uint32): bool =
  for e in lookup.order:
    case e.kind
    of lkSingle:
      if lookup.singleSubsts[e.index].coverage.covers(gid):
        return true
    of lkMultiple:
      if lookup.multipleSubsts[e.index].coverage.covers(gid):
        return true
    of lkLigature:
      if lookup.ligatureSubsts[e.index].coverage.covers(gid):
        return true
    of lkOther:
      discard
  false

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

proc applyLookup*(buf: var Buffer, lookup: Lookup, mask: uint32): bool =
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
      of lkLigature:
        let sub = lookup.ligatureSubsts[e.index]
        let ci = sub.coverage.coverageIndex(gid)
        if ci.isNone or int(ci.get) >= sub.sets.len:
          continue
        if applyLigature(buf, sub.sets[int(ci.get)], props):
          done = true
          break
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
    buf.clearOutput()
    buf.idx = 0
    discard applyLookup(buf, lookup, mask)
    discard buf.sync()

proc mapGlyphsFast*(buf: var Buffer) =
  for i in 0 ..< buf.len:
    if i >= buf.info.len:
      break
    buf.info[i].glyphId = buf.info[i].normalizerGlyphIndex()
  if buf.haveSeparateOutput:
    for i in 0 ..< min(buf.len, buf.outInfo.len):
      buf.outInfo[i].glyphId = buf.outInfo[i].normalizerGlyphIndex()
