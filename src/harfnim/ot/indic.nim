## Indic shaper: consonant-syllable reordering and staged features.
##
## Ports harfrust `ot/shaper/indic.rs`: vowel-constraint preprocessing
## and matra decompose/compose hooks feed normalization; syllables are
## found during GSUB, initial reordering moves pre-base matras/reph,
## the 17 shaping features apply in HarfBuzz stages constrained to
## syllables, and final reordering settles matras, reph, and pref.

import std/options

import ../buffer
import ../feature
import ../font
import ../script
import ../tag
import ../unicode
import ./apply
import ./gsub
import ./indic_machine
import ./map
import ./maskbits
import ./shaper
import ./syllabic
import ./vowel_constraints

export indic_table
export indic_machine
export syllabic
export vowel_constraints

const
  IndicNukt* = 0
  IndicAkhn* = 1
  IndicRphf* = 2
  IndicRkrf* = 3
  IndicPref* = 4
  IndicBlwf* = 5
  IndicAbvf* = 6
  IndicHalf* = 7
  IndicPstf* = 8
  IndicVatu* = 9
  IndicCjct* = 10
  IndicInit* = 11
  IndicPres* = 12
  IndicAbvs* = 13
  IndicBlws* = 14
  IndicPsts* = 15
  IndicHaln* = 16

  IndicFeatureTags*: array[17, string] = ["nukt", "akhn", "rphf", "rkrf",
    "pref", "blwf", "abvf", "half", "pstf", "vatu", "cjct", "init",
    "pres", "abvs", "blws", "psts", "haln"]
  # Features without F_GLOBAL: their masks are tagged per glyph during
  # initial reordering; the rest apply buffer-wide.
  IndicGlobalFeature*: array[17, bool] = [true, true, false, true, false,
    false, false, false, false, true, true, false, true, true, true, true,
    true]

type
  RephPosition* = enum
    RephAfterMain
    RephBeforeSub
    RephAfterSub
    RephBeforePost
    RephAfterPost

  RephMode* = enum
    RephImplicit
    RephExplicit
    RephLogRepha

  BlwfMode* = enum
    BlwfPreAndPost
    BlwfPostOnly

  IndicConfig* = object
    script*: Option[Script]
    hasOldSpec*: bool
    virama*: uint32
    rephPos*: RephPosition
    rephMode*: RephMode
    blwfMode*: BlwfMode

const
  IndicConfigs*: array[11, IndicConfig] = [
    IndicConfig(script: none(Script), hasOldSpec: false, virama: 0u32,
      rephPos: RephBeforePost, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Devanagari), hasOldSpec: true, virama: 0x094Du32,
      rephPos: RephBeforePost, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Bengali), hasOldSpec: true, virama: 0x09CDu32,
      rephPos: RephAfterSub, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Gurmukhi), hasOldSpec: true, virama: 0x0A4Du32,
      rephPos: RephBeforeSub, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Gujarati), hasOldSpec: true, virama: 0x0ACDu32,
      rephPos: RephBeforePost, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Oriya), hasOldSpec: true, virama: 0x0B4Du32,
      rephPos: RephAfterMain, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Tamil), hasOldSpec: true, virama: 0x0BCDu32,
      rephPos: RephAfterPost, rephMode: RephImplicit,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Telugu), hasOldSpec: true, virama: 0x0C4Du32,
      rephPos: RephAfterPost, rephMode: RephExplicit,
      blwfMode: BlwfPostOnly),
    IndicConfig(script: some(Kannada), hasOldSpec: true, virama: 0x0CCDu32,
      rephPos: RephAfterPost, rephMode: RephImplicit,
      blwfMode: BlwfPostOnly),
    IndicConfig(script: some(Malayalam), hasOldSpec: true, virama: 0x0D4Du32,
      rephPos: RephAfterMain, rephMode: RephLogRepha,
      blwfMode: BlwfPreAndPost),
    IndicConfig(script: some(Sinhala), hasOldSpec: false, virama: 0x0DCAu32,
      rephPos: RephAfterPost, rephMode: RephExplicit,
      blwfMode: BlwfPreAndPost),
  ]

proc indicConfigFor*(script: Option[Script]): IndicConfig =
  if script.isSome:
    for c in IndicConfigs:
      if c.script.isSome and c.script.get == script.get:
        return c
  IndicConfigs[0]

proc catFlag*(c: uint8): uint32 =
  if c < 32u8: 1u32 shl c else: 0u32

proc isOneOf*(g: GlyphInfo, flags: uint32): bool =
  ## Category-flag test that ignores ligated glyphs (whose stored
  ## category is stale).
  if g.ligated():
    return false
  (catFlag(g.indicCategory()) and flags) != 0u32

proc isJoiner*(g: GlyphInfo): bool =
  g.isOneOf(catFlag(OtZwj) or catFlag(OtZwnj))

proc isConsonant*(g: GlyphInfo): bool =
  g.isOneOf(catFlag(OtC) or catFlag(OtCs) or catFlag(OtRa) or
    catFlag(OtCm) or catFlag(OtV) or catFlag(OtPlaceholder) or
    catFlag(OtDottedCircle))

proc isHalant*(g: GlyphInfo): bool =
  g.isOneOf(catFlag(OtH))

proc ligatedAndDidntMultiply*(g: GlyphInfo): bool =
  g.ligated() and not g.multiplied()

type
  IndicShapePlan* = object
    config*: IndicConfig
    isOldSpec*: bool
    zeroContext*: bool
    lookups*: array[17, seq[uint16]]
    wouldBlwf*: seq[uint16]
    wouldVatu*: seq[uint16]
    wouldPstf*: seq[uint16]
    wouldPref*: seq[uint16]
    wouldRphf*: seq[uint16]
    maskArray*: array[17, uint32]
    nextBit*: uint32

proc lookupsForTag(gsub: GsubData, scriptTag, langTag: Tag,
    tagStr: string): seq[uint16] =
  result = @[]
  let t = tagFromStr(tagStr).toU32()
  for (tag, lks) in gsubFeaturesFor(gsub, scriptTag, langTag):
    if tag == t:
      result.add(lks)

proc newIndicShapePlan*(gsub: GsubData, scriptTag, langTag: Tag,
    script: Option[Script]): IndicShapePlan =
  ## Builds per-shape state: config, old-spec detection from the
  ## chosen GSUB script, would-substitute lookup lists, and mask bits
  ## for the per-position features.
  result.config = indicConfigFor(script)
  let chosen = gsubScriptTagFor(gsub, scriptTag)
  result.isOldSpec = result.config.hasOldSpec and
    (chosen.isNone or (chosen.get.toU32() and 0xFFu32) != 0x32u32)
  result.zeroContext = result.isOldSpec and
    (script.isNone or script.get != Malayalam)
  for i in 0 ..< 17:
    result.lookups[i] = lookupsForTag(gsub, scriptTag, langTag,
      IndicFeatureTags[i])
  result.wouldBlwf = lookupsForTag(gsub, scriptTag, langTag, "blwf")
  result.wouldVatu = lookupsForTag(gsub, scriptTag, langTag, "vatu")
  result.wouldPstf = lookupsForTag(gsub, scriptTag, langTag, "pstf")
  result.wouldPref = lookupsForTag(gsub, scriptTag, langTag, "pref")
  result.wouldRphf = lookupsForTag(gsub, scriptTag, langTag, "rphf")
  var nextBit = 8u32
  for i in 0 ..< 17:
    if IndicGlobalFeature[i]:
      result.maskArray[i] = 0u32
    else:
      let (m, _) = allocMaskBit(nextBit, 1u32)
      result.maskArray[i] = m
  result.nextBit = nextBit

proc classIs(cd: ClassDef, gid: uint32, cls: uint32): bool =
  cd.classOf(gid) == cls

proc lookupWouldSubstitute(gsub: GsubData, lookup: Lookup,
    glyphs: openArray[uint32], zeroContext: bool): bool =
  ## Whether any subtable of `lookup` would rewrite exactly `glyphs`.
  ## Mirrors harfrust `WouldApplyContext`-driven `would_apply`: with
  ## `zeroContext`, context rules need empty backtrack/lookahead,
  ## otherwise those are assumed matchable. Takes openArray to avoid
  ## per-glyph seq allocations in consonant-position probing.
  if glyphs.len == 0:
    return false
  for e in lookup.order:
    case e.kind
    of lkSingle:
      if glyphs.len == 1 and e.index < lookup.singleSubsts.len and
          lookup.singleSubsts[e.index].coverage.covers(glyphs[0]):
        return true
    of lkMultiple:
      if glyphs.len == 1 and e.index < lookup.multipleSubsts.len and
          lookup.multipleSubsts[e.index].coverage.covers(glyphs[0]):
        return true
    of lkAlternate:
      if glyphs.len == 1 and e.index < lookup.alternateSubsts.len and
          lookup.alternateSubsts[e.index].coverage.covers(glyphs[0]):
        return true
    of lkLigature:
      if e.index >= lookup.ligatureSubsts.len:
        continue
      let sub = lookup.ligatureSubsts[e.index]
      let ci = sub.coverage.coverageIndexRaw(glyphs[0])
      if ci < 0 or ci >= sub.sets.len:
        continue
      for lig in sub.sets[ci]:
        if lig.components.len == glyphs.len - 1:
          var ok = true
          for k in 0 ..< lig.components.len:
            if lig.components[k] != glyphs[k + 1]:
              ok = false
              break
          if ok:
            return true
    of lkContext:
      if e.index >= lookup.contextSubsts.len:
        continue
      let sub = lookup.contextSubsts[e.index]
      if sub.format == 1u16 or sub.format == 4u16:
        let ci = sub.coverage.coverageIndexRaw(glyphs[0])
        if ci < 0 or ci >= sub.ruleSets.len:
          continue
        for rule in sub.ruleSets[ci]:
          if rule.input.len == glyphs.len - 1:
            var ok = true
            for k in 0 ..< rule.input.len:
              if rule.input[k] != glyphs[k + 1]:
                ok = false
                break
            if ok:
              return true
      elif sub.format == 2u16 or sub.format == 5u16:
        if not sub.coverage.covers(glyphs[0]):
          continue
        let cls = int(sub.classDef.classOf(glyphs[0]))
        if cls >= sub.ruleSets.len:
          continue
        for rule in sub.ruleSets[cls]:
          if rule.input.len == glyphs.len - 1:
            var ok = true
            for k in 0 ..< rule.input.len:
              if not classIs(sub.classDef, glyphs[k + 1], rule.input[k]):
                ok = false
                break
            if ok:
              return true
      elif sub.format == 3u16 or sub.format == 6u16:
        if sub.coverages.len == glyphs.len:
          var ok = true
          for k in 0 ..< glyphs.len:
            if not sub.coverages[k].covers(glyphs[k]):
              ok = false
              break
          if ok:
            return true
    of lkChain:
      if e.index >= lookup.chainSubsts.len:
        continue
      let sub = lookup.chainSubsts[e.index]
      if sub.format == 1u16 or sub.format == 4u16:
        let ci = sub.coverage.coverageIndexRaw(glyphs[0])
        if ci < 0 or ci >= sub.ruleSets.len:
          continue
        for rule in sub.ruleSets[ci]:
          if rule.input.len == glyphs.len - 1:
            var ok = true
            for k in 0 ..< rule.input.len:
              if rule.input[k] != glyphs[k + 1]:
                ok = false
                break
            if ok and (not zeroContext or
                (rule.backtrack.len == 0 and rule.lookahead.len == 0)):
              return true
      elif sub.format == 2u16 or sub.format == 5u16:
        if not sub.coverage.covers(glyphs[0]):
          continue
        let cls = int(sub.inputClassDef.classOf(glyphs[0]))
        if cls >= sub.ruleSets.len:
          continue
        for rule in sub.ruleSets[cls]:
          if rule.input.len == glyphs.len - 1:
            var ok = true
            for k in 0 ..< rule.input.len:
              if not classIs(sub.inputClassDef, glyphs[k + 1],
                  rule.input[k]):
                ok = false
                break
            if ok and (not zeroContext or
                (rule.backtrack.len == 0 and rule.lookahead.len == 0)):
              return true
      elif sub.format == 3u16:
        if sub.inputCoverages.len == glyphs.len:
          var ok = true
          for k in 0 ..< glyphs.len:
            if not sub.inputCoverages[k].covers(glyphs[k]):
              ok = false
              break
          if ok and (not zeroContext or
              (sub.backtrackCoverages.len == 0 and
                sub.lookaheadCoverages.len == 0)):
            return true
    of lkReverse:
      if e.index >= lookup.reverseSubsts.len:
        continue
      let sub = lookup.reverseSubsts[e.index]
      if glyphs.len == 1 and sub.coverage.covers(glyphs[0]) and
          (not zeroContext or
          (sub.backtrackCoverages.len == 0 and
            sub.lookaheadCoverages.len == 0)):
        return true
    of lkOther:
      discard
  false

proc featureWouldSubstitute(gsub: GsubData, lookups: openArray[uint16],
    glyphs: openArray[uint32], zeroContext: bool): bool =
  for li in lookups:
    if int(li) < gsub.lookups.len and lookupWouldSubstitute(gsub,
        gsub.lookups[int(li)], glyphs, zeroContext):
      return true
  false

proc indicDecompose*(ab: uint32): Option[tuple[a, b: uint32]] =
  ## Matra-split protection: these letters must not decompose.
  case ab
  of 0x0931u32, 0x09DCu32, 0x09DDu32, 0x0B94u32:
    none(tuple[a, b: uint32])
  else:
    decomposeImpl(ab)

proc indicCompose*(a, b: uint32): Option[uint32] =
  ## Avoids recomposing split matras; keeps the YDDV composition
  ## exception that normalization would otherwise exclude.
  if generalCategoryFor(a).isMark():
    return none(uint32)
  if a == 0x09AFu32 and b == 0x09BCu32:
    return some(0x09DFu32)
  composeImpl(a, b)

proc setupIndicProperties*(buf: var Buffer) =
  ## Attaches syllabic category + position to every glyph. Runs after
  ## normalization (on codepoints), before glyph mapping.
  for i in 0 ..< min(buf.len, buf.info.len):
    let (cat, pos) = getCategories(buf.info[i].glyphId)
    buf.info[i].setIndicCategory(cat)
    buf.info[i].setIndicPosition(pos)

proc setupSyllablesIndic*(buf: var Buffer) =
  ## GSUB-pause callback: finds syllables, then marks every syllable
  ## unsafe to break across.
  findSyllablesIndic(buf)
  var start = 0
  var stop = buf.nextSyllable(0)
  while start < buf.len and buf.successful:
    buf.unsafeToBreakRange(some(start), some(stop))
    start = stop
    stop = buf.nextSyllable(start)

proc consonantPositionFromOt(gsub: GsubData, plan: IndicShapePlan,
    consonant, virama: uint32): uint8 =
  ## Decides below-base vs post-base placement by probing the font's
  ## blwf/vatu/pstf/pref lookups with both virama orders, mirroring
  ## HarfBuzz (which also tolerates old-spec tables copied to new-spec
  ## fonts). Vatu is checked as well (harfbuzz#1587).
  ## Stack arrays avoid per-glyph seq allocations in this hot probe.
  let vc = [virama, consonant]
  let cv = [consonant, virama]
  if featureWouldSubstitute(gsub, plan.wouldBlwf, vc,
      plan.zeroContext) or
      featureWouldSubstitute(gsub, plan.wouldBlwf, cv,
      plan.zeroContext) or
      featureWouldSubstitute(gsub, plan.wouldVatu, vc,
      plan.zeroContext) or
      featureWouldSubstitute(gsub, plan.wouldVatu, cv,
      plan.zeroContext):
    return PosBelowC
  if featureWouldSubstitute(gsub, plan.wouldPstf, vc,
      plan.zeroContext) or
      featureWouldSubstitute(gsub, plan.wouldPstf, cv,
      plan.zeroContext):
    return PosPostC
  if featureWouldSubstitute(gsub, plan.wouldPref, vc,
      plan.zeroContext) or
      featureWouldSubstitute(gsub, plan.wouldPref, cv,
      plan.zeroContext):
    return PosPostC
  PosBaseC

proc updateConsonantPositions(buf: var Buffer, sf: ShaperFont,
    gsub: GsubData, plan: IndicShapePlan) =
  if plan.config.virama == 0u32:
    return
  let viramaGlyph = sf.nominalGlyph(plan.config.virama)
  if viramaGlyph.isNone:
    return
  let virama = viramaGlyph.get.value
  for i in 0 ..< min(buf.len, buf.info.len):
    if buf.info[i].indicPosition() == PosBaseC:
      let consonant = buf.info[i].glyphId
      buf.info[i].setIndicPosition(consonantPositionFromOt(gsub, plan,
        consonant, virama))

proc stableSortByPosition(buf: var Buffer, start, stop: int) =
  ## Stable insertion sort of glyphs [start..stop) by indic position.
  var i = start + 1
  while i < min(stop, buf.info.len):
    let item = buf.info[i]
    var j = i
    while j > start and buf.info[j - 1].indicPosition() >
        item.indicPosition():
      buf.info[j] = buf.info[j - 1]
      dec j
    buf.info[j] = item
    inc i

proc rotateInfoLeftByOne(buf: var Buffer, first, last: int): bool =
  ## Rotates infos [first..last] left by one (both inclusive).
  if last <= first or first < 0 or last >= buf.info.len:
    buf.indexFailed()
    return false
  let tmp = buf.info[first]
  for k in first ..< last:
    buf.info[k] = buf.info[k + 1]
  buf.info[last] = tmp
  true

proc infoInRange(buf: Buffer, i: int): bool =
  i >= 0 and i < buf.len and i < buf.info.len

proc initialReorderingConsonantSyllable(buf: var Buffer, sf: ShaperFont,
    gsub: GsubData, plan: IndicShapePlan, start, stop: int): bool =
  if not infoInRange(buf, start) or stop > buf.len or
      stop > buf.info.len or start >= stop:
    buf.indexFailed()
    return false
  # Kannada Ra+H+ZWJ behaves like Ra+ZWJ+H.
  if buf.script.isSome and buf.script.get == Kannada and
      start + 3 <= stop and
      buf.info[start].indicCategory() == OtRa and
      buf.info[start + 1].indicCategory() == OtH and
      buf.info[start + 2].indicCategory() == OtZwj:
    buf.mergeClusters(start + 1, start + 3)
    swap(buf.info[start + 1], buf.info[start + 2])
  # 1. Find base consonant.
  var base = stop
  var hasReph = false
  var limit = start
  if plan.maskArray[IndicRphf] != 0u32 and start + 3 <= stop and
      ((plan.config.rephMode == RephImplicit and
        not buf.info[start + 2].isJoiner()) or
      (plan.config.rephMode == RephExplicit and
        buf.info[start + 2].indicCategory() == OtZwj)):
    let g0 = buf.info[start].glyphId
    let g1 = buf.info[start + 1].glyphId
    let g2 = buf.info[start + 2].glyphId
    # Stack buffers: implicit checks 2 glyphs, explicit checks 3.
    let glyphs2 = [g0, g1]
    let glyphs3 = [g0, g1, g2]
    let isRphf =
      if plan.config.rephMode == RephExplicit:
        featureWouldSubstitute(gsub, plan.wouldRphf, glyphs3,
          plan.zeroContext)
      else:
        featureWouldSubstitute(gsub, plan.wouldRphf, glyphs2,
          plan.zeroContext)
    if isRphf:
      limit += 2
      while limit < stop and buf.info[limit].isJoiner():
        inc limit
      base = start
      hasReph = true
  elif plan.config.rephMode == RephLogRepha and
      buf.info[start].indicCategory() == OtRepha:
    limit += 1
    while limit < stop and buf.info[limit].isJoiner():
      inc limit
    base = start
    hasReph = true
  var seenBelow = false
  var i = stop
  while true:
    dec i
    if not infoInRange(buf, i):
      buf.indexFailed()
      return false
    if buf.info[i].isConsonant():
      let pos = buf.info[i].indicPosition()
      if pos != PosBelowC and (pos != PosPostC or seenBelow):
        base = i
        break
      if pos == PosBelowC:
        seenBelow = true
      base = i
    else:
      if start < i and buf.info[i].indicCategory() == OtZwj and
          buf.info[i - 1].indicCategory() == OtH:
        break
    if i <= limit:
      break
  if hasReph and base == start and limit - base <= 2:
    hasReph = false
  # 2-3. Matra decomposition and nukta/halant reorder already handled
  # by normalization; nothing to do here.
  for k in start ..< base:
    if buf.info[k].indicPosition() > PosPreC:
      buf.info[k].setIndicPosition(PosPreC)
  if base < stop:
    buf.info[base].setIndicPosition(PosBaseC)
  if hasReph:
    buf.info[start].setIndicPosition(PosRaToBecomeReph)
  # Old-spec: move the first post-base Halant after last consonant.
  if plan.isOldSpec:
    let noDouble = buf.script.isSome and buf.script.get == Kannada
    if base + 1 < stop and
        buf.info[base + 1].indicCategory() == OtH:
      var j = stop - 1
      while j > base + 1:
        if not infoInRange(buf, j):
          buf.indexFailed()
          return false
        if buf.info[j].isConsonant() or (noDouble and
            buf.info[j].indicCategory() == OtH):
          break
        dec j
      if buf.info[j].indicCategory() != OtH and j > base + 1:
        if not buf.rotateInfoLeftByOne(base + 1, j):
          return false
  # Attach misc marks to the previous char to move with them.
  var lastPos = PosStart
  for k in start ..< stop:
    let cat = buf.info[k].indicCategory()
    if (catFlag(cat) and (catFlag(OtZwj) or catFlag(OtZwnj) or
        catFlag(OtN) or catFlag(OtRs) or catFlag(OtCm) or
        catFlag(OtH))) != 0u32:
      var pos = lastPos
      if cat == OtH and pos == PosPreM:
        for m in countdown(k - 1, start + 1):
          if buf.info[m - 1].indicPosition() != PosPreM:
            pos = buf.info[m - 1].indicPosition()
            break
      buf.info[k].setIndicPosition(pos)
    elif buf.info[k].indicPosition() != PosSmvd:
      if cat == OtMpst and k > start and
          buf.info[k - 1].indicCategory() == OtSm:
        buf.info[k - 1].setIndicPosition(buf.info[k].indicPosition())
      lastPos = buf.info[k].indicPosition()
  # Post-base consonants own everything after the last consonant/matra.
  var last = base
  for k in base + 1 ..< stop:
    if buf.info[k].isConsonant():
      for m in last + 1 ..< k:
        if buf.info[m].indicPosition() < PosSmvd:
          buf.info[m].setIndicPosition(buf.info[k].indicPosition())
      last = k
    elif (catFlag(buf.info[k].indicCategory()) and
        (catFlag(OtM) or catFlag(OtMpst))) != 0u32:
      last = k
  # Use syllable() for sort accounting temporarily.
  let savedSyllable = buf.info[start].syllable()
  var k2 = start
  while k2 < stop:
    buf.info[k2].setSyllable(uint8(k2 - start))
    inc k2
  buf.stableSortByPosition(start, stop)
  # Find base again; also flip left-matra sequences.
  var firstLeft = stop
  var lastLeft = stop
  base = stop
  var k3 = start
  while k3 < stop:
    let pos = buf.info[k3].indicPosition()
    if pos == PosBaseC:
      base = k3
      break
    elif pos == PosPreM:
      if firstLeft == stop:
        firstLeft = k3
      lastLeft = k3
    inc k3
  if firstLeft < lastLeft:
    buf.reverseRange(firstLeft, lastLeft + 1)
    var m = firstLeft
    for j in firstLeft .. lastLeft:
      if (catFlag(buf.info[j].indicCategory()) and
          (catFlag(OtM) or catFlag(OtMpst))) != 0u32:
        buf.reverseRange(m, j + 1)
        m = j + 1
  if plan.isOldSpec or stop - start > 127:
    buf.mergeClusters(base, stop)
  else:
    var k4 = base
    while k4 < stop:
      let order = buf.info[k4].syllable()
      if order != 255u8:
        var mn = k4
        var mx = k4
        var j = start + int(order)
        while j != k4:
          if not infoInRange(buf, j):
            buf.indexFailed()
            return false
          mn = min(mn, j)
          mx = max(mx, j)
          let nxt = start + int(buf.info[j].syllable())
          buf.info[j].setSyllable(255u8)
          j = nxt
        buf.mergeClusters(max(base, mn), mx + 1)
      inc k4
  for k5 in start ..< stop:
    buf.info[k5].setSyllable(savedSyllable)
  # Setup masks.
  for k6 in start ..< stop:
    if buf.info[k6].indicPosition() != PosRaToBecomeReph:
      break
    buf.info[k6].mask = buf.info[k6].mask or plan.maskArray[IndicRphf]
  var preMask = plan.maskArray[IndicHalf]
  if not plan.isOldSpec and plan.config.blwfMode == BlwfPreAndPost:
    preMask = preMask or plan.maskArray[IndicBlwf]
  for k7 in start ..< base:
    buf.info[k7].mask = buf.info[k7].mask or preMask
  if base < stop:
    discard
  var postMask = plan.maskArray[IndicBlwf] or
    plan.maskArray[IndicAbvf] or plan.maskArray[IndicPstf]
  for k8 in base + 1 ..< stop:
    buf.info[k8].mask = buf.info[k8].mask or postMask
  if plan.isOldSpec and buf.script.isSome and
      buf.script.get == Devanagari:
    for k9 in start ..< max(base - 1, start):
      if buf.info[k9].indicCategory() == OtRa and
          buf.info[k9 + 1].indicCategory() == OtH and
          (k9 + 2 == base or (k9 + 2 < buf.info.len and
            buf.info[k9 + 2].indicCategory() != OtZwj)):
        for m2 in k9 .. k9 + 1:
          buf.info[m2].mask = buf.info[m2].mask or
            plan.maskArray[IndicBlwf]
  if plan.maskArray[IndicPref] != 0u32 and base + 2 < stop:
    for k10 in base + 1 ..< stop - 1:
      if k10 + 1 >= buf.info.len:
        buf.indexFailed()
        return false
      let pair = [buf.info[k10].glyphId, buf.info[k10 + 1].glyphId]
      if featureWouldSubstitute(gsub, plan.wouldPref, pair,
          plan.zeroContext):
        buf.info[k10].mask = buf.info[k10].mask or
          plan.maskArray[IndicPref]
        buf.info[k10 + 1].mask = buf.info[k10 + 1].mask or
          plan.maskArray[IndicPref]
        break
  for k11 in start + 1 ..< stop:
    if buf.info[k11].isJoiner():
      let nonJoiner = buf.info[k11].indicCategory() == OtZwnj
      var j = k11
      while true:
        dec j
        if j < 0 or j >= buf.info.len:
          buf.indexFailed()
          return false
        if nonJoiner:
          buf.info[j].mask = buf.info[j].mask and
            not plan.maskArray[IndicHalf]
        if j <= start or buf.info[j].isConsonant():
          break
  true

proc initialReorderingSyllable(buf: var Buffer, sf: ShaperFont,
    gsub: GsubData, plan: IndicShapePlan, start, stop: int): bool =
  if not infoInRange(buf, start) or stop > buf.len or
      stop > buf.info.len or start >= stop:
    buf.indexFailed()
    return false
  case buf.info[start].syllable() and 0x0Fu8
  of 0u8, 1u8:
    # Vowels look like consonants; run the consonant logic for both.
    buf.initialReorderingConsonantSyllable(sf, gsub, plan, start, stop)
  of 2u8, 4u8:
    # Dotted circles were already inserted; chain the consonant logic.
    buf.initialReorderingConsonantSyllable(sf, gsub, plan, start, stop)
  else:
    true

proc initialReorderingIndic*(buf: var Buffer, sf: ShaperFont,
    gsub: GsubData, plan: IndicShapePlan): bool =
  ## GSUB-pause callback: consonant-position refinement, dotted-circle
  ## insertion for broken syllables, then per-syllable initial
  ## reordering.
  updateConsonantPositions(buf, sf, gsub, plan)
  if buf.insertDottedCircles(sf, uint8(ord(BrokenCluster)),
      OtDottedCircle, some(OtRepha), some(PosEnd)):
    discard
  if not buf.successful:
    return false
  var start = 0
  var stop = buf.nextSyllable(0)
  while start < buf.len and buf.successful:
    if not buf.initialReorderingSyllable(sf, gsub, plan, start, stop):
      return false
    start = stop
    stop = buf.nextSyllable(start)
  buf.successful

proc finalReorderingSyllable(buf: var Buffer, sf: ShaperFont,
    plan: IndicShapePlan, start, stop: int): bool =
  if not infoInRange(buf, start) or stop > buf.len or
      stop > buf.info.len or start >= stop:
    buf.indexFailed()
    return false
  # Recover halant category lost to ligation+multiplication when the
  # glyph is the script virama.
  if plan.config.virama != 0u32:
    let vg = sf.nominalGlyph(plan.config.virama)
    if vg.isSome:
      let viramaGlyph = vg.get.value
      for i in start ..< stop:
        if buf.info[i].glyphId == viramaGlyph and
            buf.info[i].ligated() and buf.info[i].multiplied():
          buf.info[i].setIndicCategory(OtH)
          buf.info[i].clearLigatedAndMultiplied()
  var tryPref = plan.maskArray[IndicPref] != 0u32
  var base = start
  while base < stop:
    if buf.info[base].indicPosition() >= PosBaseC:
      if tryPref and base + 1 < stop:
        var i = base + 1
        while i < stop:
          if (buf.info[i].mask and plan.maskArray[IndicPref]) != 0u32:
            if not (buf.info[i].substituted() and
                buf.info[i].ligatedAndDidntMultiply()):
              base = i
              while base < stop and buf.info[base].isHalant():
                inc base
              if base < stop:
                buf.info[base].setIndicPosition(PosBaseC)
              tryPref = false
            break
          inc i
      if buf.script.isSome and buf.script.get == Malayalam:
        var i = base + 1
        while i < stop:
          while i < stop and buf.info[i].isJoiner():
            inc i
          if i == stop or not buf.info[i].isHalant():
            break
          inc i
          while i < stop and buf.info[i].isJoiner():
            inc i
          if i < stop:
            if buf.info[i].isConsonant() and
                buf.info[i].indicPosition() == PosBelowC:
              base = i
              buf.info[i].setIndicPosition(PosBaseC)
          inc i
      if start < base and buf.info[base].indicPosition() > PosBaseC:
        dec base
      break
    inc base
  if base == stop and start < base and
      buf.info[base - 1].isOneOf(catFlag(OtZwj)):
    dec base
  if base < stop:
    while start < base and buf.info[base].isOneOf(
        catFlag(OtN) or catFlag(OtH)):
      dec base
  # Reorder pre-base matras: "after last standalone halant, after
  # initial matra position and before the main consonant".
  if start + 1 < stop and start < base:
    # Malayalam / Tamil have no half forms: position matras after them.
    let noHalfForms = buf.script.isSome and
      (buf.script.get == Malayalam or buf.script.get == Tamil)
    var newPos = if base == stop: base - 2 else: base - 1
    if not noHalfForms:
      # script is always set for Indic runs; guard anyway.
      while true:
        while newPos > start and not buf.info[newPos].isOneOf(
            catFlag(OtM) or catFlag(OtMpst) or catFlag(OtH)):
          dec newPos
        let info = buf.info[newPos]
        if info.isHalant() and info.indicPosition() != PosPreM:
          if newPos + 1 < stop:
            if buf.info[newPos + 1].indicCategory() == OtZwj:
              if newPos > start:
                dec newPos
                continue
        else:
          newPos = start
        break
    if start < newPos and
        buf.info[newPos].indicPosition() != PosPreM:
      var i = newPos
      while i > start:
        if buf.info[i - 1].indicPosition() == PosPreM:
          let oldPos = i - 1
          if oldPos < base and base <= newPos:
            dec base
          if not buf.rotateInfoLeftByOne(oldPos, newPos):
            return false
          buf.mergeClusters(newPos, min(stop, base + 1))
          dec newPos
        dec i
    else:
      for i in start ..< base:
        if buf.info[i].indicPosition() == PosPreM:
          buf.mergeClusters(i, min(stop, base + 1))
          break
  # Reorder reph.
  if start + 1 < stop and
      buf.info[start].indicPosition() == PosRaToBecomeReph and
      (buf.info[start].indicCategory() == OtRepha) !=
      buf.info[start].ligatedAndDidntMultiply():
    var newRephPos = start
    block reph:
      let rephPos = plan.config.rephPos
      if rephPos != RephAfterPost:
        newRephPos = start + 1
        while newRephPos < base and
            not buf.info[newRephPos].isHalant():
          inc newRephPos
        if newRephPos < base and buf.info[newRephPos].isHalant():
          if newRephPos + 1 < base and
              buf.info[newRephPos + 1].isJoiner():
            inc newRephPos
          break reph
        if rephPos == RephAfterMain:
          newRephPos = base
          while newRephPos + 1 < stop and
              buf.info[newRephPos + 1].indicPosition() <= PosAfterMain:
            inc newRephPos
          if newRephPos < stop:
            break reph
        if rephPos == RephAfterSub:
          newRephPos = base
          while newRephPos + 1 < stop and
              (catFlag(buf.info[newRephPos + 1].indicPosition()) and
              (catFlag(PosPostC) or catFlag(PosAfterPost) or
                catFlag(PosSmvd))) == 0u32:
            inc newRephPos
          if newRephPos < stop:
            break reph
      newRephPos = start + 1
      while newRephPos < base and
          not buf.info[newRephPos].isHalant():
        inc newRephPos
      if newRephPos < base and buf.info[newRephPos].isHalant():
        if newRephPos + 1 < base and
            buf.info[newRephPos + 1].isJoiner():
          inc newRephPos
        break reph
      newRephPos = stop - 1
      while newRephPos > start and
          buf.info[newRephPos].indicPosition() == PosSmvd:
        dec newRephPos
      if buf.info[newRephPos].isHalant():
        for k in base + 1 ..< newRephPos:
          if (catFlag(buf.info[k].indicCategory()) and
              (catFlag(OtM) or catFlag(OtMpst))) != 0u32:
            dec newRephPos
    buf.mergeClusters(start, newRephPos + 1)
    if not buf.rotateInfoLeftByOne(start, newRephPos):
      return false
    if start < base and base <= newRephPos:
      dec base
  # Reorder pre-base-reordering consonants.
  if tryPref and base + 1 < stop:
    let noHalfFormsPref = buf.script.isSome and
      (buf.script.get == Malayalam or buf.script.get == Tamil)
    var i = base + 1
    while i < stop:
      if (buf.info[i].mask and plan.maskArray[IndicPref]) != 0u32:
        if buf.info[i].ligatedAndDidntMultiply():
          var newPos = base
          # Malayalam / Tamil do not have half forms or explicit virama
          # forms; position the matra after them.
          if not noHalfFormsPref:
            while newPos > start and not buf.info[newPos - 1].isOneOf(
                catFlag(OtM) or catFlag(OtMpst) or catFlag(OtH)):
              dec newPos
          if newPos > start and buf.info[newPos - 1].isHalant():
            if newPos < stop and buf.info[newPos].isJoiner():
              inc newPos
          let oldPos = i
          buf.mergeClusters(newPos, oldPos + 1)
          # rotate_right by one over [newPos..oldPos]
          var kk = oldPos
          let tmp = buf.info[oldPos]
          while kk > newPos:
            buf.info[kk] = buf.info[kk - 1]
            dec kk
          buf.info[newPos] = tmp
          if newPos <= base and base < oldPos:
            inc base
        break
      inc i
  # Apply 'init' to a word-start left matra.
  if buf.info[start].indicPosition() == PosPreM:
    if start == 0 or not buf.info[start - 1].generalCategory()
        .inRangeInclusive(GcFormat, GcNonSpacingMark):
      buf.info[start].mask = buf.info[start].mask or
        plan.maskArray[IndicInit]
    else:
      buf.unsafeToBreakRange(some(start - 1), some(start + 1))
  true

proc finalReorderingIndic*(buf: var Buffer, sf: ShaperFont,
    plan: IndicShapePlan): bool =
  ## GSUB-pause callback: per-syllable final reordering.
  if buf.len == 0:
    return false
  var start = 0
  var stop = buf.nextSyllable(0)
  while start < buf.len and buf.successful:
    if not buf.finalReorderingSyllable(sf, plan, start, stop):
      return false
    start = stop
    stop = buf.nextSyllable(start)
  buf.successful

proc applyIndicFeature(buf: var Buffer, gsub: GsubData, tagStr: string,
    lookups: seq[uint16], mask: uint32, isGlobal: bool,
    plan: var IndicShapePlan) =
  ## Applies one shaping feature constrained to syllables. Global
  ## features get a fresh buffer-wide mask; per-position features use
  ## the masks tagged during initial reordering.
  if lookups.len == 0:
    return
  if isGlobal:
    let (m, v) = allocMaskBit(plan.nextBit, 1u32)
    if m == 0u32:
      return
    buf.setMasks(v, m, GlobalStart, GlobalEnd)
    buf.applySubstLookups(gsub, lookups, m, true)
  else:
    if mask == 0u32:
      return
    buf.applySubstLookups(gsub, lookups, mask, true)

proc applyIndicGsub*(buf: var Buffer, sf: ShaperFont, gsub: GsubData,
    scriptTag, langTag: Tag, userFeatures: openArray[Feature],
    plan: var IndicShapePlan) =
  ## Full Indic GSUB in HarfBuzz stages: locl/ccmp, syllable setup and
  ## initial reordering, basic features, final reordering, remaining
  ## features, then user features.
  buf.applyIndicFeature(gsub, "locl",
    lookupsForTag(gsub, scriptTag, langTag, "locl"), 0u32, true, plan)
  buf.applyIndicFeature(gsub, "ccmp",
    lookupsForTag(gsub, scriptTag, langTag, "ccmp"), 0u32, true, plan)
  buf.setupSyllablesIndic()
  if not buf.successful:
    return
  if not buf.initialReorderingIndic(sf, gsub, plan):
    return
  for i in 0 ..< 11:
    buf.applyIndicFeature(gsub, IndicFeatureTags[i], plan.lookups[i],
      plan.maskArray[i], IndicGlobalFeature[i], plan)
  if not buf.finalReorderingIndic(sf, plan):
    return
  for i in 11 ..< 17:
    buf.applyIndicFeature(gsub, IndicFeatureTags[i], plan.lookups[i],
      plan.maskArray[i], IndicGlobalFeature[i], plan)
  # User features last, with fresh bits above the Indic allocation.
  # Indic tags and liga (disabled for Indic scripts) are skipped.
  const indicAutoTags = ["locl", "ccmp", "nukt", "akhn", "rphf", "rkrf",
    "pref", "blwf", "abvf", "half", "pstf", "vatu", "cjct", "init",
    "pres", "abvs", "blws", "psts", "haln", "liga"]
  var uBit = plan.nextBit
  for f in userFeatures:
    if f.value == 0u32:
      continue
    var covered = false
    for t in indicAutoTags:
      if f.tag.toU32() == tagFromStr(t).toU32():
        covered = true
        break
    if covered:
      continue
    let (m, v) = allocMaskBit(uBit, f.value)
    if m == 0u32:
      continue
    var lks: seq[uint16] = @[]
    for (tag, ks) in gsubFeaturesFor(gsub, scriptTag, langTag):
      if tag == f.tag.toU32():
        lks = ks
        break
    if lks.len == 0:
      continue
    buf.setMasks(v, m, f.start, f.stop)
    buf.applySubstLookups(gsub, lks, m)
  buf.clearSyllables()
