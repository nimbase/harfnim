import std/options

import ./script
import ./ucd_table
import ./emoji_table
import ./bidi_table

export bidi_table

type
  Codepoint* = uint32
    ## Unicode scalar value.

  DecomposedKind* = enum
    ## Decomposition shape.
    dkSingleton
    ## Single codepoint decomposition.
    dkPair
    ## Pair decomposition.

  Decomposed* = object
    ## Canonical decomposition result.
    ## Which decomposition shape this holds.
    case kind*: DecomposedKind
    of dkSingleton:
      single*: uint32
      ## The decomposed codepoint.
    of dkPair:
      first*: uint32
      ## First codepoint of the pair.
      second*: uint32
      ## Second codepoint of the pair.

# --------------------------------------------------------------------------
# GeneralCategory
# --------------------------------------------------------------------------

type
  GeneralCategory* = distinct uint8
    ## Unicode general category value.

const
  GcControl* = GeneralCategory(0)
    ## Control category.
  GcFormat* = GeneralCategory(1)
    ## Format category.
  GcUnassigned* = GeneralCategory(2)
    ## Unassigned category.
  GcPrivateUse* = GeneralCategory(3)
    ## Private Use category.
  GcSurrogate* = GeneralCategory(4)
    ## Surrogate category.
  GcLowercaseLetter* = GeneralCategory(5)
    ## Lowercase Letter category.
  GcModifierLetter* = GeneralCategory(6)
    ## Modifier Letter category.
  GcOtherLetter* = GeneralCategory(7)
    ## Other Letter category.
  GcTitlecaseLetter* = GeneralCategory(8)
    ## Titlecase Letter category.
  GcUppercaseLetter* = GeneralCategory(9)
    ## Uppercase Letter category.
  GcSpacingMark* = GeneralCategory(10)
    ## Spacing Mark category.
  GcEnclosingMark* = GeneralCategory(11)
    ## Enclosing Mark category.
  GcNonSpacingMark* = GeneralCategory(12)
    ## Non Spacing Mark category.
  GcDecimalNumber* = GeneralCategory(13)
    ## Decimal Number category.
  GcLetterNumber* = GeneralCategory(14)
    ## Letter Number category.
  GcOtherNumber* = GeneralCategory(15)
    ## Other Number category.
  GcConnectPunctuation* = GeneralCategory(16)
    ## Connect Punctuation category.
  GcDashPunctuation* = GeneralCategory(17)
    ## Dash Punctuation category.
  GcClosePunctuation* = GeneralCategory(18)
    ## Close Punctuation category.
  GcFinalPunctuation* = GeneralCategory(19)
    ## Final Punctuation category.
  GcInitialPunctuation* = GeneralCategory(20)
    ## Initial Punctuation category.
  GcOtherPunctuation* = GeneralCategory(21)
    ## Other Punctuation category.
  GcOpenPunctuation* = GeneralCategory(22)
    ## Open Punctuation category.
  GcCurrencySymbol* = GeneralCategory(23)
    ## Currency Symbol category.
  GcModifierSymbol* = GeneralCategory(24)
    ## Modifier Symbol category.
  GcMathSymbol* = GeneralCategory(25)
    ## Math Symbol category.
  GcOtherSymbol* = GeneralCategory(26)
    ## Other Symbol category.
  GcLineSeparator* = GeneralCategory(27)
    ## Line Separator category.
  GcParagraphSeparator* = GeneralCategory(28)
    ## Paragraph Separator category.
  GcSpaceSeparator* = GeneralCategory(29)
    ## Space Separator category.

proc `==`*(a, b: GeneralCategory): bool =
  ## True when both categories match.
  uint8(a) == uint8(b)

proc isMark*(g: GeneralCategory): bool =
  ## True for spacing, enclosing, and nonspacing marks.
  g == GcSpacingMark or g == GcEnclosingMark or g == GcNonSpacingMark

proc isLetter*(g: GeneralCategory): bool =
  ## True for lowercase, modifier, other, titlecase, and uppercase letters.
  g == GcLowercaseLetter or g == GcModifierLetter or g == GcOtherLetter or
    g == GcTitlecaseLetter or g == GcUppercaseLetter

proc gcFlag*(g: GeneralCategory): uint32 =
  ## Single bit mask for the category.
  1u32 shl uint8(g)

proc gcFlagUnsafe*(g: GeneralCategory): uint32 =
  ## Bit mask, or zero when the category value exceeds 31.
  if uint8(g) < 32u8: 1u32 shl uint8(g) else: 0u32

proc inRangeInclusive*(g, first, last: GeneralCategory): bool =
  ## True when the category falls in the inclusive range.
  let rangeMask = (1u32 shl (uint8(last) + 1u8)) - (1u32 shl uint8(first))
  (g.gcFlagUnsafe() and rangeMask) != 0

# --------------------------------------------------------------------------
# Combining class constants
# --------------------------------------------------------------------------

const
  CcNotReordered* = 0u8
    ## Not Reordered combining class (0).
  CcOverlay* = 1u8
    ## Overlay combining class (1).
  CcNukta* = 7u8
    ## Nukta combining class (7).
  CcKanaVoicing* = 8u8
    ## Kana Voicing combining class (8).
  CcVirama* = 9u8
    ## Virama combining class (9).
  CcAttachedBelowLeft* = 200u8
    ## Attached Below Left combining class (200).
  CcAttachedBelow* = 202u8
    ## Attached Below combining class (202).
  CcAttachedAbove* = 214u8
    ## Attached Above combining class (214).
  CcAttachedAboveRight* = 216u8
    ## Attached Above Right combining class (216).
  CcBelowLeft* = 218u8
    ## Below Left combining class (218).
  CcBelow* = 220u8
    ## Below combining class (220).
  CcBelowRight* = 222u8
    ## Below Right combining class (222).
  CcLeft* = 224u8
    ## Left combining class (224).
  CcRight* = 226u8
    ## Right combining class (226).
  CcAboveLeft* = 228u8
    ## Above Left combining class (228).
  CcAbove* = 230u8
    ## Above combining class (230).
  CcAboveRight* = 232u8
    ## Above Right combining class (232).
  CcDoubleBelow* = 233u8
    ## Double Below combining class (233).
  CcDoubleAbove* = 234u8
    ## Double Above combining class (234).
  CcIotaSubscript* = 240u8
    ## Iota Subscript combining class (240).
  CcInvalid* = 255u8
    ## Invalid combining class (255).

# --------------------------------------------------------------------------
# Space fallback codes
# --------------------------------------------------------------------------

const
  SpaceNotSpace* = 0u8
    ## Not Space space fallback code (0).
  SpaceEm* = 1u8
    ## Em space fallback code (1).
  SpaceEm2* = 2u8
    ## Em 2 space fallback code (2).
  SpaceEm3* = 3u8
    ## Em 3 space fallback code (3).
  SpaceEm4* = 4u8
    ## Em 4 space fallback code (4).
  SpaceEm5* = 5u8
    ## Em 5 space fallback code (5).
  SpaceEm6* = 6u8
    ## Em 6 space fallback code (6).
  SpaceEm16* = 16u8
    ## Em 16 space fallback code (16).
  Space4Em18* = 17u8
    ## 4 Em18 space fallback code (17).
  SpaceSpace* = 18u8
    ## Space space fallback code (18).
  SpaceFigure* = 19u8
    ## Figure space fallback code (19).
  SpacePunctuation* = 20u8
    ## Punctuation space fallback code (20).
  SpaceNarrow* = 21u8
    ## Narrow space fallback code (21).

# --------------------------------------------------------------------------
# Modified combining class table
# --------------------------------------------------------------------------

const modifiedCombiningClassTable*: array[256, uint8] = [
  0, 1, 2, 3, 4, 5, 6, 7,
  8, 9, 22, 15, 16, 17, 23, 18,
  19, 20, 21, 14, 24, 12, 25, 13,
  10, 11, 26, 28, 29, 30, 31, 32,
  33, 27, 34, 35, 36, 37, 38, 39,
  40, 41, 42, 43, 44, 45, 46, 47,
  48, 49, 50, 51, 52, 53, 54, 55,
  56, 57, 58, 59, 60, 61, 62, 63,
  64, 65, 66, 67, 68, 69, 70, 71,
  72, 73, 74, 75, 76, 77, 78, 79,
  80, 81, 82, 83, 4, 85, 86, 87,
  88, 89, 90, 5, 92, 93, 94, 95,
  96, 97, 98, 99, 100, 101, 102, 3,
  104, 105, 106, 107, 108, 109, 110, 111,
  112, 113, 114, 115, 116, 117, 118, 119,
  120, 121, 122, 123, 124, 125, 126, 127,
  128, 129, 132, 131, 131, 133, 134, 135,
  136, 137, 138, 139, 140, 141, 142, 143,
  144, 145, 146, 147, 148, 149, 150, 151,
  152, 153, 154, 155, 156, 157, 158, 159,
  160, 161, 162, 163, 164, 165, 166, 167,
  168, 169, 170, 171, 172, 173, 174, 175,
  176, 177, 178, 179, 180, 181, 182, 183,
  184, 185, 186, 187, 188, 189, 190, 191,
  192, 193, 194, 195, 196, 197, 198, 199,
  200, 201, 202, 203, 204, 205, 206, 207,
  208, 209, 210, 211, 212, 213, 214, 215,
  216, 217, 218, 219, 220, 221, 222, 223,
  224, 225, 226, 227, 228, 229, 230, 231,
  232, 233, 234, 235, 236, 237, 238, 239,
  240, 241, 242, 243, 244, 245, 246, 247,
  248, 249, 250, 251, 252, 253, 254, 255,
]
    ## HarfBuzz modified combining class remap table.

# --------------------------------------------------------------------------
# Raw packtab lookups (direct ports of the generated Rust functions)
# --------------------------------------------------------------------------

proc ucdGc*(u: uint32): uint8 =
  ## Packed general category lookup; unassigned past the table end.
  if u >= 1114110u32:
    return 2u8
  let uu = int(u)
  let a = ucdU8[((uu shr 1) shr 3) shr 5]
  let b = ucdU16[(int(a) shl 5) + ((((uu shr 1) shr 3)) and 31)]
  let c = ucdU8[2176 + int(b) + ((uu shr 1) and 7)]
  ucdU8[7944 + (int(c) shl 1) + (uu and 1)]

proc ucdCcc*(u: uint32): uint8 =
  ## Packed canonical combining class lookup; zero past the table end.
  if u >= 125259u32:
    return 0u8
  let uu = int(u)
  let a = ucdU8[8332 + (((uu shr 2) shr 3) shr 4)]
  let b = ucdU8[8577 + (int(a) shl 4) + ((((uu shr 2) shr 3)) and 15)]
  let c = ucdU8[9308 + (int(b) shl 3) + ((uu shr 2) and 7)]
  ucdU8[10432 + (int(c) shl 2) + (uu and 3)]

proc ucdB4(a: openArray[uint8], i: int): uint8 =
  # Reads one packed nibble.
  (a[i shr 1] shr ((i and 1) shl 2)) and 15u8

proc ucdBmg*(u: uint32): int32 =
  ## Packed mirroring delta; zero when the codepoint does not mirror.
  if u >= 121617u32:
    return 0i32
  let uu = int(u)
  let n0 = ucdB4(ucdU8, 10952 + ((((uu shr 2) shr 3) shr 4)))
  let a = ucdU8[11071 + (int(n0) shl 4) + ((((uu shr 2) shr 3)) and 15)]
  let b = ucdU8[11272 + (int(a) shl 3) + ((uu shr 2) and 7)]
  let c = ucdU8[11624 + int(b) + (uu and 3)]
  ucdPalette[int(c)]

proc ucdSc*(u: uint32): uint8 =
  ## Packed script code lookup.
  if u >= 918000u32:
    return 2u8
  let uu = int(u)
  let a = ucdU8[11824 + (((uu shr 3) shr 3) shr 4)]
  let b = ucdU16[3392 + (int(a) shl 4) + ((((uu shr 3) shr 3)) and 15)]
  let c = ucdU16[4520 + int(b) + ((uu shr 3) and 7)]
  ucdU8[12721 + int(c) + (uu and 7)]

proc ucdDm*(u: uint32): uint16 =
  ## Packed decomposition index; zero when absent.
  if u >= 195102u32:
    return 0u16
  let uu = int(u)
  let a = ucdU8[18713 + ((uu shr 4) shr 5)]
  let b = ucdU8[19095 + (int(a) shl 5) + ((uu shr 4) and 31)]
  ucdU16[7816 + (int(b) shl 4) + (uu and 15)]

proc emojiB4(a: openArray[uint8], i: int): uint8 =
  # Reads one packed nibble.
  (a[i shr 1] shr ((i and 1) shl 2)) and 15u8

proc emojiB1(a: openArray[uint8], base, i: int): uint8 =
  # Reads one packed bit at a base offset.
  (a[base + (i shr 3)] shr (i and 7)) and 1u8

proc emojiIsExtendedPictographicU8(u: int): uint8 =
  # Packed extended pictographic test.
  if u < 131070:
    let inner = emojiB4(emojiU8, (u shr 6) shr 4)
    let mid = int(emojiU8[64 + (int(inner) shl 4) + ((u shr 6) and 15)])
    emojiB1(emojiU8, 224, (mid shl 6) + (u and 63))
  else:
    0u8

# --------------------------------------------------------------------------
# Codepoint property queries
# --------------------------------------------------------------------------

proc scriptFor*(cp: uint32): Script =
  ## Looks up the script; unknown past the valid range.
  if cp > 0x10FFFFu32:
    Unknown
  else:
    ucdScMap[int(ucdSc(cp))]

proc generalCategoryFor*(cp: uint32): GeneralCategory =
  ## Looks up the general category.
  GeneralCategory(ucdGc(cp))

proc combiningClassFor*(cp: uint32): uint8 =
  ## Looks up the canonical combining class.
  ucdCcc(cp)

proc bidiClassFor*(cp: uint32): BidiClass =
  ## Looks up the bidi class; unlisted code points default to left to right.
  var lo = 0
  var hi = bidiClassRanges.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let r = bidiClassRanges[mid]
    if cp < r.first:
      hi = mid
    elif cp > r.last:
      lo = mid + 1
    else:
      return r.cls
  BidiL

proc mirroringFor*(cp: uint32): Option[uint32] =
  ## Mirrored counterpart, if the codepoint mirrors.
  let delta = ucdBmg(cp)
  if delta == 0i32:
    none(uint32)
  else:
    some(uint32(int64(cp) + int64(delta)))

proc isEmojiExtendedPictographic*(cp: uint32): bool =
  ## True for extended pictographic codepoints.
  emojiIsExtendedPictographicU8(int(cp)) != 0u8

proc spaceFallback*(cp: uint32): uint8 =
  ## Space fallback code for the codepoint, if any.
  case cp
  of 0x0020u32, 0x00A0u32: SpaceSpace
  of 0x2000u32: SpaceEm2
  of 0x2001u32: SpaceEm
  of 0x2002u32: SpaceEm2
  of 0x2003u32: SpaceEm
  of 0x2004u32: SpaceEm3
  of 0x2005u32: SpaceEm4
  of 0x2006u32: SpaceEm6
  of 0x2007u32: SpaceFigure
  of 0x2008u32: SpacePunctuation
  of 0x2009u32: SpaceEm5
  of 0x200Au32: SpaceEm16
  of 0x202Fu32: SpaceNarrow
  of 0x205Fu32: Space4Em18
  of 0x3000u32: SpaceEm
  else: SpaceNotSpace

proc modifiedCombiningClass*(cp: uint32): uint8 =
  ## HarfBuzz modified combining class with Tai Tham and Mongolian fixes.
  if cp == 0x1A60u32:
    return 254u8
  if cp == 0x0FC6u32:
    return 254u8
  if cp == 0x0F39u32:
    return 127u8
  modifiedCombiningClassTable[int(combiningClassFor(cp))]

proc isDefaultIgnorable*(cp: uint32): bool =
  ## True for default ignorable codepoints.
  let plane = cp shr 16
  if plane == 0u32:
    let page = cp shr 8
    case page
    of 0x00u32: cp == 0x00ADu32
    of 0x03u32: cp == 0x034Fu32
    of 0x06u32: cp == 0x061Cu32
    of 0x17u32: cp >= 0x17B4u32 and cp <= 0x17B5u32
    of 0x18u32: cp >= 0x180Bu32 and cp <= 0x180Fu32
    of 0x20u32:
      (cp >= 0x200Bu32 and cp <= 0x200Fu32) or
        (cp >= 0x202Au32 and cp <= 0x202Eu32) or
        (cp >= 0x2060u32 and cp <= 0x206Fu32)
    of 0xFEu32:
      (cp >= 0xFE00u32 and cp <= 0xFE0Fu32) or cp == 0xFEFFu32
    of 0xFFu32: cp >= 0xFFF0u32 and cp <= 0xFFF8u32
    else: false
  else:
    case plane
    of 0x01u32: cp >= 0x1D173u32 and cp <= 0x1D17Au32
    of 0x0Eu32: cp >= 0xE0000u32 and cp <= 0xE0FFFu32
    else: false

proc isVariationSelector*(cp: uint32): bool =
  ## True for variation selectors.
  (cp >= 0xFE00u32 and cp <= 0xFE0Fu32) or
    (cp >= 0xE0100u32 and cp <= 0xE01EFu32)

proc verticalAlternate*(cp: uint32): Option[uint32] =
  ## Vertical presentation alternate, if defined.
  case cp shr 8
  of 0x20u32:
    case cp
    of 0x2013u32: some(0xFE32u32)
    of 0x2014u32: some(0xFE31u32)
    of 0x2025u32: some(0xFE30u32)
    of 0x2026u32: some(0xFE19u32)
    else: none(uint32)
  of 0x30u32:
    case cp
    of 0x3001u32: some(0xFE11u32)
    of 0x3002u32: some(0xFE12u32)
    of 0x3008u32: some(0xFE3Fu32)
    of 0x3009u32: some(0xFE40u32)
    of 0x300Au32: some(0xFE3Du32)
    of 0x300Bu32: some(0xFE3Eu32)
    of 0x300Cu32: some(0xFE41u32)
    of 0x300Du32: some(0xFE42u32)
    of 0x300Eu32: some(0xFE43u32)
    of 0x300Fu32: some(0xFE44u32)
    of 0x3010u32: some(0xFE3Bu32)
    of 0x3011u32: some(0xFE3Cu32)
    of 0x3014u32: some(0xFE39u32)
    of 0x3015u32: some(0xFE3Au32)
    of 0x3016u32: some(0xFE17u32)
    of 0x3017u32: some(0xFE18u32)
    else: none(uint32)
  of 0xFEu32:
    if cp == 0xFE4Fu32: some(0xFE34u32) else: none(uint32)
  of 0xFFu32:
    case cp
    of 0xFF01u32: some(0xFE15u32)
    of 0xFF08u32: some(0xFE35u32)
    of 0xFF09u32: some(0xFE36u32)
    of 0xFF0Cu32: some(0xFE10u32)
    of 0xFF1Au32: some(0xFE13u32)
    of 0xFF1Bu32: some(0xFE14u32)
    of 0xFF1Fu32: some(0xFE16u32)
    of 0xFF3Bu32: some(0xFE47u32)
    of 0xFF3Du32: some(0xFE48u32)
    of 0xFF3Fu32: some(0xFE33u32)
    of 0xFF5Bu32: some(0xFE37u32)
    of 0xFF5Du32: some(0xFE38u32)
    else: none(uint32)
  else: none(uint32)

# --------------------------------------------------------------------------
# Canonical composition / decomposition
# --------------------------------------------------------------------------

const
  # Hangul arithmetic constants.
  HangulSBase = 0xAC00u32
  # Syllable base.
  HangulLBase = 0x1100u32
  # Leading consonant base.
  HangulVBase = 0x1161u32
  # Vowel base.
  HangulTBase = 0x11A7u32
  # Trailing consonant base.
  HangulLCount = 19u32
  # Leading consonant count.
  HangulVCount = 21u32
  # Vowel count.
  HangulTCount = 28u32
  # Trailing consonant count.
  HangulNCount = HangulVCount * HangulTCount
  # Vowel by trailing block size.
  HangulSCount = HangulLCount * HangulNCount
  # Total precomposed syllable count.

proc encode3(x, y, z: uint32): uint64 =
  # Packs three 21 bit values into one key.
  (uint64(x) shl 42) or (uint64(y) shl 21) or uint64(z)

proc decode3_1(v: uint64): uint32 =
  # Unpacks the first value.
  uint32(v shr 42)
proc decode3_2(v: uint64): uint32 =
  # Unpacks the second value.
  uint32((v shr 21) and 0x001FFFFFu64)
proc decode3_3(v: uint64): uint32 =
  # Unpacks the third value.
  uint32(v and 0x001FFFFFu64)

proc encode3_11_7_14(x, y, z: uint32): uint32 =
  # Packs 11, 7, and 14 bit values into one key.
  ((x and 0x07FFu32) shl 21) or ((y and 0x007Fu32) shl 14) or (z and 0x3FFFu32)

proc decode3_11_7_14_1(v: uint32): uint32 =
  # Unpacks the first value.
  v shr 21
proc decode3_11_7_14_2(v: uint32): uint32 =
  # Unpacks the second value with the 0x300 bias.
  ((v shr 14) and 0x007Fu32) or 0x0300u32
proc decode3_11_7_14_3(v: uint32): uint32 =
  # Unpacks the third value.
  v and 0x3FFFu32

proc composeHangul(a, b: uint32): Option[uint32] =
  # Hangul LV and LVT composition.
  if HangulLBase <= a and a < HangulLBase + HangulLCount and
      HangulVBase <= b and b < HangulVBase + HangulVCount:
    some(HangulSBase + (a - HangulLBase) * HangulNCount +
      (b - HangulVBase) * HangulTCount)
  elif HangulSBase <= a and a <= HangulSBase + HangulSCount - HangulTCount and
      HangulTBase < b and b < HangulTBase + HangulTCount and
      (a - HangulSBase) mod HangulTCount == 0u32:
    some(a + (b - HangulTBase))
  else:
    none(uint32)

proc decomposeHangul(ab: uint32): Option[tuple[a, b: uint32]] =
  # Hangul syllable decomposition.
  if ab < HangulSBase or ab >= HangulSBase + HangulSCount:
    return none(tuple[a, b: uint32])
  let si = ab - HangulSBase
  if si mod HangulTCount != 0u32:
    some((HangulSBase + (si div HangulTCount) * HangulTCount,
      HangulTBase + (si mod HangulTCount)))
  else:
    some((HangulLBase + (si div HangulNCount),
      HangulVBase + (si mod HangulNCount) div HangulTCount))

proc binarySearchMaskedU32(arr: openArray[uint32], key, mask: uint32): int =
  # Masked binary search; index or -1.
  var lo = 0
  var hi = arr.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let k = arr[mid] and mask
    if k < key:
      lo = mid + 1
    elif k > key:
      hi = mid
    else:
      return mid
  -1

proc binarySearchMaskedU64(arr: openArray[uint64], key, mask: uint64): int =
  # Masked binary search; index or -1.
  var lo = 0
  var hi = arr.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let k = arr[mid] and mask
    if k < key:
      lo = mid + 1
    elif k > key:
      hi = mid
    else:
      return mid
  -1

proc composeImpl*(a, b: uint32): Option[uint32] =
  ## Canonical composition with Hangul handling.
  let hangul = composeHangul(a, b)
  if hangul.isSome:
    return hangul
  let u =
    if (a and 0xFFFFF800u32) == 0u32 and (b and 0xFFFFFF80u32) == 0x0300u32:
      let k = encode3_11_7_14(a, b, 0u32)
      let mask = encode3_11_7_14(0x001FFFFFu32, 0x001FFFFFu32, 0u32)
      let idx = binarySearchMaskedU32(ucdDm2U32Map, k, mask)
      if idx < 0:
        return none(uint32)
      decode3_11_7_14_3(ucdDm2U32Map[idx])
    else:
      let k = encode3(a, b, 0u32)
      let mask = encode3(0x001FFFFFu32, 0x001FFFFFu32, 0u32)
      let idx = binarySearchMaskedU64(ucdDm2U64Map, k, mask)
      if idx < 0:
        return none(uint32)
      decode3_3(ucdDm2U64Map[idx])
  if u == 0u32: none(uint32) else: some(u)

proc decomposeImpl*(ab: uint32): Option[tuple[a, b: uint32]] =
  ## Canonical decomposition with Hangul handling.
  let hangul = decomposeHangul(ab)
  if hangul.isSome:
    return hangul
  var i = int(ucdDm(ab))
  if i == 0:
    return none(tuple[a, b: uint32])
  dec i
  if i < ucdDm1P0Map.len + ucdDm1P2Map.len:
    let a =
      if i < ucdDm1P0Map.len: uint32(ucdDm1P0Map[i])
      else: 0x20000u32 or uint32(ucdDm1P2Map[i - ucdDm1P0Map.len])
    return some((a, 0u32))
  i -= ucdDm1P0Map.len + ucdDm1P2Map.len
  if i < ucdDm2U32Map.len:
    let v = ucdDm2U32Map[i]
    return some((decode3_11_7_14_1(v), decode3_11_7_14_2(v)))
  i -= ucdDm2U32Map.len
  let v = ucdDm2U64Map[i]
  some((decode3_1(v), decode3_2(v)))

proc compose*(a, b: uint32): Option[uint32] =
  ## Composes two codepoints, if a composition exists.
  composeImpl(a, b)

proc decompose*(cp: uint32): Option[Decomposed] =
  ## Decomposes a codepoint into singleton or pair form.
  let d = decomposeImpl(cp)
  if d.isNone:
    none(Decomposed)
  elif d.get.b == 0u32:
    some(Decomposed(kind: dkSingleton, single: d.get.a))
  else:
    some(Decomposed(kind: dkPair, first: d.get.a, second: d.get.b))

proc isMarkCodepoint*(cp: uint32): bool =
  ## True when the codepoint has a mark general category.
  generalCategoryFor(cp).isMark()
