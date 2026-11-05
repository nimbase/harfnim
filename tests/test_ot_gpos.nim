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

proc putU16At(s: var seq[uint8], pos: int, v: uint16) =
  doAssert pos >= 0 and pos + 2 <= s.len
  s[pos] = uint8(v shr 8)
  s[pos + 1] = uint8(v and 0xFFu16)

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

proc buildFontTables(gpos: seq[uint8]): seq[uint8] =
  let cmapData = buildCmapSingle()
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
    ("cmap", cmapData), ("loca", loca),
  ]
  if gpos.len > 0:
    tables.add(("GPOS", gpos))
  buildFontRaw(tables)

proc coverageBytes(glyphs: seq[uint16]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(uint16(glyphs.len))
  for g in glyphs:
    result.putU16(g)

proc classDefFormat1Bytes(start: uint16, classes: seq[uint16]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(start)
  result.putU16(uint16(classes.len))
  for c in classes:
    result.putU16(c)

proc buildSinglePos1(covGlyph: uint16, valueFormat: uint16,
    values: seq[int16]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(valueFormat)
  for v in values:
    result.putI16(v)
  let covOff = result.len
  for b in coverageBytes(@[covGlyph]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))

proc buildSinglePos2(covGlyphs: seq[uint16], valueFormat: uint16,
    values: seq[seq[int16]]): seq[uint8] =
  result = @[]
  result.putU16(2u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(valueFormat)
  result.putU16(uint16(covGlyphs.len))
  for row in values:
    for v in row:
      result.putI16(v)
  let covOff = result.len
  for b in coverageBytes(covGlyphs):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))

proc buildPairSet(pairs: seq[tuple[second: uint16, v1, v2: seq[int16]]]): seq[
    uint8] =
  result = @[]
  result.putU16(uint16(pairs.len))
  for p in pairs:
    result.putU16(p.second)
    for v in p.v1:
      result.putI16(v)
    for v in p.v2:
      result.putI16(v)

proc buildPairPos1(firstCov: uint16, format1, format2: uint16,
    pairSets: seq[seq[tuple[second: uint16, v1, v2: seq[int16]]]]): seq[
    uint8] =
  result = @[]
  result.putU16(1u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(format1)
  result.putU16(format2)
  result.putU16(uint16(pairSets.len))
  var setPoss: seq[int] = @[]
  for _ in pairSets:
    setPoss.add(result.len)
    result.putU16(0u16)
  let covOff = result.len
  for b in coverageBytes(@[firstCov]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))
  for i, pairs in pairSets:
    let off = result.len
    result.putU16At(setPoss[i], uint16(off))
    for b in buildPairSet(pairs):
      result.add(b)

proc buildPairPos2(firstCov: uint16, format1, format2: uint16,
    classDef1, classDef2: seq[uint8], class1Count, class2Count: uint16,
    matrix: seq[seq[int16]]): seq[uint8] =
  result = @[]
  result.putU16(2u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(format1)
  result.putU16(format2)
  let cd1Pos = result.len
  result.putU16(0u16)
  let cd2Pos = result.len
  result.putU16(0u16)
  result.putU16(class1Count)
  result.putU16(class2Count)
  for row in matrix:
    for v in row:
      result.putI16(v)
  let covOff = result.len
  for b in coverageBytes(@[firstCov]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))
  let cd1Off = result.len
  for b in classDef1:
    result.add(b)
  result.putU16At(cd1Pos, uint16(cd1Off))
  let cd2Off = result.len
  for b in classDef2:
    result.add(b)
  result.putU16At(cd2Pos, uint16(cd2Off))

proc extensionBytes(extType: uint16, inner: seq[uint8]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(extType)
  result.putU32(8u32)
  for b in inner:
    result.add(b)

proc buildGposOneLookup(feature: string, lookupType: uint16,
    sub: seq[uint8]): seq[uint8] =
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
  result.putU16(lookupType)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(8u16)
  for b in sub:
    result.add(b)

proc shapeWithGpos(fontBytes: seq[uint8], text: string,
    feats: seq[Feature]): seq[tuple[gid: uint32, xAdv, xOff, yAdv,
    yOff: int32]] =
  let f = parseFont(fontBytes)
  let sf = newShaperFont(f)
  let gposOpt = parseGpos(f)
  doAssert gposOpt.isSome
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
  b.clearPositions()
  for i in 0 ..< b.len:
    b.pos[i].xAdvance = sf.hAdvance(newGlyphId(b.info[i].glyphId))
  b.applyGposFeatures(gposOpt.get, tagFromStr("latn"), tagFromStr("dflt"),
    feats, sf.scale)
  b.deallocateGsubGposVars()
  result = @[]
  for i in 0 ..< b.len:
    result.add((b.info[i].glyphId, b.pos[i].xAdvance, b.pos[i].xOffset,
      b.pos[i].yAdvance, b.pos[i].yOffset))

test "singlepos adjusts placement":
  let sub = buildSinglePos1(1u16, 0x0001u16, @[50i16])
  let gpos = buildGposOneLookup("kern", 1u16, sub)
  let got = shapeWithGpos(buildFontTables(gpos), "A",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got.len == 1
  check got[0].gid == 1u32
  check got[0].xOff == 50i32
  check got[0].xAdv == 600i32
  let miss = shapeWithGpos(buildFontTables(gpos), "B",
    @[globalFeature(tagFromStr("kern"), 1)])
  check miss[0].gid == 2u32
  check miss[0].xOff == 0i32
  check miss[0].xAdv == 600i32

test "pairpos kerns pair":
  let sub = buildPairPos1(1u16, 0x0004u16, 0u16,
    @[@[(2u16, @[-80i16], newSeq[int16]())]])
  let gpos = buildGposOneLookup("kern", 2u16, sub)
  let got = shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got == @[(1u32, 520i32, 0i32, 0i32, 0i32),
    (2u32, 600i32, 0i32, 0i32, 0i32)]
  check shapeWithGpos(buildFontTables(gpos), "BA",
    @[globalFeature(tagFromStr("kern"), 1)]) ==
    @[(2u32, 600i32, 0i32, 0i32, 0i32), (1u32, 600i32, 0i32, 0i32, 0i32)]
  check shapeWithGpos(buildFontTables(gpos), "AA",
    @[globalFeature(tagFromStr("kern"), 1)]) ==
    @[(1u32, 600i32, 0i32, 0i32, 0i32), (1u32, 600i32, 0i32, 0i32, 0i32)]

test "pairpos format2 class kerns":
  let cd1 = classDefFormat1Bytes(1u16, @[1u16, 0u16])
  let cd2 = classDefFormat1Bytes(1u16, @[0u16, 1u16])
  let sub = buildPairPos2(1u16, 0x0004u16, 0u16, cd1, cd2, 2u16, 2u16,
    @[@[0i16], @[0i16], @[0i16], @[-80i16]])
  let gpos = buildGposOneLookup("kern", 2u16, sub)
  let got = shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got == @[(1u32, 520i32, 0i32, 0i32, 0i32),
    (2u32, 600i32, 0i32, 0i32, 0i32)]
  check shapeWithGpos(buildFontTables(gpos), "BA",
    @[globalFeature(tagFromStr("kern"), 1)]) ==
    @[(2u32, 600i32, 0i32, 0i32, 0i32), (1u32, 600i32, 0i32, 0i32, 0i32)]

proc buildGposTwoLookups(feature: string, lookupType0: uint16,
    sub0: seq[uint8], lookupType1: uint16, sub1: seq[uint8]): seq[uint8] =
  ## Feature enables lookup 0 only; lookup 1 is reachable as a nested
  ## target via its lookup-list index 1.
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
  # LookupList with 2 lookups.
  result.putU16(2u16)
  result.putU16(6u16) # lookup0 at list+6
  result.putU16(14u16) # lookup1 at list+14
  # Lookup0 header (at list+6).
  result.putU16(lookupType0)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(16u16) # sub after both headers (8+8)
  # Lookup1 header (at list+14).
  result.putU16(lookupType1)
  result.putU16(0u16)
  result.putU16(1u16)
  let sub1OffPos = result.len
  result.putU16(0u16) # patched below
  let sub0Off = result.len
  for b in sub0:
    result.add(b)
  let sub1Off = result.len
  for b in sub1:
    result.add(b)
  # Patch lookup1 sub offset: headers are 16 bytes, sub0 follows.
  let l1Base = 44 + 14
  result.putU16At(l1Base + 6, uint16(sub1Off - l1Base))
  doAssert sub0Off == 44 + 6 + 16

proc buildSeqRule(input: seq[uint16], seqIndex, lookupIndex: uint16): seq[
    uint8] =
  result = @[]
  result.putU16(uint16(input.len + 1))
  result.putU16(1u16)
  for g in input:
    result.putU16(g)
  result.putU16(seqIndex)
  result.putU16(lookupIndex)

proc buildSeqRuleSet(rules: seq[seq[uint8]]): seq[uint8] =
  result = @[]
  result.putU16(uint16(rules.len))
  var offs: seq[int] = @[]
  for _ in rules:
    offs.add(result.len)
    result.putU16(0u16)
  for i, r in rules:
    let off = result.len
    result.putU16At(offs[i], uint16(off))
    for b in r:
      result.add(b)

proc buildContextPos1(firstCov: uint16, inputRest: seq[uint16], seqIndex,
    lookupIndex: uint16): seq[uint8] =
  ## SequenceContextFormat1 (GPOS type 7): first glyph covered, rest in rule.
  let rule = buildSeqRule(inputRest, seqIndex, lookupIndex)
  let ruleSet = buildSeqRuleSet(@[rule])
  result = @[]
  result.putU16(1u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(1u16) # one ruleset
  let setPos = result.len
  result.putU16(0u16)
  let covOff = result.len
  for b in coverageBytes(@[firstCov]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))
  let setOff = result.len
  for b in ruleSet:
    result.add(b)
  result.putU16At(setPos, uint16(setOff))

proc buildContextPos3(coverages: seq[seq[uint16]], seqIndex,
    lookupIndex: uint16): seq[uint8] =
  ## SequenceContextFormat3: one coverage per input position.
  result = @[]
  result.putU16(3u16)
  result.putU16(uint16(coverages.len))
  result.putU16(1u16)
  var covPoss: seq[int] = @[]
  for _ in coverages:
    covPoss.add(result.len)
    result.putU16(0u16)
  result.putU16(seqIndex)
  result.putU16(lookupIndex)
  for i, cov in coverages:
    let off = result.len
    result.putU16At(covPoss[i], uint16(off))
    for b in coverageBytes(cov):
      result.add(b)

proc buildChainRule(backtrack, inputRest, lookahead: seq[uint16], seqIndex,
    lookupIndex: uint16): seq[uint8] =
  result = @[]
  result.putU16(uint16(backtrack.len))
  for g in backtrack:
    result.putU16(g)
  result.putU16(uint16(inputRest.len + 1))
  for g in inputRest:
    result.putU16(g)
  result.putU16(uint16(lookahead.len))
  for g in lookahead:
    result.putU16(g)
  result.putU16(1u16)
  result.putU16(seqIndex)
  result.putU16(lookupIndex)

proc buildChainedContextPos1(firstCov: uint16, backtrack,
    inputRest, lookahead: seq[uint16], seqIndex,
    lookupIndex: uint16): seq[uint8] =
  let rule = buildChainRule(backtrack, inputRest, lookahead, seqIndex,
    lookupIndex)
  let ruleSet = buildSeqRuleSet(@[rule])
  result = @[]
  result.putU16(1u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(1u16)
  let setPos = result.len
  result.putU16(0u16)
  let covOff = result.len
  for b in coverageBytes(@[firstCov]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))
  let setOff = result.len
  for b in ruleSet:
    result.add(b)
  result.putU16At(setPos, uint16(setOff))

proc buildChainedContextPos3(backtrack, input,
    lookahead: seq[seq[uint16]], seqIndex,
    lookupIndex: uint16): seq[uint8] =
  result = @[]
  result.putU16(3u16)
  result.putU16(uint16(backtrack.len))
  var backPoss: seq[int] = @[]
  for _ in backtrack:
    backPoss.add(result.len)
    result.putU16(0u16)
  result.putU16(uint16(input.len))
  var inPoss: seq[int] = @[]
  for _ in input:
    inPoss.add(result.len)
    result.putU16(0u16)
  result.putU16(uint16(lookahead.len))
  var lookPoss: seq[int] = @[]
  for _ in lookahead:
    lookPoss.add(result.len)
    result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(seqIndex)
  result.putU16(lookupIndex)
  for i, cov in backtrack:
    let off = result.len
    result.putU16At(backPoss[i], uint16(off))
    for b in coverageBytes(cov):
      result.add(b)
  for i, cov in input:
    let off = result.len
    result.putU16At(inPoss[i], uint16(off))
    for b in coverageBytes(cov):
      result.add(b)
  for i, cov in lookahead:
    let off = result.len
    result.putU16At(lookPoss[i], uint16(off))
    for b in coverageBytes(cov):
      result.add(b)

proc buildContextPos2(firstCov: uint16, classDef: seq[uint8],
    ruleSets: seq[seq[seq[uint8]]]): seq[uint8] =
  ## SequenceContextFormat2 with explicit rule sets per class.
  ## ruleSets[i] holds the rules for input class i.
  result = @[]
  result.putU16(2u16)
  let covPos = result.len
  result.putU16(0u16)
  let cdPos = result.len
  result.putU16(0u16)
  result.putU16(uint16(ruleSets.len))
  var setPoss: seq[int] = @[]
  for _ in ruleSets:
    setPoss.add(result.len)
    result.putU16(0u16)
  let covOff = result.len
  for b in coverageBytes(@[firstCov]):
    result.add(b)
  result.putU16At(covPos, uint16(covOff))
  let cdOff = result.len
  for b in classDef:
    result.add(b)
  result.putU16At(cdPos, uint16(cdOff))
  for i, rules in ruleSets:
    if rules.len == 0:
      continue
    let setOff = result.len
    result.putU16At(setPoss[i], uint16(setOff))
    let ruleSet = buildSeqRuleSet(rules)
    for b in ruleSet:
      result.add(b)

test "extension wraps singlepos":
  let inner = buildSinglePos1(1u16, 0x0001u16, @[50i16])
  let ext = extensionBytes(1u16, inner)
  let gpos = buildGposOneLookup("kern", 9u16, ext)
  let got = shapeWithGpos(buildFontTables(gpos), "A",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got[0].xOff == 50i32

test "unsupported gpos types are skipped":
  let gpos = buildGposOneLookup("kern", 4u16, @[1u8, 0u8])
  let got = shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got == @[(1u32, 600i32, 0i32, 0i32, 0i32),
    (2u32, 600i32, 0i32, 0i32, 0i32)]

test "contextpos format1 positions in context":
  let single = buildSinglePos1(1u16, 0x0001u16, @[50i16])
  let ctx = buildContextPos1(1u16, @[2u16], 0u16, 1u16)
  let gpos = buildGposTwoLookups("kern", 7u16, ctx, 1u16, single)
  let got = shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got[0].xOff == 50i32
  check got[1].xOff == 0i32
  # Second glyph mismatch: no positioning.
  check shapeWithGpos(buildFontTables(gpos), "AA",
    @[globalFeature(tagFromStr("kern"), 1)]) ==
    @[(1u32, 600i32, 0i32, 0i32, 0i32), (1u32, 600i32, 0i32, 0i32, 0i32)]

test "contextpos format3 positions in context":
  let single = buildSinglePos1(1u16, 0x0004u16, @[-80i16])
  let ctx = buildContextPos3(@[@[1u16], @[2u16]], 0u16, 1u16)
  let gpos = buildGposTwoLookups("kern", 7u16, ctx, 1u16, single)
  let got = shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got == @[(1u32, 520i32, 0i32, 0i32, 0i32),
    (2u32, 600i32, 0i32, 0i32, 0i32)]
  check shapeWithGpos(buildFontTables(gpos), "BA",
    @[globalFeature(tagFromStr("kern"), 1)]) ==
    @[(2u32, 600i32, 0i32, 0i32, 0i32), (1u32, 600i32, 0i32, 0i32, 0i32)]

test "chained contextpos format1 uses lookahead":
  let single = buildSinglePos1(1u16, 0x0001u16, @[50i16])
  # Input A with lookahead B.
  let ctx = buildChainedContextPos1(1u16, @[], @[], @[2u16], 0u16, 1u16)
  let gpos = buildGposTwoLookups("kern", 8u16, ctx, 1u16, single)
  check shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])[0].xOff == 50i32
  check shapeWithGpos(buildFontTables(gpos), "AA",
    @[globalFeature(tagFromStr("kern"), 1)])[0].xOff == 0i32

test "chained contextpos format3 uses backtrack":
  let single = buildSinglePos1(2u16, 0x0001u16, @[30i16])
  # Input B with backtrack A.
  let ctx = buildChainedContextPos3(@[@[1u16]], @[@[2u16]], @[], 0u16, 1u16)
  let gpos = buildGposTwoLookups("kern", 8u16, ctx, 1u16, single)
  check shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])[1].xOff == 30i32
  # Without the backtrack glyph, the second B is untouched.
  check shapeWithGpos(buildFontTables(gpos), "BB",
    @[globalFeature(tagFromStr("kern"), 1)])[1].xOff == 0i32

test "contextpos via extension":
  let single = buildSinglePos1(1u16, 0x0001u16, @[50i16])
  let inner = buildContextPos1(1u16, @[2u16], 0u16, 1u16)
  let ext = extensionBytes(7u16, inner)
  # Lookup0 is extension wrapping context; lookup1 is the nested single.
  # Extension inner references lookup index 1, which follows the ext table.
  let gpos = buildGposTwoLookups("kern", 9u16, ext, 1u16, single)
  check shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])[0].xOff == 50i32

test "contextpos format2 class input":
  let single = buildSinglePos1(1u16, 0x0001u16, @[50i16])
  # gid1 -> class 1, gid2 -> class 2. Rule for class 1 expects class 2 next.
  let cd = classDefFormat1Bytes(1u16, @[1u16, 2u16])
  let rule = buildSeqRule(@[2u16], 0u16, 1u16)
  let ctx = buildContextPos2(1u16, cd, @[@[], @[rule]])
  let gpos = buildGposTwoLookups("kern", 7u16, ctx, 1u16, single)
  check shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])[0].xOff == 50i32
  check shapeWithGpos(buildFontTables(gpos), "AA",
    @[globalFeature(tagFromStr("kern"), 1)])[0].xOff == 0i32

test "contextpos nested pair":
  let pair = buildPairPos1(1u16, 0x0004u16, 0u16,
    @[@[(2u16, @[-80i16], newSeq[int16]())]])
  let ctx = buildContextPos1(1u16, @[2u16], 0u16, 1u16)
  let gpos = buildGposTwoLookups("kern", 7u16, ctx, 2u16, pair)
  let got = shapeWithGpos(buildFontTables(gpos), "AB",
    @[globalFeature(tagFromStr("kern"), 1)])
  check got == @[(1u32, 520i32, 0i32, 0i32, 0i32),
    (2u32, 600i32, 0i32, 0i32, 0i32)]
  check shapeWithGpos(buildFontTables(gpos), "AA",
    @[globalFeature(tagFromStr("kern"), 1)]) ==
    @[(1u32, 600i32, 0i32, 0i32, 0i32), (1u32, 600i32, 0i32, 0i32, 0i32)]
