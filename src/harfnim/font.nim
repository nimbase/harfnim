import std/options

import ./buffer
import ./draw
import ./normalize
import ./scale
import ./sfnt
import ./variations

export scale
export sfnt
export draw
export variations

type
  ShaperFont* = object
    font*: SfntFont
    unitsPerEm*: uint16
    scale*: Scale
    outlineCache*: OutlineCache
    varCoords*: seq[float32]
    # TODO: FontFuncs overrides (custom nominal/metrics callbacks)
    # TODO: OT/AAT layout caches, cmap cache

proc newShaperFont*(font: SfntFont): ShaperFont =
  ShaperFont(
    font: font,
    unitsPerEm: font.unitsPerEm,
    scale: identityScale(int32(font.unitsPerEm)),
    outlineCache: newOutlineCache(),
    varCoords: newSeq[float32](font.fvarAxes.len),
  )

proc setScale*(f: var ShaperFont, scale: int32) =
  f.scale = newScale(scale, scale, int32(f.unitsPerEm))

proc setScaleSeparate*(f: var ShaperFont, xScale, yScale: int32) =
  f.scale = newScale(xScale, yScale, int32(f.unitsPerEm))

proc setVariations*(f: var ShaperFont,
    vars: openArray[tuple[tag: uint32, value: float32]]) =
  ## Sets the variation location from user-space axis values. Unknown
  ## tags are ignored; unspecified axes reset to default. Cached
  ## outlines are keyed by glyph only, so the cache is replaced to
  ## avoid serving default-location outlines at the new location
  ## (copies holding the old handle keep their own location's cache).
  f.varCoords = normalizeCoords(f.font.fvarAxes, f.font.avarMaps, vars)
  f.outlineCache = newOutlineCache(f.outlineCache.maxItems)

proc normalizedCoords*(f: ShaperFont): seq[float32] =
  f.varCoords

proc nominalGlyph*(f: ShaperFont, cp: uint32): Option[GlyphId] =
  f.font.mapUnicode(cp)

proc nominalGlyphs*(f: ShaperFont, infos: var seq[GlyphInfo], first,
    last: int): int =
  result = 0
  for i in first ..< last:
    if i < 0 or i >= infos.len:
      break
    let gid = f.nominalGlyph(infos[i].glyphId)
    if gid.isNone:
      break
    infos[i].setNormalizerGlyphIndex(gid.get.value)
    inc result

proc variationGlyph*(f: ShaperFont, base, selector: uint32): Option[GlyphId] =
  f.font.mapUnicodeVariant(base, selector)

proc hAdvance*(f: ShaperFont, gid: GlyphId): int32 =
  f.scale.clampXAdvance(f.scale.scaleX(f.font.hAdvance(gid.value)))

proc vAdvance*(f: ShaperFont, gid: GlyphId): int32 =
  let v = f.scale.clampYAdvance(f.scale.scaleY(f.font.vAdvance(gid.value)))
  if v == low(int32): high(int32) else: -v

proc drawGlyph*(f: ShaperFont, gid: GlyphId,
    cb: proc(op: DrawOp) {.closure.}): bool =
  ## Cached outline emission. Hits replay the stored outline; misses
  ## decode once and store the result (including failures). The cache
  ## lives behind a ref so it works through value copies of the font.
  let (hit, v) = cacheLookup(f.outlineCache, gid.value)
  if hit:
    if v.isNone:
      return false
    replayOutline(v.get, cb)
    return true
  var b = OutlineBuilder()
  let ok = b.collectInto(proc(
      c: proc(op: DrawOp) {.closure.}): bool =
    f.font.drawGlyph(gid.value, c, f.varCoords))
  let o = b.finish()
  cacheStore(f.outlineCache, gid.value,
    if ok: some(o) else: none(GlyphOutline))
  if not ok:
    return false
  replayOutline(o, cb)
  true

proc glyphOutline*(f: ShaperFont, gid: GlyphId): Option[GlyphOutline] =
  ## Cached value outline.
  let (hit, v) = cacheLookup(f.outlineCache, gid.value)
  if hit:
    return v
  var b = OutlineBuilder()
  let ok = b.collectInto(proc(
      c: proc(op: DrawOp) {.closure.}): bool =
    f.font.drawGlyph(gid.value, c, f.varCoords))
  let o = if ok: some(b.finish()) else: none(GlyphOutline)
  cacheStore(f.outlineCache, gid.value, o)
  o

proc glyphBoundsComputedCached*(f: ShaperFont,
    gid: GlyphId): Option[tuple[xMin, yMin, xMax, yMax: int32]] =
  let o = f.glyphOutline(gid)
  if o.isNone:
    return none(tuple[xMin, yMin, xMax, yMax: int32])
  outlineBounds(o.get)

proc isVaried*(f: ShaperFont): bool =
  ## True when a non-default variation location is active.
  for v in f.varCoords:
    if v != 0.0f32:
      return true
  false

proc glyphExtents*(f: ShaperFont, gid: GlyphId): Option[GlyphExtents] =
  if not f.isVaried() or not f.font.hasGvar():
    let b = f.font.glyphBoundsUnscaled(gid.value)
    if b.isSome:
      let (xMin, yMin, xMax, yMax) = b.get
      return some(f.scale.scaleExtents(GlyphExtents(xBearing: xMin,
        yBearing: yMax, width: xMax - xMin, height: yMin - yMax)))
  # Header box unavailable (composite glyph or CFF outlines) or the
  # location is varied: fall back to the decoded outline bounds.
  # TODO: metric variations (HVAR/MVAR) for advances.
  let cb = f.glyphBoundsComputedCached(gid)
  if cb.isNone:
    return none(GlyphExtents)
  let (xMin, yMin, xMax, yMax) = cb.get
  some(f.scale.scaleExtents(GlyphExtents(xBearing: xMin, yBearing: yMax,
    width: xMax - xMin, height: yMin - yMax)))

proc hasGlyph*(f: ShaperFont, cp: uint32): bool =
  f.nominalGlyph(cp).isSome

proc normalizeContextFor*(f: ShaperFont): NormalizeContext =
  let ff = f
  newNormalizeContext(
    nominalGlyph = proc(cp: uint32): Option[GlyphId] = ff.nominalGlyph(cp),
    nominalGlyphs = proc(infos: var seq[GlyphInfo], first,
        last: int): int =
      ff.nominalGlyphs(infos, first, last),
    variationGlyph = proc(base, selector: uint32): Option[GlyphId] =
      ff.variationGlyph(base, selector),
  )
