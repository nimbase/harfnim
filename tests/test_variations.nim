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
