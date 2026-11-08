## Indic syllabic categories and positions, plus the packed category
## trie.
##
## Ports harfrust `ot/shaper/indic_table.rs` (itself generated from
## IndicSyllabicCategory/IndicPositionalCategory/Blocks 18.0). The
## `indic_u8` blob is copied verbatim; the lookup functions are a
## direct port of `indic_b4` / `indic_get_categories_index` /
## `get_categories`.

import ../buffer

const
  OtX* = 0u8
  OtC* = 1u8
  OtV* = 2u8
  OtN* = 3u8
  OtH* = 4u8
  OtZwnj* = 5u8
  OtZwj* = 6u8
  OtM* = 7u8
  OtSm* = 8u8
  OtA* = 9u8
  OtVd* = OtA
  OtPlaceholder* = 10u8
  OtGb* = OtPlaceholder
  OtDottedCircle* = 11u8
  OtRs* = 12u8
  OtMpst* = 13u8
  OtRepha* = 14u8
  OtRa* = 15u8
  OtCm* = 16u8
  OtSymbol* = 17u8
  OtCs* = 18u8
  OtVAbv* = 20u8
  OtVBlw* = 21u8
  OtVPre* = 22u8
  OtVPst* = 23u8
  OtRobatic* = 25u8
  OtXgroup* = 26u8
  OtYgroup* = 27u8
  OtAs* = 32u8
  OtMh* = 35u8
  OtMr* = 36u8
  OtMw* = 37u8
  OtMy* = 38u8
  OtPt* = 39u8
  OtVs* = 40u8
  OtMl* = 41u8
  OtSmpst* = 57u8
  OtIv* = 2u8

  PosStart* = 0u8
  PosRaToBecomeReph* = 1u8
  PosPreM* = 2u8
  PosPreC* = 3u8
  PosBaseC* = 4u8
  PosAfterMain* = 5u8
  PosAboveC* = 6u8
  PosBeforeSub* = 7u8
  PosBelowC* = 8u8
  PosAfterSub* = 9u8
  PosBeforePost* = 10u8
  PosPostC* = 11u8
  PosAfterPost* = 12u8
  PosSmvd* = 13u8
  PosEnd* = 14u8

proc combineCatPos(s, m: uint8): uint16 =
  # Packs category and position into one lookup key.
  uint16(s) or (uint16(m) shl 8)

const
  IndicValues*: array[42, uint16] = [
    OtA.combineCatPos(PosSmvd), OtAs.combineCatPos(PosEnd),
    OtC.combineCatPos(PosBaseC), OtCm.combineCatPos(PosBaseC),
    OtCs.combineCatPos(PosBaseC), OtDottedCircle.combineCatPos(PosBaseC),
    OtGb.combineCatPos(PosBaseC), OtH.combineCatPos(PosBelowC),
    OtH.combineCatPos(PosAboveC), OtH.combineCatPos(PosEnd),
    OtM.combineCatPos(PosAfterMain), OtM.combineCatPos(PosAfterPost),
    OtM.combineCatPos(PosAfterSub), OtM.combineCatPos(PosBelowC),
    OtM.combineCatPos(PosBeforeSub), OtM.combineCatPos(PosPreM),
    OtMh.combineCatPos(PosEnd), OtMl.combineCatPos(PosEnd),
    OtMpst.combineCatPos(PosAfterPost), OtMr.combineCatPos(PosEnd),
    OtMw.combineCatPos(PosEnd), OtMy.combineCatPos(PosEnd),
    OtN.combineCatPos(PosEnd), OtPt.combineCatPos(PosEnd),
    OtRa.combineCatPos(PosBaseC), OtRepha.combineCatPos(PosEnd),
    OtRobatic.combineCatPos(PosEnd), OtSymbol.combineCatPos(PosSmvd),
    OtSm.combineCatPos(PosBeforeSub), OtSm.combineCatPos(PosSmvd),
    OtSmpst.combineCatPos(PosSmvd), OtV.combineCatPos(PosBaseC),
    OtVAbv.combineCatPos(PosAboveC), OtVBlw.combineCatPos(PosBelowC),
    OtVPre.combineCatPos(PosPreC), OtVPst.combineCatPos(PosPostC),
    OtVs.combineCatPos(PosEnd), OtX.combineCatPos(PosEnd),
    OtXgroup.combineCatPos(PosEnd), OtYgroup.combineCatPos(PosEnd),
    OtZwj.combineCatPos(PosEnd), OtZwnj.combineCatPos(PosEnd),
  ]

const
  IndicU8*: array[1224, uint8] = [
    1, 0, 50, 4, 5, 96, 0, 7, 8, 9, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 186, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192,
    0, 0, 0, 0, 208, 224, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0,
    2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 0, 0, 22, 23,
    24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 25, 26, 0, 0,
    0, 27, 0, 0, 0, 0, 28, 29, 30, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 31, 0, 0, 0, 32, 0, 0, 0, 33, 0, 34,
    0, 0, 0, 0, 0, 0, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 36, 0, 0, 0, 0, 0, 0, 37, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 25, 2, 10, 0, 0, 0, 0, 26, 0,
    27, 0, 0, 0, 28, 0, 0, 0, 0, 0, 29, 11, 30, 1, 1, 1,
    4, 31, 32, 33, 34, 1, 6, 2, 35, 1, 12, 13, 7, 1, 1, 3,
    36, 14, 15, 37, 16, 17, 6, 2, 38, 39, 18, 40, 7, 1, 1, 3,
    41, 42, 43, 44, 45, 46, 19, 2, 47, 0, 18, 48, 49, 1, 1, 3,
    20, 14, 50, 51, 0, 0, 21, 2, 0, 52, 53, 13, 7, 1, 1, 3,
    20, 54, 15, 55, 56, 17, 6, 2, 57, 0, 58, 59, 60, 61, 62, 63,
    4, 64, 65, 66, 16, 0, 19, 2, 0, 0, 67, 8, 9, 1, 1, 3,
    4, 22, 68, 69, 70, 71, 23, 2, 0, 0, 12, 8, 9, 1, 1, 3,
    72, 22, 73, 74, 75, 76, 23, 2, 77, 0, 78, 8, 9, 1, 1, 1,
    4, 79, 80, 81, 82, 83, 21, 2, 0, 84, 85, 1, 1, 86, 87, 88,
    89, 90, 2, 91, 92, 93, 94, 95, 96, 1, 97, 98, 2, 99, 0, 0,
    0, 0, 1, 1, 1, 100, 101, 11, 102, 103, 104, 105, 106, 107, 2, 10,
    0, 0, 0, 0, 108, 5, 5, 109, 110, 111, 0, 112, 113, 0, 114, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 115, 0, 116, 0, 0, 0, 0, 0,
    0, 0, 0, 117, 0, 0, 0, 0, 0, 118, 0, 0, 0, 0, 5, 5,
    119, 120, 0, 0, 0, 0, 121, 1, 2, 122, 0, 0, 0, 0, 1, 1,
    123, 124, 24, 24, 0, 0, 0, 0, 0, 0, 125, 0, 0, 0, 0, 0,
    0, 126, 0, 0, 2, 2, 2, 10, 0, 0, 0, 0, 2, 2, 2, 2,
    4, 4, 4, 4, 10, 2, 2, 2, 26, 2, 2, 2, 8, 8, 8, 8,
    6, 18, 0, 4, 20, 14, 24, 2, 6, 6, 20, 6, 20, 6, 24, 2,
    4, 0, 0, 0, 6, 6, 6, 6, 66, 12, 14, 6, 6, 6, 20, 14,
    2, 0, 36, 50, 52, 18, 38, 68, 0, 0, 0, 32, 0, 0, 2, 16,
    56, 12, 14, 6, 0, 0, 0, 4, 44, 2, 16, 2, 6, 22, 0, 4,
    2, 0, 36, 28, 6, 28, 0, 4, 30, 30, 30, 30, 0, 0, 42, 0,
    34, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 42, 12, 12, 6, 6,
    6, 6, 24, 2, 2, 18, 36, 110, 18, 18, 18, 18, 18, 18, 112, 114,
    116, 118, 120, 18, 0, 6, 6, 6, 44, 10, 0, 2, 54, 32, 46, 10,
    26, 0, 0, 0, 0, 0, 34, 70, 6, 20, 0, 14, 44, 2, 16, 10,
    2, 0, 72, 50, 122, 48, 0, 32, 48, 32, 46, 0, 124, 0, 0, 0,
    16, 2, 10, 10, 12, 2, 126, 0, 6, 6, 6, 14, 6, 14, 24, 2,
    22, 22, 52, 74, 76, 32, 46, 0, 16, 58, 58, 78, 128, 12, 14, 6,
    2, 0, 36, 130, 132, 32, 46, 0, 0, 134, 136, 138, 16, 0, 0, 0,
    0, 70, 14, 6, 6, 20, 0, 6, 20, 6, 24, 0, 16, 10, 10, 2,
    0, 16, 10, 0, 2, 10, 0, 2, 2, 0, 0, 22, 76, 48, 0, 80,
    54, 22, 82, 0, 12, 12, 140, 6, 28, 60, 38, 28, 84, 28, 86, 0,
    0, 0, 142, 84, 2, 10, 16, 0, 26, 2, 16, 2, 28, 60, 38, 60,
    38, 18, 86, 0, 0, 0, 74, 38, 0, 0, 16, 10, 144, 146, 0, 0,
    12, 12, 148, 6, 2, 150, 152, 22, 22, 22, 48, 80, 54, 22, 82, 154,
    0, 0, 2, 156, 0, 0, 0, 14, 0, 2, 2, 2, 2, 2, 26, 2,
    2, 158, 2, 2, 88, 6, 6, 6, 6, 160, 90, 92, 162, 164, 62, 58,
    166, 168, 170, 172, 4, 4, 0, 10, 2, 6, 6, 94, 96, 26, 2, 174,
    176, 98, 178, 180, 98, 100, 100, 2, 102, 62, 182, 2, 2, 184, 186, 188,
    12, 12, 12, 190, 4, 12, 192, 0, 2, 26, 2, 2, 2, 88, 6, 6,
    6, 6, 0, 90, 62, 92, 96, 194, 196, 198, 94, 200, 202, 104, 104, 106,
    106, 204, 0, 0, 42, 0, 206, 0, 8, 208, 8, 8, 210, 40, 212, 40,
    40, 2, 214, 216, 8, 34, 0, 0, 0, 0, 218, 0, 4, 4, 4, 0,
    0, 34, 0, 0, 0, 0, 108, 0, 0, 64, 108, 0, 0, 0, 220, 0,
    0, 42, 4, 34, 8, 40, 40, 40, 0, 0, 0, 222, 2, 2, 102, 16,
    4, 2, 2, 10, 16, 2, 4, 34, 0, 224, 78, 2, 56, 12, 0, 0,
    0, 226, 72, 0, 37, 37, 2, 2, 6, 6, 31, 31, 0, 0, 2, 37,
    29, 29, 37, 31, 37, 2, 12, 12, 31, 37, 11, 11, 31, 2, 24, 2,
    14, 14, 36, 36, 37, 11, 6, 37, 22, 27, 12, 37, 27, 27, 37, 6,
    24, 37, 11, 7, 11, 37, 11, 15, 11, 12, 15, 37, 37, 29, 0, 22,
    14, 12, 32, 32, 30, 30, 6, 29, 37, 15, 29, 37, 22, 37, 37, 12,
    12, 11, 22, 22, 15, 15, 11, 8, 14, 37, 14, 8, 2, 31, 35, 32,
    32, 33, 35, 35, 33, 33, 35, 23, 23, 23, 2, 32, 26, 38, 38, 38,
    30, 37, 12, 15, 12, 7, 15, 12, 37, 0, 0, 29, 29, 12, 18, 11,
    37, 13, 37, 3, 37, 28, 11, 10, 10, 37, 37, 10, 10, 22, 10, 11,
    29, 31, 37, 14, 37, 4, 4, 29, 6, 31, 2, 12, 12, 27, 25, 37,
    2, 11, 2, 24, 31, 35, 33, 34, 0, 32, 29, 9, 1, 21, 19, 20,
    16, 2, 21, 21, 17, 2, 23, 2, 2, 35, 32, 2, 20, 35, 34, 32,
    32, 29, 2, 29, 29, 32, 32, 35, 35, 34, 34, 34, 38, 39, 39, 26,
    9, 39, 27, 39, 0, 37, 0, 27, 27, 0, 0, 4, 4, 0, 41, 40,
    5, 37, 31, 12, 2, 23, 37, 22,
  ]

proc indicB4(a: openArray[uint8], i: int): uint8 =
  # Reads one packed table nibble.
  uint8((uint32(a[i shr 1]) shr uint32((i and 1) shl 2)) and 15u32)

proc indicCategoriesIndex*(u: int): uint8 =
  ## Packed-trie lookup of the category-table index for a codepoint;
  ## out-of-range codepoints map to index 37 (like harfrust).
  if u < 71396:
    let b0 = int(indicB4(IndicU8, (((u shr 1) shr 2) shr 3) shr 3))
    let l1 = int(IndicU8[70 + (b0 shl 3) + ((((u shr 1) shr 2) shr 3) and 7)])
    let l2 = int(IndicU8[186 + (l1 shl 3) + (((u shr 1) shr 2) and 7)])
    let l3 = int(IndicU8[488 + (l2 shl 2) + ((u shr 1) and 3)])
    uint8(int(IndicU8[996 + l3 + (u and 1)]))
  else:
    37u8

proc getCategories*(u: uint32): tuple[cat, pos: uint8] =
  ## Returns the (syllabic category, position) pair for a codepoint.
  let v = IndicValues[int(indicCategoriesIndex(int(u)))]
  (uint8(v and 0xFFu16), uint8(v shr 8))

proc indicCategory*(g: GlyphInfo): uint8 =
  ## Syllabic category attached during setup (otShaperCategory slot,
  ## mirroring harfrust `INDIC_CATEGORY_VAR`).
  g.otShaperCategory()

proc setIndicCategory*(g: var GlyphInfo, v: uint8) =
  ## Writes the Indic category byte.
  g.setOtShaperCategory(v)

proc indicPosition*(g: GlyphInfo): uint8 =
  ## Positional category attached during setup (otShaperAuxiliary
  ## slot, mirroring harfrust `INDIC_POSITION_VAR`).
  g.otShaperAuxiliary()

proc setIndicPosition*(g: var GlyphInfo, v: uint8) =
  ## Writes the Indic position byte.
  g.setOtShaperAuxiliary(v)
