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

proc buildGsubSingle(feature: string, covGlyphs: seq[uint16],
    substitutes: seq[uint16], delta: int16, useDelta: bool,
    flag: uint16): seq[uint8] =
  let n = covGlyphs.len
  let covSize = 4 + n * 2
  let subSize = if useDelta: 6 else: 6 + n * 2
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
  result.putTag(feature)
  result.putU16(8u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(flag)
  result.putU16(1u16)
  result.putU16(8u16)
  if useDelta:
    result.putU16(1u16)
    result.putU16(uint16(subSize))
    result.putI16(delta)
  else:
    result.putU16(2u16)
    result.putU16(uint16(subSize))
    result.putU16(uint16(n))
    for s in substitutes:
      result.putU16(s)
  result.putU16(1u16)
  result.putU16(uint16(n))
  for g in covGlyphs:
    result.putU16(g)
  doAssert result.len == 64 + covSize + subSize - 8

proc buildFont(gsub: seq[uint8], withGsub: bool = true): seq[uint8] =
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
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", buildCmapSingle()), ("loca", loca),
  ]
  if withGsub:
    tables.add(("GSUB", gsub))
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

proc shapeWithFeatures(fontBytes: seq[uint8], text: string,
    feats: seq[Feature]): seq[tuple[gid, cluster: uint32]] =
  let f = parseFont(fontBytes)
  let sf = newShaperFont(f)
  let gsubOpt = parseGsub(f)
  doAssert gsubOpt.isSome
  var b = newBuffer()
  b.pushStr(text)
  b.guessSegmentProperties()
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var nctx = sf.normalizeContextFor()
  b.normalize(nmComposedDiacritics, false, nctx)
  b.deallocateUnicodeVars()
  b.mapGlyphsFast()
  b.setContentType(some(contentGlyphs))
  b.allocateGsubGposVars()
  b.applyGsubFeatures(gsubOpt.get, tagFromStr("latn"), tagFromStr("dflt"), feats)
  b.deallocateGsubGposVars()
  result = @[]
  for g in b.glyphInfosView():
    result.add((g.glyphId, g.cluster))

test "coverage formats":
  var fmt1 = @[0u8, 1u8, 0u8, 2u8, 0u8, 5u8, 0u8, 9u8]
  let c1 = parseCoverage(fmt1, 0)
  check c1.coverageIndex(5u32) == some(0u32)
  check c1.coverageIndex(9u32) == some(1u32)
  check c1.coverageIndex(7u32) == none(uint32)
  var fmt2 = @[0u8, 2u8, 0u8, 2u8, 0u8, 1u8, 0u8, 3u8, 0u8, 0u8, 0u8, 10u8,
    0u8, 12u8, 0u8, 5u8]
  let c2 = parseCoverage(fmt2, 0)
  check c2.coverageIndex(2u32) == some(1u32)
  check c2.coverageIndex(11u32) == some(6u32)
  check c2.coverageIndex(4u32) == none(uint32)
  check c2.coverageIndex(0x10000u32) == none(uint32)
  check parseCoverage(@[0u8, 3u8, 0u8, 0u8], 0).present == false
  check parseCoverage(@[0u8], 0).present == false

test "smcp substitutes through full shaping flow":
  let gsub = buildGsubSingle("smcp", @[1u16], @[10u16], 0i16, false, 0u16)
  let got = shapeWithFeatures(buildFont(gsub), "A",
    @[globalFeature(tagFromStr("smcp"), 1)])
  check got == @[(10u32, 0u32)]

test "delta singlesub":
  let gsub = buildGsubSingle("smcp", @[1u16], @[], 9i16, true, 0u16)
  let got = shapeWithFeatures(buildFont(gsub), "A",
    @[globalFeature(tagFromStr("smcp"), 1)])
  check got == @[(10u32, 0u32)]

test "lookup flag ignores marks":
  let gsub = buildGsubSingle("smcp", @[1u16], @[10u16], 0i16, false, 8u16)
  let f = parseFont(buildFont(gsub))
  let gsubOpt = parseGsub(f)
  check gsubOpt.isSome
  var b = newBuffer()
  b.pushStr("A")
  b.allocateGsubGposVars()
  b.info[0].glyphId = 1u32
  b.info[0].setGlyphProps(GlyphPropMark)
  b.applyGsubFeatures(gsubOpt.get, tagFromStr("latn"), tagFromStr("dflt"),
    @[globalFeature(tagFromStr("smcp"), 1)])
  check b.glyphInfosView()[0].glyphId == 1u32
  b.deallocateGsubGposVars()

test "feature range limits application":
  let gsub = buildGsubSingle("smcp", @[1u16], @[10u16], 0i16, false, 0u16)
  let got = shapeWithFeatures(buildFont(gsub), "AA",
    @[newFeature(tagFromStr("smcp"), 1u32, 1u32, 2u32)])
  check got == @[(1u32, 0u32), (10u32, 1u32)]

test "unknown script or feature is a no-op":
  let gsub = buildGsubSingle("smcp", @[1u16], @[10u16], 0i16, false, 0u16)
  let fontBytes = buildFont(gsub)
  let f = parseFont(fontBytes)
  let gsubOpt = parseGsub(f)
  check gsubOpt.isSome
  var b = newBuffer()
  b.pushStr("A")
  b.allocateGsubGposVars()
  b.applyGsubFeatures(gsubOpt.get, tagFromStr("cyrl"), tagFromStr("dflt"),
    @[globalFeature(tagFromStr("smcp"), 1)])
  check b.glyphInfosView()[0].glyphId == 0x41u32
  b.applyGsubFeatures(gsubOpt.get, tagFromStr("latn"), tagFromStr("dflt"),
    @[globalFeature(tagFromStr("liga"), 1)])
  check b.glyphInfosView()[0].glyphId == 0x41u32
  b.applyGsubFeatures(gsubOpt.get, tagFromStr("latn"), tagFromStr("dflt"),
    @[globalFeature(tagFromStr("smcp"), 0)])
  check b.glyphInfosView()[0].glyphId == 0x41u32
  b.deallocateGsubGposVars()

test "font without gsub parses to none":
  let f = parseFont(buildFont(@[], false))
  check parseGsub(f).isNone
