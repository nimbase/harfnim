import std/options
import unittest

import harfnim
import harfnim/ot/arabic
import harfnim/ot/arabic_table
import harfnim/ot/map

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
  result.putU16(segX2 - 4u16)
  for pr in sorted:
    result.putU16(pr.cp)
  result.putU16(0xFFFFu16)
  result.putU16(0u16)
  for pr in sorted:
    result.putU16(pr.cp)
  result.putU16(0xFFFFu16)
  for pr in sorted:
    let d = (int(pr.gid) - int(pr.cp)) and 0xFFFF
    result.putU16(uint16(d))
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

proc buildGsubArab(features: seq[tuple[tag: string, fromGid, toGid: uint16]]): seq[
    uint8] =
  # One SingleSubst lookup per feature, all under arab/dflt.
  let n = features.len
  result = @[]
  result.putU32(0x00010000u32)
  # Offsets: scriptList=10, featureList=?, lookupList=?
  # Compute layout: header 10, scriptList (8+...), featureList, lookupList.
  # ScriptList: count=1, tag arab, off=8; script: dflt=4, langCount=0, dflt lang: req=FFFF, count=n, indices 0..n-1
  # FeatureList: count=n, each entry tag+off; each feature: params=0, count=1, lookupIdx
  # LookupList: count=n, offsets; each lookup: type=1, flag=9 (RTL+IgnoreMarks), subCount=1, subOff=8, subtable
  let scriptLen = 2 + 6 + (2 + 2 + 2 + 2 + 2 + n * 2)
  let featEntryLen = n * 6
  let featLen = 2 + featEntryLen + n * 6
  let lookupOffsetsStart = 10 + scriptLen + featLen + 2
  var lookupSize = 0
  var subSizes: seq[int] = @[]
  for _ in features:
    # lookup header 8 + subtable (6 + 2 + cov 6) = 8 + 14 = 22? singleSubstBytes gives 6+? Actually 2+2+2+2 + cov(2+2+2)=6+6=12? Let's compute: format2, covOff, count, sub, coverage(1,1,gid) = 2+2+2+2 + (2+2+2)=8+6=14. Lookup header 8. Total 22.
    subSizes.add(22)
  let featOff = 10 + scriptLen
  let lookupOff = featOff + featLen
  result.putU16(10u16)
  result.putU16(uint16(featOff))
  result.putU16(uint16(lookupOff))
  # ScriptList
  result.putU16(1u16)
  result.putTag("arab")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(uint16(n))
  for i in 0 ..< n:
    result.putU16(uint16(i))
  # FeatureList
  result.putU16(uint16(n))
  var featBase = 2 + n * 6
  for i, f in features:
    result.putTag(f.tag)
    result.putU16(uint16(featBase + i * 6))
  for i in 0 ..< n:
    result.putU16(0u16)
    result.putU16(1u16)
    result.putU16(uint16(i))
  # LookupList
  result.putU16(uint16(n))
  var loff = 2 + n * 2
  for i in 0 ..< n:
    result.putU16(uint16(loff))
    loff += 8 + subSizes[i]
  for i, f in features:
    result.putU16(1u16)
    result.putU16(9u16)
    result.putU16(1u16)
    result.putU16(8u16)
    for b in singleSubstBytes(f.fromGid, f.toGid):
      result.add(b)

test "joining types match Unicode":
  check joiningTypeFor(0x0627u32, GcOtherLetter) == ajR
  check joiningTypeFor(0x0628u32, GcOtherLetter) == ajD
  check joiningTypeFor(0x0645u32, GcOtherLetter) == ajD
  check joiningTypeFor(0x0631u32, GcOtherLetter) == ajR
  check joiningTypeFor(0x0640u32, GcModifierLetter) == ajD
  check joiningTypeFor(0x0710u32, GcOtherLetter) == ajAlaph
  check joiningTypeFor(0x0715u32, GcOtherLetter) == ajDalath
  # Transparent: marks resolve to T.
  check joiningTypeFor(0x064Eu32, GcNonSpacingMark) == ajT

test "arabic joining assigns init/medi/fina/isol":
  var b = newBuffer()
  # MEEM, REH, HAH, BEH, ALEF (logical order of مرحبا).
  b.pushStr("\u0645\u0631\u062D\u0628\u0627")
  b.guessSegmentProperties()
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.arabicJoining()
  check b.info[0].arabicAction() == ArabicInit
  check b.info[1].arabicAction() == ArabicFina
  check b.info[2].arabicAction() == ArabicInit
  # BEH between two duals: medi (both sides join).
  check b.info[3].arabicAction() == ArabicMedi
  check b.info[4].arabicAction() == ArabicFina

test "arabic gsub applies joining features":
  # ALEF alone is isol: U+0627 -> gid 10, isol form -> gid 20.
  let cmap = buildCmap(@[(0x0627u16, 10u16)])
  let gsub = buildGsubArab(@[("isol", 10u16, 20u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", gsub))
  let fontBytes = buildFontRaw(tables)
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr("\u0627")
  sf.shape(b, @[])
  check b.len == 1
  check b.info[0].glyphId == 20u32

test "arabic fallback synthesizes presentation forms":
  # No GSUB. MEEM U+0645 -> gid 11, isol form FEE1 -> gid 23.
  let cmap = buildCmap(@[(0x0645u16, 11u16), (0xFEE1u16, 23u16)])
  var tables = baseTables(cmap)
  let fontBytes = buildFontRaw(tables)
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr("\u0645")
  sf.shape(b, @[])
  check b.len == 1
  check b.info[0].glyphId == 23u32

test "arabic mark base positions via GPOS":
  # BEH base (U+0628 -> gid 10) + FATHA mark (U+064E -> gid 11).
  # MarkBase: mark anchor (100,200), base anchor (50,150) -> offset (-50,-50).
  let cmap = buildCmap(@[(0x0628u16, 10u16), (0x064Eu16, 11u16)])
  var tables = baseTables(cmap)
  # Build minimal GPOS with mark feature.
  var gpos: seq[uint8] = @[]
  gpos.putU32(0x00010000u32)
  gpos.putU16(10u16)
  gpos.putU16(30u16)
  gpos.putU16(44u16)
  # ScriptList: arab/dflt with mark feature index 0
  gpos.putU16(1u16)
  gpos.putTag("arab")
  gpos.putU16(8u16)
  gpos.putU16(4u16)
  gpos.putU16(0u16)
  gpos.putU16(0u16)
  gpos.putU16(0xFFFFu16)
  gpos.putU16(1u16)
  gpos.putU16(0u16)
  # FeatureList: mark -> lookup 0
  gpos.putU16(1u16)
  gpos.putTag("mark")
  gpos.putU16(8u16)
  gpos.putU16(0u16)
  gpos.putU16(1u16)
  gpos.putU16(0u16)
  # LookupList: 1 lookup type 4
  gpos.putU16(1u16)
  gpos.putU16(4u16)
  gpos.putU16(4u16)
  gpos.putU16(0u16)
  gpos.putU16(1u16)
  gpos.putU16(8u16)
  # MarkBasePosFormat1 at lookup+8
  # markCovOff, baseCovOff, classCount, markArrayOff, baseArrayOff
  # Layout: header 12 bytes, then markCov, baseCov, markArray, baseArray
  let markCovOff = 12
  let baseCovOff = markCovOff + 6
  let markArrayOff = baseCovOff + 6
  let baseArrayOff = markArrayOff + 12
  gpos.putU16(1u16)
  gpos.putU16(uint16(markCovOff))
  gpos.putU16(uint16(baseCovOff))
  gpos.putU16(1u16)
  gpos.putU16(uint16(markArrayOff))
  gpos.putU16(uint16(baseArrayOff))
  # markCoverage [11]
  for b in covBytes(@[11u16]): gpos.add(b)
  # baseCoverage [10]
  for b in covBytes(@[10u16]): gpos.add(b)
  # markArray: count=1, class=0, anchorOff=6
  gpos.putU16(1u16)
  gpos.putU16(0u16)
  gpos.putU16(6u16)
  # markAnchor format1 x=100 y=200
  gpos.putU16(1u16)
  gpos.putI16(100i16)
  gpos.putI16(200i16)
  # baseArray: count=1, anchorOff=4 (class 0)
  gpos.putU16(1u16)
  gpos.putU16(4u16)
  # baseAnchor format1 x=50 y=150
  gpos.putU16(1u16)
  gpos.putI16(50i16)
  gpos.putI16(150i16)
  tables.add(("GPOS", gpos))
  let fontBytes = buildFontRaw(tables)
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  sf.setScale(1000)
  var b = newBuffer()
  b.pushStr("\u0628\u064E")
  sf.shape(b, @[])
  check b.len == 2
  # Visual order RTL: base first? BEH+mark, no joining change, reversed? Single base, mark follows in logical, reversed? BEH (D) alone? Actually BEH+FATHA: BEH isol? With no GSUB, fallback isol? No presentation forms in cmap, so no fallback. Order: logical [BEH, mark], RTL reverse -> [mark?, base?]? HarfBuzz keeps base+mark cluster together, reversed as unit? For base+mark, reverse keeps base before mark? Actually RTL reverse reverses glyphs, but base+mark cluster... Our reverse reverses all. Logical [base, mark] -> visual [mark, base]? No, HarfBuzz reverses but keeps marks with base? Hmm. For simplicity, check that one glyph has offset (-50,-50) and mark advance is 0.
  var sawMark = false
  for i in 0 ..< b.len:
    if b.info[i].glyphId == 11u32:
      check b.pos[i].xAdvance == 0i32
      check b.pos[i].xOffset == -50i32
      check b.pos[i].yOffset == -50i32
      sawMark = true
  check sawMark
