import std/options
import unittest

import harfnim
import harfnim/ot/indic_machine
import harfnim/ot/indic_table
import harfnim/ot/syllabic
import harfnim/ot/vowel_constraints

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

proc putI16(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

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

proc shapeFont(pairs: seq[tuple[cp, gid: uint16]]): ShaperFont =
  newShaperFont(parseFont(buildFontRaw(baseTables(buildCmap(pairs)))))

proc tagBuffer(text: string): Buffer =
  result = newBuffer()
  result.pushStr(text)
  result.guessSegmentProperties()
  var scratch = result.scratchFlags
  for i in 0 ..< result.len:
    result.info[i].initUnicodeProps(scratch)
  result.scratchFlags = scratch
  for i in 0 ..< result.len:
    let (cat, pos) = getCategories(result.info[i].glyphId)
    result.info[i].setIndicCategory(cat)
    result.info[i].setIndicPosition(pos)

test "indic categories spot checks":
  check getCategories(0x0915u32) == (OtC, PosBaseC)
  check getCategories(0x094Du32).cat == OtH
  check getCategories(0x093Eu32).cat == OtM
  check getCategories(0x0905u32).cat == OtV
  check getCategories(0x200Du32).cat == OtZwj
  check getCategories(0x200Cu32).cat == OtZwnj
  check getCategories(0x0E01u32).cat == OtX
  check getCategories(0x110000u32).cat == OtX

test "indic machine finds a consonant cluster":
  var b = tagBuffer("\u0915\u094D\u0915")
  b.findSyllablesIndic()
  check b.len == 3
  for i in 0 ..< 3:
    check b.info[i].syllable() == 0x10u8
  check b.nextSyllable(0) == 3

test "indic machine finds a vowel syllable":
  var b = tagBuffer("\u0905\u093E")
  b.findSyllablesIndic()
  for i in 0 ..< 2:
    check b.info[i].syllable() == 0x11u8
  check b.nextSyllable(0) == 2

test "indic machine splits mixed syllables":
  var b = tagBuffer("\u0915A")
  b.findSyllablesIndic()
  check (b.info[0].syllable() and 0x0Fu8) ==
    uint8(ord(ConsonantSyllable))
  check (b.info[1].syllable() and 0x0Fu8) ==
    uint8(ord(NonIndicCluster))
  check b.info[0].syllable() != b.info[1].syllable()
  check b.nextSyllable(0) == 1
  check b.nextSyllable(1) == 2

test "indic machine flags a lone halant as broken":
  var b = tagBuffer("\u094D")
  b.findSyllablesIndic()
  check (b.info[0].syllable() and 0x0Fu8) ==
    uint8(ord(BrokenCluster))
  check (b.scratchFlags and ScratchFlagHasBrokenSyllable) != 0u32

test "vowel constraints split devanagari a + aa":
  var b = tagBuffer("\u0905\u093E")
  b.preprocessVowelConstraints()
  check b.len == 3
  check b.info[0].glyphId == 0x0905u32
  check b.info[1].glyphId == 0x25CCu32
  check b.info[2].glyphId == 0x093Eu32

test "vowel constraints leave other pairs alone":
  var b = tagBuffer("\u0905\u0906")
  b.preprocessVowelConstraints()
  check b.len == 2
  check b.info[0].glyphId == 0x0905u32
  check b.info[1].glyphId == 0x0906u32

test "vowel constraints split tamil au":
  var b = tagBuffer("\u0B85\u0BC2")
  b.preprocessVowelConstraints()
  check b.len == 3
  check b.info[1].glyphId == 0x25CCu32

test "vowel constraints split bengali vowels":
  var b = tagBuffer("\u0985\u09BE")
  b.preprocessVowelConstraints()
  check b.len == 3
  check b.info[1].glyphId == 0x25CCu32

test "vowel constraints pass latin through":
  var b = tagBuffer("AB")
  b.preprocessVowelConstraints()
  check b.len == 2
  check b.info[0].glyphId == 0x41u32
  check b.info[1].glyphId == 0x42u32

test "syllabic dotted circle inserts after repha":
  let sf = shapeFont(@[(0x25CCu16, 1u16)])
  var b = newBuffer()
  b.pushStr("ab")
  b.info[0].glyphId = 10u32
  b.info[0].mask = 0x100u32
  b.info[0].cluster = 7u32
  b.info[0].setSyllable(0x11u8)
  b.info[0].setOtShaperCategory(2u8)
  b.info[1].glyphId = 11u32
  b.info[1].setSyllable(0x11u8)
  b.info[1].setOtShaperCategory(7u8)
  b.scratchFlags = b.scratchFlags or ScratchFlagHasBrokenSyllable
  check b.insertDottedCircles(sf, 1u8, 9u8, some(2u8), none(uint8))
  check b.len == 3
  check b.info[0].glyphId == 10u32
  check b.info[1].glyphId == 1u32
  check b.info[1].mask == 0x100u32
  check b.info[1].cluster == 7u32
  check b.info[1].syllable() == 0x11u8
  check b.info[1].otShaperCategory() == 9u8
  check b.info[2].glyphId == 11u32

test "syllabic dotted circle skips clean syllables":
  let sf = shapeFont(@[(0x25CCu16, 1u16)])
  var b = newBuffer()
  b.pushStr("ab")
  b.info[0].glyphId = 10u32
  b.info[0].setSyllable(0x10u8)
  b.info[1].glyphId = 11u32
  b.info[1].setSyllable(0x10u8)
  check (not b.insertDottedCircles(sf, 1u8, 9u8, some(2u8),
    none(uint8)))
  check b.len == 2

test "syllabic dotted circle needs the font glyph":
  let sf = shapeFont(@[(0x0041u16, 1u16)])
  var b = newBuffer()
  b.pushStr("ab")
  b.info[0].setSyllable(0x11u8)
  b.info[1].setSyllable(0x11u8)
  check (not b.insertDottedCircles(sf, 1u8, 9u8, some(2u8),
    none(uint8)))
  check b.len == 2

test "syllabic clear resets syllables":
  var b = tagBuffer("\u0915\u094D\u0915")
  b.findSyllablesIndic()
  check b.info[0].syllable() != 0u8
  b.clearSyllables()
  for i in 0 ..< b.len:
    check b.info[i].syllable() == 0u8
