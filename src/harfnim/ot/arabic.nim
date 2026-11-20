## Arabic shaper: joining, masks, fallback, mark reordering, stch stretch.
##
## Ported from harfrust `ot/shaper/arabic.rs` + `arabic_fallback.rs` at a
## static-font scope. Syriac shares the joining machinery; Mongolian
## variation-selector propagation is included, as is the legacy
## Windows-1256 fixed-gid fallback. stch multiplications are recorded
## right after the stch feature and expanded into repeated tiles after
## positioning. Pre/post-context across buffer boundaries stays TODO.

import std/options
import std/sequtils

import ../buffer
import ../direction
import ../feature
import ../font
import ../tag
import ../unicode
import ./apply
import ./arabic_table
import ./coverage
import ./gsub

export arabic_table
export gsub

type
  ArabicJoining* = enum
    ## Arabic joining type.
    ajU = 0u8
    ## Non joining.
    ajL = 1u8
    ## Left joining.
    ajR = 2u8
    ## Right joining.
    ajD = 3u8
    ## Dual joining.
    ajAlaph = 4u8
    ## Alaph joining.
    ajDalath = 5u8
    ## Dalath Rish joining.
    ajT = 6u8
    ## Transparent joining.
    ajX = 7u8
    ## Unknown joining.

const
  ArabicIsol* = 0u8
    ## Isolated form.
  ArabicFina* = 1u8
    ## Final form.
  ArabicFin2* = 2u8
    ## Final form variant 2.
  ArabicFin3* = 3u8
    ## Final form variant 3.
  ArabicMedi* = 4u8
    ## Medial form.
  ArabicMed2* = 5u8
    ## Medial form variant 2.
  ArabicInit* = 6u8
    ## Initial form.
  ArabicNone* = 7u8
    ## No joining form.
  ArabicStretchFixed* = 8u8
    ## stch fixed tile.
  ArabicStretchRepeating* = 9u8
    ## stch repeating tile.

proc isStchAction*(a: uint8): bool =
  ## True for stch stretch tiles.
  a == ArabicStretchFixed or a == ArabicStretchRepeating

const
  ArabicHasStchFlag* = ScratchFlagShaper0
    ## Scratch flag marking recorded stch stretches, mirroring harfrust
    ## HB_BUFFER_SCRATCH_FLAG_ARABIC_HAS_STCH.

  ArabicFeatureTags*: array[7, string] = ["isol", "fina", "fin2", "fin3",
    "medi", "med2", "init"]
    ## Feature tag per joining action.

proc joiningTypeFor*(cp: uint32, gc: GeneralCategory): ArabicJoining =
  ## Looks up the joining type, defaulting non spacing marks.
  let raw = arabicJoiningTypeRaw(int(cp))
  if raw != 7u8:
    return ArabicJoining(raw)
  # X: use general category to choose between U or T.
  let f = gc.gcFlagUnsafe()
  let markFmt = GcNonSpacingMark.gcFlagUnsafe() or
    GcEnclosingMark.gcFlagUnsafe() or GcFormat.gcFlagUnsafe()
  if (f and markFmt) != 0u32:
    ajT
  else:
    ajU

proc isWordCategory*(gc: GeneralCategory): bool =
  # Mirrors harfrust word-category set for stch justification.
  gc == GcUnassigned or gc == GcPrivateUse or gc == GcModifierLetter or
    gc == GcOtherLetter or gc == GcSpacingMark or gc == GcEnclosingMark or
    gc == GcNonSpacingMark or gc == GcDecimalNumber or gc == GcLetterNumber or
    gc == GcOtherNumber or gc == GcCurrencySymbol or gc == GcModifierSymbol or
    gc == GcMathSymbol or gc == GcOtherSymbol

proc arabicAction*(g: GlyphInfo): uint8 =
  ## Reads the Arabic joining action.
  g.otShaperAuxiliary()

proc setArabicAction*(g: var GlyphInfo, v: uint8) =
  ## Writes the Arabic joining action.
  g.setOtShaperAuxiliary(v)

# State table: [state][joining-col] -> (prevAction, curAction, nextState).
# Columns: U, L, R, D, Alaph, Dalath. Mirrors harfrust STATE_TABLE.
const StateTable*: array[7, array[6,
    tuple[prev, cur: uint8, next: int]]] = [
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicNone, ArabicIsol, 1), (ArabicNone, ArabicIsol, 2),
    (ArabicNone, ArabicIsol, 1), (ArabicNone, ArabicIsol, 6)],
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicNone, ArabicIsol, 1), (ArabicNone, ArabicIsol, 2),
    (ArabicNone, ArabicFin2, 5), (ArabicNone, ArabicIsol, 6)],
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicInit, ArabicFina, 1), (ArabicInit, ArabicFina, 3),
    (ArabicInit, ArabicFina, 4), (ArabicInit, ArabicFina, 6)],
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicMedi, ArabicFina, 1), (ArabicMedi, ArabicFina, 3),
    (ArabicMedi, ArabicFina, 4), (ArabicMedi, ArabicFina, 6)],
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicMed2, ArabicIsol, 1), (ArabicMed2, ArabicIsol, 2),
    (ArabicMed2, ArabicFin2, 5), (ArabicMed2, ArabicIsol, 6)],
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicIsol, ArabicIsol, 1), (ArabicIsol, ArabicIsol, 2),
    (ArabicIsol, ArabicFin2, 5), (ArabicIsol, ArabicIsol, 6)],
  [(ArabicNone, ArabicNone, 0), (ArabicNone, ArabicIsol, 2),
    (ArabicNone, ArabicIsol, 1), (ArabicNone, ArabicIsol, 2),
    (ArabicNone, ArabicFin3, 5), (ArabicNone, ArabicIsol, 6)],
]

proc colForJoining*(j: ArabicJoining): int =
  ## Maps a joining type to its state table column.
  case j
  of ajU: -1
  of ajL: 1
  of ajR: 2
  of ajD: 3
  of ajAlaph: 4
  of ajDalath: 5
  of ajT: -1
  of ajX: -1

proc arabicJoining*(buf: var Buffer) =
  ## Runs Arabic joining over codepoints.
  var prev: Option[int] = none(int)
  var state = 0
  # Pre-context: only first transparent run matters for initial state.
  for k in 0 ..< buf.contextLen[0]:
    let cp = buf.context[0][k]
    let jt = joiningTypeFor(cp, generalCategoryFor(cp))
    if jt == ajT:
      continue
    let col = colForJoining(jt)
    if col >= 0:
      state = StateTable[state][col].next
    break
  for i in 0 ..< buf.len:
    if i >= buf.info.len:
      break
    let cp = buf.info[i].asCodepoint()
    let jt = joiningTypeFor(cp, buf.info[i].generalCategory())
    if jt == ajT:
      buf.info[i].setArabicAction(ArabicNone)
      continue
    let col = colForJoining(jt)
    if col < 0:
      buf.info[i].setArabicAction(ArabicNone)
      continue
    let entry = StateTable[state][col]
    if entry.prev != ArabicNone and prev.isSome:
      let p = prev.get
      if p >= 0 and p < buf.info.len:
        buf.info[p].setArabicAction(entry.prev)
        buf.safeToInsertTatweelRange(some(p), some(i + 1))
    else:
      if prev.isSome:
        let p = prev.get
        if jt >= ajR or (state >= 2 and state <= 5):
          buf.unsafeToConcatRange(some(p), some(i + 1))
      else:
        if jt >= ajR:
          buf.unsafeToConcatFromOutbuffer(some(0), some(i + 1))
    buf.info[i].setArabicAction(entry.cur)
    prev = some(i)
    state = entry.next
  # Post-context.
  for k in 0 ..< buf.contextLen[1]:
    let cp = buf.context[1][k]
    let jt = joiningTypeFor(cp, generalCategoryFor(cp))
    if jt == ajT:
      continue
    let col = colForJoining(jt)
    if col < 0:
      break
    let entry = StateTable[state][col]
    if entry.prev != ArabicNone and prev.isSome:
      let p = prev.get
      if p >= 0 and p < buf.info.len:
        buf.info[p].setArabicAction(entry.prev)
        buf.safeToInsertTatweelRange(some(p), some(buf.len))
    elif state >= 2 and state <= 5:
      if prev.isSome:
        buf.unsafeToConcatRange(prev, some(buf.len))
    break

proc mongolianVariationSelectors*(buf: var Buffer) =
  ## Handles Mongolian variation selectors.
  if buf.len == 0 or buf.info.len == 0:
    return
  var action = buf.info[0].arabicAction()
  for i in 0 ..< min(buf.len, buf.info.len):
    let gid = buf.info[i].glyphId
    if (gid >= 0x180Bu32 and gid <= 0x180Du32) or gid == 0x180Fu32:
      buf.info[i].setArabicAction(action)
    action = buf.info[i].arabicAction()

proc setupMasksArabic*(buf: var Buffer, maskArray: array[8, uint32],
    isMongolian: bool) =
  arabicJoining(buf)
  if isMongolian:
    mongolianVariationSelectors(buf)
  for i in 0 ..< min(buf.len, buf.info.len):
    let a = buf.info[i].arabicAction()
    if a <= 7u8:
      buf.info[i].mask = buf.info[i].mask or maskArray[int(a)]

# --- fallback presentation-form synthesis (unicode tables only) ---

type
  FallbackSingle* = tuple[fromGid, toGid: uint16]
    ## Fallback single substitution mapping.
  FallbackLig* = tuple[first: uint16, rest: seq[uint16], lig: uint16]
    ## Fallback ligature mapping.

const
  ## HarfBuzz signature identifying legacy Windows-1256 Arabic fonts:
  ## these encode Arabic glyphs at fixed glyph IDs rather than
  ## providing Unicode presentation forms.
  Win1256Signature*: array[5, tuple[cp: uint32, gid: uint16]] = [
    (0x0627u32, 199u16), # ALEF
    (0x0644u32, 225u16), # LAM
    (0x0649u32, 236u16), # ALEF MAKSURA
    (0x064Au32, 237u16), # YEH
    (0x0652u32, 250u16), # SUKUN
  ]

  Win1256InitMappings*: array[23, tuple[fromGid, toGid: uint16]] = [
    (198u16, 162u16), (200u16, 4u16), (201u16, 5u16), (202u16, 5u16),
    (203u16, 6u16), (204u16, 7u16), (205u16, 9u16), (206u16, 11u16),
    (211u16, 13u16), (212u16, 14u16), (213u16, 15u16), (214u16, 26u16),
    (218u16, 27u16), (219u16, 30u16), (221u16, 128u16), (222u16, 131u16),
    (223u16, 140u16), (225u16, 141u16), (227u16, 142u16), (228u16, 143u16),
    (229u16, 144u16), (236u16, 154u16), (237u16, 154u16),
  ]

  Win1256MediMappings*: array[27, tuple[fromGid, toGid: uint16]] = [
    (165u16, 170u16), (178u16, 179u16), (180u16, 185u16), (198u16, 162u16),
    (200u16, 4u16), (201u16, 5u16), (202u16, 5u16), (203u16, 6u16),
    (204u16, 7u16), (205u16, 9u16), (206u16, 11u16), (211u16, 13u16),
    (212u16, 14u16), (213u16, 15u16), (214u16, 26u16), (218u16, 28u16),
    (219u16, 31u16), (221u16, 129u16), (222u16, 138u16), (223u16, 140u16),
    (225u16, 141u16), (227u16, 142u16), (228u16, 143u16), (229u16, 149u16),
    (236u16, 154u16), (237u16, 154u16), (252u16, 255u16),
  ]

  Win1256FinaMappings*: array[18, tuple[fromGid, toGid: uint16]] = [
    (165u16, 170u16), (178u16, 179u16), (180u16, 185u16), (194u16, 2u16),
    (195u16, 1u16), (197u16, 3u16), (198u16, 181u16), (199u16, 0u16),
    (201u16, 159u16), (204u16, 8u16), (205u16, 10u16), (206u16, 12u16),
    (218u16, 29u16), (219u16, 127u16), (229u16, 152u16), (236u16, 160u16),
    (237u16, 156u16), (252u16, 255u16),
  ]

  Win1256LamAlefLigatures*: array[4,
    tuple[first, second, lig: uint16]] = [
    (225u16, 199u16, 165u16), (225u16, 195u16, 178u16),
    (225u16, 194u16, 180u16), (225u16, 197u16, 252u16),
  ]

  Win1256ShaddaLigatures*: array[3,
    tuple[first, second, lig: uint16]] = [
    (248u16, 243u16, 172u16), (248u16, 245u16, 173u16),
    (248u16, 246u16, 175u16),
  ]

proc shapingFormFor*(cp: uint16, featIdx: int): uint16 =
  # featIdx: 0 init, 1 medi, 2 fina, 3 isol.
  for e in ShapingTable:
    if e.cp == cp:
      if featIdx >= 0 and featIdx < 4:
        return e.forms[featIdx]
      return 0u16
  0u16

proc buildFallbackSingles*(nominal: proc(cp: uint32): Option[GlyphId],
    featIdx: int): seq[FallbackSingle] =
  result = @[]
  for e in ShapingTable:
    let form = if featIdx >= 0 and featIdx < 4: e.forms[featIdx] else: 0u16
    if form == 0u16:
      continue
    let g = nominal(uint32(e.cp))
    let s = nominal(uint32(form))
    if g.isNone or s.isNone:
      continue
    let gv = g.get.value
    let sv = s.get.value
    if gv > 0xFFFFu32 or sv > 0xFFFFu32 or gv == sv:
      continue
    result.add((uint16(gv), uint16(sv)))
  # Stable sort by fromGid for deterministic coverage order.
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i
    while j > 0 and result[j - 1].fromGid > cur.fromGid:
      result[j] = result[j - 1]
      dec j
    result[j] = cur

proc buildFallbackLigs*(nominal: proc(cp: uint32): Option[GlyphId],
    threePass: bool, withMarks: bool): seq[FallbackLig] =
  ## threePass selects LIGATURE_3_TABLE vs LIGATURE_TABLE; withMarks selects
  ## LIGATURE_MARK_TABLE (operates on codepoints, no IGNORE_MARKS).
  result = @[]
  if withMarks:
    for e in LigatureMarkTable:
      let c0 = nominal(uint32(e.a[0]))
      let c1 = nominal(uint32(e.a[1]))
      let l = nominal(uint32(e.lig))
      if c0.isNone or c1.isNone or l.isNone:
        continue
      let v0 = c0.get.value
      let v1 = c1.get.value
      let vl = l.get.value
      if v0 > 0xFFFFu32 or v1 > 0xFFFFu32 or vl > 0xFFFFu32:
        continue
      result.add((uint16(v0), @[uint16(v1)], uint16(vl)))
  elif threePass:
    for e in Ligature3Table:
      var gids: array[3, uint32]
      var ok = true
      for k in 0 ..< 3:
        let g = nominal(uint32(e.a[k]))
        if g.isNone or g.get.value > 0xFFFFu32:
          ok = false
          break
        gids[k] = g.get.value
      let l = nominal(uint32(e.lig))
      if not ok or l.isNone or l.get.value > 0xFFFFu32:
        continue
      result.add((uint16(gids[0]), @[uint16(gids[1]), uint16(gids[2])],
        uint16(l.get.value)))
  else:
    for e in LigatureTable:
      let c0 = nominal(uint32(e.a[0]))
      let c1 = nominal(uint32(e.a[1]))
      let l = nominal(uint32(e.lig))
      if c0.isNone or c1.isNone or l.isNone:
        continue
      let v0 = c0.get.value
      let v1 = c1.get.value
      let vl = l.get.value
      if v0 > 0xFFFFu32 or v1 > 0xFFFFu32 or vl > 0xFFFFu32:
        continue
      result.add((uint16(v0), @[uint16(v1)], uint16(vl)))
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i
    while j > 0 and result[j - 1].first > cur.first:
      result[j] = result[j - 1]
      dec j
    result[j] = cur

proc applyFallbackSingle*(buf: var Buffer, mappings: seq[FallbackSingle],
    mask: uint32) =
  if mappings.len == 0 or mask == 0u32:
    return
  var glyphs = newSeq[uint32](mappings.len)
  var subs = newSeq[uint32](mappings.len)
  for i, m in mappings:
    glyphs[i] = uint32(m.fromGid)
    subs[i] = uint32(m.toGid)
  let cov = Coverage(glyphs: glyphs, ranges: @[], present: true)
  let sub = SingleSubst(coverage: cov, wide: false, kind: ssArray,
    substitutes: subs)
  let lookup = Lookup(lookupType: GsubSingleSubst,
    lookupFlag: LookupIgnoreMarks, markFilteringSet: 0u16, isReverse: false,
    singleSubsts: @[sub], multipleSubsts: @[], alternateSubsts: @[],
    ligatureSubsts: @[], contextSubsts: @[], chainSubsts: @[],
    reverseSubsts: @[], order: @[(lkSingle, 0)])
  # Each synthetic lookup scans the whole buffer like a shaping pass.
  buf.idx = 0
  discard applyLookup(buf, GsubData(scripts: @[], features: @[],
    lookups: @[lookup]), lookup, mask)

proc applyFallbackLig*(buf: var Buffer, ligs: seq[FallbackLig], mask: uint32,
    ignoreMarks: bool) =
  if ligs.len == 0 or mask == 0u32:
    return
  var firsts: seq[uint32] = @[]
  for l in ligs:
    if firsts.len == 0 or firsts[^1] != uint32(l.first):
      firsts.add(uint32(l.first))
  let cov = Coverage(glyphs: firsts, ranges: @[], present: true)
  var sets = newSeq[seq[Ligature]](firsts.len)
  for i in 0 ..< sets.len:
    sets[i] = @[]
  for l in ligs:
    var idx = 0
    for i, f in firsts:
      if f == l.first:
        idx = i
        break
    sets[idx].add(Ligature(ligGlyph: uint32(l.lig), components: @[]))
    # Rebuild components from rest (stored separately to keep tuple flat).
    sets[idx][^1].components = l.rest.mapIt(uint32(it))
  let sub = LigatureSubst(coverage: cov, sets: sets)
  let flag = if ignoreMarks: LookupIgnoreMarks else: 0u16
  let lookup = Lookup(lookupType: GsubLigatureSubst, lookupFlag: flag,
    markFilteringSet: 0u16, isReverse: false, singleSubsts: @[],
    multipleSubsts: @[], alternateSubsts: @[], ligatureSubsts: @[sub],
    contextSubsts: @[], chainSubsts: @[], reverseSubsts: @[],
    order: @[(lkLigature, 0)])
  # Ligatures change the glyph count, so run through the output buffer
  # (mirroring applySubstLookups) and compact afterwards. Single
  # substitutions stay in place and need no output handling.
  buf.clearOutput()
  buf.idx = 0
  discard applyLookup(buf, GsubData(scripts: @[], features: @[],
    lookups: @[lookup]), lookup, mask)
  discard buf.sync()

proc isWin1256Font*(nominal: proc(cp: uint32): Option[GlyphId]): bool =
  ## Detects legacy Windows-1256 Arabic fonts by their signature
  ## codepoint-to-glyph mappings. All five must hold exactly.
  for (cp, gid) in Win1256Signature:
    let g = nominal(cp)
    if g.isNone or g.get.value != uint32(gid):
      return false
  true

proc win1256Singles*(featIdx: int): seq[FallbackSingle] =
  ## Direct gid-to-gid presentation forms. featIdx: 0 init, 1 medi,
  ## 2 fina. Sorted by fromGid for deterministic coverage order.
  result = @[]
  case featIdx
  of 0:
    for m in Win1256InitMappings:
      result.add((m.fromGid, m.toGid))
  of 1:
    for m in Win1256MediMappings:
      result.add((m.fromGid, m.toGid))
  of 2:
    for m in Win1256FinaMappings:
      result.add((m.fromGid, m.toGid))
  else:
    discard
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i
    while j > 0 and result[j - 1].fromGid > cur.fromGid:
      result[j] = result[j - 1]
      dec j
    result[j] = cur

proc win1256LamAlefLigs*(): seq[FallbackLig] =
  ## Win1256 lam alef ligature fallbacks.
  result = @[]
  for l in Win1256LamAlefLigatures:
    result.add((l.first, @[l.second], l.lig))

proc win1256ShaddaLigs*(): seq[FallbackLig] =
  ## Win1256 shadda ligature fallbacks.
  result = @[]
  for l in Win1256ShaddaLigatures:
    result.add((l.first, @[l.second], l.lig))

const ModifierCombiningMarks*: array[14, uint32] = [0x0654u32, 0x0655u32,
  0x0658u32, 0x06DCu32, 0x06E3u32, 0x06E7u32, 0x06E8u32, 0x08CAu32, 0x08CBu32,
  0x08CDu32, 0x08CEu32, 0x08CFu32, 0x08D3u32, 0x08F3u32]

proc reorderMarksArabic*(buf: var Buffer, start, stop: int) =
  ## Reorders Arabic modifier combining marks (ccc 220/230 with specific
  ## codepoints) before the base sequence, renumbering their ccc to 22/26
  ## so the normalizer keeps them sorted. Mirrors harfrust.
  var s = start
  for cc in [220u8, 230u8]:
    var i = s
    while i < stop and i < buf.info.len and
        buf.info[i].modifiedCombiningClass() < cc:
      inc i
    if i >= stop or i >= buf.info.len:
      continue
    if buf.info[i].modifiedCombiningClass() > cc:
      continue
    var j = i
    while j < stop and j < buf.info.len and
        buf.info[j].modifiedCombiningClass() == cc:
      var isMod = false
      for m in ModifierCombiningMarks:
        if buf.info[j].glyphId == m:
          isMod = true
          break
      if not isMod:
        break
      inc j
    if i == j:
      continue
    buf.mergeClusters(s, j)
    # Rotate [s..j) left by (i-s).
    let n = j - s
    let k = i - s
    if k > 0 and k < n:
      var tmp = newSeq[GlyphInfo](k)
      for t in 0 ..< k:
        tmp[t] = buf.info[s + t]
      for t in 0 ..< n - k:
        buf.info[s + t] = buf.info[s + k + t]
      for t in 0 ..< k:
        buf.info[s + n - k + t] = tmp[t]
    let newStart = s + j - i
    let newCc = if cc == 220u8: 22u8 else: 26u8
    for t in s ..< newStart:
      if t >= 0 and t < buf.info.len:
        buf.info[t].setModifiedCombiningClass(newCc)
    s = newStart

# --- stch stretching (justification) ---

proc stchAdd(a, b: int32): int32 =
  ## Saturating addition for stretch widths.
  let s = int64(a) + int64(b)
  if s > int64(high(int32)):
    high(int32)
  elif s < int64(low(int32)):
    low(int32)
  else:
    int32(s)

proc stchSub(a, b: int32): int32 =
  ## Saturating subtraction for stretch widths.
  stchAdd(a, -b)

proc clampStchI64(v: int64): int32 =
  ## Clamps a 64-bit stretch value into int32 range.
  if v > int64(high(int32)):
    high(int32)
  elif v < int64(low(int32)):
    low(int32)
  else:
    int32(v)

proc recordStch*(buf: var Buffer, hasStch: bool) =
  ## Marks glyphs multiplied by the stch feature for the justification
  ## pass. Call right after stch applied, mirroring harfrust
  ## record_stch.
  if not hasStch:
    return
  var found = false
  for i in 0 ..< min(buf.len, buf.info.len):
    if buf.info[i].multiplied():
      if buf.info[i].ligComp() mod 2u8 != 0u8:
        buf.info[i].setArabicAction(ArabicStretchRepeating)
      else:
        buf.info[i].setArabicAction(ArabicStretchFixed)
      found = true
  if found:
    buf.scratchFlags = buf.scratchFlags or ArabicHasStchFlag

proc copyStchGlyph(buf: var Buffer, src, dst: int): bool =
  ## Copies a glyph and its position; false on out of range indexes.
  if src < 0 or src >= buf.info.len or src >= buf.pos.len:
    return false
  if dst < 0 or dst >= buf.info.len or dst >= buf.pos.len:
    return false
  buf.info[dst] = buf.info[src]
  buf.pos[dst] = buf.pos[src]
  true

proc applyStchPasses(sf: ShaperFont, buf: var Buffer, rtl: bool): bool =
  ## Two pass stretch: measure the extra glyphs, enlarge, then expand
  ## from the end. False aborts the stretch; the caller fails the buffer
  ## but keeps the direction restored.
  var extra = 0
  for step in 0 ..< 2:
    let newLen = buf.len + extra
    var i = buf.len
    var j = newLen
    while i != 0:
      if i - 1 < 0 or i - 1 >= buf.info.len:
        return false
      if not isStchAction(buf.info[i - 1].arabicAction()):
        if step == 1:
          j -= 1
          if not copyStchGlyph(buf, i - 1, j):
            return false
        i -= 1
        continue
      var wTotal = 0i32
      var wFixed = 0i32
      var wRepeating = 0i32
      var nRepeating = 0i32
      let finish = i
      while i != 0:
        if i - 1 < 0 or i - 1 >= buf.info.len:
          return false
        if not isStchAction(buf.info[i - 1].arabicAction()):
          break
        i -= 1
        let info = buf.info[i]
        let width = sf.hAdvance(newGlyphId(info.glyphId))
        if info.arabicAction() == ArabicStretchFixed:
          wFixed = stchAdd(wFixed, width)
        else:
          wRepeating = stchAdd(wRepeating, width)
          nRepeating += 1i32
      let start = i
      var context = i
      while context != 0:
        if context - 1 < 0 or context - 1 >= buf.info.len:
          return false
        let info = buf.info[context - 1]
        if isStchAction(info.arabicAction()) or
            not (info.isInfoDefaultIgnorable() or
              isWordCategory(info.generalCategory())):
          break
        context -= 1
        if context < 0 or context >= buf.pos.len:
          return false
        wTotal = stchAdd(wTotal, buf.pos[context].xAdvance)
      i += 1
      var nCopies = 0i32
      var wRemaining = stchSub(wTotal, wFixed)
      if wRemaining > wRepeating and wRepeating > 0i32:
        nCopies = wRemaining div wRepeating - 1i32
      var extraOverlap = 0i32
      let shortfall = int64(wRemaining) -
        int64(wRepeating) * int64(nCopies + 1i32)
      if shortfall > 0 and nRepeating > 0i32:
        nCopies += 1i32
        let excess = int64(nCopies + 1i32) * int64(wRepeating) -
          int64(wRemaining)
        if excess > 0:
          extraOverlap = clampStchI64(excess div
            (int64(nCopies) * int64(nRepeating)))
          wRemaining = 0i32
      if step == 0:
        extra += int(int64(nCopies) * int64(nRepeating))
      else:
        buf.unsafeToBreakRange(some(context), some(finish))
        var xOffset = wRemaining div 2i32
        var k = finish
        while k > start:
          if k - 1 < 0 or k - 1 >= buf.info.len or
              k - 1 >= buf.pos.len:
            return false
          let info = buf.info[k - 1]
          let width = sf.hAdvance(newGlyphId(info.glyphId))
          var repeat = 1i32
          if info.arabicAction() == ArabicStretchRepeating:
            repeat += nCopies
          var pos = buf.pos[k - 1]
          pos.xAdvance = 0i32
          var n = 0i32
          while n < repeat:
            if rtl:
              xOffset = stchSub(xOffset, width)
              if n > 0i32:
                xOffset = stchAdd(xOffset, extraOverlap)
            pos.xOffset = xOffset
            j -= 1
            if j < 0 or j >= buf.info.len or j >= buf.pos.len:
              return false
            buf.info[j] = info
            buf.pos[j] = pos
            if not rtl:
              xOffset = stchAdd(xOffset, width)
              if n > 0i32:
                xOffset = stchSub(xOffset, extraOverlap)
            n += 1i32
          buf.pos[k - 1] = pos
          k -= 1
      i -= 1
    if step == 0:
      if not buf.ensure(buf.len + extra):
        break
    else:
      buf.len = newLen
  true

proc applyStch*(sf: ShaperFont, buf: var Buffer) =
  ## Expands recorded stch runs into repeated tiles, mirroring harfrust
  ## postprocess_glyphs_arabic. No-op when stch multiplied nothing.
  if (buf.scratchFlags and ArabicHasStchFlag) == 0u32:
    return
  let rtl = buf.direction == dirRightToLeft
  if not rtl:
    buf.reverse()
  if not applyStchPasses(sf, buf, rtl):
    buf.indexFailed()
  if not rtl:
    buf.reverse()
