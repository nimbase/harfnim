import std/options
import unittest

import harfnim

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

proc putI16(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc putTag(s: var seq[uint8], t: string) =
  for c in t:
    s.add(uint8(c))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc putU16At(s: var seq[uint8], pos: int, v: uint16) =
  doAssert pos >= 0 and pos + 2 <= s.len
  s[pos] = uint8(v shr 8)
  s[pos + 1] = uint8(v and 0xFFu16)

proc buildCmapSingle(): seq[uint8] =
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.putU16(4u16)
  result.putU16(32u16)
  result.putU16(0u16)
  result.putU16(4u16)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(0x43u16)
  result.putU16(0xFFFFu16)
  result.putU16(0u16)
  result.putU16(0x41u16)
  result.putU16(0xFFFFu16)
  result.putI16(-64i16)
  result.putI16(1i16)
  result.putU16(0u16)
  result.putU16(0u16)

proc buildFontRaw(tables: seq[tuple[name: string, data: seq[uint8]]]): seq[
    uint8] =
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(64u16)
  result.putU16(2u16)
  result.putU16(48u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    var padded = (data.len + 3) and not 3
    result.putU32(uint32(padded))
    off += padded
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc baseTables(cmap: seq[uint8]): seq[tuple[name: string, data: seq[uint8]]] =
  var head = newSeq[uint8]()
  head.putU32(0x00010000u32)
  head.putU32(0u32)
  head.putU32(0u32)
  head.putU32(0x5F0F3CF5u32)
  head.putU16(0u16)
  head.putU16(1000u16)
  for _ in 0 ..< 4:
    head.putU32(0u32)
  for _ in 0 ..< 4:
    head.putI16(0i16)
  head.putU16(0u16)
  head.putU16(0u16)
  head.putI16(0i16)
  head.putI16(0i16)
  head.putU16(0u16)
  var hhea = newSeq[uint8]()
  hhea.putU32(0x00010000u32)
  hhea.putI16(800i16)
  hhea.putI16(-200i16)
  hhea.putI16(0i16)
  hhea.putU16(600u16)
  for _ in 0 ..< 11:
    hhea.putI16(0i16)
  hhea.putU16(2u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(12u16)
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  var loca = @[0u8, 0u8, 0u8, 0u8]
  @[("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca)]

proc coverageBytes(glyphs: seq[uint16]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(uint16(glyphs.len))
  for g in glyphs:
    result.putU16(g)

proc buildGsubSingleMap(covGlyph, substitute: uint16): seq[uint8] =
  var sub = newSeq[uint8]()
  sub.putU16(2u16)
  sub.putU16(8u16)
  sub.putU16(1u16)
  sub.putU16(substitute)
  for b in coverageBytes(@[covGlyph]):
    sub.add(b)
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(10u16)
  result.putU16(30u16)
  result.putU16(44u16)
  result.putU16(1u16)
  result.putTag("latn")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putTag("smcp")
  result.putU16(8u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(8u16)
  for b in sub:
    result.add(b)

proc buildPairSet(second: uint16, kern: int16): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(second)
  result.putI16(kern)

proc buildGposKern(first, second: uint16, kern: int16): seq[uint8] =
  var pairSet = buildPairSet(second, kern)
  var sub = newSeq[uint8]()
  sub.putU16(1u16)
  let covPos = sub.len
  sub.putU16(0u16)
  sub.putU16(0x0004u16)
  sub.putU16(0u16)
  sub.putU16(1u16)
  let setPos = sub.len
  sub.putU16(0u16)
  let covOff = sub.len
  for b in coverageBytes(@[first]):
    sub.add(b)
  sub.putU16At(covPos, uint16(covOff))
  let setOff = sub.len
  sub.putU16At(setPos, uint16(setOff))
  for b in pairSet:
    sub.add(b)
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(10u16)
  result.putU16(30u16)
  result.putU16(44u16)
  result.putU16(1u16)
  result.putTag("latn")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putTag("kern")
  result.putU16(8u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(4u16)
  result.putU16(2u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(8u16)
  for b in sub:
    result.add(b)

proc fontWith(gsub, gpos: seq[uint8]): seq[uint8] =
  var tables = baseTables(buildCmapSingle())
  if gsub.len > 0:
    tables.add(("GSUB", gsub))
  if gpos.len > 0:
    tables.add(("GPOS", gpos))
  buildFontRaw(tables)

proc shapeText(fontBytes: seq[uint8], text: string,
    feats: seq[Feature]): tuple[gids: seq[uint32], pos: seq[
    tuple[xAdv, xOff, yAdv, yOff: int32]]] =
  let f = parseFont(fontBytes)
  let sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr(text)
  sf.shape(b, feats)
  var gids: seq[uint32] = @[]
  var pos: seq[tuple[xAdv, xOff, yAdv, yOff: int32]] = @[]
  for i in 0 ..< b.len:
    gids.add(b.info[i].glyphId)
    pos.add((b.pos[i].xAdvance, b.pos[i].xOffset, b.pos[i].yAdvance,
      b.pos[i].yOffset))
  (gids, pos)

test "shape applies gsub substitution end to end":
  let fontBytes = fontWith(buildGsubSingleMap(1u16, 10u16), @[])
  let (gids, _) = shapeText(fontBytes, "AB",
    @[globalFeature(tagFromStr("smcp"), 1)])
  check gids == @[10u32, 2u32]

test "shape applies gpos kerning end to end":
  let fontBytes = fontWith(@[], buildGposKern(1u16, 2u16, -80i16))
  let (gids, pos) = shapeText(fontBytes, "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 520i32
  check pos[1].xAdv == 600i32

test "shape applies gsub then gpos in order":
  let fontBytes = fontWith(buildGsubSingleMap(1u16, 10u16),
    buildGposKern(10u16, 2u16, -80i16))
  let (gids, pos) = shapeText(fontBytes, "AB",
    @[globalFeature(tagFromStr("smcp"), 1),
      globalFeature(tagFromStr("kern"), 1)])
  check gids == @[10u32, 2u32]
  check pos[0].xAdv == 520i32
  check pos[1].xAdv == 600i32
  let stale = fontWith(buildGsubSingleMap(1u16, 10u16),
    buildGposKern(1u16, 2u16, -80i16))
  let (gids2, pos2) = shapeText(stale, "AB",
    @[globalFeature(tagFromStr("smcp"), 1),
      globalFeature(tagFromStr("kern"), 1)])
  check gids2 == @[10u32, 2u32]
  check pos2[0].xAdv == 600i32
  check pos2[1].xAdv == 600i32
