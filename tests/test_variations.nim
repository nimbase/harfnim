## Variable-font coordinates: fvar axes, avar maps, normalization.
##
## All fonts are synthetic; no binary fixtures.

import std/options
import std/tables
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

proc putFixed(s: var seq[uint8], v: float32) =
  s.putU32(cast[uint32](int32(v * 65536.0f32)))

proc putF2dot14(s: var seq[uint8], v: float32) =
  s.putI16(int16(v * 16384.0f32))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc buildFvar(axes: seq[tuple[tag: string, min, def, max: float32]],
    instances: seq[seq[float32]] = @[]): seq[uint8] =
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(16u16)
  result.putU16(2u16)
  result.putU16(uint16(axes.len))
  result.putU16(20u16)
  result.putU16(uint16(instances.len))
  let instSize = 2u16 + uint16(axes.len * 4)
  result.putU16(instSize)
  for a in axes:
    result.putU32(tagFromStr(a.tag).toU32())
    result.putFixed(a.min)
    result.putFixed(a.def)
    result.putFixed(a.max)
    result.putU16(0u16)
    result.putU16(256u16)
  for inst in instances:
    result.putU16(257u16)
    result.putU16(0u16) # postScriptNameID unused flags
    for v in inst:
      result.putFixed(v)

proc buildAvar(maps: seq[seq[tuple[fromV, toV: float32]]]): seq[uint8] =
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(0u16)
  result.putU16(uint16(maps.len))
  for m in maps:
    result.putU16(uint16(m.len))
    for seg in m:
      result.putF2dot14(seg.fromV)
      result.putF2dot14(seg.toV)

proc buildCmapFormat4(): seq[uint8] =
  result = @[]
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

proc buildCmap(): seq[uint8] =
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.add(buildCmapFormat4())

proc buildFontVar(extra: seq[tuple[name: string,
    data: seq[uint8]]]): seq[uint8] =
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
  maxp.putU16(3u16)
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putI16(20i16)
  var loca = @[0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8]
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", buildCmap()), ("loca", loca),
  ]
  for t in extra:
    tables.add(t)
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (tname, data) in tables:
    for c in tname:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    var padded = (data.len + 3) and not 3
    result.putU32(uint32(padded))
    off += padded
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc wghtTag(): uint32 = tagFromStr("wght").toU32()
proc wdthTag(): uint32 = tagFromStr("wdth").toU32()

proc varFont(): SfntFont =
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32),
    ("wdth", 50.0f32, 100.0f32, 200.0f32)], @[@[700.0f32, 100.0f32]])
  parseFont(buildFontVar(@[("fvar", fvar)]))

test "fvar axes parse with instances skipped":
  let f = varFont()
  check f.fvarAxes.len == 2
  check f.fvarAxes[0].tag == wghtTag()
  check f.fvarAxes[0].min == 100.0f32
  check f.fvarAxes[0].default == 400.0f32
  check f.fvarAxes[0].max == 900.0f32
  check f.fvarAxes[1].tag == wdthTag()

test "fvar malformed is contained":
  var bad = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32)])
  bad.setLen(bad.len - 4)
  let f = parseFont(buildFontVar(@[("fvar", bad)]))
  check f.fvarAxes.len == 0
  check f.mapUnicode(0x41u32) == some(newGlyphId(1))

test "axis normalization":
  let f = varFont()
  check normalizeAxisValue(f.fvarAxes[0], 400.0f32) == 0.0f32
  check normalizeAxisValue(f.fvarAxes[0], 700.0f32) == 0.6f32
  check normalizeAxisValue(f.fvarAxes[0], 100.0f32) == -1.0f32
  check normalizeAxisValue(f.fvarAxes[0], 1200.0f32) == 1.0f32
  check normalizeAxisValue(f.fvarAxes[0], 0.0f32) == -1.0f32
  let deg = FvarAxis(tag: wghtTag(), min: 400.0f32, default: 400.0f32,
    max: 900.0f32, hidden: false, nameID: 256u16)
  check normalizeAxisValue(deg, 100.0f32) == 0.0f32
  check normalizeAxisValue(deg, 900.0f32) == 1.0f32

test "avar map applies after normalization":
  let maps = @[@[(-1.0f32, -1.0f32), (0.0f32, 0.0f32),
    (0.5f32, 0.75f32), (1.0f32, 1.0f32)], newSeq[AvarSegment]()]
  check applyAvarMap(maps[1], 0.3f32) == 0.3f32
  check applyAvarMap(maps[0], 0.5f32) == 0.75f32
  check applyAvarMap(maps[0], 0.25f32) == 0.375f32
  check applyAvarMap(maps[0], -2.0f32) == -1.0f32
  check applyAvarMap(maps[0], 2.0f32) == 1.0f32

test "avar table parses per axis":
  let avar = buildAvar(@[@[(-1.0f32, -1.0f32), (0.0f32, 0.0f32),
    (0.5f32, 0.75f32), (1.0f32, 1.0f32)], @[]])
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32),
    ("wdth", 50.0f32, 100.0f32, 200.0f32)])
  let f = parseFont(buildFontVar(@[("fvar", fvar), ("avar", avar)]))
  check f.avarMaps.len == 2
  check f.avarMaps[0].len == 4
  check f.avarMaps[1].len == 0
  var sf = newShaperFont(f)
  check sf.normalizedCoords() == @[0.0f32, 0.0f32]
  sf.setVariations([(wghtTag(), 650.0f32)])
  # (650-400)/500 = 0.5 -> avar 0.75
  check sf.normalizedCoords()[0] == 0.75f32
  check sf.normalizedCoords()[1] == 0.0f32

test "setVariations resets unspecified and ignores unknown":
  var sf = newShaperFont(varFont())
  sf.setVariations([(wghtTag(), 900.0f32),
    (tagFromStr("XXXX").toU32(), 5.0f32)])
  check sf.normalizedCoords() == @[1.0f32, 0.0f32]
  sf.setVariations([(wdthTag(), 200.0f32)])
  check sf.normalizedCoords() == @[0.0f32, 1.0f32]

test "setVariations replaces the outline cache":
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32)])
  var sf = newShaperFont(parseFont(buildFontVar(@[("fvar", fvar)])))
  var ops: seq[DrawOp] = @[]
  discard sf.drawGlyph(newGlyphId(0u32), proc(op: DrawOp) = ops.add(op))
  check len(sf.outlineCache.items) == 1
  sf.setVariations([(wghtTag(), 900.0f32)])
  check sf.normalizedCoords() == @[1.0f32]
  check len(sf.outlineCache.items) == 0

test "static font has no coordinates":
  let f = parseFont(buildFontVar(@[]))
  check f.fvarAxes.len == 0
  var sf = newShaperFont(f)
  sf.setVariations([(wghtTag(), 900.0f32)])
  check sf.normalizedCoords().len == 0

# --------------------------------------------------------------------------
# gvar outline variations
# --------------------------------------------------------------------------

proc putF2dot14(s: var seq[uint8], v: float64) =
  s.putI16(int16(v * 16384.0))

proc simpleTri(): seq[uint8] =
  # Triangle (0,0) (100,0) (50,100), all on-curve.
  result = @[]
  result.putU16(1u16) # numContours
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(100i16)
  result.putU16(2u16) # end pt
  result.putU16(0u16) # no instructions
  result.add(@[1u8, 1u8, 1u8])
  # x deltas: 0, 100, -50
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(-50i16)
  # y deltas: 0, 0, 100
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16)
  while result.len mod 2 != 0:
    result.add(0u8)

proc simpleSquare(): seq[uint8] =
  # Square (0,0) (100,0) (100,100) (0,100).
  result = @[]
  result.putU16(1u16)
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(100i16)
  result.putU16(3u16)
  result.putU16(0u16)
  result.add(@[1u8, 1u8, 1u8, 1u8])
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(0i16)
  result.putI16(-100i16)
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(0i16)
  while result.len mod 2 != 0:
    result.add(0u8)

proc compositeAt(gid, dx, dy: int): seq[uint8] =
  result = @[]
  result.putI16(-1i16)
  result.putI16(0i16)
  result.putI16(0i16)
  result.putI16(100i16)
  result.putI16(100i16)
  result.putU16(0x0003u16)
  result.putU16(uint16(gid))
  result.putI16(int16(dx))
  result.putI16(int16(dy))
  while result.len mod 2 != 0:
    result.add(0u8)

proc packPointsRun(pts: seq[int], useWords: bool): seq[uint8] =
  result = @[]
  if pts.len < 0x80:
    result.add(uint8(pts.len))
  else:
    result.add(uint8((pts.len shr 8) or 0x80))
    result.add(uint8(pts.len and 0xFF))
  var last = 0
  result.add(if useWords: uint8((pts.len - 1) or 0x80) else: uint8(pts.len - 1))
  for p in pts:
    let d = p - last
    if useWords:
      result.putU16(uint16(d))
    else:
      result.add(uint8(d))
    last = p

proc packDeltasRun(vals: seq[int32]): seq[uint8] =
  result = @[]
  var allZero = true
  var fitByte = true
  var fitWord = true
  for v in vals:
    if v != 0i32:
      allZero = false
    if v < -128i32 or v > 127i32:
      fitByte = false
    if v < -32768i32 or v > 32767i32:
      fitWord = false
  if allZero:
    result.add(uint8(0x80 or (vals.len - 1)))
  elif fitByte:
    result.add(uint8(vals.len - 1))
    for v in vals:
      result.add(uint8(cast[int8](v)))
  elif fitWord:
    result.add(uint8(0x40 or (vals.len - 1)))
    for v in vals:
      result.putI16(cast[int16](v))
  else:
    result.add(uint8(0xC0 or (vals.len - 1)))
    for v in vals:
      result.putU32(cast[uint32](v))

proc tupHead(peak: seq[float64], inter: seq[float64] = @[],
    priv = false, sharedIdx = 0): seq[uint8] =
  result = @[]
  var flags = 0u16
  if peak.len > 0:
    flags = flags or 0x8000u16
  if inter.len > 0:
    flags = flags or 0x4000u16
  if priv:
    flags = flags or 0x2000u16
  if peak.len == 0:
    flags = flags or uint16(sharedIdx)
  result.putU16(flags)
  for p in peak:
    result.putF2dot14(p)
  # inter holds start ++ finish concatenated.
  for v in inter:
    result.putF2dot14(v)

proc glyphVarData(heads: seq[seq[uint8]], sharedPts: seq[uint8],
    datas: seq[seq[uint8]]): seq[uint8] =
  result = @[]
  var count = uint16(heads.len)
  if sharedPts.len > 0:
    count = count or 0x8000u16
  result.putU16(count)
  var headersLen = 0
  for h in heads:
    headersLen += h.len
  let dataOff = 4 + headersLen + sharedPts.len
  result.putU16(uint16(dataOff))
  for h in heads:
    result.add(h)
  result.add(sharedPts)
  for d in datas:
    result.add(d)
  if result.len mod 2 != 0:
    result.add(0u8)

proc buildGvar(axisCount: int, shared: seq[seq[float64]],
    vardatas: seq[seq[uint8]]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(uint16(axisCount))
  result.putU16(uint16(shared.len))
  let sharedOff = 20
  result.putU32(uint32(sharedOff))
  result.putU16(uint16(vardatas.len))
  result.putU16(0u16) # short offsets
  let varDataOff = sharedOff + shared.len * axisCount * 2
  result.putU32(uint32(varDataOff))
  for tup in shared:
    for v in tup:
      result.putF2dot14(v)
  var cur = (vardatas.len + 1) * 2
  for vd in vardatas:
    doAssert cur mod 2 == 0
    result.putU16(uint16(cur div 2))
    cur += vd.len
  doAssert cur mod 2 == 0
  result.putU16(uint16(cur div 2))
  for vd in vardatas:
    result.add(vd)

proc buildVarFontFull(numGlyphs: int, loca, glyf, fvar,
    gvar: seq[uint8]): SfntFont =
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
  hhea.putU16(uint16(numGlyphs))
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(uint16(numGlyphs))
  var hmtx = newSeq[uint8]()
  for _ in 0 ..< numGlyphs:
    hmtx.putU16(500u16)
    hmtx.putI16(0i16)
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", buildCmap()), ("loca", loca), ("glyf", glyf),
    ("fvar", fvar), ("gvar", gvar),
  ]
  var fontBytes: seq[uint8] = @[]
  fontBytes.putU32(0x00010000u32)
  fontBytes.putU16(uint16(tables.len))
  fontBytes.putU16(32u16)
  fontBytes.putU16(1u16)
  fontBytes.putU16(16u16)
  var off = 12 + tables.len * 16
  for (tname, data) in tables:
    for c in tname:
      fontBytes.add(uint8(c))
    fontBytes.putU32(0u32)
    fontBytes.putU32(uint32(off))
    var padded = (data.len + 3) and not 3
    fontBytes.putU32(uint32(padded))
    off += padded
  for (_, data) in tables:
    fontBytes.add(data)
    fontBytes.pad4()
  parseFont(fontBytes)

proc triFont(gvar: seq[uint8]): SfntFont =
  let tri = simpleTri()
  var glyf = newSeq[uint8](10) # gid 0 empty
  let o1 = glyf.len
  glyf.add(tri)
  var loca = newSeq[uint8]()
  loca.putU16(0u16)
  loca.putU16(uint16(o1 div 2))
  loca.putU16(uint16(glyf.len div 2))
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32)])
  buildVarFontFull(2, loca, glyf, fvar, gvar)

proc collectVar(sf: ShaperFont, gid: uint32): seq[DrawOp] =
  var ops: seq[DrawOp] = @[]
  let ok = sf.drawGlyph(newGlyphId(gid),
    proc(op: DrawOp) = ops.add(op))
  doAssert ok
  ops

test "gvar default location keeps base outline":
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)],
    @[], @[packPointsRun(@[0, 1, 2], false),
      packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32])])
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 100i32)

test "gvar single tuple scales with coordinate":
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)],
    @[], @[packPointsRun(@[0, 1, 2], false),
      packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32])])
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 200i32)
  var sf2 = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  sf2.setVariations([(wghtTag(), 650.0f32)])
  let ops2 = collectVar(sf2, 1)
  check ops2[2].to == (50i32, 150i32)

test "gvar intermediate region interpolates":
  let vd = glyphVarData(@[tupHead(@[0.6], @[0.2, 1.0], priv = true)],
    @[], @[packPointsRun(@[0, 1, 2], false),
      packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32])])
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  # coord 0.4 -> (0.4-0.2)/(0.6-0.2) = 0.5
  sf.setVariations([(wghtTag(), 600.0f32)])
  check sf.normalizedCoords()[0] == 0.4f32
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 150i32)
  var sf2 = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  sf2.setVariations([(wghtTag(), 400.0f32)])
  let ops2 = collectVar(sf2, 1)
  check ops2[2].to == (50i32, 100i32)

test "gvar IUP fills untouched points":
  let sq = simpleSquare()
  var glyf = newSeq[uint8](10) # gid 0 empty
  let o1 = glyf.len
  glyf.add(sq)
  var loca = newSeq[uint8]()
  loca.putU16(0u16)
  loca.putU16(uint16(o1 div 2))
  loca.putU16(uint16(glyf.len div 2))
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32)])
  # Touch corners 0 and 2; edge midpoints interpolate.
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)], @[],
    @[packPointsRun(@[0, 2], false), packDeltasRun(@[0i32, 100i32]),
      packDeltasRun(@[0i32, 100i32])])
  let f = buildVarFontFull(2, loca, glyf, fvar,
    buildGvar(1, @[], @[@[], vd]))
  var sf = newShaperFont(f)
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 1)
  check ops[0].to == (0i32, 0i32)
  check ops[1].to == (200i32, 0i32)
  check ops[2].to == (200i32, 200i32)
  check ops[3].to == (0i32, 200i32)

test "gvar shared tuples and points sum":
  let vd = glyphVarData(@[tupHead(@[]), tupHead(@[])], packPointsRun(
      @[0, 1, 2], false),
    @[packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32]),
      packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 50i32])])
  var sf = newShaperFont(triFont(buildGvar(1, @[@[1.0]], @[@[], vd])))
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 250i32)

test "gvar peak-zero axis does not participate":
  let tri = simpleTri()
  var glyf = newSeq[uint8](10) # gid 0 empty
  let o1 = glyf.len
  glyf.add(tri)
  var loca = newSeq[uint8]()
  loca.putU16(0u16)
  loca.putU16(uint16(o1 div 2))
  loca.putU16(uint16(glyf.len div 2))
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32),
    ("wdth", 50.0f32, 100.0f32, 200.0f32)])
  # All-points tuple: 3 real + 4 phantom deltas.
  let vd = glyphVarData(@[tupHead(@[])], @[],
    @[packDeltasRun(@[0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32, 0i32, 0i32, 0i32, 0i32])])
  let f = buildVarFontFull(2, loca, glyf, fvar,
    buildGvar(2, @[@[1.0, 0.0]], @[@[], vd]))
  var sf = newShaperFont(f)
  sf.setVariations([(wghtTag(), 900.0f32), (wdthTag(), 200.0f32)])
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 200i32)

test "gvar phantom deltas do not move outlines":
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)], @[],
    @[packPointsRun(@[0, 2, 3], false),
      packDeltasRun(@[0i32, 10i32, 500i32]),
      packDeltasRun(@[0i32, 20i32, 600i32])])
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 1)
  # pt0 listed with zero delta; pt1 IUP between pt0 (0,0) and pt2
  # (10,20): x=100 clamps to 10, y=0 clamps to 0.
  check ops[0].to == (0i32, 0i32)
  check ops[1].to == (110i32, 0i32)
  check ops[2].to == (60i32, 120i32)

test "gvar malformed data keeps base outline":
  var vd = glyphVarData(@[tupHead(@[1.0], priv = true)], @[],
    @[packPointsRun(@[2], false), packDeltasRun(@[0i32]),
      packDeltasRun(@[100i32])])
  vd[3] = 0xFFu8 # corrupt offsetToData
  vd[2] = 0xFFu8
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 100i32)

test "gvar extents follow the location":
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)],
    @[], @[packPointsRun(@[0, 1, 2], false),
      packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32])])
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  check sf.glyphExtents(newGlyphId(1)) ==
    some(GlyphExtents(xBearing: 0i32, yBearing: 100i32, width: 100i32,
      height: -100i32))
  sf.setVariations([(wghtTag(), 900.0f32)])
  check sf.glyphExtents(newGlyphId(1)) ==
    some(GlyphExtents(xBearing: 0i32, yBearing: 200i32, width: 100i32,
      height: -200i32))

test "gvar composite components vary pre-transform":
  let tri = simpleTri()
  let comp = compositeAt(1, 200, 50)
  var glyf: seq[uint8] = @[]
  let o1 = 0
  glyf.add(tri)
  let o2 = glyf.len
  glyf.add(comp)
  var loca = newSeq[uint8]()
  loca.putU16(0u16)
  loca.putU16(uint16(o1 div 2))
  loca.putU16(uint16(o2 div 2))
  loca.putU16(uint16(glyf.len div 2))
  let fvar = buildFvar(@[("wght", 100.0f32, 400.0f32, 900.0f32)])
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)],
    @[], @[packPointsRun(@[0, 1, 2], false),
      packDeltasRun(@[0i32, 0i32, 0i32]),
      packDeltasRun(@[0i32, 0i32, 100i32])])
  let f = buildVarFontFull(3, loca, glyf, fvar,
    buildGvar(1, @[], @[@[], vd, @[]]))
  var sf = newShaperFont(f)
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 2)
  check ops[0].to == (200i32, 50i32)
  check ops[2].to == (250i32, 250i32)

test "gvar word and long runs decode":
  let vd = glyphVarData(@[tupHead(@[1.0], priv = true)], @[],
    @[packPointsRun(@[300], true),
      packDeltasRun(@[70000i32]),
      packDeltasRun(@[0i32])])
  # Point 300 is out of range (phantom-skipped): base kept even
  # though the delta uses a 32-bit long run.
  var sf = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd])))
  sf.setVariations([(wghtTag(), 900.0f32)])
  let ops = collectVar(sf, 1)
  check ops[2].to == (50i32, 100i32)
  # Long run on a real point applies.
  let vd2 = glyphVarData(@[tupHead(@[1.0], priv = true)], @[],
    @[packPointsRun(@[2], false),
      packDeltasRun(@[70000i32]),
      packDeltasRun(@[0i32])])
  var sf2 = newShaperFont(triFont(buildGvar(1, @[], @[@[], vd2])))
  sf2.setVariations([(wghtTag(), 900.0f32)])
  let ops2 = collectVar(sf2, 1)
  check ops2[2].to == (70050i32, 100i32)
