## Hebrew shaper: presentation-form composition and mark reordering.
##
## Ported from harfrust `ot/shaper/hebrew.rs`. Hebrew shaping is the
## default path plus two behaviors: legacy presentation-form
## composition (dagesh, shin/sin dots, hiriq/patah/qamats/holam/rafe
## forms, from UCD-excluded forms wanted by old fonts) and a
## post-reorder swap of the last two marks in patah/qamats +
## sheva/hiriq + meteg/below triples.

import std/options

import ../buffer
import ../normalize
import ../unicode

const
  # harfrust `modified_combining_class` namespace: the permuted
  # fixed-position classes from the SBL Hebrew manual.
  HebSheva* = 22u8
  HebHiriq* = 23u8
  HebPatah* = 20u8
  HebQamats* = 21u8
  HebMeteg* = 25u8
  HebBelow* = 220u8

  # Presentation forms with dagesh for U+05D0..U+05EA. Zero means the
  # letter has no encoded dagesh form.
  DageshForms*: array[27, uint32] = [
    0xFB30u32, # ALEF
    0xFB31u32, # BET
    0xFB32u32, # GIMEL
    0xFB33u32, # DALET
    0xFB34u32, # HE
    0xFB35u32, # VAV
    0xFB36u32, # ZAYIN
    0x0000u32, # HET
    0xFB38u32, # TET
    0xFB39u32, # YOD
    0xFB3Au32, # FINAL KAF
    0xFB3Bu32, # KAF
    0xFB3Cu32, # LAMED
    0x0000u32, # FINAL MEM
    0xFB3Eu32, # MEM
    0x0000u32, # FINAL NUN
    0xFB40u32, # NUN
    0xFB41u32, # SAMEKH
    0x0000u32, # AYIN
    0xFB43u32, # FINAL PE
    0xFB44u32, # PE
    0x0000u32, # FINAL TSADI
    0xFB46u32, # TSADI
    0xFB47u32, # QOF
    0xFB48u32, # RESH
    0xFB49u32, # SHIN
    0xFB4Au32, # TAV
  ]

proc hebrewComposeFn*(hasGposMark: bool): ComposeFn =
  ## Presentation-form composition for old fonts. Standard Unicode
  ## composition first; the legacy Hebrew forms only apply when the
  ## font provides no GPOS mark positioning (mirrors harfrust
  ## `hebrew::compose`, gated on `!plan.has_gpos_mark`).
  result = proc(a, b: uint32): Option[uint32] {.closure.} =
    let std = composeImpl(a, b)
    if std.isSome:
      return std
    if hasGposMark:
      return none(uint32)
    case b
    of 0x05B4u32: # HIRIQ
      if a == 0x05D9u32: # YOD
        return some(0xFB1Du32)
    of 0x05B7u32: # PATAH
      if a == 0x05D9u32: # YIDDISH YOD YOD
        return some(0xFB1Fu32)
      if a == 0x05D0u32: # ALEF
        return some(0xFB2Eu32)
    of 0x05B8u32: # QAMATS
      if a == 0x05D0u32: # ALEF
        return some(0xFB2Fu32)
    of 0x05B9u32: # HOLAM
      if a == 0x05D5u32: # VAV
        return some(0xFB4Bu32)
    of 0x05BCu32: # DAGESH
      if a >= 0x05D0u32 and a <= 0x05EAu32:
        let c = DageshForms[int(a - 0x05D0u32)]
        if c != 0u32:
          return some(c)
      elif a == 0xFB2Au32: # SHIN WITH SHIN DOT
        return some(0xFB2Cu32)
      elif a == 0xFB2Bu32: # SHIN WITH SIN DOT
        return some(0xFB2Du32)
    of 0x05BFu32: # RAFE
      if a == 0x05D1u32: # BET
        return some(0xFB4Cu32)
      if a == 0x05DBu32: # KAF
        return some(0xFB4Du32)
      if a == 0x05E4u32: # PE
        return some(0xFB4Eu32)
    of 0x05C1u32: # SHIN DOT
      if a == 0x05E9u32: # SHIN
        return some(0xFB2Au32)
      if a == 0xFB49u32: # SHIN WITH DAGESH
        return some(0xFB2Cu32)
    of 0x05C2u32: # SIN DOT
      if a == 0x05E9u32: # SHIN
        return some(0xFB2Bu32)
      if a == 0xFB49u32: # SHIN WITH DAGESH
        return some(0xFB2Du32)
    else:
      discard
    none(uint32)

proc reorderMarksHebrew*(buf: var Buffer, start, stop: int) =
  ## Swaps the last two marks of a patah/qamats + sheva/hiriq +
  ## meteg/below triple, merging their clusters first. Runs as the
  ## normalize mark-reorder hook over each mark run.
  if start < 0 or stop > buf.info.len or stop - start < 3:
    return
  var found = -1
  var i = start
  while i + 2 < stop:
    let c0 = buf.info[i].modifiedCombiningClass()
    let c1 = buf.info[i + 1].modifiedCombiningClass()
    let c2 = buf.info[i + 2].modifiedCombiningClass()
    if (c0 == HebPatah or c0 == HebQamats) and
        (c1 == HebSheva or c1 == HebHiriq) and
        (c2 == HebMeteg or c2 == HebBelow):
      found = i
      break
    inc i
  if found < 0:
    return
  let at = found + 2
  if at < 1 or at >= buf.info.len:
    return
  buf.mergeClusters(at - 1, at + 1)
  swap(buf.info[at - 1], buf.info[at])
