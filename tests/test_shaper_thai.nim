import std/options
import unittest

import harfnim
import harfnim/ot/thai

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

proc buildGsubThaiDummy(): seq[uint8] =
  # Minimal GSUB with an exact thai script record so the PUA gate
  # sees Thai GSUB. The lookup maps an unrelated glyph.
  let sub = singleSubstBytes(9u16, 8u16)
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(10u16)
  result.putU16(30u16)
  result.putU16(44u16)
  result.putU16(1u16)
  result.putTag("thai")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putTag("ccmp")
  result.putU16(8u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(8u16)
  result.putU16(1u16)
  result.putU16(8u16)
  for b in sub:
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

test "thai consonant and mark types":
  check getConsonantType(0x0E01u32) == Nc
  check getConsonantType(0x0E1Bu32) == Ac
  check getConsonantType(0x0E0Du32) == Rc
  check getConsonantType(0x0E0Eu32) == Dc
  check getConsonantType(0x0E33u32) == NotConsonant
  check getMarkType(0x0E31u32) == Av
  check getMarkType(0x0E4Du32) == Av
  check getMarkType(0x0E38u32) == Bv
  check getMarkType(0x0E3Au32) == Bv
  check getMarkType(0x0E48u32) == T
  check getMarkType(0x0E01u32) == NotMark
  check isSaraAm(0x0E33u32)
  check isSaraAm(0x0EB3u32)
  check (not isSaraAm(0x0E32u32))
  check nikhahitFromSaraAm(0x0E33u32) == 0x0E4Du32
  check nikhahitFromSaraAm(0x0EB3u32) == 0x0ECDu32
  check saraAaFromSaraAm(0x0E33u32) == 0x0E32u32

test "thai sara am splits and reorders over above marks":
  # The documented <0E14, 0E4B, 0E33> -> <0E14, 0E4D, 0E4B, 0E32> case.
  let cmap = buildCmap(@[(0x0E14u16, 1u16), (0x0E4Bu16, 2u16),
    (0x0E33u16, 3u16), (0x0E4Du16, 4u16), (0x0E32u16, 5u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E14\u0E4B\u0E33") ==
    @[1u32, 4u32, 2u32, 5u32]

test "thai lone sara am splits without reorder":
  let cmap = buildCmap(@[(0x0E33u16, 3u16), (0x0E4Du16, 4u16),
    (0x0E32u16, 5u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E33") ==
    @[4u32, 5u32]

test "lao sara am splits the same way":
  let cmap = buildCmap(@[(0x0EB3u16, 3u16), (0x0ECDu16, 4u16),
    (0x0EB2u16, 5u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0EB3") ==
    @[4u32, 5u32]

test "thai plain nikhahit is left alone":
  let cmap = buildCmap(@[(0x0E14u16, 1u16), (0x0E4Bu16, 2u16),
    (0x0E4Du16, 4u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E14\u0E4B\u0E4D") ==
    @[1u32, 2u32, 4u32]

test "thai pua shapes mai ek above a plain consonant":
  let cmap = buildCmap(@[(0x0E01u16, 1u16), (0xF70Au16, 2u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E01\u0E48") ==
    @[1u32, 2u32]

test "thai pua removes the descender with sara u":
  let cmap = buildCmap(@[(0x0E0Du16, 1u16), (0x0E38u16, 2u16),
    (0xF70Fu16, 3u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E0D\u0E38") ==
    @[3u32, 2u32]

test "thai pua is skipped when the font has thai gsub":
  let cmap = buildCmap(@[(0x0E01u16, 1u16), (0x0E48u16, 4u16),
    (0xF70Au16, 2u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", buildGsubThaiDummy()))
  check shapeGids(buildFontRaw(tables), "\u0E01\u0E48") == @[1u32, 4u32]

test "lao text never takes the pua path":
  let cmap = buildCmap(@[(0x0EDCu16, 1u16), (0x0EC8u16, 2u16),
    (0xF70Au16, 3u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0EDC\u0EC8") ==
    @[1u32, 2u32]

test "thai pua falls back to mac glyphs":
  # Win PUA F70A missing, Mac PUA F88B present: MAI EK still remaps.
  let cmap = buildCmap(@[(0x0E01u16, 1u16), (0xF88Bu16, 2u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E01\u0E48") ==
    @[1u32, 2u32]

test "thai pua leaves marks alone without pua glyphs":
  let cmap = buildCmap(@[(0x0E01u16, 1u16), (0x0E48u16, 4u16)])
  check shapeGids(buildFontRaw(baseTables(cmap)), "\u0E01\u0E48") ==
    @[1u32, 4u32]
