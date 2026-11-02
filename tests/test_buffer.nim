import std/options
import std/unicode
import unittest

import harfnim

test "new buffer defaults":
  let b = newBuffer()
  check b.length() == 0
  check b.isEmpty()
  check b.contentType == none(ContentType)
  check b.direction == dirInvalid
  check b.allocationSuccessful()

test "push and pushStr clusters":
  var b = newBuffer()
  b.push(0x41u32, 0)
  check b.contentType == some(contentUnicode)
  check b.length() == 1
  var c = newBuffer()
  c.pushStr("Aé")
  check c.length() == 2
  let infos = c.glyphInfosView()
  check infos[0].glyphId == 0x41u32
  check infos[0].cluster == 0u32
  check infos[1].glyphId == 0xE9u32
  check infos[1].cluster == 1u32
  var d = newBuffer()
  d.pushStr("A" & $Rune(0xE9) & $Rune(0x1F600))
  let di = d.glyphInfosView()
  check di.len == 3
  check di[2].glyphId == 0x1F600u32
  check di[2].cluster == 3u32

test "pushCodepoints and pushGlyphInfos":
  var b = newBuffer()
  b.pushCodepoints([0x61u32, 0x62u32])
  let infos = b.glyphInfosView()
  check infos[0].cluster == 0u32
  check infos[1].cluster == 1u32
  var e = newBuffer()
  check e.pushGlyphInfos(infos)
  check e.length() == 2

test "setLength and reserve":
  var b = newBuffer()
  b.pushStr("abc")
  check b.setLength(5)
  check b.length() == 5
  check b.glyphInfosView()[4].glyphId == 0u32
  check b.setLength(2)
  check b.length() == 2
  check b.reserve(100)
  check b.allocationSuccessful()

test "context pre and post":
  var b = newBuffer()
  b.setPreContext("hello")
  check b.preContextCodepoints() == @[0x6Fu32, 0x6Cu32, 0x6Cu32, 0x65u32, 0x68u32]
  b.setPostContext("world!")
  check b.postContextCodepoints() == @[0x77u32, 0x6Fu32, 0x72u32, 0x6Cu32, 0x64u32]
  b.setPreContextCodepoints([1u32, 2u32, 3u32])
  check b.preContextCodepoints() == @[1u32, 2u32, 3u32]

test "direction script language flags":
  var b = newBuffer()
  b.setDirection(dirLeftToRight)
  check b.direction() == dirLeftToRight
  b.setScript(some(Latin))
  check b.script() == some(Latin)
  let (ok, lang) = newLanguage("en")
  check ok
  b.setLanguage(some(lang))
  check b.language().get().asStr() == "en"
  b.setFlags(BeginningOfText or EndOfText)
  check b.flags().contains(BeginningOfText)
  b.setClusterLevel(clCharacters)
  check b.clusterLevel() == clCharacters
  b.setInvisibleGlyph(some(newGlyphId(5)))
  check b.invisibleGlyph() == some(newGlyphId(5))

test "clear and reset":
  var b = newBuffer()
  b.pushStr("abc")
  b.setDirection(dirRightToLeft)
  b.setFlags(BeginningOfText)
  b.clear()
  check b.length() == 0
  check b.direction == dirInvalid
  check b.flags().contains(BeginningOfText)
  b.setFlags(BeginningOfText)
  b.reset()
  check b.flags() == BufferFlags(0)

test "reverse operations":
  var b = newBuffer()
  b.pushStr("abcd")
  b.reverseRange(1, 3)
  let infos = b.glyphInfosView()
  check infos[0].glyphId == 0x61u32
  check infos[1].glyphId == 0x63u32
  check infos[2].glyphId == 0x62u32
  b.reverse()
  let r = b.glyphInfosView()
  check r[0].glyphId == 0x64u32
  check r[3].glyphId == 0x61u32
  var c = newBuffer()
  c.push(1u32, 0)
  c.push(2u32, 0)
  c.push(3u32, 1)
  c.reverseClusters()
  let rc = c.glyphInfosView()
  check rc[0].glyphId == 3u32
  check rc[1].glyphId == 1u32
  check rc[2].glyphId == 2u32
  c.resetClusters()
  check c.glyphInfosView()[1].cluster == 1u32

test "serialize unicode and glyphs":
  var b = newBuffer()
  b.pushStr("AB")
  check b.serialize(SerializeFlags(0)) == "<U+0041=0|U+0042=1>"
  var g = newBuffer()
  g.pushStr("A")
  g.setContentType(some(contentGlyphs))
  discard g.setLength(1)
  g.glyphInfos()[0].glyphId = 36
  g.glyphInfos()[0].cluster = 0
  check g.serialize(NoGlyphNames) == "[36=0]"
  check g.serialize(SerializeFlags(0)) == "[gid36=0]"

test "positions allocation":
  var b = newBuffer()
  b.pushStr("ab")
  check b.glyphPositions().len == 0
  b.glyphPositionsMut()[0].xAdvance = 500
  check b.glyphPositions().len == 2
  check b.glyphPositions()[0].xAdvance == 500
  b.setContentType(some(contentGlyphs))
  check b.serialize(SerializeFlags(0)) == "[gid97=0+500|gid98=1+0]"

test "var allocation and accessors":
  var b = newBuffer()
  b.pushStr("a")
  b.allocateUnicodeVars()
  b.allocateGsubGposVars()
  check b.tryAllocateVar(GlyphPropsVar) == false
  var g = b.glyphInfosView()[0]
  g.setUnicodeProps(0x1234u16)
  check g.unicodeProps() == 0x1234u16
  g.setGlyphProps(GlyphPropBaseGlyph)
  check g.glyphProps() == GlyphPropBaseGlyph
  g.setLigProps(0xABu8)
  check g.ligProps() == 0xABu8
  check g.glyphProps() == GlyphPropBaseGlyph
  g.setSyllable(7u8)
  check g.syllable() == 7u8
  g.setNormalizerGlyphIndex(999u32)
  check g.normalizerGlyphIndex() == 999u32
  b.deallocateGsubGposVars()
  b.deallocateUnicodeVars()

test "lig props helpers":
  var g = GlyphInfo()
  g.setGlyphProps(GlyphPropLigature)
  g.setLigPropsForLigature(3u8, 2u8)
  check g.ligId() == 3u8
  check g.ligNumComps() == 2u8
  check g.ligatedInternal()
  check g.isLigature()
  var m = GlyphInfo()
  m.setLigPropsForMark(3u8, 1u8)
  check m.ligId() == 3u8
  check m.ligComp() == 1u8
  m.setLigPropsForComponent(2u8)
  check m.ligId() == 0u8
  check m.ligComp() == 2u8

test "output machinery sync":
  var b = newBuffer()
  b.pushStr("abc")
  b.clearOutput()
  b.nextGlyph()
  check b.idx == 1
  check b.outLen == 1
  b.outputGlyph(99u32)
  check b.outLen == 2
  b.skipGlyph()
  check b.sync()
  let infos = b.glyphInfosView()
  check infos.len == 3
  check infos[0].glyphId == 0x61u32
  check infos[1].glyphId == 99u32
  check infos[2].glyphId == 0x63u32

test "replace and delete":
  var b = newBuffer()
  b.pushStr("abc")
  b.clearOutput()
  b.replaceGlyphs(2, 1, [0x7Au32])
  check b.sync()
  let infos = b.glyphInfosView()
  check infos.len == 2
  check infos[0].glyphId == 0x7Au32
  check infos[0].cluster == 0u32
  var d = newBuffer()
  d.pushStr("aab")
  d.clearOutput()
  d.nextGlyph()
  d.deleteGlyph()
  check d.sync()
  check d.length() == 2

test "merge clusters monotone":
  var b = newBuffer()
  b.push(1u32, 5)
  b.push(2u32, 3)
  b.mergeClusters(0, 2)
  check b.glyphInfosView()[0].cluster == 3u32
  check b.glyphInfosView()[1].cluster == 3u32

test "masks and glyph flags":
  var b = newBuffer()
  b.pushStr("abc")
  b.setMasks(0xFF00u32, 0x0F00u32, 0u32, high(uint32))
  check (b.glyphInfosView()[0].mask and 0x0F00u32) == 0x0F00u32
  b.setClusterLevel(clCharacters)
  b.unsafeToBreakRange(some(0), some(3))
  check b.glyphInfosView()[2].unsafeToBreak()
  check b.glyphInfosView()[2].unsafeToConcat()
  check (not b.glyphInfosView()[0].unsafeToBreak())
  var c = newBuffer()
  c.pushStr("abc")
  c.unsafeToConcatRange(some(0), some(3))
  check (not c.glyphInfosView()[1].unsafeToConcat())

test "moveTo and sort":
  var b = newBuffer()
  b.pushStr("cab")
  b.sort(0, 3, proc(a, bb: GlyphInfo): bool {.closure.} =
    a.glyphId > bb.glyphId)
  let infos = b.glyphInfosView()
  check infos[0].glyphId == 0x61u32
  check infos[2].glyphId == 0x63u32
  var m = newBuffer()
  m.pushStr("abcd")
  m.clearOutput()
  check m.moveTo(2)
  check m.idx == 2
  check m.outLen == 2
  check m.moveTo(0)
  check m.idx == 0
  check m.outLen == 0

test "enter leave and lig id":
  var b = newBuffer()
  b.pushStr("abcdef")
  b.enter()
  check b.maxOps > 0
  check b.maxLen >= MaxLenMin
  let id = b.allocateLigId()
  check id != 0
  b.leave()
  check b.maxLen == MaxLenDefault
