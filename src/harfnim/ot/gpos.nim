## GPOS positioning tables, ported from harfrust `ot/lookup/gpos.rs`.
##
## Scope: static (non-variable) fonts. ValueRecord device tables and
## variation deltas are skipped (TODO); anchors ignore contour points and
## device tables (TODO). Wide (24-bit) formats are deferred with TODO.
## Extension (type 9) flattens inner SinglePos, PairPos, cursive, mark
## attachments, and contextual positioning (types 7/8 share the GSUB
## SequenceContext/ChainedSequenceContext layouts and rule engine).

import std/options

import ../sfnt
import ./coverage
import ./gsub

export coverage
export gsub

const
  GposSinglePos* = 1u16
  GposPairPos* = 2u16
  GposCursivePos* = 3u16
  GposMarkBasePos* = 4u16
  GposMarkLigPos* = 5u16
  GposMarkMarkPos* = 6u16
  GposContextPos* = 7u16
  GposChainedContextPos* = 8u16
  GposExtensionPos* = 9u16

  ValueXPlacement* = 0x0001u16
  ValueYPlacement* = 0x0002u16
  ValueXAdvance* = 0x0004u16
  ValueYAdvance* = 0x0008u16
  ValueXPlacementDevice* = 0x0010u16
  ValueYPlacementDevice* = 0x0020u16
  ValueXAdvanceDevice* = 0x0040u16
  ValueYAdvanceDevice* = 0x0080u16

type
  ValueRecord* = object
    format*: uint16
    xPlacement*: int32
    yPlacement*: int32
    xAdvance*: int32
    yAdvance*: int32

  Anchor* = object
    format*: uint16
    x*: int32
    y*: int32

  SinglePos* = object
    coverage*: Coverage
    format*: uint16
    values*: seq[ValueRecord]

  PairValue* = tuple[first, second: ValueRecord]

  PairSet* = object
    seconds*: seq[uint16]
    values*: seq[PairValue]

  PairPos* = object
    coverage*: Coverage
    format*: uint16
    format1*: uint16
    format2*: uint16
    pairSets*: seq[PairSet]
    classDef1*: ClassDef
    classDef2*: ClassDef
    class1Count*: uint16
    class2Count*: uint16
    matrix*: seq[PairValue]

  GposLookupKind* = enum
    pkSingle
    pkPair
    pkCursive
    pkMarkBase
    pkMarkLig
    pkMarkMark
    pkContext
    pkChain
    pkOther

  PosLookupEntry* = tuple[kind: GposLookupKind, index: int]

  MarkSub* = object
    ## Mark-to-base / mark-to-mark shared layout: mark coverage drives the
    ## index, base coverage selects the attachment target.
    markCoverage*: Coverage
    baseCoverage*: Coverage
    classCount*: uint16
    markClasses*: seq[uint16]
    markAnchors*: seq[Anchor]
    baseCount*: int
    baseAnchors*: seq[Anchor]

  LigSub* = object
    markCoverage*: Coverage
    ligCoverage*: Coverage
    classCount*: uint16
    markClasses*: seq[uint16]
    markAnchors*: seq[Anchor]
    ligCount*: int
    # Per-ligature component anchor rows, flattened with offsets.
    compOffsets*: seq[int]
    compCounts*: seq[int]
    compAnchors*: seq[Anchor]

  CursiveSub* = object
    coverage*: Coverage
    entryAnchors*: seq[Anchor]
    exitAnchors*: seq[Anchor]

  PosLookup* = object
    lookupType*: uint16
    lookupFlag*: uint16
    markFilteringSet*: uint16
    singlePos*: seq[SinglePos]
    pairPos*: seq[PairPos]
    cursivePos*: seq[CursiveSub]
    markBasePos*: seq[MarkSub]
    markLigPos*: seq[LigSub]
    markMarkPos*: seq[MarkSub]
    contextPos*: seq[ContextSubst]
    chainPos*: seq[ChainContextSubst]
    order*: seq[PosLookupEntry]

  GposData* = object
    scripts*: seq[tuple[tag: uint32, script: ScriptTable]]
    features*: seq[tuple[tag: uint32, lookups: seq[uint16]]]
    lookups*: seq[PosLookup]

const TagGpos = 0x47504F53u32

proc valueRecordLen*(format: uint16): int =
  var n = 0
  var f = format
  while f != 0u16:
    n += int(f and 1u16)
    f = f shr 1
  n * 2

proc parseValueRecord*(bytes: openArray[uint8], off: int,
    format: uint16): ValueRecord =
  result = ValueRecord(format: format)
  if off < 0:
    return result
  var p = off
  if (format and ValueXPlacement) != 0u16:
    if p + 2 > bytes.len:
      return ValueRecord(format: format)
    result.xPlacement = int32(readI16(bytes, p))
    p += 2
  if (format and ValueYPlacement) != 0u16:
    if p + 2 > bytes.len:
      return ValueRecord(format: format)
    result.yPlacement = int32(readI16(bytes, p))
    p += 2
  if (format and ValueXAdvance) != 0u16:
    if p + 2 > bytes.len:
      return ValueRecord(format: format)
    result.xAdvance = int32(readI16(bytes, p))
    p += 2
  if (format and ValueYAdvance) != 0u16:
    if p + 2 > bytes.len:
      return ValueRecord(format: format)
    result.yAdvance = int32(readI16(bytes, p))
    p += 2
  # TODO: device tables and variation deltas (offsets after the values).
  # They occupy 2 bytes per set device bit but only affect hinting or
  # variable fonts, so shaping ignores them.

proc parseAnchor*(bytes: openArray[uint8], off: int): Anchor =
  if off <= 0 or off + 6 > bytes.len:
    return Anchor(format: 0u16)
  let format = readU16(bytes, off)
  if format == 1u16 or format == 2u16:
    if off + 6 > bytes.len:
      return Anchor(format: format)
    # Format 2 appends an anchorPoint index into the glyph outline;
    # without outline parsing we use the raw x/y (TODO).
    Anchor(format: format, x: int32(readI16(bytes, off + 2)),
      y: int32(readI16(bytes, off + 4)))
  elif format == 3u16:
    if off + 6 > bytes.len:
      return Anchor(format: format)
    # Format 3 appends device-table offsets (TODO, hinting only).
    Anchor(format: format, x: int32(readI16(bytes, off + 2)),
      y: int32(readI16(bytes, off + 4)))
  else:
    Anchor(format: 0u16)

proc parseSinglePos*(bytes: openArray[uint8], off: int): SinglePos =
  if off + 6 > bytes.len:
    raise newException(FontError, "short SinglePos table")
  let format = readU16(bytes, off)
  let covOff = int(readU16(bytes, off + 2))
  let coverage = parseCoverage(bytes, off + covOff)
  let valueFormat = readU16(bytes, off + 4)
  if format == 1u16:
    let recLen = valueRecordLen(valueFormat)
    if off + 6 + recLen > bytes.len:
      raise newException(FontError, "short SinglePosFormat1 table")
    let v = parseValueRecord(bytes, off + 6, valueFormat)
    SinglePos(coverage: coverage, format: 1u16, values: @[v])
  elif format == 2u16:
    if off + 8 > bytes.len:
      raise newException(FontError, "short SinglePosFormat2 table")
    let count = int(readU16(bytes, off + 6))
    let recLen = valueRecordLen(valueFormat)
    if off + 8 + count * recLen > bytes.len:
      raise newException(FontError, "short SinglePosFormat2 table")
    var vals = newSeq[ValueRecord](count)
    for i in 0 ..< count:
      vals[i] = parseValueRecord(bytes, off + 8 + i * recLen, valueFormat)
    SinglePos(coverage: coverage, format: 2u16, values: vals)
  else:
    # TODO: SinglePos formats 3/4 (24-bit glyphs)
    raise newException(FontError, "unsupported SinglePos format")

proc parsePairSet(bytes: openArray[uint8], off: int, format1,
    format2: uint16): PairSet =
  if off + 2 > bytes.len:
    raise newException(FontError, "short PairSet table")
  let count = int(readU16(bytes, off))
  let len1 = valueRecordLen(format1)
  let len2 = valueRecordLen(format2)
  let recLen = 2 + len1 + len2
  if off + 2 + count * recLen > bytes.len:
    raise newException(FontError, "short PairSet table")
  var seconds = newSeq[uint16](count)
  var values = newSeq[PairValue](count)
  for i in 0 ..< count:
    let base = off + 2 + i * recLen
    seconds[i] = readU16(bytes, base)
    values[i] = (parseValueRecord(bytes, base + 2, format1),
      parseValueRecord(bytes, base + 2 + len1, format2))
  PairSet(seconds: seconds, values: values)

proc parsePairPos*(bytes: openArray[uint8], off: int): PairPos =
  if off + 10 > bytes.len:
    raise newException(FontError, "short PairPos table")
  let format = readU16(bytes, off)
  let covOff = int(readU16(bytes, off + 2))
  let coverage = parseCoverage(bytes, off + covOff)
  let format1 = readU16(bytes, off + 4)
  let format2 = readU16(bytes, off + 6)
  if format == 1u16:
    let setCount = int(readU16(bytes, off + 8))
    if off + 10 + setCount * 2 > bytes.len:
      raise newException(FontError, "short PairPosFormat1 table")
    var sets: seq[PairSet] = @[]
    for i in 0 ..< setCount:
      let soff = int(readU16(bytes, off + 10 + i * 2))
      if soff == 0:
        sets.add(PairSet(seconds: @[], values: @[]))
      else:
        sets.add(parsePairSet(bytes, off + soff, format1, format2))
    PairPos(coverage: coverage, format: 1u16, format1: format1,
      format2: format2, pairSets: sets, classDef1: noClassDef(),
      classDef2: noClassDef(), class1Count: 0u16, class2Count: 0u16,
      matrix: @[])
  elif format == 2u16:
    if off + 16 > bytes.len:
      raise newException(FontError, "short PairPosFormat2 table")
    let class1Off = int(readU16(bytes, off + 8))
    let class2Off = int(readU16(bytes, off + 10))
    let classDef1 =
      if class1Off == 0: noClassDef()
      else: parseClassDef(bytes, off + class1Off)
    let classDef2 =
      if class2Off == 0: noClassDef()
      else: parseClassDef(bytes, off + class2Off)
    let class1Count = readU16(bytes, off + 12)
    let class2Count = readU16(bytes, off + 14)
    let len1 = valueRecordLen(format1)
    let len2 = valueRecordLen(format2)
    let recLen = len1 + len2
    let count = int(class1Count) * int(class2Count)
    if off + 16 + count * recLen > bytes.len:
      raise newException(FontError, "short PairPosFormat2 table")
    var matrix = newSeq[PairValue](count)
    for i in 0 ..< count:
      let base = off + 16 + i * recLen
      matrix[i] = (parseValueRecord(bytes, base, format1),
        parseValueRecord(bytes, base + len1, format2))
    PairPos(coverage: coverage, format: 2u16, format1: format1,
      format2: format2, pairSets: @[], classDef1: classDef1,
      classDef2: classDef2, class1Count: class1Count,
      class2Count: class2Count, matrix: matrix)
  else:
    # TODO: PairPos formats 3/4 (24-bit glyphs)
    raise newException(FontError, "unsupported PairPos format")

proc parseMarkArray(bytes: openArray[uint8], off: int,
    markClasses, markAnchorOffs: var seq[uint16],
    outCount: var int) =
  if off + 2 > bytes.len:
    raise newException(FontError, "short MarkArray table")
  let count = int(readU16(bytes, off))
  if off + 2 + count * 4 > bytes.len:
    raise newException(FontError, "short MarkArray table")
  markClasses.setLen(count)
  markAnchorOffs.setLen(count)
  for i in 0 ..< count:
    markClasses[i] = readU16(bytes, off + 2 + i * 4)
    markAnchorOffs[i] = readU16(bytes, off + 4 + i * 4)
  outCount = count

proc parseMarkBase*(bytes: openArray[uint8], off: int): MarkSub =
  if off + 10 > bytes.len:
    raise newException(FontError, "short MarkBasePos table")
  if readU16(bytes, off) != 1u16:
    raise newException(FontError, "unsupported MarkBasePos format")
  let markCovOff = int(readU16(bytes, off + 2))
  let baseCovOff = int(readU16(bytes, off + 4))
  let classCount = readU16(bytes, off + 6)
  let markArrayOff = int(readU16(bytes, off + 8))
  let baseArrayOff = int(readU16(bytes, off + 10))
  let markCov = parseCoverage(bytes, off + markCovOff)
  let baseCov = parseCoverage(bytes, off + baseCovOff)
  if markArrayOff == 0 or baseArrayOff == 0:
    raise newException(FontError, "short MarkBasePos table")
  let markBase = off + markArrayOff
  var markClasses: seq[uint16] = @[]
  var markOffs: seq[uint16] = @[]
  var markCount = 0
  parseMarkArray(bytes, markBase, markClasses, markOffs, markCount)
  var markAnchors = newSeq[Anchor](markCount)
  for i in 0 ..< markCount:
    if markOffs[i] == 0u16:
      markAnchors[i] = Anchor(format: 0u16)
    else:
      markAnchors[i] = parseAnchor(bytes, markBase + int(markOffs[i]))
  let baseOff = off + baseArrayOff
  if baseOff + 2 > bytes.len:
    raise newException(FontError, "short BaseArray table")
  let baseCount = int(readU16(bytes, baseOff))
  let total = baseCount * int(classCount)
  if baseOff + 2 + total * 2 > bytes.len:
    raise newException(FontError, "short BaseArray table")
  var baseAnchors = newSeq[Anchor](total)
  for i in 0 ..< total:
    let aoff = int(readU16(bytes, baseOff + 2 + i * 2))
    if aoff == 0:
      baseAnchors[i] = Anchor(format: 0u16)
    else:
      baseAnchors[i] = parseAnchor(bytes, baseOff + aoff)
  MarkSub(markCoverage: markCov, baseCoverage: baseCov,
    classCount: classCount, markClasses: markClasses,
    markAnchors: markAnchors, baseCount: baseCount, baseAnchors: baseAnchors)

proc parseMarkMark*(bytes: openArray[uint8], off: int): MarkSub =
  if off + 10 > bytes.len:
    raise newException(FontError, "short MarkMarkPos table")
  if readU16(bytes, off) != 1u16:
    raise newException(FontError, "unsupported MarkMarkPos format")
  # Layout mirrors MarkBase: mark1 array attaches to mark2 array.
  let mark1CovOff = int(readU16(bytes, off + 2))
  let mark2CovOff = int(readU16(bytes, off + 4))
  let classCount = readU16(bytes, off + 6)
  let mark1Off = int(readU16(bytes, off + 8))
  let mark2Off = int(readU16(bytes, off + 10))
  let markCov = parseCoverage(bytes, off + mark1CovOff)
  let baseCov = parseCoverage(bytes, off + mark2CovOff)
  if mark1Off == 0 or mark2Off == 0:
    raise newException(FontError, "short MarkMarkPos table")
  let markBase = off + mark1Off
  var markClasses: seq[uint16] = @[]
  var markOffs: seq[uint16] = @[]
  var markCount = 0
  parseMarkArray(bytes, markBase, markClasses, markOffs, markCount)
  var markAnchors = newSeq[Anchor](markCount)
  for i in 0 ..< markCount:
    if markOffs[i] == 0u16:
      markAnchors[i] = Anchor(format: 0u16)
    else:
      markAnchors[i] = parseAnchor(bytes, markBase + int(markOffs[i]))
  let baseOff = off + mark2Off
  if baseOff + 2 > bytes.len:
    raise newException(FontError, "short Mark2Array table")
  let baseCount = int(readU16(bytes, baseOff))
  let total = baseCount * int(classCount)
  if baseOff + 2 + total * 2 > bytes.len:
    raise newException(FontError, "short Mark2Array table")
  var baseAnchors = newSeq[Anchor](total)
  for i in 0 ..< total:
    let aoff = int(readU16(bytes, baseOff + 2 + i * 2))
    if aoff == 0:
      baseAnchors[i] = Anchor(format: 0u16)
    else:
      baseAnchors[i] = parseAnchor(bytes, baseOff + aoff)
  MarkSub(markCoverage: markCov, baseCoverage: baseCov,
    classCount: classCount, markClasses: markClasses,
    markAnchors: markAnchors, baseCount: baseCount, baseAnchors: baseAnchors)

proc parseMarkLig*(bytes: openArray[uint8], off: int): LigSub =
  if off + 10 > bytes.len:
    raise newException(FontError, "short MarkLigPos table")
  if readU16(bytes, off) != 1u16:
    raise newException(FontError, "unsupported MarkLigPos format")
  let markCovOff = int(readU16(bytes, off + 2))
  let ligCovOff = int(readU16(bytes, off + 4))
  let classCount = readU16(bytes, off + 6)
  let markArrayOff = int(readU16(bytes, off + 8))
  let ligArrayOff = int(readU16(bytes, off + 10))
  let markCov = parseCoverage(bytes, off + markCovOff)
  let ligCov = parseCoverage(bytes, off + ligCovOff)
  if markArrayOff == 0 or ligArrayOff == 0:
    raise newException(FontError, "short MarkLigPos table")
  let markBase = off + markArrayOff
  var markClasses: seq[uint16] = @[]
  var markOffs: seq[uint16] = @[]
  var markCount = 0
  parseMarkArray(bytes, markBase, markClasses, markOffs, markCount)
  var markAnchors = newSeq[Anchor](markCount)
  for i in 0 ..< markCount:
    if markOffs[i] == 0u16:
      markAnchors[i] = Anchor(format: 0u16)
    else:
      markAnchors[i] = parseAnchor(bytes, markBase + int(markOffs[i]))
  let ligBase = off + ligArrayOff
  if ligBase + 2 > bytes.len:
    raise newException(FontError, "short LigatureArray table")
  let ligCount = int(readU16(bytes, ligBase))
  if ligBase + 2 + ligCount * 2 > bytes.len:
    raise newException(FontError, "short LigatureArray table")
  var compOffsets: seq[int] = @[]
  var compCounts: seq[int] = @[]
  var compAnchors: seq[Anchor] = @[]
  for li in 0 ..< ligCount:
    let attachOff = int(readU16(bytes, ligBase + 2 + li * 2))
    if attachOff == 0:
      compOffsets.add(compAnchors.len)
      compCounts.add(0)
      continue
    let compBase = ligBase + attachOff
    if compBase + 2 > bytes.len:
      raise newException(FontError, "short LigatureAttach table")
    let compCount = int(readU16(bytes, compBase))
    if compBase + 2 + compCount * int(classCount) * 2 > bytes.len:
      raise newException(FontError, "short LigatureAttach table")
    compOffsets.add(compAnchors.len)
    compCounts.add(compCount)
    for ci in 0 ..< compCount * int(classCount):
      let aoff = int(readU16(bytes, compBase + 2 + ci * 2))
      if aoff == 0:
        compAnchors.add(Anchor(format: 0u16))
      else:
        compAnchors.add(parseAnchor(bytes, compBase + aoff))
  LigSub(markCoverage: markCov, ligCoverage: ligCov, classCount: classCount,
    markClasses: markClasses, markAnchors: markAnchors, ligCount: ligCount,
    compOffsets: compOffsets, compCounts: compCounts,
    compAnchors: compAnchors)

proc parseCursive*(bytes: openArray[uint8], off: int): CursiveSub =
  if off + 6 > bytes.len:
    raise newException(FontError, "short CursivePos table")
  if readU16(bytes, off) != 1u16:
    raise newException(FontError, "unsupported CursivePos format")
  let covOff = int(readU16(bytes, off + 2))
  let cov = parseCoverage(bytes, off + covOff)
  let entryExitCount = int(readU16(bytes, off + 4))
  if off + 6 + entryExitCount * 4 > bytes.len:
    raise newException(FontError, "short CursivePos table")
  var entries = newSeq[Anchor](entryExitCount)
  var exits = newSeq[Anchor](entryExitCount)
  for i in 0 ..< entryExitCount:
    let entryOff = int(readU16(bytes, off + 6 + i * 4))
    let exitOff = int(readU16(bytes, off + 8 + i * 4))
    entries[i] = if entryOff == 0: Anchor(format: 0u16)
      else: parseAnchor(bytes, off + entryOff)
    exits[i] = if exitOff == 0: Anchor(format: 0u16)
      else: parseAnchor(bytes, off + exitOff)
  CursiveSub(coverage: cov, entryAnchors: entries, exitAnchors: exits)

proc parsePosLookup(bytes: openArray[uint8], tableOff, off: int): PosLookup =
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
  var singles: seq[SinglePos] = @[]
  var pairs: seq[PairPos] = @[]
  var cursives: seq[CursiveSub] = @[]
  var markBases: seq[MarkSub] = @[]
  var markLigs: seq[LigSub] = @[]
  var markMarks: seq[MarkSub] = @[]
  var ctxs: seq[ContextSubst] = @[]
  var chains: seq[ChainContextSubst] = @[]
  var order: seq[PosLookupEntry] = @[]
  if lookupType == GposSinglePos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        singles.add(parseSinglePos(bytes, base + subOff))
        order.add((pkSingle, singles.len - 1))
      except FontError:
        continue
  elif lookupType == GposPairPos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        pairs.add(parsePairPos(bytes, base + subOff))
        order.add((pkPair, pairs.len - 1))
      except FontError:
        continue
  elif lookupType == GposCursivePos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        cursives.add(parseCursive(bytes, base + subOff))
        order.add((pkCursive, cursives.len - 1))
      except FontError:
        continue
  elif lookupType == GposMarkBasePos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        markBases.add(parseMarkBase(bytes, base + subOff))
        order.add((pkMarkBase, markBases.len - 1))
      except FontError:
        continue
  elif lookupType == GposMarkLigPos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        markLigs.add(parseMarkLig(bytes, base + subOff))
        order.add((pkMarkLig, markLigs.len - 1))
      except FontError:
        continue
  elif lookupType == GposMarkMarkPos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        markMarks.add(parseMarkMark(bytes, base + subOff))
        order.add((pkMarkMark, markMarks.len - 1))
      except FontError:
        continue
  elif lookupType == GposContextPos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        ctxs.add(parseContextSubst(bytes, base + subOff))
        order.add((pkContext, ctxs.len - 1))
      except FontError:
        # Skip unreadable or unsupported (wide) subtables.
        continue
  elif lookupType == GposChainedContextPos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      try:
        chains.add(parseChainContextSubst(bytes, base + subOff))
        order.add((pkChain, chains.len - 1))
      except FontError:
        continue
  elif lookupType == GposExtensionPos:
    for i in 0 ..< subCount:
      let subOff = int(readU16(bytes, base + 6 + i * 2))
      let extBase = base + subOff
      try:
        if extBase + 8 > bytes.len:
          raise newException(FontError, "short ExtensionPos table")
        if readU16(bytes, extBase) != 1u16:
          raise newException(FontError, "unsupported ExtensionPos format")
        let extType = readU16(bytes, extBase + 2)
        let extOffset = int(readU32(bytes, extBase + 4))
        if extOffset == 0 or extType == GposExtensionPos:
          continue
        let innerOff = extBase + extOffset
        case extType
        of GposSinglePos:
          singles.add(parseSinglePos(bytes, innerOff))
          order.add((pkSingle, singles.len - 1))
        of GposPairPos:
          pairs.add(parsePairPos(bytes, innerOff))
          order.add((pkPair, pairs.len - 1))
        of GposCursivePos:
          cursives.add(parseCursive(bytes, innerOff))
          order.add((pkCursive, cursives.len - 1))
        of GposMarkBasePos:
          markBases.add(parseMarkBase(bytes, innerOff))
          order.add((pkMarkBase, markBases.len - 1))
        of GposMarkLigPos:
          markLigs.add(parseMarkLig(bytes, innerOff))
          order.add((pkMarkLig, markLigs.len - 1))
        of GposMarkMarkPos:
          markMarks.add(parseMarkMark(bytes, innerOff))
          order.add((pkMarkMark, markMarks.len - 1))
        of GposContextPos:
          ctxs.add(parseContextSubst(bytes, innerOff))
          order.add((pkContext, ctxs.len - 1))
        of GposChainedContextPos:
          chains.add(parseChainContextSubst(bytes, innerOff))
          order.add((pkChain, chains.len - 1))
        else:
          continue
      except FontError:
        continue
  else:
    discard
  PosLookup(lookupType: lookupType, lookupFlag: flag,
    markFilteringSet: markSet, singlePos: singles, pairPos: pairs,
    cursivePos: cursives, markBasePos: markBases, markLigPos: markLigs,
    markMarkPos: markMarks, contextPos: ctxs, chainPos: chains,
    order: order)

proc parseGposTable*(bytes: openArray[uint8], off: int): GposData =
  if off + 10 > bytes.len:
    raise newException(FontError, "short GPOS header")
  let scriptOff = int(readU16(bytes, off + 4))
  let featureOff = int(readU16(bytes, off + 6))
  let lookupOff = int(readU16(bytes, off + 8))
  let scripts = parseScriptList(bytes, off + scriptOff)
  let features = parseFeatureList(bytes, off + featureOff)
  var lookups: seq[PosLookup] = @[]
  let lookupBase = off + lookupOff
  let lookupCount = int(readU16(bytes, lookupBase))
  if lookupBase + 2 + lookupCount * 2 > bytes.len:
    raise newException(FontError, "short LookupList")
  for i in 0 ..< lookupCount:
    let loff = int(readU16(bytes, lookupBase + 2 + i * 2))
    lookups.add(parsePosLookup(bytes, lookupBase, loff))
  GposData(scripts: scripts, features: features, lookups: lookups)

proc parseGpos*(f: SfntFont): Option[GposData] =
  let (ok, off, len) = f.tableData(TagGpos)
  if not ok or len < 10:
    return none(GposData)
  try:
    some(parseGposTable(f.bytes, off))
  except FontError:
    none(GposData)
