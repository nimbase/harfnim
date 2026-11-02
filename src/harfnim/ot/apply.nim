import std/options

import ../buffer
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

proc applyLookup*(buf: var Buffer, lookup: Lookup, mask: uint32): bool =
  if lookup.lookupType != GsubSingleSubst or lookup.singleSubsts.len == 0:
    return false
  let props = lookup.lookupProps()
  while buf.successful:
    var j = buf.idx
    while j < buf.len and j < buf.info.len:
      let g = buf.info[j]
      if (g.mask and mask) != 0u32 and checkGlyphProperty(g, props) and
          (block:
            var covered = false
            for sub in lookup.singleSubsts:
              if sub.coverage.covers(g.glyphId):
                covered = true
                break
            covered):
        break
      inc j
    if j > buf.idx:
      buf.nextGlyphs(j - buf.idx)
    if buf.idx >= buf.len or buf.idx >= buf.info.len:
      break
    let gid = buf.info[buf.idx].glyphId
    var done = false
    for sub in lookup.singleSubsts:
      let ci = sub.coverage.coverageIndex(gid)
      if ci.isNone:
        continue
      let rep = sub.singleSubstitute(gid, ci.get)
      if rep.isNone:
        continue
      replaceWithSubstituted(buf, rep.get)
      done = true
      break
    if done:
      result = true
    else:
      buf.nextGlyph()

proc applySingleSubstLookups*(buf: var Buffer, gsub: GsubData,
    lookupIndices: openArray[uint16], mask: uint32) =
  if buf.isEmpty() or mask == 0u32:
    return
  for li in lookupIndices:
    if int(li) >= gsub.lookups.len:
      continue
    let lookup = gsub.lookups[int(li)]
    if lookup.lookupType != GsubSingleSubst:
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
