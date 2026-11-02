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
  GsubLigatureSubst* = 4u16

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

  Ligature* = object
    ligGlyph*: uint32
    components*: seq[uint32]

  LigatureSubst* = object
    coverage*: Coverage
    sets*: seq[seq[Ligature]]

  GsubLookupKind* = enum
    lkSingle
    lkMultiple
    lkLigature
    lkOther

  LookupEntry* = tuple[kind: GsubLookupKind, index: int]

  Lookup* = object
    lookupType*: uint16
    lookupFlag*: uint16
    markFilteringSet*: uint16
    singleSubsts*: seq[SingleSubst]
    multipleSubsts*: seq[MultipleSubst]
    ligatureSubsts*: seq[LigatureSubst]
    order*: seq[LookupEntry]

  GsubData* = object
    scripts*: seq[tuple[tag: uint32, script: ScriptTable]]
    features*: seq[tuple[tag: uint32, lookups: seq[uint16]]]
    lookups*: seq[Lookup]

const TagGsub = 0x47535542u32

proc parseLangSys(bytes: openArray[uint8], off: int): LangSys =
  if off + 6 > bytes.len:
    raise newException(FontError, "short LangSys table")
  let featureCount = int(readU16(bytes, off + 4))
  if off + 6 + featureCount * 2 > bytes.len:
    raise newException(FontError, "short LangSys table")
  var indices = newSeq[uint16](featureCount)
  for i in 0 ..< featureCount:
    indices[i] = readU16(bytes, off + 6 + i * 2)
  LangSys(requiredFeature: readU16(bytes, off + 2), featureIndices: indices)

proc parseScriptTable(bytes: openArray[uint8], off: int): ScriptTable =
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
  var ligs: seq[LigatureSubst] = @[]
  var order: seq[LookupEntry] = @[]
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
  elif lookupType == GsubLigatureSubst:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      ligs.add(parseLigatureSubst(bytes, base + subOff))
      order.add((lkLigature, ligs.len - 1))
  # TODO: other GSUB lookup types (alternate, contextual, chained,
  #   extension, reverse-chained)
  Lookup(lookupType: lookupType, lookupFlag: flag, markFilteringSet: markSet,
    singleSubsts: subs, multipleSubsts: multis, ligatureSubsts: ligs,
    order: order)

proc parseGsubTable*(bytes: openArray[uint8], off: int): GsubData =
  if off + 10 > bytes.len:
    raise newException(FontError, "short GSUB header")
  let scriptOff = int(readU16(bytes, off + 4))
  let featureOff = int(readU16(bytes, off + 6))
  let lookupOff = int(readU16(bytes, off + 8))
  var scripts: seq[tuple[tag: uint32, script: ScriptTable]] = @[]
  let scriptBase = off + scriptOff
  let scriptCount = int(readU16(bytes, scriptBase))
  if scriptBase + 2 + scriptCount * 6 > bytes.len:
    raise newException(FontError, "short ScriptList")
  for i in 0 ..< scriptCount:
    let base = scriptBase + 2 + i * 6
    scripts.add((readU32(bytes, base),
      parseScriptTable(bytes, scriptBase + int(readU16(bytes, base + 4)))))
  var features: seq[tuple[tag: uint32, lookups: seq[uint16]]] = @[]
  let featureBase = off + featureOff
  let featureCount = int(readU16(bytes, featureBase))
  if featureBase + 2 + featureCount * 6 > bytes.len:
    raise newException(FontError, "short FeatureList")
  for i in 0 ..< featureCount:
    let base = featureBase + 2 + i * 6
    let fbase = featureBase + int(readU16(bytes, base + 4))
    if fbase + 4 > bytes.len:
      raise newException(FontError, "short Feature table")
    let lookupCount = int(readU16(bytes, fbase + 2))
    if fbase + 4 + lookupCount * 2 > bytes.len:
      raise newException(FontError, "short Feature table")
    var lookups = newSeq[uint16](lookupCount)
    for j in 0 ..< lookupCount:
      lookups[j] = readU16(bytes, fbase + 4 + j * 2)
    features.add((readU32(bytes, base), lookups))
  var lookups: seq[Lookup] = @[]
  let lookupBase = off + lookupOff
  let lookupCount = int(readU16(bytes, lookupBase))
  if lookupBase + 2 + lookupCount * 2 > bytes.len:
    raise newException(FontError, "short LookupList")
  for i in 0 ..< lookupCount:
    let loff = int(readU16(bytes, lookupBase + 2 + i * 2))
    lookups.add(parseLookup(bytes, lookupBase, loff))
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
