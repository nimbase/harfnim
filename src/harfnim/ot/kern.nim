## Legacy `kern` table (TrueType kerning), ported from harfrust
## `aat/kern.rs` at static-font scope.
##
## Supports format 0 pair kerning in both the MS (table version 0) and
## Apple (table version 1) layouts. State-machine (format 1),
## class-based (formats 2/3), cross-stream, and tuple-variation
## subtables are skipped with TODO. Wide (24-bit) formats are deferred.

import std/options

import ../sfnt

export sfnt

type
  KernPair* = tuple[left, right: uint16, value: int32]
    ## One kerning pair with its adjustment.

  KernSubtable* = object
    ## Format 0 kerning subtable.
    horizontal*: bool
    ## True for horizontal text.
    crossStream*: bool
    ## True for cross stream kerning.
    pairs*: seq[KernPair]
    ## Sorted kerning pairs.

  KernData* = object
    ## Parsed kern table.
    subtables*: seq[KernSubtable]
    ## Format 0 subtables.

const TagKern = 0x6B65726Eu32
    # kern table tag.

proc parseKernPairs(bytes: openArray[uint8], off, count,
    tableEnd: int): seq[KernPair] =
  # Parses and sorts one pair array.
  result = @[]
  if off < 0 or count < 0 or off + count * 6 > tableEnd or
      off + count * 6 > bytes.len:
    raise newException(FontError, "short kern pair array")
  for i in 0 ..< count:
    let base = off + i * 6
    result.add((readU16(bytes, base), readU16(bytes, base + 2),
      int32(readI16(bytes, base + 4))))
  # Keep pairs sorted for binary search; stable for well-formed fonts.
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i
    while j > 0 and (result[j - 1].left, result[j - 1].right) >
        (cur.left, cur.right):
      result[j] = result[j - 1]
      dec j
    result[j] = cur

proc kernValueAt*(sub: KernSubtable, left, right: uint32): int32 =
  ## Binary searches the pair value; zero on miss.
  if left > 0xFFFFu32 or right > 0xFFFFu32 or sub.pairs.len == 0:
    return 0i32
  let l = uint16(left)
  let r = uint16(right)
  var lo = 0
  var hi = sub.pairs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let p = sub.pairs[mid]
    if (p.left, p.right) < (l, r):
      lo = mid + 1
    elif (p.left, p.right) > (l, r):
      hi = mid
    else:
      return p.value
  0i32

proc parseKernTable*(bytes: openArray[uint8], off: int): KernData =
  ## Parses MS and Apple kern layouts, skipping other formats.
  if off + 4 > bytes.len:
    raise newException(FontError, "short kern header")
  let v0 = readU16(bytes, off)
  var nTables = 0
  var pos = off
  var apple = false
  if v0 == 0u16:
    nTables = int(readU16(bytes, off + 2))
    pos = off + 4
  elif v0 == 1u16:
    # Apple layout: version is 0x00010000, then a u32 table count.
    if readU16(bytes, off + 2) != 0u16:
      raise newException(FontError, "unsupported kern version")
    nTables = int(readU32(bytes, off + 4))
    pos = off + 8
    apple = true
  else:
    raise newException(FontError, "unsupported kern version")
  result = KernData(subtables: @[])
  for _ in 0 ..< nTables:
    if apple:
      if pos + 8 > bytes.len:
        break
      let length = int(readU32(bytes, pos))
      if length < 8 or pos + length > bytes.len:
        break
      let coverage = bytes[pos + 4]
      let format = bytes[pos + 5]
      let tupleIndex = readU16(bytes, pos + 6)
      if tupleIndex != 0u16 or format != 0u8:
        # TODO: tuple variations and formats 1/2/3.
        pos += length
        continue
      # Apple coverage bit 0 is inverted versus MS: 0 means horizontal.
      let horizontal = (coverage and 1u8) == 0u8
      let cross = (coverage and 2u8) != 0u8
      if pos + 16 > bytes.len:
        pos += length
        continue
      let nPairs = int(readU16(bytes, pos + 8))
      try:
        let pairs = parseKernPairs(bytes, pos + 16, nPairs, pos + length)
        result.subtables.add(KernSubtable(horizontal: horizontal,
          crossStream: cross, pairs: pairs))
      except FontError:
        discard
      pos += length
    else:
      if pos + 6 > bytes.len:
        break
      let sver = readU16(bytes, pos)
      let length = int(readU16(bytes, pos + 2))
      if length < 6 or pos + length > bytes.len:
        break
      if sver != 0u16:
        pos += length
        continue
      let format = bytes[pos + 4]
      let coverage = bytes[pos + 5]
      if format != 0u8:
        # TODO: formats 1/2/3.
        pos += length
        continue
      let horizontal = (coverage and 1u8) != 0u8
      let cross = (coverage and 4u8) != 0u8
      if pos + 14 > bytes.len:
        pos += length
        continue
      let nPairs = int(readU16(bytes, pos + 6))
      try:
        let pairs = parseKernPairs(bytes, pos + 14, nPairs, pos + length)
        result.subtables.add(KernSubtable(horizontal: horizontal,
          crossStream: cross, pairs: pairs))
      except FontError:
        discard
      pos += length

proc parseKern*(f: SfntFont): Option[KernData] =
  ## Parses the kern table, none when absent or malformed.
  let (ok, off, len) = f.tableData(TagKern)
  if not ok or len < 4:
    return none(KernData)
  try:
    some(parseKernTable(f.bytes, off))
  except FontError:
    none(KernData)
