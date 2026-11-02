import std/options

import ../sfnt
import ./coverage

export coverage

const
  LookupRightToLeft* = 0x0001u16
  LookupIgnoreBaseGlyphs* = 0x0002u16
  LookupIgnoreLigatures* = 0x0004u16
  LookupIgnoreMarks* = 0x0008u16
  LookupUseMarkFilteringSet* = 0x0010u16
  LookupMarkAttachmentTypeMask* = 0xFF00u16
  LookupIgnoreFlags* = 0x000Eu16

  GsubSingleSubst* = 1u16
  GsubMultipleSubst* = 2u16
  GsubAlternateSubst* = 3u16
  GsubLigatureSubst* = 4u16
  GsubContextSubst* = 5u16
  GsubChainedContextSubst* = 6u16
  GsubExtensionSubst* = 7u16
  GsubReverseChainSubst* = 8u16

  MaxNestingLevel* = 64
  MaxContextLength* = 64

type
  LangSys* = object
    requiredFeature*: uint16
    featureIndices*: seq[uint16]

  ScriptTable* = object
    defaultLang*: Option[LangSys]
    langSys*: seq[tuple[tag: uint32, lang: LangSys]]

  SingleSubstKind* = enum
    ssDelta
    ssArray

  SingleSubst* = object
    coverage*: Coverage
    case kind*: SingleSubstKind
    of ssDelta:
      delta*: int32
    of ssArray:
      substitutes*: seq[uint32]

  MultipleSubst* = object
    coverage*: Coverage
    sequences*: seq[seq[uint32]]

  AlternateSubst* = object
    coverage*: Coverage
    sets*: seq[seq[uint32]]

  Ligature* = object
    ligGlyph*: uint32
    components*: seq[uint32]

  LigatureSubst* = object
    coverage*: Coverage
    sets*: seq[seq[Ligature]]

  GsubLookupKind* = enum
    lkSingle
    lkMultiple
    lkAlternate
    lkLigature
    lkContext
    lkChain
    lkReverse
    lkOther

  LookupEntry* = tuple[kind: GsubLookupKind, index: int]

  LookupRecord* = tuple[seqIndex: uint16, lookupIndex: uint16]

  ContextRule* = object
    input*: seq[uint32]
    records*: seq[LookupRecord]

  ChainRule* = object
    backtrack*: seq[uint32]
    input*: seq[uint32]
    lookahead*: seq[uint32]
    records*: seq[LookupRecord]

  ContextSubst* = object
    format*: uint16
    coverage*: Coverage
    classDef*: ClassDef
    ruleSets*: seq[seq[ContextRule]]
    coverages*: seq[Coverage]
    records*: seq[LookupRecord]

  ChainContextSubst* = object
    format*: uint16
    coverage*: Coverage
    backtrackClassDef*: ClassDef
    inputClassDef*: ClassDef
    lookaheadClassDef*: ClassDef
    ruleSets*: seq[seq[ChainRule]]
    backtrackCoverages*: seq[Coverage]
    inputCoverages*: seq[Coverage]
    lookaheadCoverages*: seq[Coverage]
    records*: seq[LookupRecord]

  ReverseChainSubst* = object
    coverage*: Coverage
    backtrackCoverages*: seq[Coverage]
    lookaheadCoverages*: seq[Coverage]
    substitutes*: seq[uint32]

  Lookup* = object
    lookupType*: uint16
    lookupFlag*: uint16
    markFilteringSet*: uint16
    isReverse*: bool
    singleSubsts*: seq[SingleSubst]
    multipleSubsts*: seq[MultipleSubst]
    alternateSubsts*: seq[AlternateSubst]
    ligatureSubsts*: seq[LigatureSubst]
    contextSubsts*: seq[ContextSubst]
    chainSubsts*: seq[ChainContextSubst]
    reverseSubsts*: seq[ReverseChainSubst]
    order*: seq[LookupEntry]

  GsubData* = object
    scripts*: seq[tuple[tag: uint32, script: ScriptTable]]
    features*: seq[tuple[tag: uint32, lookups: seq[uint16]]]
    lookups*: seq[Lookup]

const TagGsub = 0x47535542u32

proc parseLangSys*(bytes: openArray[uint8], off: int): LangSys =
  if off + 6 > bytes.len:
    raise newException(FontError, "short LangSys table")
  let featureCount = int(readU16(bytes, off + 4))
  if off + 6 + featureCount * 2 > bytes.len:
    raise newException(FontError, "short LangSys table")
  var indices = newSeq[uint16](featureCount)
  for i in 0 ..< featureCount:
    indices[i] = readU16(bytes, off + 6 + i * 2)
  LangSys(requiredFeature: readU16(bytes, off + 2), featureIndices: indices)

proc parseScriptTable*(bytes: openArray[uint8], off: int): ScriptTable =
  if off + 4 > bytes.len:
    raise newException(FontError, "short Script table")
  let defaultOff = int(readU16(bytes, off))
  let langCount = int(readU16(bytes, off + 2))
  if off + 4 + langCount * 6 > bytes.len:
    raise newException(FontError, "short Script table")
  var defaultLang: Option[LangSys] = none(LangSys)
  if defaultOff != 0:
    defaultLang = some(parseLangSys(bytes, off + defaultOff))
  var langs: seq[tuple[tag: uint32, lang: LangSys]] = @[]
  for i in 0 ..< langCount:
    let base = off + 4 + i * 6
    let tag = readU32(bytes, base)
    let langOff = int(readU16(bytes, base + 4))
    langs.add((tag, parseLangSys(bytes, off + langOff)))
  ScriptTable(defaultLang: defaultLang, langSys: langs)

proc parseScriptList*(bytes: openArray[uint8],
    off: int): seq[tuple[tag: uint32, script: ScriptTable]] =
  if off + 2 > bytes.len:
    raise newException(FontError, "short ScriptList")
  let scriptCount = int(readU16(bytes, off))
  if off + 2 + scriptCount * 6 > bytes.len:
    raise newException(FontError, "short ScriptList")
  result = @[]
  for i in 0 ..< scriptCount:
    let base = off + 2 + i * 6
    result.add((readU32(bytes, base),
      parseScriptTable(bytes, off + int(readU16(bytes, base + 4)))))

proc parseFeatureList*(bytes: openArray[uint8],
    off: int): seq[tuple[tag: uint32, lookups: seq[uint16]]] =
  if off + 2 > bytes.len:
    raise newException(FontError, "short FeatureList")
  let featureCount = int(readU16(bytes, off))
  if off + 2 + featureCount * 6 > bytes.len:
    raise newException(FontError, "short FeatureList")
  result = @[]
  for i in 0 ..< featureCount:
    let base = off + 2 + i * 6
    let fbase = off + int(readU16(bytes, base + 4))
    if fbase + 4 > bytes.len:
      raise newException(FontError, "short Feature table")
    let lookupCount = int(readU16(bytes, fbase + 2))
    if fbase + 4 + lookupCount * 2 > bytes.len:
      raise newException(FontError, "short Feature table")
    var lookups = newSeq[uint16](lookupCount)
    for j in 0 ..< lookupCount:
      lookups[j] = readU16(bytes, fbase + 4 + j * 2)
    result.add((readU32(bytes, base), lookups))

proc parseSingleSubst(bytes: openArray[uint8], off: int): SingleSubst =
  if off + 4 > bytes.len:
    raise newException(FontError, "short SingleSubst table")
  let format = readU16(bytes, off)
  let covOff = int(readU16(bytes, off + 2))
  let coverage = parseCoverage(bytes, off + covOff)
  if format == 1u16:
    if off + 6 > bytes.len:
      raise newException(FontError, "short SingleSubst format 1")
    SingleSubst(coverage: coverage, kind: ssDelta,
      delta: int32(readI16(bytes, off + 4)))
  elif format == 2u16:
    if off + 6 > bytes.len:
      raise newException(FontError, "short SingleSubst format 2")
    let count = int(readU16(bytes, off + 4))
    if off + 6 + count * 2 > bytes.len:
      raise newException(FontError, "short SingleSubst format 2")
    var subs = newSeq[uint32](count)
    for i in 0 ..< count:
      subs[i] = uint32(readU16(bytes, off + 6 + i * 2))
    SingleSubst(coverage: coverage, kind: ssArray, substitutes: subs)
  else:
    # TODO: SingleSubst formats 3/4 (24-bit glyphs)
    raise newException(FontError, "unsupported SingleSubst format")

proc parseMultipleSubst(bytes: openArray[uint8], off: int): MultipleSubst =
  if off + 4 > bytes.len:
    raise newException(FontError, "short MultipleSubst table")
  let format = readU16(bytes, off)
  if format != 2u16:
    raise newException(FontError, "unsupported MultipleSubst format")
  let covOff = int(readU16(bytes, off + 2))
  let coverage = parseCoverage(bytes, off + covOff)
  let count = int(readU16(bytes, off + 4))
  if off + 6 + count * 2 > bytes.len:
    raise newException(FontError, "short MultipleSubst table")
  var seqs: seq[seq[uint32]] = @[]
  for i in 0 ..< count:
    let soff = off + int(readU16(bytes, off + 6 + i * 2))
    if soff + 2 > bytes.len:
      raise newException(FontError, "short Sequence table")
    let n = int(readU16(bytes, soff))
    if soff + 2 + n * 2 > bytes.len:
      raise newException(FontError, "short Sequence table")
    var s = newSeq[uint32](n)
    for j in 0 ..< n:
      s[j] = uint32(readU16(bytes, soff + 2 + j * 2))
    seqs.add(s)
  MultipleSubst(coverage: coverage, sequences: seqs)

proc parseLigatureSubst(bytes: openArray[uint8], off: int): LigatureSubst =
  if off + 4 > bytes.len:
    raise newException(FontError, "short LigatureSubst table")
  let format = readU16(bytes, off)
  if format != 4u16:
    raise newException(FontError, "unsupported LigatureSubst format")
  let covOff = int(readU16(bytes, off + 2))
  let coverage = parseCoverage(bytes, off + covOff)
  let count = int(readU16(bytes, off + 4))
  if off + 6 + count * 2 > bytes.len:
    raise newException(FontError, "short LigatureSubst table")
  var sets: seq[seq[Ligature]] = @[]
  for i in 0 ..< count:
    let setOff = off + int(readU16(bytes, off + 6 + i * 2))
    if setOff + 2 > bytes.len:
      raise newException(FontError, "short LigatureSet table")
    let ligCount = int(readU16(bytes, setOff))
    if setOff + 2 + ligCount * 2 > bytes.len:
      raise newException(FontError, "short LigatureSet table")
    var ligs: seq[Ligature] = @[]
    for j in 0 ..< ligCount:
      let loff = setOff + int(readU16(bytes, setOff + 2 + j * 2))
      if loff + 4 > bytes.len:
        raise newException(FontError, "short Ligature table")
      let ligGlyph = uint32(readU16(bytes, loff))
      let compCount = int(readU16(bytes, loff + 2))
      if compCount < 1 or loff + 4 + (compCount - 1) * 2 > bytes.len:
        raise newException(FontError, "short Ligature table")
      var comps = newSeq[uint32](compCount - 1)
      for k in 0 ..< compCount - 1:
        comps[k] = uint32(readU16(bytes, loff + 4 + k * 2))
      ligs.add(Ligature(ligGlyph: ligGlyph, components: comps))
    sets.add(ligs)
  LigatureSubst(coverage: coverage, sets: sets)

proc parseAlternateSubst(bytes: openArray[uint8], off: int): AlternateSubst =
  if off + 4 > bytes.len:
    raise newException(FontError, "short AlternateSubst table")
  let format = readU16(bytes, off)
  if format != 3u16:
    raise newException(FontError, "unsupported AlternateSubst format")
  let covOff = int(readU16(bytes, off + 2))
  let coverage = parseCoverage(bytes, off + covOff)
  let count = int(readU16(bytes, off + 4))
  if off + 6 + count * 2 > bytes.len:
    raise newException(FontError, "short AlternateSubst table")
  var sets: seq[seq[uint32]] = @[]
  for i in 0 ..< count:
    let soff = off + int(readU16(bytes, off + 6 + i * 2))
    if soff + 2 > bytes.len:
      raise newException(FontError, "short AlternateSet table")
    let n = int(readU16(bytes, soff))
    if soff + 2 + n * 2 > bytes.len:
      raise newException(FontError, "short AlternateSet table")
    var s = newSeq[uint32](n)
    for j in 0 ..< n:
      s[j] = uint32(readU16(bytes, soff + 2 + j * 2))
    sets.add(s)
  AlternateSubst(coverage: coverage, sets: sets)

proc parseLookupRecords(bytes: openArray[uint8], off: int,
    count: int): seq[LookupRecord] =
  if off < 0 or off + count * 4 > bytes.len:
    raise newException(FontError, "short SubstLookupRecord table")
  result = newSeq[LookupRecord](count)
  for i in 0 ..< count:
    result[i] = (readU16(bytes, off + i * 4), readU16(bytes, off + i * 4 + 2))

proc parseSeqValues(bytes: openArray[uint8], off: int,
    count: int): seq[uint32] =
  if off < 0 or off + count * 2 > bytes.len:
    raise newException(FontError, "short sequence rule table")
  result = newSeq[uint32](count)
  for i in 0 ..< count:
    result[i] = uint32(readU16(bytes, off + i * 2))

proc parseContextRule(bytes: openArray[uint8], off: int): ContextRule =
  if off + 4 > bytes.len:
    raise newException(FontError, "short SequenceRule table")
  let glyphCount = int(readU16(bytes, off))
  let substCount = int(readU16(bytes, off + 2))
  let inputCount = max(0, glyphCount - 1)
  let inputEnd = off + 4 + inputCount * 2
  if inputEnd + substCount * 4 > bytes.len:
    raise newException(FontError, "short SequenceRule table")
  ContextRule(input: parseSeqValues(bytes, off + 4, inputCount),
    records: parseLookupRecords(bytes, inputEnd, substCount))

proc parseChainRule(bytes: openArray[uint8], off: int): ChainRule =
  if off + 2 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRule table")
  let backCount = int(readU16(bytes, off))
  let backEnd = off + 2 + backCount * 2
  if backEnd + 2 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRule table")
  let inputCount = int(readU16(bytes, backEnd))
  let inputVals = max(0, inputCount - 1)
  let inputEnd = backEnd + 2 + inputVals * 2
  if inputEnd + 2 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRule table")
  let lookCount = int(readU16(bytes, inputEnd))
  let lookEnd = inputEnd + 2 + lookCount * 2
  if lookEnd + 2 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRule table")
  let substCount = int(readU16(bytes, lookEnd))
  if lookEnd + 2 + substCount * 4 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRule table")
  ChainRule(backtrack: parseSeqValues(bytes, off + 2, backCount),
    input: parseSeqValues(bytes, backEnd + 2, inputVals),
    lookahead: parseSeqValues(bytes, inputEnd + 2, lookCount),
    records: parseLookupRecords(bytes, lookEnd + 2, substCount))

proc parseContextRuleSet(bytes: openArray[uint8],
    setOff: int): seq[ContextRule] =
  if setOff + 2 > bytes.len:
    raise newException(FontError, "short SequenceRuleSet table")
  let ruleCount = int(readU16(bytes, setOff))
  if setOff + 2 + ruleCount * 2 > bytes.len:
    raise newException(FontError, "short SequenceRuleSet table")
  result = @[]
  for i in 0 ..< ruleCount:
    let roff = int(readU16(bytes, setOff + 2 + i * 2))
    if roff == 0:
      continue
    result.add(parseContextRule(bytes, setOff + roff))

proc parseChainRuleSet(bytes: openArray[uint8], setOff: int): seq[ChainRule] =
  if setOff + 2 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRuleSet table")
  let ruleCount = int(readU16(bytes, setOff))
  if setOff + 2 + ruleCount * 2 > bytes.len:
    raise newException(FontError, "short ChainedSequenceRuleSet table")
  result = @[]
  for i in 0 ..< ruleCount:
    let roff = int(readU16(bytes, setOff + 2 + i * 2))
    if roff == 0:
      continue
    result.add(parseChainRule(bytes, setOff + roff))

proc parseCoverageList(bytes: openArray[uint8], base: int, off: int,
    count: int): seq[Coverage] =
  if off < 0 or off + count * 2 > bytes.len:
    raise newException(FontError, "short coverage list")
  result = newSeq[Coverage](count)
  for i in 0 ..< count:
    let coff = int(readU16(bytes, off + i * 2))
    if coff == 0:
      result[i] = noCoverage()
    else:
      result[i] = parseCoverage(bytes, base + coff)

proc parseContextSubst(bytes: openArray[uint8], off: int): ContextSubst =
  if off + 6 > bytes.len:
    raise newException(FontError, "short SequenceContext table")
  let format = readU16(bytes, off)
  if format == 1u16:
    let covOff = int(readU16(bytes, off + 2))
    let coverage =
      if covOff == 0: noCoverage()
      else: parseCoverage(bytes, off + covOff)
    let setCount = int(readU16(bytes, off + 4))
    if off + 6 + setCount * 2 > bytes.len:
      raise newException(FontError, "short SequenceContextFormat1 table")
    var sets: seq[seq[ContextRule]] = @[]
    for i in 0 ..< setCount:
      let soff = int(readU16(bytes, off + 6 + i * 2))
      if soff == 0:
        sets.add(@[])
      else:
        sets.add(parseContextRuleSet(bytes, off + soff))
    ContextSubst(format: 1u16, coverage: coverage,
      classDef: noClassDef(), ruleSets: sets, coverages: @[], records: @[])
  elif format == 2u16:
    if off + 8 > bytes.len:
      raise newException(FontError, "short SequenceContextFormat2 table")
    let covOff = int(readU16(bytes, off + 2))
    let coverage =
      if covOff == 0: noCoverage()
      else: parseCoverage(bytes, off + covOff)
    let classOff = int(readU16(bytes, off + 4))
    let classDef =
      if classOff == 0: noClassDef()
      else: parseClassDef(bytes, off + classOff)
    let setCount = int(readU16(bytes, off + 6))
    if off + 8 + setCount * 2 > bytes.len:
      raise newException(FontError, "short SequenceContextFormat2 table")
    var sets: seq[seq[ContextRule]] = @[]
    for i in 0 ..< setCount:
      let soff = int(readU16(bytes, off + 8 + i * 2))
      if soff == 0:
        sets.add(@[])
      else:
        sets.add(parseContextRuleSet(bytes, off + soff))
    ContextSubst(format: 2u16, coverage: coverage, classDef: classDef,
      ruleSets: sets, coverages: @[], records: @[])
  elif format == 3u16:
    let glyphCount = int(readU16(bytes, off + 2))
    let substCount = int(readU16(bytes, off + 4))
    if off + 6 + glyphCount * 2 + substCount * 4 > bytes.len:
      raise newException(FontError, "short SequenceContextFormat3 table")
    let covs = parseCoverageList(bytes, off, off + 6, glyphCount)
    let recs = parseLookupRecords(bytes, off + 6 + glyphCount * 2, substCount)
    ContextSubst(format: 3u16, coverage: noCoverage(),
      classDef: noClassDef(), ruleSets: @[], coverages: covs, records: recs)
  else:
    # TODO: SequenceContext formats 4/5/6 (24-bit glyphs)
    raise newException(FontError, "unsupported SequenceContext format")

proc parseChainContextSubst(bytes: openArray[uint8],
    off: int): ChainContextSubst =
  if off + 6 > bytes.len:
    raise newException(FontError, "short ChainedSequenceContext table")
  let format = readU16(bytes, off)
  if format == 1u16:
    let covOff = int(readU16(bytes, off + 2))
    let coverage =
      if covOff == 0: noCoverage()
      else: parseCoverage(bytes, off + covOff)
    let setCount = int(readU16(bytes, off + 4))
    if off + 6 + setCount * 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat1")
    var sets: seq[seq[ChainRule]] = @[]
    for i in 0 ..< setCount:
      let soff = int(readU16(bytes, off + 6 + i * 2))
      if soff == 0:
        sets.add(@[])
      else:
        sets.add(parseChainRuleSet(bytes, off + soff))
    ChainContextSubst(format: 1u16, coverage: coverage,
      backtrackClassDef: noClassDef(), inputClassDef: noClassDef(),
      lookaheadClassDef: noClassDef(), ruleSets: sets,
      backtrackCoverages: @[], inputCoverages: @[], lookaheadCoverages: @[],
      records: @[])
  elif format == 2u16:
    if off + 12 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat2")
    let covOff = int(readU16(bytes, off + 2))
    let coverage =
      if covOff == 0: noCoverage()
      else: parseCoverage(bytes, off + covOff)
    let backOff = int(readU16(bytes, off + 4))
    let inputOff = int(readU16(bytes, off + 6))
    let lookOff = int(readU16(bytes, off + 8))
    let backDef =
      if backOff == 0: noClassDef()
      else: parseClassDef(bytes, off + backOff)
    let inputDef =
      if inputOff == 0: noClassDef()
      else: parseClassDef(bytes, off + inputOff)
    let lookDef =
      if lookOff == 0: noClassDef()
      else: parseClassDef(bytes, off + lookOff)
    let setCount = int(readU16(bytes, off + 10))
    if off + 12 + setCount * 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat2")
    var sets: seq[seq[ChainRule]] = @[]
    for i in 0 ..< setCount:
      let soff = int(readU16(bytes, off + 12 + i * 2))
      if soff == 0:
        sets.add(@[])
      else:
        sets.add(parseChainRuleSet(bytes, off + soff))
    ChainContextSubst(format: 2u16, coverage: coverage,
      backtrackClassDef: backDef, inputClassDef: inputDef,
      lookaheadClassDef: lookDef, ruleSets: sets,
      backtrackCoverages: @[], inputCoverages: @[], lookaheadCoverages: @[],
      records: @[])
  elif format == 3u16:
    if off + 4 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let backCount = int(readU16(bytes, off + 2))
    var p = off + 4
    if p + backCount * 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let backCovs = parseCoverageList(bytes, off, p, backCount)
    p += backCount * 2
    if p + 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let inputCount = int(readU16(bytes, p))
    p += 2
    if p + inputCount * 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let inputCovs = parseCoverageList(bytes, off, p, inputCount)
    p += inputCount * 2
    if p + 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let lookCount = int(readU16(bytes, p))
    p += 2
    if p + lookCount * 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let lookCovs = parseCoverageList(bytes, off, p, lookCount)
    p += lookCount * 2
    if p + 2 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let substCount = int(readU16(bytes, p))
    p += 2
    if p + substCount * 4 > bytes.len:
      raise newException(FontError, "short ChainedSequenceContextFormat3")
    let recs = parseLookupRecords(bytes, p, substCount)
    ChainContextSubst(format: 3u16, coverage: noCoverage(),
      backtrackClassDef: noClassDef(), inputClassDef: noClassDef(),
      lookaheadClassDef: noClassDef(), ruleSets: @[],
      backtrackCoverages: backCovs, inputCoverages: inputCovs,
      lookaheadCoverages: lookCovs, records: recs)
  else:
    # TODO: ChainedSequenceContext formats 4/5/6 (24-bit glyphs)
    raise newException(FontError, "unsupported ChainedSequenceContext format")

proc parseReverseChainSubst(bytes: openArray[uint8],
    off: int): ReverseChainSubst =
  if off + 6 > bytes.len:
    raise newException(FontError, "short ReverseChainSingleSubst table")
  let format = readU16(bytes, off)
  if format != 1u16:
    # TODO: ReverseChainSingleSubstFormat2 (24-bit glyphs)
    raise newException(FontError, "unsupported ReverseChainSingleSubst format")
  let covOff = int(readU16(bytes, off + 2))
  let coverage =
    if covOff == 0: noCoverage()
    else: parseCoverage(bytes, off + covOff)
  let backCount = int(readU16(bytes, off + 4))
  if off + 6 + backCount * 2 > bytes.len:
    raise newException(FontError, "short ReverseChainSingleSubst table")
  let backCovs = parseCoverageList(bytes, off, off + 6, backCount)
  var p = off + 6 + backCount * 2
  if p + 2 > bytes.len:
    raise newException(FontError, "short ReverseChainSingleSubst table")
  let lookCount = int(readU16(bytes, p))
  p += 2
  if p + lookCount * 2 > bytes.len:
    raise newException(FontError, "short ReverseChainSingleSubst table")
  let lookCovs = parseCoverageList(bytes, off, p, lookCount)
  p += lookCount * 2
  if p + 2 > bytes.len:
    raise newException(FontError, "short ReverseChainSingleSubst table")
  let glyphCount = int(readU16(bytes, p))
  p += 2
  if p + glyphCount * 2 > bytes.len:
    raise newException(FontError, "short ReverseChainSingleSubst table")
  var subs = newSeq[uint32](glyphCount)
  for i in 0 ..< glyphCount:
    subs[i] = uint32(readU16(bytes, p + i * 2))
  ReverseChainSubst(coverage: coverage, backtrackCoverages: backCovs,
    lookaheadCoverages: lookCovs, substitutes: subs)

proc parseLookup(bytes: openArray[uint8], tableOff, off: int): Lookup =
  let base = tableOff + off
  if base + 6 > bytes.len:
    raise newException(FontError, "short Lookup table")
  let lookupType = readU16(bytes, base)
  let flag = readU16(bytes, base + 2)
  let subCount = int(readU16(bytes, base + 4))
  if base + 6 + subCount * 2 + (if (flag and
      LookupUseMarkFilteringSet) != 0u16: 2 else: 0) > bytes.len:
    raise newException(FontError, "short Lookup table")
  var markSet = 0u16
  if (flag and LookupUseMarkFilteringSet) != 0u16:
    markSet = readU16(bytes, base + 6 + subCount * 2)
  var subs: seq[SingleSubst] = @[]
  var multis: seq[MultipleSubst] = @[]
  var alts: seq[AlternateSubst] = @[]
  var ligs: seq[LigatureSubst] = @[]
  var ctxs: seq[ContextSubst] = @[]
  var chains: seq[ChainContextSubst] = @[]
  var revs: seq[ReverseChainSubst] = @[]
  var order: seq[LookupEntry] = @[]
  var isReverse = lookupType == GsubReverseChainSubst
  if lookupType == GsubSingleSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      subs.add(parseSingleSubst(bytes, base + subOff))
      order.add((lkSingle, subs.len - 1))
  elif lookupType == GsubMultipleSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      multis.add(parseMultipleSubst(bytes, base + subOff))
      order.add((lkMultiple, multis.len - 1))
  elif lookupType == GsubAlternateSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      alts.add(parseAlternateSubst(bytes, base + subOff))
      order.add((lkAlternate, alts.len - 1))
  elif lookupType == GsubLigatureSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      ligs.add(parseLigatureSubst(bytes, base + subOff))
      order.add((lkLigature, ligs.len - 1))
  elif lookupType == GsubContextSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        ctxs.add(parseContextSubst(bytes, base + subOff))
        order.add((lkContext, ctxs.len - 1))
      except FontError:
        # Skip unreadable or unsupported (wide) subtables.
        continue
  elif lookupType == GsubChainedContextSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        chains.add(parseChainContextSubst(bytes, base + subOff))
        order.add((lkChain, chains.len - 1))
      except FontError:
        continue
  elif lookupType == GsubReverseChainSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        revs.add(parseReverseChainSubst(bytes, base + subOff))
        order.add((lkReverse, revs.len - 1))
      except FontError:
        continue
  elif lookupType == GsubExtensionSubst:
    # Extension lookups flatten their inner subtables into the
    # corresponding sequences. A lookup is reverse if its first
    # extension wraps type 8, mirroring harfrust's is_reversed.
    if subCount > 0:
      let firstOff = int(readU16(bytes, base + 6))
      let extBase = base + firstOff
      if extBase + 8 <= bytes.len and readU16(bytes, extBase) == 1u16:
        isReverse = readU16(bytes, extBase + 2) == GsubReverseChainSubst
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      let extBase = base + subOff
      try:
        if extBase + 8 > bytes.len:
          raise newException(FontError, "short ExtensionSubst table")
        if readU16(bytes, extBase) != 1u16:
          raise newException(FontError, "unsupported ExtensionSubst format")
        let extType = readU16(bytes, extBase + 2)
        let extOffset = int(readU32(bytes, extBase + 4))
        if extOffset == 0 or extType == GsubExtensionSubst:
          continue
        let innerOff = extBase + extOffset
        case extType
        of GsubSingleSubst:
          subs.add(parseSingleSubst(bytes, innerOff))
          order.add((lkSingle, subs.len - 1))
        of GsubMultipleSubst:
          multis.add(parseMultipleSubst(bytes, innerOff))
          order.add((lkMultiple, multis.len - 1))
        of GsubAlternateSubst:
          alts.add(parseAlternateSubst(bytes, innerOff))
          order.add((lkAlternate, alts.len - 1))
        of GsubLigatureSubst:
          ligs.add(parseLigatureSubst(bytes, innerOff))
          order.add((lkLigature, ligs.len - 1))
        of GsubContextSubst:
          ctxs.add(parseContextSubst(bytes, innerOff))
          order.add((lkContext, ctxs.len - 1))
        of GsubChainedContextSubst:
          chains.add(parseChainContextSubst(bytes, innerOff))
          order.add((lkChain, chains.len - 1))
        of GsubReverseChainSubst:
          revs.add(parseReverseChainSubst(bytes, innerOff))
          order.add((lkReverse, revs.len - 1))
        else:
          continue
      except FontError:
        continue
  Lookup(lookupType: lookupType, lookupFlag: flag, markFilteringSet: markSet,
    isReverse: isReverse, singleSubsts: subs, multipleSubsts: multis,
    alternateSubsts: alts, ligatureSubsts: ligs, contextSubsts: ctxs,
    chainSubsts: chains, reverseSubsts: revs, order: order)

proc parseGsubTable*(bytes: openArray[uint8], off: int): GsubData =
  if off + 10 > bytes.len:
    raise newException(FontError, "short GSUB header")
  let scriptOff = int(readU16(bytes, off + 4))
  let featureOff = int(readU16(bytes, off + 6))
  let lookupOff = int(readU16(bytes, off + 8))
  let scripts = parseScriptList(bytes, off + scriptOff)
  let features = parseFeatureList(bytes, off + featureOff)
  var lookups: seq[Lookup] = @[]
  let lookupBase = off + lookupOff
  let lookupCount = int(readU16(bytes, lookupBase))
  if lookupBase + 2 + lookupCount * 2 > bytes.len:
    raise newException(FontError, "short LookupList")
  for i in 0 ..< lookupCount:
    let loff = int(readU16(bytes, lookupBase + 2 + i * 2))
    try:
      lookups.add(parseLookup(bytes, lookupBase, loff))
    except FontError:
      # Skip unreadable lookups but keep the slot so feature
      # references stay aligned (mirrors harfrust lazy lookup caching).
      lookups.add(Lookup(lookupType: 0u16, lookupFlag: 0u16,
        markFilteringSet: 0u16, isReverse: false, singleSubsts: @[],
        multipleSubsts: @[], alternateSubsts: @[], ligatureSubsts: @[],
        contextSubsts: @[], chainSubsts: @[], reverseSubsts: @[],
        order: @[]))
  GsubData(scripts: scripts, features: features, lookups: lookups)

proc parseGsub*(f: SfntFont): Option[GsubData] =
  let (ok, off, len) = f.tableData(TagGsub)
  if not ok or len < 10:
    return none(GsubData)
  try:
    some(parseGsubTable(f.bytes, off))
  except FontError:
    none(GsubData)

proc singleSubstitute*(sub: SingleSubst, gid: uint32,
    index: uint32): Option[uint32] =
  case sub.kind
  of ssDelta:
    some(uint32((int32(gid) + sub.delta) and 0xFFFFi32))
  of ssArray:
    if int(index) < sub.substitutes.len:
      some(sub.substitutes[int(index)])
    else:
      none(uint32)
