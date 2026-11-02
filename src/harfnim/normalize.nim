import std/options

import ./buffer
import ./unicode

const MaxCombiningMarks* = 32

type
  NormalizationMode* = enum
    nmNone
    nmDecomposed
    nmComposedDiacritics
    nmComposedDiacriticsNoShortCircuit
    nmAuto

  DecomposeFn* = proc(ab: uint32): Option[tuple[a, b: uint32]] {.closure.}
  ComposeFn* = proc(a, b: uint32): Option[uint32] {.closure.}
  ReorderMarksFn* = proc(buf: var Buffer, first, last: int) {.closure.}
  NominalGlyphFn* = proc(cp: uint32): Option[GlyphId] {.closure.}
  NominalGlyphsFn* = proc(infos: var seq[GlyphInfo], first, last: int): int {.closure.}
  VariationGlyphFn* = proc(base, selector: uint32): Option[GlyphId] {.closure.}

  NormalizeContext* = object
    nominalGlyph*: NominalGlyphFn
    nominalGlyphs*: NominalGlyphsFn
    variationGlyph*: VariationGlyphFn
    decomposeFn*: DecomposeFn
    composeFn*: ComposeFn
    reorderMarks*: Option[ReorderMarksFn]

proc defaultDecompose(ab: uint32): Option[tuple[a, b: uint32]] =
  let d = decomposeImpl(ab)
  if d.isNone:
    none(tuple[a, b: uint32])
  else:
    some(d.get)

proc defaultCompose(a, b: uint32): Option[uint32] =
  composeImpl(a, b)

proc newNormalizeContext*(
    nominalGlyph: NominalGlyphFn,
    nominalGlyphs: NominalGlyphsFn,
    variationGlyph: VariationGlyphFn,
    decompose: Option[DecomposeFn] = none(DecomposeFn),
    compose: Option[ComposeFn] = none(ComposeFn),
    reorderMarks: Option[ReorderMarksFn] = none(ReorderMarksFn),
): NormalizeContext =
  NormalizeContext(
    nominalGlyph: nominalGlyph,
    nominalGlyphs: nominalGlyphs,
    variationGlyph: variationGlyph,
    decomposeFn: decompose.get(defaultDecompose),
    composeFn: compose.get(defaultCompose),
    reorderMarks: reorderMarks,
  )

proc outputChar(buf: var Buffer, unichar, glyph: uint32) =
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return
  cur[].setNormalizerGlyphIndex(glyph)
  buf.outputGlyph(unichar)
  let prev = buf.prevMut()
  if prev == nil:
    buf.indexFailed()
    return
  var flags = buf.scratchFlags
  prev[].initUnicodeProps(flags)
  buf.scratchFlags = flags

proc nextChar(buf: var Buffer, glyph: uint32) =
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return
  cur[].setNormalizerGlyphIndex(glyph)
  buf.nextGlyph()

proc skipChar(buf: var Buffer) =
  buf.skipGlyph()

proc setCurrentGlyph(ctx: NormalizeContext, buf: var Buffer) =
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return
  let gid = ctx.nominalGlyph(cur[].glyphId)
  if gid.isSome:
    cur[].setNormalizerGlyphIndex(gid.get.value)

proc decomposeRec(ctx: NormalizeContext, buf: var Buffer, shortest: bool,
    ab: uint32): uint32 =
  let d = ctx.decomposeFn(ab)
  if d.isNone:
    return 0
  let a = d.get.a
  let b = d.get.b
  let aGlyph = ctx.nominalGlyph(a)
  var bGlyph: Option[GlyphId]
  if b != 0u32:
    let bg = ctx.nominalGlyph(b)
    if bg.isNone:
      return 0
    bGlyph = bg
  if aGlyph.isSome and shortest:
    outputChar(buf, a, aGlyph.get.value)
    if bGlyph.isSome:
      outputChar(buf, b, bGlyph.get.value)
      return 2
    return 1
  let ret = decomposeRec(ctx, buf, shortest, a)
  if ret != 0:
    if bGlyph.isSome:
      outputChar(buf, b, bGlyph.get.value)
      return ret + 1
    return ret
  if aGlyph.isSome:
    outputChar(buf, a, aGlyph.get.value)
    if bGlyph.isSome:
      outputChar(buf, b, bGlyph.get.value)
      return 2
    return 1
  0

proc decomposeCurrentCharacter(ctx: NormalizeContext, buf: var Buffer,
    shortest: bool) =
  let cur = buf.cur(0)
  if cur == nil:
    buf.indexFailed()
    return
  let u = cur[].asCodepoint()
  let glyph = ctx.nominalGlyph(u)
  if glyph.isSome and shortest:
    nextChar(buf, glyph.get.value)
    return
  if decomposeRec(ctx, buf, shortest, u) > 0:
    skipChar(buf)
    return
  if glyph.isSome:
    nextChar(buf, glyph.get.value)
    return
  let cur2 = buf.cur(0)
  if cur2 != nil and cur2[].isUnicodeSpace():
    let spaceType = spaceFallback(u)
    if spaceType != SpaceNotSpace:
      let direct = ctx.nominalGlyph(0x0020u32)
      let spaceGlyph =
        if direct.isSome: direct else: buf.invisibleGlyph()
      if spaceGlyph.isSome:
        let m = buf.cur(0)
        if m == nil:
          buf.indexFailed()
          return
        m[].setUnicodeSpaceFallbackType(spaceType)
        nextChar(buf, spaceGlyph.get.value)
        buf.scratchFlags = buf.scratchFlags or ScratchFlagHasSpaceFallback
        return
  if u == 0x2011u32:
    let other = ctx.nominalGlyph(0x2010u32)
    if other.isSome:
      nextChar(buf, other.get.value)
      return
  nextChar(buf, 0u32)

proc handleVariationSelectorCluster(ctx: NormalizeContext, buf: var Buffer,
    stop: int) =
  while buf.idx < stop - 1 and buf.successful:
    let n1 = buf.cur(1)
    if n1 == nil or not isVariationSelector(n1[].asCodepoint()):
      setCurrentGlyph(ctx, buf)
      buf.nextGlyph()
    else:
      let c0 = buf.cur(0)
      if c0 == nil:
        buf.indexFailed()
        return
      let base = c0[].asCodepoint()
      let selector = n1[].asCodepoint()
      let gid = ctx.variationGlyph(base, selector)
      if gid.isSome:
        let m = buf.cur(0)
        if m == nil:
          buf.indexFailed()
          return
        m[].setNormalizerGlyphIndex(gid.get.value)
        let uni = m[].glyphId
        buf.replaceGlyphs(2, 1, [uni])
      else:
        setCurrentGlyph(ctx, buf)
        buf.nextGlyph()
        buf.scratchFlags =
          buf.scratchFlags or ScratchFlagHasVariationSelectorFallback
        let v = buf.cur(0)
        if v == nil:
          buf.indexFailed()
          return
        v[].setVariationSelector(true)
        if buf.notFoundVsGlyph().isSome:
          v[].clearDefaultIgnorable()
        setCurrentGlyph(ctx, buf)
        buf.nextGlyph()
      while buf.idx < stop:
        let c = buf.cur(0)
        if c == nil or not isVariationSelector(c[].asCodepoint()):
          break
        setCurrentGlyph(ctx, buf)
        buf.nextGlyph()
  if buf.idx < stop:
    setCurrentGlyph(ctx, buf)
    buf.nextGlyph()

proc decomposeMultiCharCluster(ctx: NormalizeContext, buf: var Buffer,
    stop: int, shortCircuit: bool) =
  var i = buf.idx
  while i < stop and buf.successful:
    if i < buf.info.len and
        isVariationSelector(buf.info[i].asCodepoint()):
      handleVariationSelectorCluster(ctx, buf, stop)
      return
    inc i
  while buf.idx < stop and buf.successful:
    decomposeCurrentCharacter(ctx, buf, shortCircuit)

proc compareCombiningClass(a, b: GlyphInfo): bool =
  a.modifiedCombiningClass() > b.modifiedCombiningClass()

proc normalize*(buf: var Buffer, mode: NormalizationMode, hasGposMark: bool,
    ctx: NormalizeContext) =
  if buf.isEmpty():
    return
  var resolved = mode
  if resolved == nmAuto:
    resolved = nmComposedDiacritics
  let alwaysShortCircuit = resolved == nmNone
  let mightShortCircuit = alwaysShortCircuit or
    (resolved != nmDecomposed and
      resolved != nmComposedDiacriticsNoShortCircuit)

  var allSimple = true
  buf.clearOutput()
  let count = buf.len
  buf.idx = 0
  while true:
    var stop = buf.idx + 1
    while stop < count and stop < buf.info.len and
        not buf.info[stop].isUnicodeMark():
      inc stop
    if stop < count:
      dec stop
    if mightShortCircuit:
      let idx = buf.idx
      let done =
        if idx < buf.info.len:
          ctx.nominalGlyphs(buf.info, idx, min(stop, buf.info.len))
        else:
          0
      buf.nextGlyphs(done)
    while buf.idx < stop and buf.successful:
      decomposeCurrentCharacter(ctx, buf, mightShortCircuit)
    if buf.idx == count or not buf.successful:
      break
    allSimple = false
    stop = buf.idx + 1
    while stop < count and stop < buf.info.len and
        buf.info[stop].isUnicodeMark():
      inc stop
    decomposeMultiCharCluster(ctx, buf, stop, alwaysShortCircuit)
    if buf.idx >= count or not buf.successful:
      break
  discard buf.sync()

  if not allSimple:
    let reorderCount = buf.len
    var i = 0
    while i < reorderCount:
      if i >= buf.info.len or buf.info[i].modifiedCombiningClass() == 0u8:
        inc i
        continue
      var stop = i + 1
      while stop < reorderCount and stop < buf.info.len and
          buf.info[stop].modifiedCombiningClass() != 0u8:
        inc stop
      if stop - i <= MaxCombiningMarks:
        buf.sort(i, stop, compareCombiningClass)
        if ctx.reorderMarks.isSome:
          ctx.reorderMarks.get()(buf, i, stop)
      i = stop + 1
  if (buf.scratchFlags and ScratchFlagHasCgj) != 0u32:
    for i in 1 ..< buf.len - 1:
      if i - 1 < 0 or i + 1 >= buf.info.len:
        continue
      if buf.info[i].glyphId == 0x034Fu32:
        let last = buf.info[i - 1].modifiedCombiningClass()
        let next = buf.info[i + 1].modifiedCombiningClass()
        if next == 0u8 or last <= next:
          buf.info[i].unhide()

  if not allSimple and buf.successful and
      (resolved == nmComposedDiacritics or
        resolved == nmComposedDiacriticsNoShortCircuit):
    let composeCount = buf.len
    var starter = 0
    buf.clearOutput()
    buf.nextGlyph()
    while buf.idx < composeCount and buf.successful:
      let cur = buf.cur(0)
      if cur == nil:
        buf.indexFailed()
        break
      let prev = buf.prev()
      if cur[].isUnicodeMark() and
          (starter == buf.outLen - 1 or
            (prev != nil and
              prev[].modifiedCombiningClass() < cur[].modifiedCombiningClass())):
        let starterInfo = buf.outAt(starter)
        var composed: Option[uint32]
        if starterInfo != nil:
          composed = ctx.composeFn(starterInfo[].asCodepoint(), cur[].asCodepoint())
        if composed.isSome:
          let gid = ctx.nominalGlyph(composed.get)
          if gid.isSome:
            buf.nextGlyph()
            if not buf.successful:
              return
            buf.mergeOutClusters(starter, buf.outLen)
            dec buf.outLen
            let slot = buf.outAt(starter)
            if slot == nil:
              buf.indexFailed()
              return
            slot[].glyphId = composed.get
            slot[].setNormalizerGlyphIndex(gid.get.value)
            var flags = buf.scratchFlags
            slot[].initUnicodeProps(flags)
            buf.scratchFlags = flags
            continue
      buf.nextGlyph()
      let p = buf.prev()
      if p != nil and p[].modifiedCombiningClass() == 0u8:
        starter = buf.outLen - 1
    discard buf.sync()
