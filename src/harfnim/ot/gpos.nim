## GPOS positioning tables, ported from harfrust `ot/lookup/gpos.rs`.
##
## Scope: static (non-variable) fonts. ValueRecord device tables and
## variation deltas are skipped (TODO); anchors ignore contour points and
## device tables (TODO). Mark-to-base/mark-to-ligature/mark-to-mark,
## cursive, contextual positioning, and wide (24-bit) formats are deferred
## with TODO. Extension (type 9) flattens inner SinglePos/PairPos.

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
    pkOther

  PosLookupEntry* = tuple[kind: GposLookupKind, index: int]

  PosLookup* = object
    lookupType*: uint16
    lookupFlag*: uint16
    markFilteringSet*: uint16
    singlePos*: seq[SinglePos]
    pairPos*: seq[PairPos]
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
        else:
          # TODO: cursive, marks, contextual positioning
          continue
      except FontError:
        continue
  else:
    # TODO: cursive (3), marks (4/5/6), contextual (7/8) positioning
    discard
  PosLookup(lookupType: lookupType, lookupFlag: flag,
    markFilteringSet: markSet, singlePos: singles, pairPos: pairs,
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
