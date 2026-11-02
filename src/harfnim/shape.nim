## Full shaping orchestration: ShapePlan + shape() entry.
##
## Mirrors harfrust shape.rs / ot/layout.rs. Arabic joining, fallback
## presentation forms, mark/cursive GPOS, and fallback mark positioning are
## implemented; indic-family, thai, hangul, hebrew, khmer, myanmar, USE and
## syllabic shapers, stch stretching, and win1256 legacy fallback stay TODO.

import std/options
import std/bitops

import ./buffer
import ./direction
import ./feature
import ./font
import ./normalize
import ./script
import ./tag
import ./unicode
import ./ot/arabic
import ./ot/gpos
import ./ot/gsub
import ./ot/map

export buffer
export feature
export font
export tag

type
  ShapePlan* = object
    scriptTag*: Tag
    langTag*: Tag
    features*: seq[Feature]

proc newShapePlan*(scriptTag, langTag: Tag,
    features: openArray[Feature]): ShapePlan =
  var feats: seq[Feature] = @[]
  for f in features:
    feats.add(f)
  ShapePlan(scriptTag: scriptTag, langTag: langTag, features: feats)

proc scriptTagForBuffer(b: Buffer): Tag =
  if b.script.isSome:
    # TODO: full ISO 15924 to OpenType script-tag mapping (harfrust
    # hb_ot_tag_from_script has special cases); lowercasing covers
    # Latin, Arabic, and most scripts in our synthetic fonts.
    b.script.get.tag().toLower()
  else:
    defaultScriptTag()

proc langTagForBuffer(b: Buffer): Tag =
  # TODO: BCP47 to OpenType language-tag mapping (harfrust map language).
  # For now always the default language system.
  discard b
  defaultLanguageTag()

proc isArabicShaperScript(b: Buffer): bool =
  if b.script.isNone:
    return false
  let s = b.script.get
  (s == Arabic or s == Syriac) and b.direction.isHorizontal()

proc formClusters(b: var Buffer) =
  ## Merges grapheme clusters (base plus continuation marks) so marks
  ## share their base cluster, mirroring harfrust form_clusters.
  if (b.scratchFlags and ScratchFlagHasContinuations) == 0u32:
    return
  var i = 0
  while i < b.len:
    var j = i + 1
    while j < b.len and j < b.info.len and b.info[j].isContinuation():
      inc j
    if j - i > 1 and i < b.info.len:
      b.mergeGraphemeClusters(i, min(j, b.info.len))
    i = j

proc insertDottedCircle(b: var Buffer) =
  if b.isEmpty():
    return
  if b.flags.contains(DoNotInsertDottedCircle):
    return
  if b.len > b.info.len:
    return
  if not b.info[0].isUnicodeMark():
    return
  if not b.ensure(b.len + 1):
    return
  let cluster =
    if b.len > 0: b.info[0].cluster
    else: 0u32
  for i in countdown(b.len - 1, 0):
    b.info[i + 1] = b.info[i]
  b.info[0] = GlyphInfo(glyphId: 0x25CCu32, cluster: cluster)
  inc b.len
  var scratch = 0u32
  b.info[0].initUnicodeProps(scratch)

proc setBaseAdvances(b: var Buffer, sf: ShaperFont) =
  if b.direction.isHorizontal():
    for i in 0 ..< b.len:
      if i < b.info.len and i < b.pos.len:
        b.pos[i].xAdvance = sf.hAdvance(newGlyphId(b.info[i].glyphId))
  else:
    # TODO: vertical origin adjustment (needs vOrigin from extents/metrics).
    for i in 0 ..< b.len:
      if i < b.info.len and i < b.pos.len:
        b.pos[i].yAdvance = sf.vAdvance(newGlyphId(b.info[i].glyphId))

proc synthesizeGlyphClasses*(buf: var Buffer) =
  ## Fallback GDEF: bases vs marks from Unicode categories, mirroring
  ## harfrust synthesize_glyph_classes (used when the font has no GDEF).
  for i in 0 ..< min(buf.len, buf.info.len):
    var g = addr buf.info[i]
    let isMark = g[].generalCategory() == GcNonSpacingMark and
      not g[].isInfoDefaultIgnorable()
    let cls = if isMark: GlyphPropMark else: GlyphPropBaseGlyph
    g[].setGlyphProps((g[].glyphProps() and not GlyphPropClassMask) or cls)

proc allocMaskBit(nextBit: var uint32, value: uint32): tuple[mask, val: uint32] =
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
  ArabicMasks* = object
    actions*: array[8, uint32]
    stchMask*, stchVal*: uint32
    ccmpMask*, ccmpVal*: uint32
    loclMask*, loclVal*: uint32
    rligMask*, rligVal*: uint32
    caltMask*, caltVal*: uint32
    ligaMask*, ligaVal*: uint32
    cligMask*, cligVal*: uint32
    msetMask*, msetVal*: uint32
    nextBit*: uint32

proc prepareArabicMasks*(buf: var Buffer): ArabicMasks =
  ## Allocates arabic masks and runs joining on codepoints. Call before
  ## mapGlyphsFast (joining needs Unicode codepoints, not glyph IDs).
  var nextBit = 8u32
  for i in 0 ..< 7:
    let (m, _) = allocMaskBit(nextBit, 1u32)
    result.actions[i] = m
  result.actions[7] = 0u32
  (result.stchMask, result.stchVal) = allocMaskBit(nextBit, 1u32)
  (result.ccmpMask, result.ccmpVal) = allocMaskBit(nextBit, 1u32)
  (result.loclMask, result.loclVal) = allocMaskBit(nextBit, 1u32)
  (result.rligMask, result.rligVal) = allocMaskBit(nextBit, 1u32)
  (result.caltMask, result.caltVal) = allocMaskBit(nextBit, 1u32)
  (result.ligaMask, result.ligaVal) = allocMaskBit(nextBit, 1u32)
  (result.cligMask, result.cligVal) = allocMaskBit(nextBit, 1u32)
  (result.msetMask, result.msetVal) = allocMaskBit(nextBit, 1u32)
  result.nextBit = nextBit
  let isMong = buf.script.isSome and buf.script.get == Mongolian
  buf.setupMasksArabic(result.actions, isMong)
  for (m, v) in [(result.stchMask, result.stchVal),
      (result.ccmpMask, result.ccmpVal), (result.loclMask, result.loclVal),
      (result.rligMask, result.rligVal), (result.caltMask, result.caltVal),
      (result.ligaMask, result.ligaVal), (result.cligMask, result.cligVal),
      (result.msetMask, result.msetVal)]:
    if m != 0u32:
      buf.setMasks(v, m, GlobalStart, GlobalEnd)

proc applyArabicGsub*(buf: var Buffer, gsub: GsubData, scriptTag,
    langTag: Tag, userFeatures: openArray[Feature], sf: ShaperFont,
    am: ArabicMasks) =
  ## Ordered Arabic GSUB with precomputed masks (call after mapping).
  let maskArray = am.actions
  let stchMask = am.stchMask
  let ccmpMask = am.ccmpMask
  let loclMask = am.loclMask
  let rligMask = am.rligMask
  let caltMask = am.caltMask
  let ligaMask = am.ligaMask
  let cligMask = am.cligMask
  let msetMask = am.msetMask
  let available = gsubFeaturesFor(gsub, scriptTag, langTag)
  proc lookupsForAvail(avail: seq[tuple[tag: uint32, lookups: seq[uint16]]],
      tagStr: string): seq[uint16] =
    let t = tagFromStr(tagStr).toU32()
    for (tag, lks) in avail:
      if tag == t:
        return lks
    @[]
  # Order mirrors harfrust arabic collect_features (pauses between each).
  template applyMasked(tagStr: string, mask: uint32) =
    if mask != 0u32:
      let lks = lookupsForAvail(available, tagStr)
      if lks.len > 0:
        buf.applySubstLookups(gsub, lks, mask)
  applyMasked("stch", stchMask)
  applyMasked("ccmp", ccmpMask)
  applyMasked("locl", loclMask)
  const arabTags = ["isol", "fina", "fin2", "fin3", "medi", "med2", "init"]
  for i, t in arabTags:
    applyMasked(t, maskArray[i])
  # rlig with unicode fallback afterwards.
  applyMasked("rlig", rligMask)
  let isArab = buf.script.isSome and buf.script.get == Arabic
  if isArab:
    var needsFallback = true
    for t in arabTags:
      if lookupsForAvail(available, t).len > 0:
        needsFallback = false
        break
    if needsFallback and rligMask != 0u32:
      let nominal = proc(cp: uint32): Option[GlyphId] = sf.nominalGlyph(cp)
      let s0 = buildFallbackSingles(nominal, 0)
      let s1 = buildFallbackSingles(nominal, 1)
      let s2 = buildFallbackSingles(nominal, 2)
      let s3 = buildFallbackSingles(nominal, 3)
      let all = [(s0, 0), (s1, 1), (s2, 2), (s3, 3)]
      # Map init/medi/fina/isol fallback to the arabic action masks.
      # FALLBACK_FEATURES order is init, medi, fina, isol.
      let actionForFeat = [ArabicInit, ArabicMedi, ArabicFina, ArabicIsol]
      for k in 0 ..< 4:
        let (mappings, fi) = all[k]
        # Find which arabic tag this fallback corresponds to.
        var featTag = ""
        case fi
        of 0: featTag = "init"
        of 1: featTag = "medi"
        of 2: featTag = "fina"
        else: featTag = "isol"
        # Determine mask: use the arabic action mask if the font lacks the
        # feature, else the rlig mask is irrelevant here. We apply the
        # fallback substitutions under the arabic action mask so only
        # correctly joined glyphs are replaced.
        var m = 0u32
        for ai, at in arabTags:
          if at == featTag:
            m = maskArray[ai]
            break
        discard actionForFeat
        if m != 0u32:
          buf.applyFallbackSingle(mappings, m)
      let lig3 = buildFallbackLigs(nominal, true, false)
      let lig2 = buildFallbackLigs(nominal, false, false)
      let ligM = buildFallbackLigs(nominal, false, true)
      buf.applyFallbackLig(lig3, rligMask, true)
      buf.applyFallbackLig(lig2, rligMask, true)
      buf.applyFallbackLig(ligM, rligMask, false)
  applyMasked("calt", caltMask)
  applyMasked("liga", ligaMask)
  applyMasked("clig", cligMask)
  applyMasked("mset", msetMask)
  # User features last, with fresh low bits that do not disturb arabic bits
  # (they start above the arabic allocation). Features the arabic path
  # already applied with joining-aware masks are skipped to avoid applying
  # them twice (the global re-application would be redundant).
  const arabAutoGsub = ["stch", "ccmp", "locl", "isol", "fina", "fin2",
    "fin3", "medi", "med2", "init", "rlig", "calt", "liga", "clig", "mset"]
  var uBit = am.nextBit
  for f in userFeatures:
    if f.value == 0u32:
      continue
    var covered = false
    for t in arabAutoGsub:
      if f.tag.toU32() == tagFromStr(t).toU32():
        covered = true
        break
    if covered:
      continue
    let (m, v) = allocMaskBit(uBit, f.value)
    if m == 0u32:
      continue
    let lks = block:
      var r: seq[uint16] = @[]
      for (tag, ks) in available:
        if tag == f.tag.toU32():
          r = ks
          break
      r
    if lks.len == 0:
      continue
    buf.setMasks(v, m, f.start, f.stop)
    buf.applySubstLookups(gsub, lks, m)

proc applyArabicFallback*(buf: var Buffer, sf: ShaperFont,
    am: ArabicMasks) =
  ## Fallback when the font has no GSUB: synthesize presentation forms.
  let nominal = proc(cp: uint32): Option[GlyphId] = sf.nominalGlyph(cp)
  const arabTags = ["isol", "fina", "fin2", "fin3", "medi", "med2", "init"]
  for fi in 0 ..< 4:
    let mappings = buildFallbackSingles(nominal, fi)
    var featTag = ""
    case fi
    of 0: featTag = "init"
    of 1: featTag = "medi"
    of 2: featTag = "fina"
    else: featTag = "isol"
    var m = 0u32
    for ai, at in arabTags:
      if at == featTag:
        m = am.actions[ai]
        break
    if m != 0u32:
      buf.applyFallbackSingle(mappings, m)
  let lig3 = buildFallbackLigs(nominal, true, false)
  let lig2 = buildFallbackLigs(nominal, false, false)
  let ligM = buildFallbackLigs(nominal, false, true)
  buf.applyFallbackLig(lig3, am.rligMask, true)
  buf.applyFallbackLig(lig2, am.rligMask, true)
  buf.applyFallbackLig(ligM, am.rligMask, false)

proc applyDefaultGpos*(buf: var Buffer, gpos: GposData, scriptTag,
    langTag: Tag, userFeatures: openArray[Feature], scale: Scale) =
  ## Applies mark/mkmk/curs/dist/abvm/blwm by default plus user features.
  const autoTags = ["abvm", "blwm", "mark", "mkmk", "curs", "dist"]
  let available = gposFeaturesFor(gpos, scriptTag, langTag)
  var nextBit = 8u32
  var autoMasks: array[6, tuple[mask, val: uint32]]
  for i in 0 ..< 6:
    autoMasks[i] = allocMaskBit(nextBit, 1u32)
  for i, t in autoTags:
    let (m, v) = autoMasks[i]
    if m == 0u32:
      continue
    let tagU = tagFromStr(t).toU32()
    var lks: seq[uint16] = @[]
    for (tag, ks) in available:
      if tag == tagU:
        lks = ks
        break
    if lks.len == 0:
      continue
    buf.setMasks(v, m, GlobalStart, GlobalEnd)
    buf.applyPosLookups(gpos, lks, m, scale)
  # User-requested GPOS (kern etc) with shared allocation above arabic bits.
  # Features already applied above with automatic masks are skipped.
  var uBit = nextBit
  for f in userFeatures:
    if f.value == 0u32:
      continue
    var covered = false
    for t in autoTags:
      if f.tag.toU32() == tagFromStr(t).toU32():
        covered = true
        break
    if covered:
      continue
    let (m, v) = allocMaskBit(uBit, f.value)
    if m == 0u32:
      continue
    var lks: seq[uint16] = @[]
    for (tag, ks) in available:
      if tag == f.tag.toU32():
        lks = ks
        break
    if lks.len == 0:
      continue
    buf.setMasks(v, m, f.start, f.stop)
    buf.applyPosLookups(gpos, lks, m, scale)

proc zeroMarkWidths*(buf: var Buffer, adjust: bool) =
  let horiz = buf.direction.isHorizontal()
  for i in 0 ..< min(buf.len, buf.info.len):
    if i >= buf.pos.len:
      break
    if buf.info[i].isMarkGlyph():
      if adjust:
        if horiz:
          buf.pos[i].xOffset -= buf.pos[i].xAdvance
        else:
          buf.pos[i].yOffset -= buf.pos[i].yAdvance
      buf.pos[i].xAdvance = 0i32
      buf.pos[i].yAdvance = 0i32

proc recategorizeMarks*(buf: var Buffer) =
  for i in 0 ..< min(buf.len, buf.info.len):
    if buf.info[i].generalCategory() == GcNonSpacingMark:
      var c = buf.info[i].modifiedCombiningClass()
      case c
      of 27u8, 28u8, 30u8, 31u8, 33u8, 34u8, 35u8, 36u8:
        buf.info[i].setModifiedCombiningClass(CcAbove)
      of 29u8, 32u8:
        buf.info[i].setModifiedCombiningClass(CcBelow)
      else:
        discard

proc hideDefaultIgnorables(buf: var Buffer, sf: ShaperFont) =
  ## Mirrors harfrust hide_default_ignorables: default ignorables take
  ## the space glyph when the font has one (else they are deleted),
  ## unless preservation or removal was requested.
  if (buf.scratchFlags and ScratchFlagHasDefaultIgnorables) == 0u32:
    return
  if buf.flags.contains(PreserveDefaultIgnorables):
    return
  if buf.flags.contains(RemoveDefaultIgnorables):
    buf.deleteGlyphsInplace(isInfoDefaultIgnorable)
    return
  let space = sf.nominalGlyph(0x20u32)
  if space.isSome:
    for i in 0 ..< min(buf.len, buf.info.len):
      if buf.info[i].isInfoDefaultIgnorable():
        buf.info[i].glyphId = space.get.value
  else:
    buf.deleteGlyphsInplace(isInfoDefaultIgnorable)

proc zeroWidthDefaultIgnorables*(buf: var Buffer) =
  ## Mirrors harfrust zero_width_default_ignorables.
  if (buf.scratchFlags and ScratchFlagHasDefaultIgnorables) == 0u32:
    return
  if buf.flags.contains(PreserveDefaultIgnorables):
    return
  if buf.flags.contains(RemoveDefaultIgnorables):
    return
  let horiz = buf.direction.isHorizontal()
  for i in 0 ..< min(buf.len, buf.info.len):
    if i >= buf.pos.len:
      break
    if buf.info[i].isInfoDefaultIgnorable():
      buf.pos[i].xAdvance = 0i32
      buf.pos[i].yAdvance = 0i32
      if horiz:
        buf.pos[i].xOffset = 0i32
      else:
        buf.pos[i].yOffset = 0i32

proc fallbackPositionMarks*(buf: var Buffer, sf: ShaperFont) =
  ## Simplified HarfBuzz fallback mark positioning for horizontal text:
  ## center above/below marks over the previous base using extents.
  if not buf.direction.isHorizontal():
    return
  let yGap = sf.scale.scaleY(int32(sf.unitsPerEm) div 16)
  var i = 0
  while i < min(buf.len, buf.info.len):
    if not buf.info[i].isMarkGlyph():
      inc i
      continue
    # Find base: previous non-mark glyph.
    var b = i - 1
    while b >= 0 and buf.info[b].isMarkGlyph():
      dec b
    if b < 0:
      inc i
      continue
    let baseGid = newGlyphId(buf.info[b].glyphId)
    let markGid = newGlyphId(buf.info[i].glyphId)
    let baseExt = sf.glyphExtents(baseGid)
    let markExt = sf.glyphExtents(markGid)
    if baseExt.isNone or markExt.isNone:
      buf.pos[i].xAdvance = 0i32
      buf.pos[i].yAdvance = 0i32
      inc i
      continue
    let be = baseExt.get
    let me = markExt.get
    let cc = buf.info[i].modifiedCombiningClass()
    var xOff = be.xBearing + (be.width - me.width) div 2 - me.xBearing
    # Left/right variants.
    case cc
    of CcAttachedBelowLeft, CcBelowLeft, CcAboveLeft:
      xOff = be.xBearing - me.xBearing
    of CcAttachedAboveRight, CcBelowRight, CcAboveRight:
      xOff = be.xBearing + be.width - me.width - me.xBearing
    of CcDoubleBelow, CcDoubleAbove:
      if buf.direction.isForward():
        xOff = be.xBearing + be.width - me.width div 2 - me.xBearing
      else:
        xOff = be.xBearing - me.width div 2 - me.xBearing
    else:
      discard
    var yOff = 0i32
    case cc
    of CcBelowLeft, CcBelow, CcBelowRight, CcAttachedBelowLeft,
        CcAttachedBelow, CcDoubleBelow:
      yOff = (be.yBearing + be.height) - me.yBearing - yGap
      if (yGap > 0) == (yOff > 0):
        yOff = 0i32
    of CcAboveLeft, CcAbove, CcAboveRight, CcAttachedAbove,
        CcAttachedAboveRight, CcDoubleAbove:
      yOff = be.yBearing - (me.yBearing + me.height) + yGap
    else:
      yOff = be.yBearing - (me.yBearing + me.height) + yGap
    buf.pos[i].xOffset = xOff
    buf.pos[i].yOffset = yOff
    buf.pos[i].xAdvance = 0i32
    buf.pos[i].yAdvance = 0i32
    inc i

proc shapePlan*(font: ShaperFont, buf: var Buffer,
    features: openArray[Feature]): ShapePlan =
  buf.guessSegmentProperties()
  newShapePlan(scriptTagForBuffer(buf), langTagForBuffer(buf), features)

proc shapeWithPlan*(font: ShaperFont, buf: var Buffer, plan: ShapePlan) =
  buf.guessSegmentProperties()
  let sf = font
  let useArabic = isArabicShaperScript(buf)
  buf.allocateUnicodeVars()
  var scratch = buf.scratchFlags
  for i in 0 ..< buf.len:
    if i < buf.info.len:
      buf.info[i].initUnicodeProps(scratch)
  buf.scratchFlags = scratch
  insertDottedCircle(buf)
  formClusters(buf)
  # TODO: ensure_native_direction, per-syllable matching.
  var nctx = sf.normalizeContextFor()
  buf.normalize(nmComposedDiacritics, false, nctx)
  buf.deallocateUnicodeVars()
  # Arabic joining + mark reordering happen on Unicode codepoints.
  var arabicMasks: ArabicMasks
  var haveArabicMasks = false
  if useArabic:
    arabicMasks = buf.prepareArabicMasks()
    haveArabicMasks = true
    if buf.len > 1:
      buf.reorderMarksArabic(0, min(buf.len, buf.info.len))
  buf.mapGlyphsFast()
  buf.setContentType(some(contentGlyphs))
  buf.allocateGsubGposVars()
  synthesizeGlyphClasses(buf)
  recategorizeMarks(buf)
  let gsubOpt = parseGsub(sf.font)
  if useArabic and haveArabicMasks:
    if gsubOpt.isSome:
      buf.applyArabicGsub(gsubOpt.get, plan.scriptTag, plan.langTag,
        plan.features, sf, arabicMasks)
    else:
      buf.applyArabicFallback(sf, arabicMasks)
  else:
    if gsubOpt.isSome:
      buf.applyGsubFeatures(gsubOpt.get, plan.scriptTag, plan.langTag,
        plan.features)
  buf.hideDefaultIgnorables(sf)
  buf.clearPositions()
  buf.positionStart()
  setBaseAdvances(buf, sf)
  let gposOpt = parseGpos(sf.font)
  if gposOpt.isSome:
    if useArabic:
      buf.applyDefaultGpos(gposOpt.get, plan.scriptTag, plan.langTag,
        plan.features, sf.scale)
    else:
      buf.applyGposFeatures(gposOpt.get, plan.scriptTag, plan.langTag,
        plan.features, sf.scale)
  # Legacy `kern` table, mirroring harfrust position_by_plan: it runs
  # after GPOS when kerning was requested but GPOS supplied no kern
  # feature for the script.
  let kernTag = if buf.direction.isHorizontal(): tagFromStr("kern")
    else: tagFromStr("vkrn")
  var kernRequested = false
  for f in plan.features:
    if f.tag.toU32() == kernTag.toU32() and f.value != 0u32:
      kernRequested = true
      break
  var kernRan = false
  var hasCrossKern = false
  if kernRequested:
    let kernOpt = parseKern(sf.font)
    if kernOpt.isSome and kernOpt.get.subtables.len > 0:
      var hasGposKern = false
      if gposOpt.isSome:
        for (tg, _) in gposFeaturesFor(gposOpt.get, plan.scriptTag,
            plan.langTag):
          if tg == kernTag.toU32():
            hasGposKern = true
            break
      if not hasGposKern:
        for sub in kernOpt.get.subtables:
          if sub.crossStream:
            hasCrossKern = true
        buf.applyKernTable(kernOpt.get, KernWalkMask, sf.scale)
        kernRan = true
  # Fallback mark positioning runs only when neither GPOS nor legacy
  # kern positioning applied, mirroring harfrust position_by_plan
  # (adjust_mark_positioning_when_zeroing).
  let fallbackAllowed = not gposOpt.isSome and
    (not kernRan or not hasCrossKern)
  # Late mark zeroing (arabic/hebrew/default) when GPOS did not attach.
  if (buf.scratchFlags and ScratchFlagHasGposAttachment) == 0u32:
    buf.zeroMarkWidths(buf.direction.isForward())
  buf.zeroWidthDefaultIgnorables()
  buf.propagateAttachmentOffsets()
  if (buf.scratchFlags and ScratchFlagHasGposAttachment) == 0u32 and
      fallbackAllowed:
    # Fallback mark positioning when no GPOS attachment happened.
    buf.fallbackPositionMarks(sf)
  else:
    # Marks without GPOS attachment still get zero advances.
    for i in 0 ..< min(buf.len, buf.info.len):
      if i < buf.pos.len and buf.info[i].isMarkGlyph():
        if buf.pos[i].attachChain() == 0i16:
          buf.pos[i].xAdvance = 0i32
          buf.pos[i].yAdvance = 0i32
  if buf.direction.isBackward():
    buf.reverse()
  # TODO: fallback spaces.
  buf.deallocateGsubGposVars()

proc shape*(font: ShaperFont, buf: var Buffer,
    features: openArray[Feature] = []) =
  let plan = shapePlan(font, buf, features)
  shapeWithPlan(font, buf, plan)
