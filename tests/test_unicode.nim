import std/options
import std/unicode
import unittest

import harfnim

test "script mapping spot checks":
  check scriptFor(0x41u32) == Latin
  check scriptFor(0xE9u32) == Latin
  check scriptFor(0x627u32) == Arabic
  check scriptFor(0x3B1u32) == Greek
  check scriptFor(0x4E00u32) == Han
  check scriptFor(0x20u32) == Common
  check scriptFor(0x30u32) == Common
  check scriptFor(0x110000u32) == Unknown
  check scriptFor(high(uint32)) == Unknown

test "unicode 18 scripts":
  for cp in 0x125A8u32 .. 0x125AAu32:
    check scriptFor(cp) == ProtoCuneiform
    check generalCategoryFor(cp) == GcLetterNumber
    check combiningClassFor(cp) == 0u8
  for cp in [0x18E00u32, 0x19191u32]:
    check scriptFor(cp) == Jurchen
    check generalCategoryFor(cp) == GcOtherLetter
  check scriptFor(0x3D000u32) == Seal
  check generalCategoryFor(0x3D000u32) == GcOtherLetter

test "general category":
  check generalCategoryFor(0x41u32) == GcUppercaseLetter
  check generalCategoryFor(0x61u32) == GcLowercaseLetter
  check generalCategoryFor(0x300u32) == GcNonSpacingMark
  check generalCategoryFor(0x345u32) == GcNonSpacingMark
  check generalCategoryFor(0x20u32) == GcSpaceSeparator
  check generalCategoryFor(0x390000u32) == GcUnassigned
  check GcUppercaseLetter.isLetter()
  check (not GcSpaceSeparator.isLetter())
  check GcNonSpacingMark.isMark()
  check GcSpacingMark.isMark()
  check GcEnclosingMark.isMark()
  check (not GcOtherLetter.isMark())
  check GcLowercaseLetter.inRangeInclusive(GcLowercaseLetter, GcUppercaseLetter)
  check GcUppercaseLetter.inRangeInclusive(GcLowercaseLetter, GcUppercaseLetter)
  check (not GcSpacingMark.inRangeInclusive(GcLowercaseLetter, GcUppercaseLetter))
  check (not GcControl.inRangeInclusive(GcFormat, GcNonSpacingMark))

test "combining classes":
  check combiningClassFor(0x300u32) == 230u8
  check combiningClassFor(0x345u32) == CcIotaSubscript
  check combiningClassFor(0x41u32) == 0u8
  check combiningClassFor(0x0C55u32) == 84u8
  check combiningClassFor(0x0C56u32) == 91u8

test "telugu length marks reorder before virama":
  check modifiedCombiningClass(0x0C55u32) == 4u8
  check modifiedCombiningClass(0x0C56u32) == 5u8
  check modifiedCombiningClass(0x0C4Du32) == 9u8
  check modifiedCombiningClass(0x1A60u32) == 254u8
  check modifiedCombiningClass(0x0FC6u32) == 254u8
  check modifiedCombiningClass(0x0F39u32) == 127u8
  check modifiedCombiningClass(0x300u32) == 230u8

test "hebrew modified classes":
  check modifiedCombiningClass(0x05B0u32) == 22u8
  check combiningClassFor(0x05B0u32) == 10u8

test "compose basic latin":
  check compose(0x41u32, 0x300u32) == some(0xC0u32)
  check compose(0x41u32, 0x301u32) == some(0xC1u32)
  check compose(0x41u32, 0x42u32) == none(uint32)
  check compose(0x3Cu32, 0x338u32) == some(0x226Eu32)

test "compose hangul":
  check compose(0x1100u32, 0x1161u32) == some(0xAC00u32)
  check compose(0xAC00u32, 0x11A8u32) == some(0xAC01u32)
  check compose(0x1100u32, 0x1100u32) == none(uint32)

test "decompose":
  let d1 = decompose(0xC0u32)
  check d1.isSome and d1.get.kind == dkPair
  check d1.get.first == 0x41u32 and d1.get.second == 0x300u32
  let d2 = decompose(0xAC00u32)
  check d2.isSome and d2.get.kind == dkPair
  check d2.get.first == 0x1100u32 and d2.get.second == 0x1161u32
  let d3 = decompose(0xAC01u32)
  check d3.isSome and d3.get.first == 0xAC00u32 and d3.get.second == 0x11A8u32
  check decompose(0x41u32).isNone

test "mirroring":
  check mirroringFor(0x28u32) == some(0x29u32)
  check mirroringFor(0x41u32) == none(uint32)

test "default ignorables and variation selectors":
  check isDefaultIgnorable(0x200Bu32)
  check isDefaultIgnorable(0xFEFFu32)
  check isDefaultIgnorable(0x034Fu32)
  check (not isDefaultIgnorable(0x41u32))
  check (not isDefaultIgnorable(0x115Fu32))
  check isVariationSelector(0xFE00u32)
  check isVariationSelector(0xE0100u32)
  check (not isVariationSelector(0x41u32))

test "space fallback":
  check spaceFallback(0x20u32) == SpaceSpace
  check spaceFallback(0x2003u32) == SpaceEm
  check spaceFallback(0x2009u32) == SpaceEm5
  check spaceFallback(0x41u32) == SpaceNotSpace

test "vertical alternates":
  check verticalAlternate(0x2014u32) == some(0xFE31u32)
  check verticalAlternate(0x3001u32) == some(0xFE11u32)
  check verticalAlternate(0x41u32) == none(uint32)

test "emoji extended pictographic":
  check isEmojiExtendedPictographic(0x1F600u32)
  check (not isEmojiExtendedPictographic(0x41u32))

test "initUnicodeProps marks and ignorables":
  var scratch = 0u32
  var zwj = GlyphInfo(glyphId: 0x200Du32)
  zwj.initUnicodeProps(scratch)
  check (zwj.unicodeProps() and UnicodePropIgnorable) != 0u16
  check (zwj.unicodeProps() and UnicodePropCfZwj) != 0u16
  check (scratch and ScratchFlagHasDefaultIgnorables) != 0u32
  var scratch2 = 0u32
  var zwnj = GlyphInfo(glyphId: 0x200Cu32)
  zwnj.initUnicodeProps(scratch2)
  check (zwnj.unicodeProps() and UnicodePropCfZwnj) != 0u16
  var scratch3 = 0u32
  var cgj = GlyphInfo(glyphId: 0x034Fu32)
  cgj.initUnicodeProps(scratch3)
  check (cgj.unicodeProps() and UnicodePropHidden) != 0u16
  check (scratch3 and ScratchFlagHasCgj) != 0u32
  var scratch4 = 0u32
  var grave = GlyphInfo(glyphId: 0x300u32)
  grave.initUnicodeProps(scratch4)
  check (grave.unicodeProps() and UnicodePropContinuation) != 0u16
  check (scratch4 and ScratchFlagHasContinuations) != 0u32
  check ((grave.unicodeProps() shr 8) and 0xFFu16) == 230u16
  var a = GlyphInfo(glyphId: 0x41u32)
  var scratch5 = 0u32
  a.initUnicodeProps(scratch5)
  check a.unicodeProps() == uint16(uint8(GcUppercaseLetter))
  check scratch5 == 0u32

test "unhide clears hidden bit":
  var cgj = GlyphInfo(glyphId: 0x034Fu32)
  var scratch = 0u32
  cgj.initUnicodeProps(scratch)
  check (cgj.unicodeProps() and UnicodePropHidden) != 0u16
  cgj.unhide()
  check (cgj.unicodeProps() and UnicodePropHidden) == 0u16

test "guess segment properties":
  var b = newBuffer()
  b.pushStr("hello")
  b.guessSegmentProperties()
  check b.script() == some(Latin)
  check b.direction() == dirLeftToRight
  var ar = newBuffer()
  ar.pushStr("مرحبا")
  ar.guessSegmentProperties()
  check ar.script() == some(Arabic)
  check ar.direction() == dirRightToLeft
  var preset = newBuffer()
  preset.pushStr("hello")
  preset.setDirection(dirRightToLeft)
  preset.guessSegmentProperties()
  check preset.direction() == dirRightToLeft
  check preset.script() == some(Latin)
