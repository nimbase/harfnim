## Item variation store and delta-set index maps (HVAR/VVAR).
##
## Parses the shared `ItemVariationStore` (regions + delta sets) and
## the per-glyph `DeltaSetIndexMap`s that HVAR/VVAR use for advance
## adjustments, and evaluates deltas at normalized coordinates.
## Malformed data yields `ok == false` (contained); the font then
## behaves as static. Only advance maps are consumed for now
## (LSB/RSB/TSB/BSB side-bearing maps are a follow-up).

type
  VarRegion* = tuple[start, peak, finish: float64]

  VarData* = object
    ## One item variation data block.
    regionIndexes*: seq[int]
    ## Region indexes.
    deltas*: seq[seq[int32]]
    ## Delta rows.

  VarStore* = object
    ## Parsed item variation store.
    ok*: bool
    ## True when parsing succeeded.
    ## Per region, the per-axis triples.
    regions*: seq[seq[VarRegion]]
    ## Variation regions.
    datas*: seq[VarData]
    ## Variation data blocks.

  DeltaSetIndexMap* = object
    ## Delta set index mapping.
    ok*: bool
    ## True when parsing succeeded.
    entries*: seq[uint32]
    ## Packed outer and inner indexes.

const NoVariationIndex* = 0xFFFFFFFFu32

type
  Cursor = object
    # Bounded variation store cursor.
    bytes: seq[uint8]
    # Input bytes.
    pos: int
    # Read offset.
    limit: int
    # Valid end offset.
    failed: bool
    # True once a read overruns.

proc need(c: var Cursor, n: int): bool =
  # Advances the cursor, failing on overrun.
  if c.failed or n < 0 or c.pos + n > c.limit or
      c.pos + n > c.bytes.len:
    c.failed = true
    return false
  true

proc u8(c: var Cursor): uint8 =
  # Reads one byte.
  if not c.need(1):
    return 0u8
  result = c.bytes[c.pos]
  inc c.pos

proc u16(c: var Cursor): uint16 =
  # Reads a big endian uint16.
  let hi = uint16(c.u8())
  let lo = uint16(c.u8())
  if c.failed:
    0u16
  else:
    (hi shl 8) or lo

proc i16(c: var Cursor): int16 =
  # Reads a big endian int16.
  cast[int16](c.u16())

proc i8(c: var Cursor): int8 =
  # Reads a signed byte.
  cast[int8](c.u8())

proc u24(c: var Cursor): uint32 =
  # Reads a big endian uint24.
  let a = uint32(c.u8())
  let b = uint32(c.u8())
  let d = uint32(c.u8())
  if c.failed:
    0u32
  else:
    (a shl 16) or (b shl 8) or d

proc u32(c: var Cursor): uint32 =
  # Reads a big endian uint32.
  let a = uint32(c.u8())
  let b = uint32(c.u8())
  let d = uint32(c.u8())
  let e = uint32(c.u8())
  if c.failed:
    0u32
  else:
    (a shl 24) or (b shl 16) or (d shl 8) or e

proc i32(c: var Cursor): int32 =
  # Reads a big endian int32.
  cast[int32](c.u32())

proc parseVarStoreInner(bytes: seq[uint8], off, len: int,
    topLevel: bool): VarStore =
  ## Shared body: top-level `VarStore` starts with a 4-byte version,
  ## embedded `ItemVariationStore` with a 2-byte format (= 1).
  result.ok = false
  if off < 0 or len < 8 or off + len > bytes.len:
    return
  var c = Cursor(bytes: bytes, pos: off, limit: off + len)
  if topLevel:
    discard c.u16()
    discard c.u16()
  else:
    if c.u16() != 1u16:
      return
  let regionListOff = int(c.u32())
  let dataCount = int(c.u16())
  if c.failed or dataCount < 0:
    return
  var dataOffs = newSeq[int](dataCount)
  for i in 0 ..< dataCount:
    dataOffs[i] = off + int(c.u16())
    if c.failed:
      return
  # Region list: axis count, region count, then per-region per-axis
  # (start, peak, end) F2DOT14 triples.
  let rBase = off + regionListOff
  if regionListOff < 0 or rBase + 4 > off + len or rBase + 4 > bytes.len:
    return
  var r = Cursor(bytes: bytes, pos: rBase, limit: off + len)
  let regionAxisCount = int(r.u16())
  let regionCount = int(r.u16())
  if r.failed or regionAxisCount < 0 or regionCount < 0:
    return
  if regionAxisCount > 0 and rBase + 4 + regionCount * regionAxisCount * 6 >
      off + len:
    return
  if regionAxisCount > 0 and rBase + 4 + regionCount * regionAxisCount * 6 >
      bytes.len:
    return
  var regions = newSeq[seq[VarRegion]](regionCount)
  for i in 0 ..< regionCount:
    var axes = newSeq[VarRegion](regionAxisCount)
    for a in 0 ..< regionAxisCount:
      let s = float64(r.i16()) / 16384.0
      let p = float64(r.i16()) / 16384.0
      let e = float64(r.i16()) / 16384.0
      if r.failed:
        return
      axes[a] = (s, p, e)
    regions[i] = axes
  # Item variation data subtables.
  var datas = newSeq[VarData](dataCount)
  for d in 0 ..< dataCount:
    let dBase = dataOffs[d]
    if dBase < off or dBase + 6 > off + len or dBase + 6 > bytes.len:
      return
    var v = Cursor(bytes: bytes, pos: dBase, limit: off + len)
    let itemCount = int(v.u16())
    let numShortsRaw = v.u16()
    let regionIndexCount = int(v.u16())
    if v.failed or itemCount < 0 or regionIndexCount < 0:
      return
    let longWords = (numShortsRaw and 0x8000u16) != 0u16
    let wordCount = int(numShortsRaw and 0x7FFFu16)
    let bigSize = if longWords: 4 else: 2
    let smallSize = if longWords: 2 else: 1
    let n1 = min(regionIndexCount, wordCount)
    if dBase + 6 + regionIndexCount * 2 +
        itemCount * (n1 * bigSize + (regionIndexCount - n1) * smallSize) >
        off + len:
      return
    var ridx = newSeq[int](regionIndexCount)
    for i in 0 ..< regionIndexCount:
      ridx[i] = int(v.u16())
      if v.failed:
        return
      if ridx[i] < 0 or ridx[i] >= regionCount:
        return
    var rows = newSeq[seq[int32]](itemCount)
    for i in 0 ..< itemCount:
      var row = newSeq[int32](regionIndexCount)
      for k in 0 ..< n1:
        if longWords:
          row[k] = v.i32()
        else:
          row[k] = int32(v.i16())
        if v.failed:
          return
      for k in n1 ..< regionIndexCount:
        if longWords:
          row[k] = int32(v.i16())
        else:
          row[k] = int32(v.i8())
        if v.failed:
          return
      rows[i] = row
    datas[d] = VarData(regionIndexes: ridx, deltas: rows)
  result = VarStore(ok: true, regions: regions, datas: datas)

proc parseItemVariationStore*(bytes: seq[uint8], off, len: int): VarStore =
  ## Parses an item variation store, yielding empty on bad input.
  parseVarStoreInner(bytes, off, len, false)

proc parseVarStore*(bytes: seq[uint8], off, len: int): VarStore =
  ## Parses a variation store, yielding empty on bad input.
  parseVarStoreInner(bytes, off, len, true)

proc parseDeltaSetIndexMap*(bytes: seq[uint8], off, len: int): DeltaSetIndexMap =
  ## Parses a `DeltaSetIndexMap` (formats 0/1, 8-bit format tag).
  ## Entry decoding follows the packed outer/inner rule with an
  ## 0xFFFFFFFF no-variation sentinel.
  result.ok = false
  if off < 0 or len < 2 or off + len > bytes.len:
    return
  let format = bytes[off]
  if format != 0u8 and format != 1u8:
    return
  var c = Cursor(bytes: bytes, pos: off + 1, limit: off + len)
  let entryFormat = c.u8()
  var mapCount = 0
  if format == 0u8:
    mapCount = int(c.u16())
  else:
    mapCount = int(c.u32())
  if c.failed or mapCount < 0:
    return
  let innerBits = 1 + int(entryFormat and 0x0Fu8)
  if innerBits < 1 or innerBits > 16:
    return
  let innerMask = (1u32 shl innerBits) - 1u32
  let outerShift = 16 - innerBits
  let entrySize = 1 + (int(entryFormat and 0x30u8) shr 4)
  if entrySize < 1 or entrySize > 4:
    return
  if c.pos + mapCount * entrySize > off + len or
      c.pos + mapCount * entrySize > bytes.len:
    return
  var entries = newSeq[uint32](mapCount)
  for i in 0 ..< mapCount:
    var raw = 0u32
    for k in 0 ..< entrySize:
      raw = (raw shl 8) or uint32(c.u8())
    if c.failed:
      return
    let inner = raw and innerMask
    let outer = raw and (not innerMask)
    entries[i] = (outer shl outerShift) or inner
  result = DeltaSetIndexMap(ok: true, entries: entries)

proc mapVarIndex*(m: DeltaSetIndexMap, gid: int): uint32 =
  ## Glyph id to packed variation index; out-of-range glyphs and
  ## malformed maps yield the no-variation sentinel.
  if not m.ok or gid < 0 or gid >= m.entries.len:
    return NoVariationIndex
  m.entries[gid]

proc regionScalar*(region: seq[VarRegion],
    coords: openArray[float32]): float64 =
  ## Per-region scalar: product over axes of the OT support factor.
  result = 1.0
  for a, triple in region:
    let (lower, peak, upper) = triple
    if peak == 0.0:
      continue
    if lower > peak or peak > upper:
      continue
    if lower < 0.0 and upper > 0.0:
      continue
    var v = 0.0
    if a < coords.len:
      v = float64(coords[a])
    if v == peak:
      continue
    if v <= lower or upper <= v:
      return 0.0
    if v < peak:
      result *= (v - lower) / (peak - lower)
    else:
      result *= (v - upper) / (peak - upper)

proc deltaFor*(store: VarStore, varIdx: uint32,
    coords: openArray[float32]): int32 =
  ## Evaluates a packed (outer << 16 | inner) variation index.
  if not store.ok or varIdx == NoVariationIndex:
    return 0i32
  let outer = int(varIdx shr 16)
  let inner = int(varIdx and 0xFFFFu32)
  if outer < 0 or outer >= store.datas.len:
    return 0i32
  let data = store.datas[outer]
  if inner < 0 or inner >= data.deltas.len:
    return 0i32
  let row = data.deltas[inner]
  var total = 0.0
  for k, ridx in data.regionIndexes:
    if ridx < 0 or ridx >= store.regions.len:
      continue
    total += regionScalar(store.regions[ridx], coords) * float64(row[k])
  if total > float64(high(int32)):
    return high(int32)
  if total < float64(low(int32)):
    return low(int32)
  if total >= 0.0:
    int32(total + 0.5)
  else:
    int32(total - 0.5)
