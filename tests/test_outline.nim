## Outline extraction tests: glyf decoding, CFF charstrings, draw
## callbacks, value outlines, extents fallback, and the ShaperFont cache.
##
## All fonts are synthetic; no binary fixtures.

import std/options
import std/tables
import unittest

import harfnim

# --------------------------------------------------------------------------
# Byte builders
# --------------------------------------------------------------------------

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

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

proc encInt(v: int): seq[uint8] =
  ## Charstring/DICT integer encoding for small test values.
  if v >= -107 and v <= 107:
    @[uint8(v + 139)]
  elif v >= 108 and v <= 1131:
    let q = v - 108
    @[uint8(247 + (q shr 8)), uint8(q and 0xFF)]
  elif v >= -1131 and v <= -108:
    let q = -v - 108
    @[uint8(251 + (q shr 8)), uint8(q and 0xFF)]
  else:
    @[255u8, uint8((v shr 24) and 0xFF), uint8((v shr 16) and 0xFF),
      uint8((v shr 8) and 0xFF), uint8(v and 0xFF)]

proc buildIndex(entries: seq[seq[uint8]]): seq[uint8] =
  result = @[]
  result.putU16(uint16(entries.len))
  if entries.len == 0:
    return
  var total = 0
  for e in entries:
    total += e.len
  let offSize = if total + 1 <= 255: 1 else: 2
  result.add(uint8(offSize))
  var off = 1
  for e in entries:
    if offSize == 1:
      result.add(uint8(off))
    else:
      result.putU16(uint16(off))
    off += e.len
  if offSize == 1:
    result.add(uint8(off))
  else:
    result.putU16(uint16(off))
  for e in entries:
    result.add(e)

# --------------------------------------------------------------------------
# glyf builders
# --------------------------------------------------------------------------

proc simpleGlyph(pts: seq[tuple[x, y: int32, on: bool]],
    ends: seq[int]): seq[uint8] =
  result = @[]
  result.putI16(int16(ends.len))
  if pts.len == 0:
    result.putI16(0i16)
    result.putI16(0i16)
    result.putI16(0i16)
    result.putI16(0i16)
    return
  var x0 = pts[0].x
  var y0 = pts[0].y
  var x1 = x0
  var y1 = y0
  for p in pts:
    x0 = min(x0, p.x)
    y0 = min(y0, p.y)
    x1 = max(x1, p.x)
    y1 = max(y1, p.y)
  result.putI16(int16(x0))
  result.putI16(int16(y0))
  result.putI16(int16(x1))
  result.putI16(int16(y1))
  for e in ends:
    result.putU16(uint16(e))
  result.putU16(0u16) # no instructions
  for p in pts:
    result.add(if p.on: 1u8 else: 0u8)
  var px = 0i32
  for p in pts:
    result.putI16(int16(p.x - px))
    px = p.x
  var py = 0i32
  for p in pts:
    result.putI16(int16(p.y - py))
    py = p.y
  # Short loca records offset/2, so glyph data must be even-length.
  while result.len mod 2 != 0:
    result.add(0u8)

proc compositeGlyph(comps: seq[tuple[gid: int, dx, dy: int,
    matched: bool]]): seq[uint8] =
  result = @[]
  result.putI16(-1i16)
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(0i16)
  for i, c in comps:
    var flags = 0x0003u16 # WORDS | ARGS_ARE_XY_VALUES
    if c.matched:
      flags = 0x0001u16 # WORDS, point matching
    if i + 1 < comps.len:
      flags = flags or 0x0020u16 # MORE_COMPONENTS
    result.putU16(flags)
    result.putU16(uint16(c.gid))
    if c.matched:
      result.putU16(uint16(c.dx))
      result.putU16(uint16(c.dy))
    else:
      result.putI16(int16(c.dx))
      result.putI16(int16(c.dy))
  while result.len mod 2 != 0:
    result.add(0u8)

proc buildLocaShort(offsets: seq[int]): seq[uint8] =
  result = @[]
  for o in offsets:
    result.putU16(uint16(o div 2))

proc buildCmapGlyphs(): seq[uint8] =
  # format 4 mapping A->1 B->2 C->3 D->4 E->5
  var sub: seq[uint8] = @[]
  sub.putU16(4u16)
  sub.putU16(32u16)
  sub.putU16(0u16)
  sub.putU16(4u16)
  sub.putU16(4u16)
  sub.putU16(1u16)
  sub.putU16(0u16)
  sub.putU16(0x45u16)
  sub.putU16(0xFFFFu16)
  sub.putU16(0u16)
  sub.putU16(0x41u16)
  sub.putU16(0xFFFFu16)
  sub.putI16(-64i16)
  sub.putI16(1i16)
  sub.putU16(0u16)
  sub.putU16(0u16)
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.add(sub)

proc buildTtf(numGlyphs: int, loca, glyf: seq[uint8]): seq[uint8] =
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
  maxp.putU16(uint16(numGlyphs))
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putI16(20i16)
  let cmap = buildCmapGlyphs()
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca), ("glyf", glyf),
  ]
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    result.putU32(uint32((data.len + 3) and not 3))
    off += (data.len + 3) and not 3
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc collectOps(f: ShaperFont, gid: uint32): tuple[ok: bool,
    ops: seq[DrawOp]] =
  var ops: seq[DrawOp] = @[]
  let ok = f.drawGlyph(newGlyphId(gid), proc(op: DrawOp) = ops.add(op))
  (ok, ops)

# --------------------------------------------------------------------------
# CFF builders
# --------------------------------------------------------------------------

proc buildCffTable(charstrings: seq[seq[uint8]],
    globalSubrs: seq[seq[uint8]] = @[],
    privateDict: seq[uint8] = @[],
    localSubrs: seq[seq[uint8]] = @[],
    fdArray: seq[seq[uint8]] = @[],
    fdSelect: seq[uint8] = @[],
    ros: bool = false,
    charset: seq[uint8] = @[]): seq[uint8] =
  let nameIdx = buildIndex(@[@[uint8('T')]])
  let strIdx = buildIndex(@[])
  let gsubrIdx = buildIndex(globalSubrs)
  let csIdx = buildIndex(charstrings)
  let fdArrayIdx = buildIndex(fdArray)
  # Layout: header | name | top | string | gsubr | charstrings |
  #         private | localsubrs | fdarray | fdselect
  let topStub = 40 # ample room; Top DICT rebuilt below with real offsets
  var topOff = 4 + nameIdx.len
  var cursor = topOff + (5 + topStub)
  let strOff = cursor
  cursor += strIdx.len
  let gsubrOff = cursor
  cursor += gsubrIdx.len
  let csOff = cursor
  cursor += csIdx.len
  let privateOff = cursor
  cursor += privateDict.len
  let localOff = cursor
  let localIdx = buildIndex(localSubrs)
  cursor += localIdx.len
  let fdArrayOff = cursor
  cursor += fdArrayIdx.len
  let fdSelectOff = cursor
  cursor += fdSelect.len
  let charsetOff = cursor
  cursor += charset.len
  # Top DICT with real offsets.
  var top: seq[uint8] = @[]
  top.add(encInt(csOff))
  top.add(17u8)
  if privateDict.len > 0:
    top.add(encInt(privateDict.len))
    top.add(encInt(privateOff))
    top.add(18u8)
  if charset.len > 0:
    top.add(encInt(charsetOff))
    top.add(15u8)
  if ros:
    top.add(encInt(0))
    top.add(encInt(0))
    top.add(encInt(0))
    top.add(12u8)
    top.add(30u8)
    top.add(encInt(fdArrayOff))
    top.add(12u8)
    top.add(36u8)
    top.add(encInt(fdSelectOff))
    top.add(12u8)
    top.add(37u8)
  doAssert top.len <= topStub
  while top.len < topStub:
    top.add(0u8) # padding parsed as version op; harmless
  let topIdx = buildIndex(@[top])
  doAssert topIdx.len == 5 + topStub
  result = @[1u8, 0u8, 4u8, 4u8]
  result.add(nameIdx)
  result.add(topIdx)
  result.add(strIdx)
  result.add(gsubrIdx)
  result.add(csIdx)
  result.add(privateDict)
  result.add(localIdx)
  result.add(fdArrayIdx)
  result.add(fdSelect)
  result.add(charset)

proc buildOtf(cff: seq[uint8], numGlyphs: int): seq[uint8] =
  var head = newSeq[uint8]()
  head.putU32(0x4F54544Fu32)
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
  maxp.putU16(uint16(numGlyphs))
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putI16(20i16)
  let cmap = buildCmapGlyphs()
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("CFF ", cff),
  ]
  result = @[]
  result.putU32(0x4F54544Fu32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    result.putU32(uint32((data.len + 3) and not 3))
    off += (data.len + 3) and not 3
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc csSquare(): seq[uint8] =
  # move(10,20) hline(100) vline(100) hline(-100) vline(-100) end
  @[149u8, 159u8, 21u8, 239u8, 6u8, 239u8, 7u8, 39u8, 6u8, 39u8, 7u8,
    14u8]

# --------------------------------------------------------------------------
# glyf tests
# --------------------------------------------------------------------------

test "glyf triangle emits lines":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (100i32, 0i32, true),
    (50i32, 100i32, true)], @[2])
  var glyf: seq[uint8] = @[]
  glyf.add(tri)
  let loca = buildLocaShort(@[0, 0, tri.len])
  let sf = newShaperFont(parseFont(buildTtf(2, loca, glyf)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 4
  check ops[0].kind == moveTo and ops[0].to == (0i32, 0i32)
  check ops[1].kind == lineTo and ops[1].to == (100i32, 0i32)
  check ops[2].kind == lineTo and ops[2].to == (50i32, 100i32)
  check ops[3].kind == closePath
  let o = sf.glyphOutline(newGlyphId(1))
  check o.isSome
  check o.get.contours.len == 1
  check o.get.contours[0].points.len == 3
  check sf.glyphExtents(newGlyphId(1)) ==
    some(GlyphExtents(xBearing: 0i32, yBearing: 100i32, width: 100i32,
      height: -100i32))

test "glyf quadratic midpoint":
  let g = simpleGlyph(@[(0i32, 0i32, true), (50i32, 50i32, false),
    (100i32, 0i32, true)], @[2])
  let loca = buildLocaShort(@[0, 0, g.len])
  let sf = newShaperFont(parseFont(buildTtf(2, loca, g)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 3
  check ops[0].kind == moveTo and ops[0].to == (0i32, 0i32)
  check ops[1].kind == quadraticTo
  check ops[1].qCtrl == (50i32, 50i32)
  check ops[1].qTo == (100i32, 0i32)
  check ops[2].kind == closePath

test "glyf implied on-curve start":
  let g = simpleGlyph(@[(0i32, 100i32, false), (100i32, 100i32, false),
    (100i32, 0i32, false), (0i32, 0i32, false)], @[3])
  let loca = buildLocaShort(@[0, 0, g.len])
  let sf = newShaperFont(parseFont(buildTtf(2, loca, g)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 6
  check ops[0].kind == moveTo and ops[0].to == (0i32, 50i32)
  check ops[1].kind == quadraticTo
  check ops[1].qCtrl == (0i32, 100i32)
  check ops[1].qTo == (50i32, 100i32)
  check ops[5].kind == closePath

test "glyf empty and out of range":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (100i32, 0i32, true),
    (50i32, 100i32, true)], @[2])
  let loca = buildLocaShort(@[0, 0, tri.len])
  let sf = newShaperFont(parseFont(buildTtf(2, loca, tri)))
  check collectOps(sf, 0).ok == false
  check sf.glyphOutline(newGlyphId(0)).isNone
  check sf.glyphExtents(newGlyphId(0)).isNone
  check collectOps(sf, 9).ok == false

test "glyf composite translated":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (100i32, 0i32, true),
    (50i32, 100i32, true)], @[2])
  let comp = compositeGlyph(@[(gid: 1, dx: 200, dy: 50, matched: false)])
  var glyf: seq[uint8] = @[]
  glyf.add(newSeq[uint8](10)) # gid 0 empty
  let o1 = glyf.len
  glyf.add(tri)
  let o2 = glyf.len
  glyf.add(comp)
  let loca = buildLocaShort(@[0, o1, o2, glyf.len])
  let sf = newShaperFont(parseFont(buildTtf(3, loca, glyf)))
  let (ok, ops) = collectOps(sf, 2)
  check ok
  check ops.len == 4
  check ops[0].to == (200i32, 50i32)
  check ops[1].to == (300i32, 50i32)
  check ops[2].to == (250i32, 150i32)
  # Extents come from the decoded outline (composite header has none).
  check sf.glyphExtents(newGlyphId(2)) ==
    some(GlyphExtents(xBearing: 200i32, yBearing: 150i32, width: 100i32,
      height: -100i32))

test "glyf composite skips empty component":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (10i32, 0i32, true),
    (0i32, 10i32, true)], @[2])
  let empty: seq[uint8] = @[0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
    0u8, 0u8]
  let comp = compositeGlyph(@[(gid: 0, dx: 0, dy: 0, matched: false),
    (gid: 1, dx: 100, dy: 0, matched: false)])
  var glyf: seq[uint8] = @[]
  let o0 = 0
  glyf.add(empty)
  let o1 = glyf.len
  glyf.add(tri)
  let o2 = glyf.len
  glyf.add(comp)
  let loca = buildLocaShort(@[o0, o1, o2, glyf.len])
  let sf = newShaperFont(parseFont(buildTtf(3, loca, glyf)))
  let (ok, ops) = collectOps(sf, 2)
  check ok
  # Empty first component contributes nothing; second is shifted by 100.
  check ops.len == 4
  check ops[0].to == (100i32, 0i32)

test "glyf composite matched points":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (100i32, 0i32, true),
    (50i32, 100i32, true)], @[2])
  # comp1 places tri at origin; comp2 matches its point 0 onto acc
  # point 2 (50,100), translating the copy by (50,100).
  let comp = compositeGlyph(@[(gid: 1, dx: 0, dy: 0, matched: false),
    (gid: 1, dx: 0, dy: 0, matched: true)])
  var glyf: seq[uint8] = @[]
  glyf.add(newSeq[uint8](10))
  let o1 = glyf.len
  glyf.add(tri)
  let o2 = glyf.len
  glyf.add(comp)
  # Patch comp2 args: point matching (acc point 2, comp point 0).
  # comp2 args sit after its 4-byte flags+gid header.
  glyf[o2 + 22] = 0u8
  glyf[o2 + 23] = 2u8
  glyf[o2 + 24] = 0u8
  glyf[o2 + 25] = 0u8
  let loca = buildLocaShort(@[0, o1, o2, glyf.len])
  let sf = newShaperFont(parseFont(buildTtf(3, loca, glyf)))
  let (ok, ops) = collectOps(sf, 2)
  check ok
  check ops.len == 8
  check ops[0].to == (0i32, 0i32)
  check ops[4].to == (50i32, 100i32)
  check ops[5].to == (150i32, 100i32)

test "glyf truncated fails cleanly":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (100i32, 0i32, true),
    (50i32, 100i32, true)], @[2])
  let cut = tri[0 ..< tri.len - 3]
  let loca = buildLocaShort(@[0, 0, cut.len])
  let sf = newShaperFont(parseFont(buildTtf(2, loca, cut)))
  check collectOps(sf, 1).ok == false

# --------------------------------------------------------------------------
# CFF tests
# --------------------------------------------------------------------------

test "cff square outline and bounds":
  let cff = buildCffTable(@[@[14u8], csSquare()])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 6
  check ops[0].kind == moveTo and ops[0].to == (10i32, 20i32)
  check ops[1].kind == lineTo and ops[1].to == (110i32, 20i32)
  check ops[2].to == (110i32, 120i32)
  check ops[3].to == (10i32, 120i32)
  check ops[4].to == (10i32, 20i32)
  check ops[5].kind == closePath
  check sf.glyphExtents(newGlyphId(1)) ==
    some(GlyphExtents(xBearing: 10i32, yBearing: 120i32, width: 100i32,
      height: -100i32))

test "cff extents scale with font size":
  let cff = buildCffTable(@[@[14u8], csSquare()])
  var sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  sf.setScale(2000i32)
  check sf.glyphExtents(newGlyphId(1)) ==
    some(GlyphExtents(xBearing: 20i32, yBearing: 240i32, width: 200i32,
      height: -200i32))

test "cff rrcurveto":
  var cs: seq[uint8] = @[]
  cs.add(encInt(0))
  cs.add(encInt(0))
  cs.add(21u8)
  for v in [30, 0, 30, 60, 0, 30]:
    cs.add(encInt(v))
  cs.add(8u8)
  cs.add(14u8)
  let cff = buildCffTable(@[@[14u8], cs])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 3
  check ops[1].kind == cubicTo
  check ops[1].c1 == (30i32, 0i32)
  check ops[1].c2 == (60i32, 60i32)
  check ops[1].cTo == (60i32, 90i32)

test "cff global subr":
  let sub: seq[uint8] = encInt(50) & @[6u8]
  var cs: seq[uint8] = @[]
  cs.add(encInt(0))
  cs.add(encInt(0))
  cs.add(21u8)
  cs.add(encInt(-107)) # subr 0 with bias 107
  cs.add(29u8)
  cs.add(14u8)
  let cff = buildCffTable(@[@[14u8], cs], @[sub])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 3
  check ops[1].kind == lineTo and ops[1].to == (50i32, 0i32)

test "cff local subr via private":
  let sub: seq[uint8] = encInt(40) & @[7u8]
  # Private DICT [enc(2), Subrs]: the local subrs INDEX sits right
  # after the 2 private bytes, so its relative offset is 2.
  let cff = buildCffTable(@[@[14u8],
    @[139u8, 139u8, 21u8, 32u8, 10u8, 14u8]],
    privateDict = @[141u8, 19u8], localSubrs = @[sub])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 3
  check ops[1].kind == lineTo and ops[1].to == (0i32, 40i32)

test "cff hints and width do not disturb path":
  var cs: seq[uint8] = @[]
  cs.add(encInt(50)) # width
  cs.add(encInt(0))
  cs.add(encInt(100))
  cs.add(1u8) # hstem
  cs.add(19u8) # hintmask
  cs.add(0x80u8)
  cs.add(csSquare())
  let cff = buildCffTable(@[@[14u8], cs])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 6
  check ops[0].to == (10i32, 20i32)

test "cff hhcurveto and hvcurveto":
  var cs: seq[uint8] = @[]
  cs.add(encInt(0))
  cs.add(encInt(0))
  cs.add(21u8)
  for v in [30, 30, 30, 30]:
    cs.add(encInt(v))
  cs.add(27u8) # hhcurveto: c1=(30,0) c2=(60,30) p=(90,30)
  for v in [10, 20, 20, 10]:
    cs.add(encInt(v))
  cs.add(31u8) # hvcurveto: c1=(10,0) c2=(30,20) p=(30,30)
  cs.add(14u8)
  let cff = buildCffTable(@[@[14u8], cs])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 4
  check ops[1].kind == cubicTo
  check ops[1].c1 == (30i32, 0i32)
  check ops[1].c2 == (60i32, 30i32)
  check ops[1].cTo == (90i32, 30i32)
  check ops[2].c1 == (100i32, 30i32)
  check ops[2].c2 == (120i32, 50i32)
  check ops[2].cTo == (120i32, 60i32)

test "cff vvcurveto odd first arg":
  var cs: seq[uint8] = @[]
  cs.add(encInt(0))
  cs.add(encInt(0))
  cs.add(21u8)
  for v in [15, 40, 10, 10, 20]:
    cs.add(encInt(v))
  cs.add(26u8) # vv odd: c1=(15,40) c2=(25,50) p=(25,70)
  cs.add(14u8)
  let cff = buildCffTable(@[@[14u8], cs])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 3
  check ops[1].c1 == (15i32, 40i32)
  check ops[1].c2 == (25i32, 50i32)
  check ops[1].cTo == (25i32, 70i32)

test "cff flex":
  var cs: seq[uint8] = @[]
  cs.add(encInt(0))
  cs.add(encInt(0))
  cs.add(21u8)
  for v in [10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 50]:
    cs.add(encInt(v))
  cs.add(12u8)
  cs.add(35u8)
  cs.add(14u8)
  let cff = buildCffTable(@[@[14u8], cs])
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 4
  check ops[1].kind == cubicTo
  check ops[1].cTo == (30i32, 0i32)
  check ops[2].cTo == (60i32, 0i32)

test "cff malformed inputs fail":
  # Truncated number.
  let bad1 = buildCffTable(@[@[14u8], @[21u8, 247u8]])
  check collectOps(newShaperFont(parseFont(buildOtf(bad1, 2))),
    1).ok == false
  # Unknown operator.
  let bad2 = buildCffTable(@[@[14u8],
    @[139u8, 139u8, 21u8, 13u8, 14u8]])
  check collectOps(newShaperFont(parseFont(buildOtf(bad2, 2))),
    1).ok == false
  # Stack underflow.
  let bad3 = buildCffTable(@[@[14u8],
    @[139u8, 139u8, 21u8, 140u8, 5u8, 14u8]])
  check collectOps(newShaperFont(parseFont(buildOtf(bad3, 2))),
    1).ok == false
  # seac to empty .notdef components yields no outline.
  let bad4 = buildCffTable(@[@[14u8],
    @[139u8, 139u8, 139u8, 139u8, 139u8, 14u8]])
  check collectOps(newShaperFont(parseFont(buildOtf(bad4, 2))),
    1).ok == false

test "cff cid font resolves fdselect":
  # CID-keyed: ROS + one Font DICT with an empty private + FDSelect.
  var fdDict: seq[uint8] = @[]
  fdDict.add(encInt(0))
  fdDict.add(encInt(0))
  fdDict.add(18u8) # private size 0 at offset 0 (unused)
  let fdSelect = @[0u8, 0u8, 0u8]
  let cff = buildCffTable(@[@[14u8], csSquare()], fdArray = @[fdDict],
    fdSelect = fdSelect, ros = true)
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops.len == 6
  check ops[1].to == (110i32, 20i32)

test "cff cid fdselect format 3":
  var fdDict: seq[uint8] = @[]
  fdDict.add(encInt(0))
  fdDict.add(encInt(0))
  fdDict.add(18u8)
  var fdSelect: seq[uint8] = @[3u8, 0u8, 1u8, 0u8, 0u8, 0u8, 0u8, 2u8]
  let cff = buildCffTable(@[@[14u8], csSquare()], fdArray = @[fdDict],
    fdSelect = fdSelect, ros = true)
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  let (ok, ops) = collectOps(sf, 1)
  check ok
  check ops[1].to == (110i32, 20i32)

test "cff width before hmoveto via subr":
  # Regression: a width on the stack plus a single-arg moveto is an
  # even-count stack; the width is the one extra arg. Mirrors the
  # NotoSansJavanese pattern (width, callgsubr into hmoveto).
  let sub: seq[uint8] = encInt(840) & @[22u8]
  var cs: seq[uint8] = @[]
  cs.add(encInt(-102))
  cs.add(encInt(-72))
  cs.add(29u8) # callgsubr 35 with bias 107 and 228 subrs
  cs.add(14u8)
  var subs: seq[seq[uint8]] = @[]
  for i in 0 ..< 35:
    subs.add(@[11u8])
  subs.add(sub) # index 35
  while subs.len < 228:
    subs.add(@[11u8])
  let cff = buildCffTable(@[@[14u8], cs], subs)
  let sf = newShaperFont(parseFont(buildOtf(cff, 2)))
  # 228 global subrs, index 35 = hmoveto subr; number -72 + 107 = 35.
  var ops: seq[DrawOp] = @[]
  let ok = sf.drawGlyph(newGlyphId(1u32),
    proc(op: DrawOp) = ops.add(op))
  check ok
  check ops.len == 2
  check ops[0].kind == moveTo and ops[0].to == (840i32, 0i32)
  check ops[1].kind == closePath

test "dict longint operand":
  # Regression: real tables encode large offsets with DICT operand 29.
  let d = decodeDict(@[0x1Du8, 0u8, 0u8, 0x83u8, 0xABu8, 17u8], 0, 6)
  check d.isSome
  check d.get.len == 1
  check d.get[0].op == 17
  check d.get[0].args == @[33707.0]

test "outline cache stores hits and misses":
  let tri = simpleGlyph(@[(0i32, 0i32, true), (100i32, 0i32, true),
    (50i32, 100i32, true)], @[2])
  var glyf: seq[uint8] = @[]
  glyf.add(tri)
  let loca = buildLocaShort(@[0, 0, tri.len])
  var sf = newShaperFont(parseFont(buildTtf(2, loca, glyf)))
  let (ok1, ops1) = collectOps(sf, 1)
  check ok1
  check sf.outlineCache.items.hasKey(1u32)
  let (ok2, ops2) = collectOps(sf, 1)
  check ok2
  check ops1 == ops2
  check collectOps(sf, 0).ok == false
  check sf.outlineCache.items.hasKey(0u32)
  check collectOps(sf, 0).ok == false

proc charset0(sids: seq[uint16]): seq[uint8] =
  ## Charset format 0 covering gids 1 .. sids.len.
  result = @[0u8]
  for s in sids:
    result.putU16(s)

proc csAccent(): seq[uint8] =
  # move(0,0) hline(20) end -> ops: move, line, close.
  @[139u8, 139u8, 21u8, 159u8, 6u8, 14u8]

test "cff seac composes base and accent":
  # 'A' (code 65) -> SID 34 at gid 1; 'quoteleft' (code 96) ->
  # SID 65 at gid 2; composite at gid 3 references them via seac.
  let cs = charset0(@[34u16, 65u16, 35u16])
  let seac = encInt(50) & encInt(100) & encInt(65) & encInt(96) & @[14u8]
  let cff = buildCffTable(@[@[14u8], csSquare(), csAccent(), seac],
    charset = cs)
  let sf = newShaperFont(parseFont(buildOtf(cff, 4)))
  let (ok, ops) = collectOps(sf, 3)
  check ok
  # Base square (6 ops) then accent translated by (50,100) (3 ops).
  check ops.len == 9
  check ops[0].kind == moveTo and ops[0].to == (10i32, 20i32)
  check ops[5].kind == closePath
  check ops[6].kind == moveTo and ops[6].to == (50i32, 100i32)
  check ops[7].kind == lineTo and ops[7].to == (70i32, 100i32)
  check ops[8].kind == closePath

test "cff seac with width arg":
  # Optional leading width is consumed; same composite as above.
  let cs = charset0(@[34u16, 65u16, 35u16])
  let seac = encInt(0) & encInt(50) & encInt(100) & encInt(65) &
    encInt(96) & @[14u8]
  let cff = buildCffTable(@[@[14u8], csSquare(), csAccent(), seac],
    charset = cs)
  let sf = newShaperFont(parseFont(buildOtf(cff, 4)))
  let (ok, ops) = collectOps(sf, 3)
  check ok
  check ops.len == 9
  check ops[6].to == (50i32, 100i32)

test "cff seac rejects bad components and nesting":
  let cs = charset0(@[34u16, 65u16, 35u16, 37u16])
  # 'C' (code 67) -> SID 36 is absent from the charset.
  let badComp = encInt(0) & encInt(0) & encInt(67) & encInt(96) & @[14u8]
  let cff = buildCffTable(@[@[14u8], csSquare(), csAccent(), badComp],
    charset = cs)
  let sf = newShaperFont(parseFont(buildOtf(cff, 4)))
  check collectOps(sf, 3).ok == false
  # Nested seac: gid 4 references gid 3, itself a seac composite
  # ('B' code 66 -> SID 35 -> gid 3).
  let nested = encInt(0) & encInt(0) & encInt(66) & encInt(96) & @[14u8]
  let square = csSquare()
  let accent = csAccent()
  let seacInner = encInt(50) & encInt(100) & encInt(65) & encInt(96) &
    @[14u8]
  let cff2 = buildCffTable(@[@[14u8], square, accent, seacInner, nested],
    charset = cs)
  let sf2 = newShaperFont(parseFont(buildOtf(cff2, 5)))
  check collectOps(sf2, 4).ok == false
  # The inner composite still decodes on its own.
  check collectOps(sf2, 3).ok == true

test "outline cache is bounded":
  var c = newOutlineCache(2)
  let empty = GlyphOutline(contours: @[])
  cacheStore(c, 1u32, none(GlyphOutline))
  cacheStore(c, 2u32, some(empty))
  cacheStore(c, 3u32, none(GlyphOutline))
  check c.items.len == 2
  check not c.items.hasKey(1u32)
  check c.items.hasKey(2u32)
  check c.items.hasKey(3u32)
  # Updating an existing key does not evict.
  cacheStore(c, 2u32, none(GlyphOutline))
  check c.items.len == 2
  check c.items.hasKey(2u32)
