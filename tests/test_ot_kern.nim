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

proc putU16At(s: var seq[uint8], pos: int, v: uint16) =
  doAssert pos >= 0 and pos + 2 <= s.len
  s[pos] = uint8(v shr 8)
  s[pos + 1] = uint8(v and 0xFFu16)

proc putU32At(s: var seq[uint8], pos: int, v: uint32) =
  doAssert pos >= 0 and pos + 4 <= s.len
  s[pos] = uint8(v shr 24)
  s[pos + 1] = uint8((v shr 16) and 0xFFu32)
  s[pos + 2] = uint8((v shr 8) and 0xFFu32)
  s[pos + 3] = uint8(v and 0xFFu32)

proc putTag(s: var seq[uint8], t: string) =
  for c in t:
    s.add(uint8(c))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc buildCmap(pairs: seq[tuple[cp, gid: uint16]]): seq[uint8] =
  var sorted = pairs
  for i in 1 ..< sorted.len:
    let cur = sorted[i]
    var j = i
    while j > 0 and sorted[j - 1].cp > cur.cp:
      sorted[j] = sorted[j - 1]
      dec j
    sorted[j] = cur
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.putU16(4u16)
  let segCount = sorted.len + 1
  let segX2 = uint16(segCount * 2)
  result.putU16(uint16(16 + segCount * 8))
  result.putU16(0u16)
  result.putU16(segX2)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(segX2 - 4u16)
  for pr in sorted:
    result.putU16(pr.cp)
  result.putU16(0xFFFFu16)
  result.putU16(0u16)
  for pr in sorted:
    result.putU16(pr.cp)
  result.putU16(0xFFFFu16)
  for pr in sorted:
    result.putU16(uint16((int(pr.gid) - int(pr.cp)) and 0xFFFF))
  result.putI16(1i16)
  for _ in sorted:
    result.putU16(0u16)
  result.putU16(0u16)

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

proc covBytes(glyphs: seq[uint16]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(uint16(glyphs.len))
  for g in glyphs:
    result.putU16(g)

proc buildKernMs(pairs: seq[tuple[left, right: uint16, value: int16]],
    coverage: uint8 = 1u8): seq[uint8] =
  var sub = newSeq[uint8]()
  sub.putU16(0u16)
  let lenPos = sub.len
  sub.putU16(0u16)
  sub.add(0u8)
  sub.add(coverage)
  sub.putU16(uint16(pairs.len))
  sub.putU16(0u16)
  sub.putU16(0u16)
  sub.putU16(0u16)
  for p in pairs:
    sub.putU16(p.left)
    sub.putU16(p.right)
    sub.putI16(p.value)
  sub.putU16At(lenPos, uint16(sub.len))
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.add(sub)

proc buildKernApple(pairs: seq[tuple[left, right: uint16, value: int16]]): seq[
    uint8] =
  var sub = newSeq[uint8]()
  let lenPos = sub.len
  sub.putU32(0u32)
  sub.add(0u8)
  sub.add(0u8)
  sub.putU16(0u16)
  sub.putU16(uint16(pairs.len))
  sub.putU16(0u16)
  sub.putU16(0u16)
  sub.putU16(0u16)
  for p in pairs:
    sub.putU16(p.left)
    sub.putU16(p.right)
    sub.putI16(p.value)
  sub.putU32At(lenPos, uint32(sub.len))
  result = @[]
  result.putU32(0x00010000u32)
  result.putU32(1u32)
  result.add(sub)

proc buildGposKern(first, second: uint16, kern: int16): seq[uint8] =
  var pairSet = newSeq[uint8]()
  pairSet.putU16(1u16)
  pairSet.putU16(second)
  pairSet.putI16(kern)
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
  for b in covBytes(@[first]):
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

proc fontWith(kern, gpos: seq[uint8]): seq[uint8] =
  let cmap = buildCmap(@[(0x41u16, 1u16), (0x42u16, 2u16)])
  var tables = baseTables(cmap)
  if kern.len > 0:
    tables.add(("kern", kern))
  if gpos.len > 0:
    tables.add(("GPOS", gpos))
  buildFontRaw(tables)

proc shapeAB(fontBytes: seq[uint8],
    feats: seq[Feature]): tuple[gids: seq[uint32], pos: seq[
    tuple[xAdv, xOff, yAdv, yOff: int32]]] =
  let f = parseFont(fontBytes)
  let sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr("AB")
  sf.shape(b, feats)
  var gids: seq[uint32] = @[]
  var pos: seq[tuple[xAdv, xOff, yAdv, yOff: int32]] = @[]
  for i in 0 ..< b.len:
    gids.add(b.info[i].glyphId)
    pos.add((b.pos[i].xAdvance, b.pos[i].xOffset, b.pos[i].yAdvance,
      b.pos[i].yOffset))
  (gids, pos)

proc kernFeat(): Feature =
  globalFeature(tagFromStr("kern"), 1)

test "kern table splits value across pair":
  let kern = buildKernMs(@[(1u16, 2u16, -100i16)])
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[kernFeat()])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 550i32
  check pos[1].xAdv == 550i32
  check pos[1].xOff == -50i32
  check pos[0].xOff == 0i32

test "kern table splits odd negative toward first":
  # -53 splits into -27 (first advance) and -26 (second advance+offset).
  let kern = buildKernMs(@[(1u16, 2u16, -53i16)])
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[kernFeat()])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 573i32
  check pos[1].xAdv == 574i32
  check pos[1].xOff == -26i32

test "kern table ignored without kern feature":
  let kern = buildKernMs(@[(1u16, 2u16, -100i16)])
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 600i32
  check pos[1].xAdv == 600i32
  check pos[1].xOff == 0i32

test "kern table ignored when disabled":
  let kern = buildKernMs(@[(1u16, 2u16, -100i16)])
  let off = Feature(tag: tagFromStr("kern"), value: 0u32, start: 0u32,
    stop: high(uint32))
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[off])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 600i32
  check pos[1].xAdv == 600i32

test "gpos kern takes precedence over kern table":
  let kern = buildKernMs(@[(1u16, 2u16, -100i16)])
  let gpos = buildGposKern(1u16, 2u16, -10i16)
  let (gids, pos) = shapeAB(fontWith(kern, gpos), @[kernFeat()])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 590i32
  check pos[1].xAdv == 600i32
  check pos[1].xOff == 0i32

test "apple kern table applies":
  let kern = buildKernApple(@[(1u16, 2u16, -100i16)])
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[kernFeat()])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 550i32
  check pos[1].xAdv == 550i32
  check pos[1].xOff == -50i32

test "cross-stream kern subtable is skipped":
  let kern = buildKernMs(@[(1u16, 2u16, -100i16)], coverage = 5u8)
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[kernFeat()])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 600i32
  check pos[1].xAdv == 600i32
  check pos[1].xOff == 0i32

test "multiple kern subtables accumulate":
  var kern = buildKernMs(@[(1u16, 2u16, -100i16)])
  # Append a second format 0 subtable with -6 for the same pair.
  var second = newSeq[uint8]()
  second.putU16(0u16)
  let lenPos = second.len
  second.putU16(0u16)
  second.add(0u8)
  second.add(1u8)
  second.putU16(1u16)
  second.putU16(0u16)
  second.putU16(0u16)
  second.putU16(0u16)
  second.putU16(1u16)
  second.putU16(2u16)
  second.putI16(-6i16)
  second.putU16At(lenPos, uint16(second.len))
  # Header table count becomes 2; splice the second subtable in.
  kern[2] = 0u8
  kern[3] = 2u8
  kern.add(second)
  let (gids, pos) = shapeAB(fontWith(kern, @[]), @[kernFeat()])
  check gids == @[1u32, 2u32]
  check pos[0].xAdv == 547i32
  check pos[1].xAdv == 547i32
  check pos[1].xOff == -53i32
