import std/options
import unittest

import harfnim
import harfnim/ot/hangul

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
  # Format 4 with one segment per pair (plus sentinel), sorted by cp.
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

proc singleSubstBytes(fromGid, toGid: uint16): seq[uint8] =
  # SingleSubstFormat2, single mapping.
  result = @[]
  result.putU16(2u16)
  result.putU16(8u16)
  result.putU16(1u16)
  result.putU16(toGid)
  for b in covBytes(@[fromGid]):
    result.add(b)

proc buildGsubHang(features: seq[tuple[tag: string, fromGid,
    toGid: uint16]]): seq[uint8] =
  # One SingleSubst lookup per feature, all under hang/dflt, LTR
  # IgnoreMarks flag.
  let n = features.len
  result = @[]
  result.putU32(0x00010000u32)
  let scriptLen = 2 + 6 + (2 + 2 + 2 + 2 + 2 + n * 2)
  let featEntryLen = n * 6
  let featLen = 2 + featEntryLen + n * 6
  let featOff = 10 + scriptLen
  let lookupOff = featOff + featLen
  result.putU16(10u16)
  result.putU16(uint16(featOff))
  result.putU16(uint16(lookupOff))
  result.putU16(1u16)
  result.putTag("hang")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(uint16(n))
  for i in 0 ..< n:
    result.putU16(uint16(i))
  result.putU16(uint16(n))
  var featBase = 2 + n * 6
  for i, f in features:
    result.putTag(f.tag)
    result.putU16(uint16(featBase + i * 6))
  for i in 0 ..< n:
    result.putU16(0u16)
    result.putU16(1u16)
    result.putU16(uint16(i))
  result.putU16(uint16(n))
  var loff = 2 + n * 2
  for i in 0 ..< n:
    result.putU16(uint16(loff))
    loff += 8 + 14
  for i, f in features:
    result.putU16(1u16)
    result.putU16(8u16)
    result.putU16(1u16)
    result.putU16(8u16)
    for b in singleSubstBytes(f.fromGid, f.toGid):
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

test "hangul jamo ranges":
  check isL(0x1100u32)
  check isL(0x115Fu32)
  check isL(0xA960u32)
  check (not isL(0x1160u32))
  check isV(0x1160u32)
  check isV(0xD7C6u32)
  check (not isV(0x1100u32))
  check isT(0x11A8u32)
  check isT(0xD7FBu32)
  check (not isT(0x11A7u32))
  check isCombiningL(0x1100u32)
  check (not isCombiningL(0x115Fu32))
  check isCombiningT(0x11A8u32)
  check (not isCombiningT(0x11A7u32))
  check isCombinedS(0xAC00u32)
  check isHangulTone(0x302Eu32)
  check (not isHangulTone(0x302Du32))

test "hangul composes L+V when the font has the syllable":
  let cmap = buildCmap(@[(0x1100u16, 1u16), (0x1161u16, 2u16),
    (0xAC00u16, 3u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u1100\u1161") ==
    @[3u32]

test "hangul decomposes L+V with jamo features":
  let cmap = buildCmap(@[(0x1100u16, 1u16), (0x1161u16, 2u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubHang(@[("ljmo", 1u16, 10u16),
    ("vjmo", 2u16, 20u16)])))
  check shapeGids(buildFontRaw(tables), "\u1100\u1161") == @[10u32, 20u32]

test "hangul composes L+V+T when the font has the syllable":
  # U+11A8 has trailing index 1, so L+V+11A8 -> U+AC01.
  let cmap = buildCmap(@[(0x1100u16, 1u16), (0x1161u16, 2u16),
    (0x11A8u16, 4u16), (0xAC01u16, 5u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u1100\u1161\u11A8") ==
    @[5u32]

test "hangul old hangul L+V+T decomposes with tjmo":
  let cmap = buildCmap(@[(0x1100u16, 1u16), (0x1161u16, 2u16),
    (0x11A8u16, 4u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubHang(@[("ljmo", 1u16, 10u16),
    ("vjmo", 2u16, 20u16), ("tjmo", 4u16, 40u16)])))
  check shapeGids(buildFontRaw(tables), "\u1100\u1161\u11A8") ==
    @[10u32, 20u32, 40u32]

test "hangul LV+T composes when the font has LVT":
  let cmap = buildCmap(@[(0xAC00u16, 1u16), (0x11A8u16, 2u16),
    (0xAC01u16, 3u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\uAC00\u11A8") ==
    @[3u32]

test "hangul LV stays when the font has it":
  let cmap = buildCmap(@[(0xAC00u16, 1u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\uAC00") == @[1u32]

test "hangul LV decomposes when the font lacks it":
  let cmap = buildCmap(@[(0x1100u16, 1u16), (0x1161u16, 2u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubHang(@[("ljmo", 1u16, 10u16),
    ("vjmo", 2u16, 20u16)])))
  check shapeGids(buildFontRaw(tables), "\uAC00") == @[10u32, 20u32]

test "hangul tone mark reorders before the syllable":
  let cmap = buildCmap(@[(0xAC00u16, 1u16), (0x302Eu16, 2u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\uAC00\u302E") ==
    @[2u32, 1u32]

test "hangul tone after non-syllable gets a dotted circle":
  # U+314B is a Hangul letter but not a syllable start, so the tone
  # takes the dotted-circle path. Leading with a non-mark also keeps
  # the generic dotted-circle insertion out of the picture.
  let cmap = buildCmap(@[(0x314Bu16, 5u16), (0x302Eu16, 2u16),
    (0x25CCu16, 3u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u314B\u302E") ==
    @[5u32, 2u32, 3u32]

test "hangul lone tone passes through without dotted circle":
  let cmap = buildCmap(@[(0x314Bu16, 5u16), (0x302Eu16, 2u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u314B\u302E") ==
    @[5u32, 2u32]

test "hangul calt is cleared on jamo":
  let cmap = buildCmap(@[(0x1100u16, 1u16), (0x1161u16, 2u16),
    (0x314Bu16, 5u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubHang(@[("ljmo", 1u16, 10u16),
    ("calt", 1u16, 9u16), ("calt", 5u16, 6u16)])))
  # U+314B is a Hangul letter but not jamo: calt fires there, while
  # the L keeps only its ljmo substitution.
  check shapeGids(buildFontRaw(tables), "\u314B\u1100\u1161") ==
    @[6u32, 10u32, 2u32]
