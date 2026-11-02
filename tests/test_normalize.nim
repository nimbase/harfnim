import std/options
import unittest

import harfnim

proc identityGlyph(cp: uint32): Option[GlyphId] =
  if cp <= 0xFFFFu32: some(newGlyphId(cp)) else: none(GlyphId)

proc identityGlyphs(infos: var seq[GlyphInfo], first, last: int): int =
  result = 0
  for i in first ..< last:
    let cp = infos[i].glyphId
    if cp > 0xFFFFu32:
      break
    infos[i].setNormalizerGlyphIndex(cp)
    inc result

proc noGlyph(cp: uint32): Option[GlyphId] =
  none(GlyphId)

proc noGlyphs(infos: var seq[GlyphInfo], first, last: int): int =
  0

proc noVariation(base, selector: uint32): Option[GlyphId] =
  none(GlyphId)

proc identityCtx(): NormalizeContext =
  newNormalizeContext(identityGlyph, identityGlyphs, noVariation)

test "passthrough ascii":
  var b = newBuffer()
  b.pushStr("hello")
  for i in 0 ..< b.len:
    var scratch = 0u32
    b.info[i].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = identityCtx()
  ctx.nominalGlyphs = identityGlyphs
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 5
  let infos = b.glyphInfosView()
  check infos[0].glyphId == 0x68u32
  check infos[0].normalizerGlyphIndex() == 0x68u32
  b.deallocateUnicodeVars()

test "decompose precomposed":
  var nom: NominalGlyphFn = proc(cp: uint32): Option[GlyphId] =
    if cp == 0xC0u32: none(GlyphId) else: identityGlyph(cp)
  var noms: NominalGlyphsFn = proc(infos: var seq[GlyphInfo], first,
      last: int): int =
    result = 0
    for i in first ..< last:
      if infos[i].glyphId == 0xC0u32:
        break
      infos[i].setNormalizerGlyphIndex(infos[i].glyphId)
      inc result
  var b = newBuffer()
  b.push(0xC0u32, 0)
  var scratch = 0u32
  b.info[0].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = newNormalizeContext(nom, noms, noVariation)
  b.normalize(nmDecomposed, false, ctx)
  check b.len == 2
  let infos = b.glyphInfosView()
  check infos[0].glyphId == 0x41u32
  check infos[1].glyphId == 0x300u32
  check infos[0].cluster == 0u32
  check infos[1].cluster == 0u32
  b.deallocateUnicodeVars()

test "recompose base plus mark":
  var b = newBuffer()
  b.push(0x41u32, 0)
  b.push(0x301u32, 1)
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = identityCtx()
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 1
  let infos = b.glyphInfosView()
  check infos[0].glyphId == 0xC1u32
  check infos[0].normalizerGlyphIndex() == 0xC1u32
  check infos[0].cluster == 0u32
  b.deallocateUnicodeVars()

test "reorder marks by combining class":
  var b = newBuffer()
  b.push(0x62u32, 0)
  b.push(0x301u32, 1)
  b.push(0x327u32, 2)
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = identityCtx()
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 3
  let infos = b.glyphInfosView()
  check infos[0].glyphId == 0x62u32
  check infos[1].glyphId == 0x327u32
  check infos[2].glyphId == 0x301u32
  b.deallocateUnicodeVars()

test "space fallback":
  var nom: NominalGlyphFn = proc(cp: uint32): Option[GlyphId] =
    if cp == 0xA0u32: none(GlyphId) else: identityGlyph(cp)
  var noms: NominalGlyphsFn = proc(infos: var seq[GlyphInfo], first,
      last: int): int =
    result = 0
    for i in first ..< last:
      if infos[i].glyphId == 0xA0u32:
        break
      infos[i].setNormalizerGlyphIndex(infos[i].glyphId)
      inc result
  var b = newBuffer()
  b.push(0xA0u32, 0)
  var scratch = 0u32
  b.info[0].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = newNormalizeContext(nom, noms, noVariation)
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 1
  check b.glyphInfosView()[0].glyphId == 0xA0u32
  check b.glyphInfosView()[0].normalizerGlyphIndex() == 0x20u32
  check b.glyphInfosView()[0].unicodeSpaceFallbackType() == SpaceSpace
  check (b.scratchFlags and ScratchFlagHasSpaceFallback) != 0u32
  b.deallocateUnicodeVars()

test "variation selector cluster":
  var vs: VariationGlyphFn = proc(base, selector: uint32): Option[GlyphId] =
    if base == 0x4E00u32 and selector == 0xFE00u32:
      some(newGlyphId(700))
    else:
      none(GlyphId)
  var b = newBuffer()
  b.push(0x4E00u32, 0)
  b.push(0xFE00u32, 1)
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = newNormalizeContext(identityGlyph, identityGlyphs, vs)
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 1
  check b.glyphInfosView()[0].glyphId == 0x4E00u32
  check b.glyphInfosView()[0].normalizerGlyphIndex() == 700u32
  b.deallocateUnicodeVars()

test "missing glyph becomes notdef":
  var b = newBuffer()
  b.push(0x41u32, 0)
  var scratch = 0u32
  b.info[0].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = newNormalizeContext(noGlyph, noGlyphs, noVariation)
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 1
  check b.glyphInfosView()[0].glyphId == 0x41u32
  check b.glyphInfosView()[0].normalizerGlyphIndex() == 0u32
  b.deallocateUnicodeVars()

test "mode none keeps decomposed form":
  var b = newBuffer()
  b.push(0x41u32, 0)
  b.push(0x301u32, 1)
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = identityCtx()
  b.normalize(nmNone, false, ctx)
  check b.len == 2
  check b.glyphInfosView()[1].glyphId == 0x301u32
  b.deallocateUnicodeVars()

test "glyph info unicode helpers":
  var m = GlyphInfo(glyphId: 0x300u32)
  var scratch = 0u32
  m.initUnicodeProps(scratch)
  check m.isUnicodeMark()
  check (not m.isUnicodeSpace())
  check m.modifiedCombiningClass() == 230u8
  var base = GlyphInfo(glyphId: 0x41u32)
  var s2 = 0u32
  base.initUnicodeProps(s2)
  check (not base.isUnicodeMark())
  check base.modifiedCombiningClass() == 0u8
  base.setModifiedCombiningClass(99u8)
  check base.modifiedCombiningClass() == 0u8
  var sp = GlyphInfo(glyphId: 0x20u32)
  var s3 = 0u32
  sp.initUnicodeProps(s3)
  check sp.isUnicodeSpace()
  check sp.unicodeSpaceFallbackType() == 0u8
  sp.setUnicodeSpaceFallbackType(SpaceEm)
  check sp.unicodeSpaceFallbackType() == SpaceEm
  base.setUnicodeSpaceFallbackType(SpaceEm)
  check base.unicodeSpaceFallbackType() == SpaceNotSpace
  var vs = GlyphInfo(glyphId: 0xFE00u32)
  var s4 = 0u32
  vs.initUnicodeProps(s4)
  vs.setVariationSelector(true)
  check vs.isInfoVariationSelector()
  check vs.generalCategory() == GcFormat
  vs.setVariationSelector(false)
  check vs.generalCategory() == GcNonSpacingMark
  check (not vs.isInfoVariationSelector())
  var ign = GlyphInfo(glyphId: 0x200Bu32)
  var s5 = 0u32
  ign.initUnicodeProps(s5)
  check ign.isInfoDefaultIgnorable()
  ign.clearDefaultIgnorable()
  check (not ign.isInfoDefaultIgnorable())
  check ign.isHidden() == false
  var cgj = GlyphInfo(glyphId: 0x034Fu32)
  var s6 = 0u32
  cgj.initUnicodeProps(s6)
  check cgj.isHidden()
