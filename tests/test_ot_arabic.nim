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
    loff += subSizes[i]
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
  # Grapheme cluster merging: the mark shares its base cluster.
  check b.info[0].cluster == b.info[1].cluster
  var sawMark = false
  for i in 0 ..< b.len:
    if b.info[i].glyphId == 11u32:
      check b.pos[i].xAdvance == 0i32
      check b.pos[i].xOffset == -50i32
      check b.pos[i].yOffset == -50i32
      sawMark = true
  check sawMark

proc win1256Cmap(extra: seq[tuple[cp, gid: uint16]] = @[]): seq[uint8] =
  var pairs = @[
    (0x0627u16, 199u16), (0x0644u16, 225u16), (0x0649u16, 236u16),
    (0x064Au16, 237u16), (0x0652u16, 250u16),
  ]
  for e in extra:
    pairs.add(e)
  buildCmap(pairs)

test "win1256 signature detection":
  let f = parseFont(buildFontRaw(baseTables(win1256Cmap())))
  var sf = newShaperFont(f)
  let nominal = proc(cp: uint32): Option[GlyphId] = sf.nominalGlyph(cp)
  check isWin1256Font(nominal)
  # One entry off breaks the signature.
  let f2 = parseFont(buildFontRaw(baseTables(win1256Cmap(
    @[(0x0628u16, 198u16)]))))
  var sf2 = newShaperFont(f2)
  let nominal2 = proc(cp: uint32): Option[GlyphId] = sf2.nominalGlyph(cp)
  check isWin1256Font(nominal2)
  let f3 = parseFont(buildFontRaw(baseTables(buildCmap(
    @[(0x0627u16, 200u16), (0x0644u16, 225u16), (0x0649u16, 236u16),
      (0x064Au16, 237u16), (0x0652u16, 250u16)]))))
  var sf3 = newShaperFont(f3)
  let nominal3 = proc(cp: uint32): Option[GlyphId] = sf3.nominalGlyph(cp)
  check (not isWin1256Font(nominal3))

test "win1256 tables are sorted and bounded":
  for t in [win1256Singles(0), win1256Singles(1), win1256Singles(2)]:
    check t.len > 0
    for i in 1 ..< t.len:
      check t[i - 1].fromGid < t[i].fromGid
  check win1256LamAlefLigs().len == 4
  check win1256ShaddaLigs().len == 3
  check win1256Singles(3).len == 0

test "win1256 fallback shapes beh-beh":
  # BEH U+0628 -> gid 198; init -> 162, fina -> 181.
  # RTL output is in visual order, so the final (rightmost logical)
  # glyph comes first.
  let cmap = win1256Cmap(@[(0x0628u16, 198u16)])
  let fontBytes = buildFontRaw(baseTables(cmap))
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr("\u0628\u0628")
  sf.shape(b, @[])
  check b.len == 2
  check b.info[0].glyphId == 181u32
  check b.info[1].glyphId == 162u32

test "win1256 fallback forms lam-alef ligature":
  let cmap = win1256Cmap()
  let fontBytes = buildFontRaw(baseTables(cmap))
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr("\u0644\u0627")
  sf.shape(b, @[])
  check b.len == 1
  check b.info[0].glyphId == 165u32

test "non-win1256 font keeps base glyphs":
  # Same text, but the signature is broken: no fallback applies.
  let cmap = buildCmap(@[(0x0627u16, 200u16), (0x0644u16, 225u16),
    (0x0649u16, 236u16), (0x064Au16, 237u16), (0x0652u16, 250u16),
    (0x0628u16, 198u16)])
  let fontBytes = buildFontRaw(baseTables(cmap))
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  var b = newBuffer()
  b.pushStr("\u0628\u0628")
  sf.shape(b, @[])
  check b.len == 2
  check b.info[0].glyphId == 198u32
  check b.info[1].glyphId == 198u32

proc shapeRunDir(fontBytes: seq[uint8], text: string,
    d: Direction): Buffer =
  # Shapes one bidi run with an explicit direction, the ex05 pattern.
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  result = newBuffer()
  result.pushStr(text)
  result.setDirection(d)
  sf.shape(result, @[])

proc visualGlyphs(fontBytes: seq[uint8],
    text: string): seq[tuple[gid, cluster: uint32]] =
  # Shapes each visualRuns run with its own direction and concatenates
  # the runs in visual order, mapping run-relative clusters back to
  # paragraph bytes.
  let vt = visualRuns(text, bdAuto)
  result = @[]
  for run in vt.runs:
    var srcMin = text.len
    var srcMax = -1
    for j in run.first ..< run.last:
      if j < vt.map.len - 1:
        srcMin = min(srcMin, vt.map[j])
        srcMax = max(srcMax, vt.map[j])
    let b = shapeRunDir(fontBytes, text[srcMin .. srcMax], run.dir)
    for i in 0 ..< b.len:
      result.add((gid: b.info[i].glyphId,
        cluster: b.info[i].cluster + uint32(srcMin)))

test "arabic latin mixed runs join inside the rtl run":
  # a(10) c(11); BEH(20) with init(21) medi(22) fina(23) isol(24).
  let cmap = buildCmap(@[(0x0061u16, 10u16), (0x0063u16, 11u16),
    (0x0628u16, 20u16)])
  let gsub = buildGsubArab(@[("init", 20u16, 21u16),
    ("medi", 20u16, 22u16), ("fina", 20u16, 23u16),
    ("isol", 20u16, 24u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", gsub))
  let fontBytes = buildFontRaw(tables)
  # Bytes: a@0 BEH@1 BEH@3 c@5.
  let text = "a\u0628\u0628c"
  let vt = visualRuns(text, bdAuto)
  check vt.runs.len == 3
  check vt.runs[0].level == 0
  check vt.runs[1].level == 1
  check vt.runs[2].level == 0
  check vt.runs[1].dir == dirRightToLeft
  # Logical BEH BEH join to init plus fina, then reverse to visual
  # order; each letter keeps its own cluster, unlike base plus mark.
  check visualGlyphs(fontBytes, text) == @[(gid: 10u32, cluster: 0u32),
    (gid: 23u32, cluster: 3u32), (gid: 21u32, cluster: 1u32),
    (gid: 11u32, cluster: 5u32)]

test "arabic and hebrew runs keep their own shapers":
  # a(10) b(11) c(12); BEH(20) with joining forms; BET(30) SHEVA(31).
  let cmap = buildCmap(@[(0x0061u16, 10u16), (0x0062u16, 11u16),
    (0x0063u16, 12u16), (0x0628u16, 20u16), (0x05D1u16, 30u16),
    (0x05B0u16, 31u16)])
  let gsub = buildGsubArab(@[("init", 20u16, 21u16),
    ("medi", 20u16, 22u16), ("fina", 20u16, 23u16),
    ("isol", 20u16, 24u16)])
  var tables = baseTables(cmap)
  tables.add(("GSUB", gsub))
  let fontBytes = buildFontRaw(tables)
  # Bytes: a@0 BEH@1 b@3 BET@4 SHEVA@6 c@8.
  let text = "a\u0628b\u05D1\u05B0c"
  let vt = visualRuns(text, bdAuto)
  check vt.runs.len == 5
  check vt.runs[0].level == 0
  check vt.runs[1].level == 1
  check vt.runs[2].level == 0
  check vt.runs[3].level == 1
  check vt.runs[4].level == 0
  # The lone BEH takes the isol form through the arabic shaper while
  # the Hebrew run reverses to SHEVA BET; the mark merges into the
  # base cluster.
  check visualGlyphs(fontBytes, text) == @[(gid: 10u32, cluster: 0u32),
    (gid: 24u32, cluster: 1u32), (gid: 11u32, cluster: 3u32),
    (gid: 31u32, cluster: 4u32), (gid: 30u32, cluster: 4u32),
    (gid: 12u32, cluster: 8u32)]

proc buildGsubStch(): seq[uint8] =
  # arab/dflt with stch/init/fina mapping to lookups 0/1/2.
  # stch is a multiple substitution 10 -> [14, 15]; init maps
  # 10 -> 12 and fina maps 11 -> 13.
  var lookup0: seq[uint8] = @[]
  lookup0.putU16(2u16)
  lookup0.putU16(9u16)
  lookup0.putU16(1u16)
  lookup0.putU16(8u16)
  lookup0.putU16(1u16)
  lookup0.putU16(8u16)
  lookup0.putU16(1u16)
  lookup0.putU16(14u16)
  lookup0.putU16(1u16)
  lookup0.putU16(1u16)
  lookup0.putU16(10u16)
  lookup0.putU16(2u16)
  lookup0.putU16(14u16)
  lookup0.putU16(15u16)
  var lookup1: seq[uint8] = @[]
  lookup1.putU16(1u16)
  lookup1.putU16(9u16)
  lookup1.putU16(1u16)
  lookup1.putU16(8u16)
  lookup1.putU16(2u16)
  lookup1.putU16(8u16)
  lookup1.putU16(1u16)
  lookup1.putU16(12u16)
  lookup1.putU16(1u16)
  lookup1.putU16(1u16)
  lookup1.putU16(10u16)
  var lookup2: seq[uint8] = @[]
  lookup2.putU16(1u16)
  lookup2.putU16(9u16)
  lookup2.putU16(1u16)
  lookup2.putU16(8u16)
  lookup2.putU16(2u16)
  lookup2.putU16(8u16)
  lookup2.putU16(1u16)
  lookup2.putU16(13u16)
  lookup2.putU16(1u16)
  lookup2.putU16(1u16)
  lookup2.putU16(11u16)
  doAssert lookup0.len == 28
  doAssert lookup1.len == 22
  doAssert lookup2.len == 22
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(10u16)
  result.putU16(34u16)
  result.putU16(72u16)
  result.putU16(1u16)
  result.putTag("arab")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(3u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(2u16)
  result.putU16(3u16)
  result.putTag("stch")
  result.putU16(20u16)
  result.putTag("init")
  result.putU16(26u16)
  result.putTag("fina")
  result.putU16(32u16)
  for li in [0u16, 1u16, 2u16]:
    result.putU16(0u16)
    result.putU16(1u16)
    result.putU16(li)
  result.putU16(3u16)
  result.putU16(8u16)
  result.putU16(uint16(8 + lookup0.len))
  result.putU16(uint16(8 + lookup0.len + lookup1.len))
  result.add(lookup0)
  result.add(lookup1)
  result.add(lookup2)
  doAssert result.len == 72 + 8 + 28 + 22 + 22

proc stchFont(fixedAdv, repAdv: uint16): seq[uint8] =
  # BEH U+0628 -> 10, ALEF U+0627 -> 11; stretch tiles 14 (fixed)
  # and 15 (repeating) take the given advances, everything else 600.
  let cmap = buildCmap(@[(0x627u16, 11u16), (0x628u16, 10u16)])
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
  hhea.putU16(16u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(32u16)
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  for _ in 1 ..< 14:
    hmtx.putU16(600u16)
    hmtx.putI16(0i16)
  hmtx.putU16(fixedAdv)
  hmtx.putI16(0i16)
  hmtx.putU16(repAdv)
  hmtx.putI16(0i16)
  var loca = newSeq[uint8](66)
  let tables = @[("head", head), ("hhea", hhea), ("maxp", maxp),
    ("hmtx", hmtx), ("cmap", cmap), ("loca", loca),
    ("GSUB", buildGsubStch())]
  buildFontRaw(tables)

proc shapeStch(text: string, fixedAdv, repAdv: uint16): Buffer =
  let f = parseFont(stchFont(fixedAdv, repAdv))
  var sf = newShaperFont(f)
  sf.setScale(1000)
  result = newBuffer()
  result.pushStr(text)
  sf.shape(result, @[])

test "stch record marks multiplied tiles":
  var b = newBuffer()
  b.pushStr("ab")
  b.info[0].setGlyphProps(b.info[0].glyphProps() or GlyphPropMultiplied)
  b.info[0].setLigPropsForComponent(0u8)
  b.info[1].setGlyphProps(b.info[1].glyphProps() or GlyphPropMultiplied)
  b.info[1].setLigPropsForComponent(1u8)
  check isStchAction(ArabicStretchFixed)
  check isStchAction(ArabicStretchRepeating)
  check not isStchAction(ArabicInit)
  b.recordStch(false)
  check (b.scratchFlags and ArabicHasStchFlag) == 0u32
  b.recordStch(true)
  check (b.scratchFlags and ArabicHasStchFlag) != 0u32
  check b.info[0].arabicAction() == ArabicStretchFixed
  check b.info[1].arabicAction() == ArabicStretchRepeating

test "stch run without room keeps one copy per tile":
  # BEH plus ALEF: BEH multiplies to fixed plus repeating tiles while
  # ALEF takes fina. The preceding word covers exactly the fixed tile,
  # so nothing repeats: advances zero out and offsets center the rest.
  let b = shapeStch("\u0628\u0627", 600u16, 600u16)
  check b.len == 3
  check b.info[0].glyphId == 13u32
  check b.info[1].glyphId == 15u32
  check b.info[2].glyphId == 14u32
  check b.info[0].cluster == 2u32
  check b.info[1].cluster == 0u32
  check b.info[2].cluster == 0u32
  check b.pos[0].xAdvance == 600i32
  check b.pos[1].xAdvance == 0i32
  check b.pos[2].xAdvance == 0i32
  check b.pos[0].xOffset == 0i32
  check b.pos[1].xOffset == -1200i32
  check b.pos[2].xOffset == -600i32
  check b.info[1].arabicAction() == ArabicStretchRepeating
  check b.info[2].arabicAction() == ArabicStretchFixed

test "stch expands repeating tiles to fill the word":
  # Narrow tiles leave room: the word advance minus the fixed tile
  # repeats the repeating tile five times in total.
  let b = shapeStch("\u0628\u0627", 100u16, 100u16)
  check b.len == 7
  check b.info[0].glyphId == 13u32
  for i in 1 ..< 6:
    check b.info[i].glyphId == 15u32
  check b.info[6].glyphId == 14u32
  for i in 0 ..< 7:
    if i == 0:
      check b.info[i].cluster == 2u32
    else:
      check b.info[i].cluster == 0u32
  check b.pos[0].xAdvance == 600i32
  for i in 1 ..< 7:
    check b.pos[i].xAdvance == 0i32
  let offs = [0i32, -350i32, -250i32, -150i32, -50i32, 50i32, 150i32]
  for i in 0 ..< 7:
    check b.pos[i].xOffset == offs[i]

test "stch expands ltr runs after reversing":
  # Manual left-to-right run: fixed tile, repeating tile, word glyph.
  # The shaper reverses around the run and restores order afterwards.
  # The word glyph is a CJK ideograph: Ll letters are not
  # word-category (mirroring harfrust), Lo letters are.
  let f = parseFont(stchFont(100u16, 100u16))
  var sf = newShaperFont(f)
  sf.setScale(1000)
  var b = newBuffer()
  b.pushStr("ab\u4E2D")
  b.guessSegmentProperties()
  var scratch = 0u32
  for i in 0 ..< b.len:
    b.info[i].initUnicodeProps(scratch)
  b.scratchFlags = scratch
  b.info[0].glyphId = 14u32
  b.info[1].glyphId = 15u32
  b.info[2].glyphId = 20u32
  b.info[0].setGlyphProps(b.info[0].glyphProps() or GlyphPropMultiplied)
  b.info[0].setLigPropsForComponent(0u8)
  b.info[1].setGlyphProps(b.info[1].glyphProps() or GlyphPropMultiplied)
  b.info[1].setLigPropsForComponent(1u8)
  b.recordStch(true)
  doAssert b.ensure(3)
  b.clearPositions()
  b.pos[0].xAdvance = 100i32
  b.pos[1].xAdvance = 100i32
  b.pos[2].xAdvance = 600i32
  applyStch(sf, b)
  check b.len == 7
  check b.info[0].glyphId == 14u32
  for i in 1 ..< 6:
    check b.info[i].glyphId == 15u32
  check b.info[6].glyphId == 20u32
  check b.info[0].cluster == 0u32
  for i in 1 ..< 6:
    check b.info[i].cluster == 1u32
  check b.info[6].cluster == 2u32
  for i in 0 ..< 6:
    check b.pos[i].xAdvance == 0i32
  check b.pos[6].xAdvance == 600i32
  let offs = [250i32, 350i32, 450i32, 550i32, 650i32, 750i32, 0i32]
  for i in 0 ..< 7:
    check b.pos[i].xOffset == offs[i]
