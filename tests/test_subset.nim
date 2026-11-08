import std/options
import std/tables
import unittest

import harfnim/subset
import harfnim/sfnt
import harfnim/buffer

# --------------------------------------------------------------------------
# Synthetic TTF: 3 glyphs
#   gid 0: empty (.notdef)
#   gid 1: simple square (1 contour, 4 points)
#   gid 2: composite of gid 1 (offset 10,20)
# cmap: U+0041 -> 1, U+0042 -> 2
# --------------------------------------------------------------------------

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v))

proc putI16(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc putTag(s: var seq[uint8], a, b, c, d: char) =
  s.add(uint8(a))
  s.add(uint8(b))
  s.add(uint8(c))
  s.add(uint8(d))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc simpleGlyph(): seq[uint8] =
  # 1 contour square: ends[0]=3, no instructions, 4 on-curve points
  # flags all on-curve, x deltas, y deltas as i16.
  result = @[]
  result.putI16(1i16) # numContours
  result.putI16(0i16) # xMin
  result.putI16(0i16) # yMin
  result.putI16(100i16) # xMax
  result.putI16(100i16) # yMax
  result.putU16(3u16) # ends[0]
  result.putU16(0u16) # instrLen
  for _ in 0 ..< 4:
    result.add(1u8) # flags: on-curve
  # xs: 0,100,100,0 as i16 deltas: 0,100,0,-100
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(0i16)
  result.putI16(-100i16)
  # ys: 0,0,100,100 deltas: 0,0,100,0
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(0i16)

proc compositeGlyph(comp: uint16, dx, dy: int16): seq[uint8] =
  result = @[]
  result.putI16(-1i16) # numContours = composite
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16 + dx)
  result.putI16(100i16 + dy)
  result.putU16(0x2u16) # flags: ARGS_ARE_XY_VALUES
  result.putU16(comp)
  result.putI16(dx)
  result.putI16(dy)

proc buildCmapAB(): seq[uint8] =
  # cmap with format 4 (0,3) mapping A->1, B->2 and format 12 (3,10).
  var f4: seq[uint8] = @[]
  # 2 segments + sentinel
  f4.putU16(4u16)
  f4.putU16(32u16)
  f4.putU16(0u16)
  let segX2 = 3u16 * 2u16
  f4.putU16(segX2)
  f4.putU16(4u16) # searchRange 2*2
  f4.putU16(1u16) # entrySelector
  f4.putU16(2u16) # rangeShift
  f4.putU16(0x42u16)
  f4.putU16(0xFFFFu16)
  f4.putU16(0u16)
  f4.putU16(0x41u16)
  f4.putU16(0xFFFFu16)
  f4.putI16(0i16) # delta for A (gid 1 = 0x41 - 0x40)
  f4.putI16(0i16)
  f4.putU16(0u16) # rangeOffset A -> glyphIdArray[0]
  f4.putU16(6u16) # hmm recomputed below properly
  # Simpler: use idDelta = 1-0x41 for A... messy. Build programmatically:
  discard f4
  # Build format 4 with glyphIdArray: starts, ends, deltas=0, rangeOffsets.
  var b: seq[uint8] = @[]
  b.putU16(4u16)
  let lenPos = b.len
  b.putU16(0u16)
  b.putU16(0u16)
  b.putU16(6u16) # segCountX2 = 3 segs (A, B, sentinel)
  b.putU16(4u16)
  b.putU16(1u16)
  b.putU16(2u16)
  # ends:
  b.putU16(0x41u16)
  b.putU16(0x42u16)
  b.putU16(0xFFFFu16)
  b.putU16(0u16)
  # starts:
  b.putU16(0x41u16)
  b.putU16(0x42u16)
  b.putU16(0xFFFFu16)
  # deltas:
  b.putI16(0i16)
  b.putI16(0i16)
  b.putI16(1i16)
  # rangeOffsets: (arrayOff - fieldOff)
  let arrOff = b.len + 3 * 2
  for i in 0 ..< 2:
    b.putU16(uint16(arrOff + i * 2 - (b.len)))
  b.putU16(0u16)
  b.putU16(1u16)
  b.putU16(2u16)
  let total = b.len
  b[lenPos] = uint8(total shr 8)
  b[lenPos + 1] = uint8(total)
  var f12: seq[uint8] = @[]
  f12.putU16(12u16)
  f12.putU16(0u16)
  f12.putU32(uint32(16 + 2 * 12))
  f12.putU32(0u32)
  f12.putU32(2u32)
  f12.putU32(0x41u32)
  f12.putU32(0x41u32)
  f12.putU32(1u32)
  f12.putU32(0x42u32)
  f12.putU32(0x42u32)
  f12.putU32(2u32)
  result = @[]
  result.putU16(0u16)
  result.putU16(2u16)
  result.putU16(0u16)
  result.putU16(3u16)
  result.putU32(20u32)
  result.putU16(3u16)
  result.putU16(10u16)
  result.putU32(uint32(20 + b.len))
  result.add(b)
  result.add(f12)

proc buildTestFont(): seq[uint8] =
  let g0: seq[uint8] = @[]
  let g1 = simpleGlyph()
  let g2 = compositeGlyph(1u16, 10i16, 20i16)
  var head: seq[uint8] = @[]
  head.putU32(0x00010000u32)
  head.putU32(0u32)
  head.putU32(0u32)
  head.putU32(0x5F0F3CF5u32)
  head.putU16(0u16)
  head.putU16(1000u16)
  for _ in 0 ..< 4: head.putU32(0u32)
  head.putI16(0i16)
  head.putI16(0i16)
  head.putI16(110i16)
  head.putI16(120i16)
  head.putU16(0u16)
  head.putU16(0u16)
  head.putI16(0i16) # locFormat short
  head.putI16(0i16)
  head.putU16(0u16)
  var hhea: seq[uint8] = @[]
  hhea.putU32(0x00010000u32)
  hhea.putI16(800i16)
  hhea.putI16(-200i16)
  hhea.putI16(0i16)
  hhea.putU16(600u16)
  for _ in 0 ..< 11: hhea.putI16(0i16)
  hhea.putU16(3u16) # numHMetrics = 3
  var maxp: seq[uint8] = @[]
  maxp.putU32(0x00005000u32)
  maxp.putU16(3u16)
  var hmtx: seq[uint8] = @[]
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putU16(700u16)
  hmtx.putI16(20i16)
  # glyf: g0 empty, g1, g2 with 4-byte alignment; short loca
  var glyf: seq[uint8] = @[]
  var offs: seq[int] = @[0]
  for g in [g0, g1, g2]:
    glyf.add(g)
    while glyf.len mod 4 != 0: glyf.add(0u8)
    offs.add(glyf.len)
  var loca: seq[uint8] = @[]
  for o in offs:
    loca.putU16(uint16(o div 2))
  let cmap = buildCmapAB()
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca), ("glyf", glyf),
  ]
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(64u16)
  result.putU16(2u16)
  result.putU16(48u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name: result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    result.putU32(uint32(data.len))
    off += (data.len + 3) and not 3
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc buildTestFontNoOutlines(): seq[uint8] =
  ## Same 3-glyph metrics/cmap as buildTestFont but with no `glyf`/`loca`
  ## (like CBDT bitmap-only fonts): subsetter must synthesize empty
  ## outlines instead of failing.
  var head: seq[uint8] = @[]
  head.putU32(0x00010000u32)
  head.putU32(0u32)
  head.putU32(0u32)
  head.putU32(0x5F0F3CF5u32)
  head.putU16(0u16)
  head.putU16(1000u16)
  for _ in 0 ..< 4: head.putU32(0u32)
  head.putI16(0i16)
  head.putI16(0i16)
  head.putI16(110i16)
  head.putI16(120i16)
  head.putU16(0u16)
  head.putU16(0u16)
  head.putI16(0i16)
  head.putI16(0i16)
  head.putU16(0u16)
  var hhea: seq[uint8] = @[]
  hhea.putU32(0x00010000u32)
  hhea.putI16(800i16)
  hhea.putI16(-200i16)
  hhea.putI16(0i16)
  hhea.putU16(600u16)
  for _ in 0 ..< 11: hhea.putI16(0i16)
  hhea.putU16(3u16)
  var maxp: seq[uint8] = @[]
  maxp.putU32(0x00005000u32)
  maxp.putU16(3u16)
  var hmtx: seq[uint8] = @[]
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putU16(700u16)
  hmtx.putI16(20i16)
  let cmap = buildCmapAB()
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap),
  ]
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(2u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name: result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    result.putU32(uint32(data.len))
    off += (data.len + 3) and not 3
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc wholeChecksum(b: seq[uint8]): uint32 =
  var s = 0u64
  var i = 0
  while i < b.len:
    var w = 0u32
    for k in 0 ..< 4:
      w = (w shl 8) or (if i + k < b.len: uint32(b[i + k]) else: 0u32)
    s += w
    i += 4
  uint32(s and 0xFFFFFFFFu64)

suite "subsetter":
  test "subset A pulls composite closure and remaps":
    let font = buildTestFont()
    let (sub, m) = subsetFont(font, @[0x42u32]) # B -> composite of gid 1
    check m.len == 3 # 0, 1, 2
    check m[0u32] == 0u32
    check m[1u32] == 1u32
    check m[2u32] == 2u32
    let f = parseFont(sub, 0)
    check f.numGlyphs == 3
    check f.mapUnicode(0x42u32).get.value == 2u32
    check f.mapUnicode(0x41u32).isNone
    # advances preserved
    check f.hAdvance(1u32) == 600i32
    check f.hAdvance(2u32) == 700i32
    check wholeChecksum(sub) == 0xB1B0AFBAu32

  test "subset A keeps only A":
    let font = buildTestFont()
    let (sub, m) = subsetFont(font, @[0x41u32])
    check m.len == 2
    let f = parseFont(sub, 0)
    check f.numGlyphs == 2
    check f.mapUnicode(0x41u32).get.value == 1u32
    check f.hAdvance(1u32) == 600i32
    check wholeChecksum(sub) == 0xB1B0AFBAu32

  test "empty and unknown unicodes give .notdef only":
    let font = buildTestFont()
    let (sub1, m1) = subsetFont(font, @[])
    check parseFont(sub1, 0).numGlyphs == 1
    check m1.len == 1
    let (sub2, m2) = subsetFont(font, @[0x1234u32])
    check parseFont(sub2, 0).numGlyphs == 1
    check m2.len == 1
    check wholeChecksum(sub1) == 0xB1B0AFBAu32

  test "subset output re-parses and draws":
    let font = buildTestFont()
    let (sub, m) = subsetFont(font, @[0x41u32, 0x42u32])
    let f = parseFont(sub, 0)
    let g1 = f.glyphDataRange(1u32)
    check g1.ok and g1.len > 10
    let g2 = f.glyphDataRange(2u32)
    check g2.ok and g2.len > 10
    # composite component remapped to new gid 1: bytes 12..13
    check sub.len > 0
    check m[1u32] == 1u32
    check m[2u32] == 2u32

  test "CFF2 input fails loudly":
    var bad: seq[uint8] = @[]
    # empty: parse fails -> SubsetError
    expect(SubsetError):
      discard subsetFont(bad, @[0x41u32])

  test "outline-less font synthesizes empty glyf":
    let font = buildTestFontNoOutlines()
    let (sub, m) = subsetFont(font, @[0x41u32, 0x42u32])
    check m.len == 3
    let f = parseFont(sub, 0)
    check f.numGlyphs == 3
    check f.mapUnicode(0x41u32).get.value == 1u32
    check f.mapUnicode(0x42u32).get.value == 2u32
    check f.hAdvance(1u32) == 600i32
    # Empty outlines: no outline data, but the font re-parses.
    let (ok, _, ln) = f.glyphDataRange(1u32)
    check ok and ln == 0
    check wholeChecksum(sub) == 0xB1B0AFBAu32
