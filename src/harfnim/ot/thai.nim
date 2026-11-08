## Thai/Lao shaper: SARA AM split and PUA fallback shaping.
##
## Ported from harfrust `ot/shaper/thai.rs`, implementing the rules
## from https://linux.thai.net/~thep/th-otf/shaping.html. SARA AM
## always decomposes to NIKHAHIT + SARA AA with the NIKHAHIT moved
## back over above-base marks; the PUA positioning fallback only runs
## for Thai (not Lao) when the font has no Thai GSUB.

import std/options

import ../buffer
import ../font
import ../script
import ../tag
import ../unicode
import ./gsub

type
  Consonant* = enum
    Nc, Ac, Rc, Dc, NotConsonant
  Mark* = enum
    Av, Bv, T, NotMark
  AboveState = enum
    T0, T1, T2, T3
  BelowState = enum
    B0, B1, B2
  ThaiAction = enum
    Nop, Sd, Sl, Sdl, Rd

proc getConsonantType*(u: uint32): Consonant =
  # Specific consonants first: they sit inside the 0x0E01..0x0E2E
  # range, which Nim's case labels would reject as overlapping.
  if u == 0x0E1Bu32 or u == 0x0E1Du32 or u == 0x0E1Fu32:
    Ac
  elif u == 0x0E0Du32 or u == 0x0E10u32:
    Rc
  elif u == 0x0E0Eu32 or u == 0x0E0Fu32:
    Dc
  elif u >= 0x0E01u32 and u <= 0x0E2Eu32:
    Nc
  else:
    NotConsonant

proc getMarkType*(u: uint32): Mark =
  ## Classifies Thai and Lao marks.
  if u == 0x0E31u32 or (u >= 0x0E34u32 and u <= 0x0E37u32) or
      u == 0x0E47u32 or (u >= 0x0E4Du32 and u <= 0x0E4Eu32):
    Av
  elif u >= 0x0E38u32 and u <= 0x0E3Au32:
    Bv
  elif u >= 0x0E48u32 and u <= 0x0E4Cu32:
    T
  else:
    NotMark

const
  SdMappings*: array[9, tuple[u, win, mac: uint16]] = [
    (0x0E48u16, 0xF70Au16, 0xF88Bu16),
    (0x0E49u16, 0xF70Bu16, 0xF88Eu16),
    (0x0E4Au16, 0xF70Cu16, 0xF891u16),
    (0x0E4Bu16, 0xF70Du16, 0xF894u16),
    (0x0E4Cu16, 0xF70Eu16, 0xF897u16),
    (0x0E38u16, 0xF718u16, 0xF89Bu16),
    (0x0E39u16, 0xF719u16, 0xF89Cu16),
    (0x0E3Au16, 0xF71Au16, 0xF89Du16),
    (0x0000u16, 0x0000u16, 0x0000u16),
  ]
  SdlMappings*: array[6, tuple[u, win, mac: uint16]] = [
    (0x0E48u16, 0xF705u16, 0xF88Cu16),
    (0x0E49u16, 0xF706u16, 0xF88Fu16),
    (0x0E4Au16, 0xF707u16, 0xF892u16),
    (0x0E4Bu16, 0xF708u16, 0xF895u16),
    (0x0E4Cu16, 0xF709u16, 0xF898u16),
    (0x0000u16, 0x0000u16, 0x0000u16),
  ]
  SlMappings*: array[12, tuple[u, win, mac: uint16]] = [
    (0x0E48u16, 0xF713u16, 0xF88Au16),
    (0x0E49u16, 0xF714u16, 0xF88Du16),
    (0x0E4Au16, 0xF715u16, 0xF890u16),
    (0x0E4Bu16, 0xF716u16, 0xF893u16),
    (0x0E4Cu16, 0xF717u16, 0xF896u16),
    (0x0E31u16, 0xF710u16, 0xF884u16),
    (0x0E34u16, 0xF701u16, 0xF885u16),
    (0x0E35u16, 0xF702u16, 0xF886u16),
    (0x0E36u16, 0xF703u16, 0xF887u16),
    (0x0E37u16, 0xF704u16, 0xF888u16),
    (0x0E47u16, 0xF712u16, 0xF889u16),
    (0x0E4Du16, 0xF711u16, 0xF899u16),
  ]
  # No trailing sentinel in harfrust; the loop ends at the array end.
  RdMappings*: array[2, tuple[u, win, mac: uint16]] = [
    (0x0E0Du16, 0xF70Fu16, 0xF89Au16),
    (0x0E10u16, 0xF700u16, 0xF89Eu16),
  ]

  AboveStartState: array[5, AboveState] = [T0, T1, T0, T0, T3]
  AboveStateMachine: array[4, array[3,
    tuple[action: ThaiAction, next: AboveState]]] = [
    [(Nop, T3), (Nop, T0), (Sd, T3)],
    [(Sl, T2), (Nop, T1), (Sdl, T2)],
    [(Nop, T3), (Nop, T2), (Sl, T3)],
    [(Nop, T3), (Nop, T3), (Nop, T3)],
  ]
  BelowStartState: array[5, BelowState] = [B0, B0, B1, B2, B2]
  BelowStateMachine: array[3, array[3,
    tuple[action: ThaiAction, next: BelowState]]] = [
    [(Nop, B0), (Nop, B2), (Nop, B0)],
    [(Nop, B1), (Rd, B2), (Nop, B1)],
    [(Nop, B2), (Sd, B2), (Nop, B2)],
  ]

proc puaShape(u: uint32, action: ThaiAction, sf: ShaperFont): uint32 =
  ## Remaps a mark to its Windows PUA glyph (Mac PUA as fallback)
  ## when the font provides it, else returns the mark unchanged.
  var mappings: seq[tuple[u, win, mac: uint16]] = @[]
  case action
  of Nop:
    return u
  of Sd:
    for m in SdMappings:
      mappings.add(m)
  of Sdl:
    for m in SdlMappings:
      mappings.add(m)
  of Sl:
    for m in SlMappings:
      mappings.add(m)
  of Rd:
    for m in RdMappings:
      mappings.add(m)
  for m in mappings:
    if m.u == 0u16:
      break
    if uint32(m.u) == u:
      if sf.hasGlyph(uint32(m.win)):
        return uint32(m.win)
      if sf.hasGlyph(uint32(m.mac)):
        return uint32(m.mac)
      break
  u

proc doPuaShaping(sf: ShaperFont, buf: var Buffer) =
  ## Fallback mark positioning for fonts without Thai GSUB, driven by
  ## the above/below state machines. Only the glyph id changes, so
  ## the buffer length is stable throughout.
  var aboveState = AboveStartState[ord(NotConsonant)]
  var belowState = BelowStartState[ord(NotConsonant)]
  var base = 0
  var i = 0
  while i < buf.len and buf.successful:
    if i >= buf.info.len:
      buf.indexFailed()
      return
    let glyph = buf.info[i].glyphId
    let mt = getMarkType(glyph)
    if mt == NotMark:
      let ct = getConsonantType(glyph)
      aboveState = AboveStartState[ord(ct)]
      belowState = BelowStartState[ord(ct)]
      base = i
      inc i
      continue
    let aboveEdge = AboveStateMachine[ord(aboveState)][ord(mt)]
    let belowEdge = BelowStateMachine[ord(belowState)][ord(mt)]
    aboveState = aboveEdge.next
    belowState = belowEdge.next
    # At least one of the above/below actions is Nop.
    let action =
      if aboveEdge.action != Nop: aboveEdge.action
      else: belowEdge.action
    buf.unsafeToBreakRange(some(base), some(i))
    let target = if action == Rd: base else: i
    if target < 0 or target >= buf.info.len:
      buf.indexFailed()
      return
    buf.info[target].glyphId = puaShape(buf.info[target].glyphId,
      action, sf)
    inc i

proc isSaraAm*(u: uint32): bool =
  ## True for SARA AM across Thai and Lao blocks.
  (u and not 0x0080u32) == 0x0E33u32

proc nikhahitFromSaraAm*(u: uint32): uint32 =
  ## Splits the nikhahit half out of SARA AM.
  u - 0x0E33u32 + 0x0E4Du32

proc saraAaFromSaraAm*(u: uint32): uint32 =
  ## Splits the sara aa half out of SARA AM.
  u - 1u32

proc isAboveBaseMark(u: uint32): bool =
  # True for above base marks.
  let v = u and not 0x0080u32
  (v >= 0x0E34u32 and v <= 0x0E37u32) or
    (v >= 0x0E47u32 and v <= 0x0E4Eu32) or v == 0x0E31u32 or
    v == 0x0E3Bu32

proc moveNikhahit(buf: var Buffer, fin: int): Option[int] =
  ## Moves the NIKHAHIT emitted at `fin - 2` back over preceding
  ## above-base marks, returning where it lands.
  let nikhahit = fin - 2
  if nikhahit < 0:
    return none(int)
  let slot = buf.outAt(nikhahit)
  if slot == nil:
    buf.indexFailed()
    return none(int)
  # Make NIKHAHIT be recognized as a ccc=0 mark when zeroing widths.
  slot[].setGeneralCategory(GcNonSpacingMark)
  var start = nikhahit
  while start > 0:
    let prev = buf.outAt(start - 1)
    if prev == nil:
      buf.indexFailed()
      return none(int)
    if not isAboveBaseMark(prev[].glyphId):
      break
    dec start
  if start < nikhahit:
    buf.mergeOutClusters(start, fin)
    if not buf.rotateOutRightByOne(start, nikhahit):
      return none(int)
  some(start)

proc gsubHasThai*(gsub: GsubData): bool =
  ## Whether GSUB carries an exact Thai script record. Only then is
  ## PUA fallback shaping skipped (mirroring harfrust's
  ## `found_script`, which is false under DFLT fallback).
  for s in gsub.scripts:
    if s.tag == tagFromStr("thai").toU32():
      return true
  false

proc preprocessThai*(buf: var Buffer, sf: ShaperFont, hasThaiGsub: bool) =
  ## Splits SARA AM into NIKHAHIT + SARA AA (moving the NIKHAHIT back
  ## over above-base marks), then runs PUA fallback shaping for Thai
  ## fonts without Thai GSUB. Operates on codepoints, pre-normalize.
  buf.clearOutput()
  buf.idx = 0
  while buf.idx < buf.len and buf.successful:
    let c = buf.cur(0)
    if c == nil:
      buf.indexFailed()
      return
    let u = c[].glyphId
    if not isSaraAm(u):
      buf.nextGlyph()
      continue
    buf.outputGlyph(nikhahitFromSaraAm(u))
    # harfrust reads the emitted info into a discarded copy before
    # calling set_continuation, so there is nothing to port here.
    buf.replaceGlyph(saraAaFromSaraAm(u))
    let fin = buf.outLen
    let moved = moveNikhahit(buf, fin)
    let start = if moved.isSome: moved.get else: fin - 2
    if buf.successful and start != 0:
      buf.mergeOutGraphemeClusters(start - 1, fin)
  discard buf.sync()
  if buf.script.isSome and buf.script.get == Thai and not hasThaiGsub:
    doPuaShaping(sf, buf)
