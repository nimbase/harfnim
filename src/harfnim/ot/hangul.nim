## Hangul shaper: jamo composition/decomposition and tone reordering.
##
## Ported from harfrust `ot/shaper/hangul.rs`. Precomposed LV/LVT
## syllables compose when the font has the glyph, otherwise the
## syllable decomposes and ljmo/vjmo/tjmo features apply to the jamo;
## a following tone mark moves before the syllable unless it is
## zero-width. `calt` is kept away from jamo (some fonts route jamo
## lookups through it).

import std/bitops
import std/options

import ../buffer
import ../feature
import ../font
import ../tag
import ./map

const
  Ljmo* = 1u8
  Vjmo* = 2u8
  Tjmo* = 3u8

  LBase = 0x1100u32
  VBase = 0x1161u32
  TBase = 0x11A7u32
  LCount = 19u32
  VCount = 21u32
  TCount = 28u32
  NCount = VCount * TCount
  SBase = 0xAC00u32

proc isCombiningL*(u: uint32): bool =
  u >= LBase and u < LBase + LCount

proc isCombiningV*(u: uint32): bool =
  u >= VBase and u < VBase + VCount

proc isCombiningT*(u: uint32): bool =
  u >= TBase + 1u32 and u < TBase + TCount

proc isCombinedS*(u: uint32): bool =
  u >= SBase and u < SBase + LCount * NCount

proc isL*(u: uint32): bool =
  (u >= 0x1100u32 and u <= 0x115Fu32) or (u >= 0xA960u32 and u <= 0xA97Cu32)

proc isV*(u: uint32): bool =
  (u >= 0x1160u32 and u <= 0x11A7u32) or (u >= 0xD7B0u32 and u <= 0xD7C6u32)

proc isT*(u: uint32): bool =
  (u >= 0x11A8u32 and u <= 0x11FFu32) or (u >= 0xD7CBu32 and u <= 0xD7FBu32)

proc isHangulTone*(u: uint32): bool =
  u >= 0x302Eu32 and u <= 0x302Fu32

proc hangulShapingFeature*(g: GlyphInfo): uint8 =
  g.otShaperAuxiliary()

proc setHangulShapingFeature*(g: var GlyphInfo, v: uint8) =
  g.setOtShaperAuxiliary(v)

proc unsafeToBreakEmitted*(buf: var Buffer, start: int) =
  ## `unsafeToBreakFromOutbuffer(start, idx)` equivalent that also
  ## works while the buffer is still in in-place mode (emitted glyphs
  ## alias info there, so the dedicated out buffer is empty).
  if buf.haveSeparateOutput:
    buf.unsafeToBreakFromOutbuffer(some(start), some(buf.idx))
  else:
    for i in start ..< min(buf.outLen, buf.info.len):
      if i >= 0:
        buf.info[i].mask = buf.info[i].mask or 0x03u32

proc isZeroWidthChar(sf: ShaperFont, c: uint32): bool =
  sf.hAdvance(newGlyphId(c)) == 0i32

proc allocHangulMaskBit(nextBit: var uint32, value: uint32): tuple[mask,
    val: uint32] =
  if value == 0u32:
    return (0u32, 0u32)
  var bitsNeeded = 32u32 - uint32(countLeadingZeroBits(value))
  if bitsNeeded == 0u32:
    bitsNeeded = 1u32
  if nextBit + bitsNeeded > 31u32:
    return (0u32, 0u32)
  let mask =
    if nextBit + bitsNeeded >= 32u32: (not 0u32) shl nextBit
    else: ((1u32 shl (nextBit + bitsNeeded)) - (1u32 shl nextBit))
  let vb = value shl nextBit
  nextBit += bitsNeeded
  (mask, vb)

type
  HangulMasks* = object
    ljmoMask*, ljmoVal*: uint32
    vjmoMask*, vjmoVal*: uint32
    tjmoMask*, tjmoVal*: uint32
    caltMask*, caltVal*: uint32
    nextBit*: uint32

proc prepareHangulMasks*(buf: var Buffer): HangulMasks =
  ## Allocates ljmo/vjmo/tjmo/calt mask bits and enables calt
  ## globally; per-glyph jamo bits and the jamo calt exclusion happen
  ## in setupMasksHangul on codepoints, before glyph mapping.
  var nextBit = 8u32
  (result.ljmoMask, result.ljmoVal) = allocHangulMaskBit(nextBit, 1u32)
  (result.vjmoMask, result.vjmoVal) = allocHangulMaskBit(nextBit, 1u32)
  (result.tjmoMask, result.tjmoVal) = allocHangulMaskBit(nextBit, 1u32)
  (result.caltMask, result.caltVal) = allocHangulMaskBit(nextBit, 1u32)
  result.nextBit = nextBit
  if result.caltMask != 0u32:
    buf.setMasks(result.caltVal, result.caltMask, GlobalStart, GlobalEnd)

proc setupMasksHangul*(buf: var Buffer, hm: HangulMasks) =
  ## Tags each glyph with its jamo-feature mask and clears calt on
  ## jamo so `calt`-routed jamo lookups do not fire. Operates on
  ## codepoints; call before mapGlyphsFast.
  let maskArray = [0u32, hm.ljmoMask, hm.vjmoMask, hm.tjmoMask]
  for i in 0 ..< min(buf.len, buf.info.len):
    let f = int(buf.info[i].hangulShapingFeature())
    if f >= 0 and f <= 3:
      buf.info[i].mask = buf.info[i].mask or maskArray[f]
    let u = buf.info[i].glyphId
    if isL(u) or isV(u) or isT(u):
      buf.info[i].mask = buf.info[i].mask and not hm.caltMask

proc preprocessHangul*(buf: var Buffer, sf: ShaperFont) =
  ## Composes/decomposes Hangul syllables on codepoints, before
  ## normalization. Mirrors harfrust `preprocess_text_hangul`, whose
  ## Hangul normalization preference is None.
  buf.clearOutput()
  var start = 0
  var fin = 0
  buf.idx = 0
  while buf.idx < buf.len and buf.successful:
    let c0 = buf.cur(0)
    if c0 == nil:
      buf.indexFailed()
      return
    let u = c0[].glyphId
    if isHangulTone(u):
      if start < fin and fin == buf.outLen:
        # Tone mark follows a valid syllable: move it in front,
        # unless it is zero-width (assumed overstriking by design).
        buf.unsafeToBreakEmitted(start)
        buf.nextGlyph()
        if not isZeroWidthChar(sf, u):
          buf.mergeOutClusters(start, fin + 1)
          if not buf.rotateOutRightByOne(start, fin):
            return
      else:
        # No valid syllable as base: dotted circle if available.
        if not buf.flags.contains(DoNotInsertDottedCircle) and
            sf.hasGlyph(0x25CCu32):
          var chars = [0u32, 0u32]
          if not isZeroWidthChar(sf, u):
            chars[0] = u
            chars[1] = 0x25CCu32
          else:
            chars[0] = 0x25CCu32
            chars[1] = u
          buf.replaceGlyphs(1, 2, chars)
        else:
          buf.nextGlyph()
      start = buf.outLen
      fin = buf.outLen
      continue
    # Remember current position as a potential syllable start; only
    # used when fin advances past it.
    start = buf.outLen
    if isL(u) and buf.idx + 1 < buf.len:
      let l = u
      let c1 = buf.cur(1)
      if c1 == nil:
        buf.indexFailed()
        return
      let v = c1[].glyphId
      if isV(v):
        # Have <L,V> or <L,V,T>.
        var t = 0u32
        var tindex = 0u32
        if buf.idx + 2 < buf.len:
          let c2 = buf.cur(2)
          if c2 == nil:
            buf.indexFailed()
            return
          t = c2[].glyphId
          if isT(t):
            tindex = t - TBase
          else:
            t = 0u32
        let offset = if t != 0u32: 3 else: 2
        buf.unsafeToBreakRange(some(buf.idx), some(buf.idx + offset))
        if isCombiningL(l) and isCombiningV(v) and
            (t == 0u32 or isCombiningT(t)):
          let s = SBase + (l - LBase) * NCount + (v - VBase) * TCount +
            tindex
          if sf.hasGlyph(s):
            buf.replaceGlyphs(if t != 0u32: 3 else: 2, 1, [s])
            fin = start + 1
            continue
        # No composition: tag the jamo and advance past them.
        let m0 = buf.cur(0)
        if m0 == nil:
          buf.indexFailed()
          return
        m0[].setHangulShapingFeature(Ljmo)
        buf.nextGlyph()
        let m1 = buf.cur(0)
        if m1 == nil:
          buf.indexFailed()
          return
        m1[].setHangulShapingFeature(Vjmo)
        buf.nextGlyph()
        if t != 0u32:
          let m2 = buf.cur(0)
          if m2 == nil:
            buf.indexFailed()
            return
          m2[].setHangulShapingFeature(Tjmo)
          buf.nextGlyph()
          fin = start + 3
        else:
          fin = start + 2
        buf.mergeOutGraphemeClusters(start, fin)
        continue
    elif isCombinedS(u):
      # Have <LV>, <LVT>, or <LV,T>.
      let s = u
      let hasGlyph = sf.hasGlyph(s)
      let lindex = (s - SBase) div NCount
      let nindex = (s - SBase) mod NCount
      let vindex = nindex div TCount
      let tindex = nindex mod TCount
      if tindex == 0u32 and buf.idx + 1 < buf.len:
        let cn = buf.cur(1)
        if cn == nil:
          buf.indexFailed()
          return
        if isCombiningT(cn[].glyphId):
          # <LV,T>: try to combine.
          let newS = s + (cn[].glyphId - TBase)
          if sf.hasGlyph(newS):
            buf.replaceGlyphs(2, 1, [newS])
            fin = start + 1
            continue
          buf.unsafeToBreakRange(some(buf.idx), some(buf.idx + 2))
      # Decompose when the font lacks the syllable, or a
      # non-combining T follows an LV.
      var followedByT = false
      if tindex == 0u32 and buf.idx + 1 < buf.len:
        let cn = buf.cur(1)
        if cn == nil:
          buf.indexFailed()
          return
        followedByT = isT(cn[].glyphId)
      if (not hasGlyph) or followedByT:
        let d0 = LBase + lindex
        let d1 = VBase + vindex
        let d2 = TBase + tindex
        if sf.hasGlyph(d0) and sf.hasGlyph(d1) and
            (tindex == 0u32 or sf.hasGlyph(d2)):
          var sLen = if tindex != 0u32: 3 else: 2
          let decomposed = [d0, d1, d2]
          buf.replaceGlyphs(1, sLen, decomposed)
          # A decomposed LV followed by a non-combining T absorbs
          # the T into the syllable.
          if hasGlyph and tindex == 0u32:
            buf.nextGlyph()
            inc sLen
          fin = start + sLen
          let feats = [Ljmo, Vjmo, Tjmo]
          for k in 0 ..< sLen:
            let slot = buf.outAt(start + k)
            if slot == nil:
              buf.indexFailed()
              return
            slot[].setHangulShapingFeature(feats[k])
          buf.mergeOutGraphemeClusters(start, fin)
          continue
        else:
          # Mirrors harfrust: the trailing-LV corner evaluates cur(1)
          # past the end and fails the buffer there.
          if tindex == 0u32:
            if buf.idx + 1 >= buf.len:
              buf.indexFailed()
              return
            let cn = buf.cur(1)
            if cn == nil:
              buf.indexFailed()
              return
            if isT(cn[].glyphId):
              buf.unsafeToBreakRange(some(buf.idx), some(buf.idx + 2))
      if hasGlyph:
        fin = start + 1
        buf.nextGlyph()
        continue
    # No recognizable syllable; fin stays put so a following tone
    # mark does not reorder.
    buf.nextGlyph()
  discard buf.sync()

proc applyHangulGsub*(buf: var Buffer, gsub: GsubData, scriptTag,
    langTag: Tag, userFeatures: openArray[Feature], hm: HangulMasks) =
  ## Applies ljmo/vjmo/tjmo/calt with per-glyph masks, then user
  ## features with fresh bits above the Hangul allocation (mirroring
  ## the arabic applier; already-applied tags are skipped).
  let langOpt = gsubLangSys(gsub, scriptTag, langTag)
  template lookupsFor(tagStr: string): seq[uint16] =
    if langOpt.isNone: @[]
    else: gsubLookupsForLang(gsub, langOpt.get,
      tagFromStr(tagStr).toU32())
  template applyMasked(tagStr: string, mask: uint32) =
    if mask != 0u32:
      let lks = lookupsFor(tagStr)
      if lks.len > 0:
        buf.applySubstLookups(gsub, lks, mask)
  applyMasked("ljmo", hm.ljmoMask)
  applyMasked("vjmo", hm.vjmoMask)
  applyMasked("tjmo", hm.tjmoMask)
  applyMasked("calt", hm.caltMask)
  const hangulAutoGsub = ["ljmo", "vjmo", "tjmo", "calt"]
  var uBit = hm.nextBit
  for f in userFeatures:
    if f.value == 0u32:
      continue
    var covered = false
    for t in hangulAutoGsub:
      if f.tag.toU32() == tagFromStr(t).toU32():
        covered = true
        break
    if covered:
      continue
    let (m, v) = allocHangulMaskBit(uBit, f.value)
    if m == 0u32:
      continue
    let lks =
      if langOpt.isNone: @[]
      else: gsubLookupsForLang(gsub, langOpt.get, f.tag.toU32())
    if lks.len == 0:
      continue
    buf.setMasks(v, m, f.start, f.stop)
    buf.applySubstLookups(gsub, lks, m)
