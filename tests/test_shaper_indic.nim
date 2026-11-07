import std/options
import unittest

import harfnim
import harfnim/ot/indic

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
  let length = uint16(16 + segCount * 8)
  result.putU16(length)
  result.putU16(0u16)
  result.putU16(segX2)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(0u16)
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

proc ligSubstBytes(first: uint16,
    ligs: seq[tuple[lig: uint16, comps: seq[uint16]]]): seq[uint8] =
  # LigatureSubst format 1, one ligature set.
  result = @[]
  result.putU16(1u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(1u16)
  let setPos = result.len
  result.putU16(0u16)
  let covOff = result.len
  for b in covBytes(@[first]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))
  let setOff = result.len
  result.putU16At(setPos, uint16(setOff))
  result.putU16(uint16(ligs.len))
  var lpos: seq[int] = @[]
  for _ in ligs:
    lpos.add(result.len)
    result.putU16(0u16)
  for i, l in ligs:
    let loff = result.len
    result.putU16At(lpos[i], uint16(loff - setOff))
    result.putU16(l.lig)
    result.putU16(uint16(l.comps.len + 1))
    for c in l.comps:
      result.putU16(c)

proc buildGsubIndic(features: seq[tuple[tag: string, lookup: int]],
    lookups: seq[tuple[typ, flag: uint16, sub: seq[uint8]]]): seq[uint8] =
  # GSUB with a deva/default script record. Each lookup holds one subtable.
  result = @[]
  result.putU32(0x00010000u32)
  let scriptLen = 2 + 6 + (2 + 2 + 2 + 2 + 2 + features.len * 2)
  let featLen = 2 + features.len * 6 + features.len * 6
  let featOff = 10 + scriptLen
  let lookupOff = featOff + featLen
  result.putU16(10u16)
  result.putU16(uint16(featOff))
  result.putU16(uint16(lookupOff))
  result.putU16(1u16)
  result.putTag("deva")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(uint16(features.len))
  for f in features:
    result.putU16(uint16(f.lookup))
  result.putU16(uint16(features.len))
  var featBase = 2 + features.len * 6
  for i, f in features:
    result.putTag(f.tag)
    result.putU16(uint16(featBase + i * 6))
  for i in 0 ..< features.len:
    result.putU16(0u16)
    result.putU16(1u16)
    result.putU16(uint16(i))
  result.putU16(uint16(lookups.len))
  var loff = 2 + lookups.len * 2
  for i in 0 ..< lookups.len:
    result.putU16(uint16(loff))
    loff += 8 + lookups[i].sub.len
  for lk in lookups:
    result.putU16(lk.typ)
    result.putU16(lk.flag)
    result.putU16(1u16)
    result.putU16(8u16)
    for b in lk.sub:
      result.add(b)

proc shapeGids(fontBytes: seq[uint8], text: string): seq[uint32] =
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr(text)
  sf.shape(b, @[])
  result = @[]
  for i in 0 ..< b.len:
    result.add(b.info[i].glyphId)

test "indic conjunct passes through with empty deva gsub":
  let cmap = buildCmap(@[(0x0915u16, 1u16), (0x094Du16, 2u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubIndic(@[], @[])))
  check shapeGids(buildFontRaw(tables), "\u0915\u094D\u0915") ==
    @[1u32, 2u32, 1u32]

test "indic akhn forms the conjunct ligature":
  let cmap = buildCmap(@[(0x0915u16, 1u16), (0x094Du16, 2u16),
    (0x0930u16, 3u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubIndic(@[("akhn", 0)],
    @[(4u16, 0u16, ligSubstBytes(1u16, @[(10u16, @[2u16, 1u16])]))])))
  check shapeGids(buildFontRaw(tables), "\u0915\u094D\u0915") == @[10u32]

test "indic reph reorders after the base":
  let cmap = buildCmap(@[(0x0915u16, 1u16), (0x094Du16, 2u16),
    (0x0930u16, 4u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubIndic(@[("rphf", 0)],
    @[(4u16, 0u16, ligSubstBytes(4u16, @[(10u16, @[2u16])]))])))
  check shapeGids(buildFontRaw(tables), "\u0930\u094D\u0915") ==
    @[1u32, 10u32]

test "indic i-matra moves before the base":
  let cmap = buildCmap(@[(0x0915u16, 1u16), (0x093Fu16, 3u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubIndic(@[], @[])))
  check shapeGids(buildFontRaw(tables), "\u0915\u093F") == @[3u32, 1u32]

test "indic blwf below-base positioning moves the halant":
  # The blwf lookup matches [virama, KA], so the first KA becomes
  # below-base; the base search then lands on the first consonant and
  # the old-spec halant move carries the halant after the last
  # consonant. Verified against hb-shape.
  let cmap = buildCmap(@[(0x0915u16, 1u16), (0x094Du16, 2u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubIndic(@[("blwf", 0)],
    @[(4u16, 0u16, ligSubstBytes(2u16, @[(10u16, @[1u16])]))])))
  check shapeGids(buildFontRaw(tables), "\u0915\u094D\u0915") ==
    @[1u32, 1u32, 2u32]

test "indic matra decompose hook keeps rra intact":
  # U+0931 must not decompose (decompose hook exclusion).
  check indicDecompose(0x0931u32).isNone
  check indicCompose(0x09AFu32, 0x09BCu32) == some(0x09DFu32)
