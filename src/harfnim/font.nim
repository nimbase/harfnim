import std/options

import ./buffer
import ./normalize
import ./scale
import ./sfnt

export scale
export sfnt

type
  ShaperFont* = object
    font*: SfntFont
    unitsPerEm*: uint16
    scale*: Scale
    # TODO: FontFuncs overrides (custom nominal/metrics callbacks)
    # TODO: OT/AAT layout caches, cmap cache, variation coordinates

proc newShaperFont*(font: SfntFont): ShaperFont =
  ShaperFont(
    font: font,
    unitsPerEm: font.unitsPerEm,
    scale: identityScale(int32(font.unitsPerEm)),
  )

proc setScale*(f: var ShaperFont, scale: int32) =
  f.scale = newScale(scale, scale, int32(f.unitsPerEm))

proc setScaleSeparate*(f: var ShaperFont, xScale, yScale: int32) =
  f.scale = newScale(xScale, yScale, int32(f.unitsPerEm))

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
  # TODO: cmap format 14 (Unicode Variation Sequences)
  none(GlyphId)

proc hAdvance*(f: ShaperFont, gid: GlyphId): int32 =
  f.scale.clampXAdvance(f.scale.scaleX(f.font.hAdvance(gid.value)))

proc vAdvance*(f: ShaperFont, gid: GlyphId): int32 =
  let v = f.scale.clampYAdvance(f.scale.scaleY(f.font.vAdvance(gid.value)))
  if v == low(int32): high(int32) else: -v

proc glyphExtents*(f: ShaperFont, gid: GlyphId): Option[GlyphExtents] =
  # TODO: glyf/CFF outline parsing
  none(GlyphExtents)

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
