import std/options

import ../sfnt

type
  CoverageRange* = tuple[first, last, index: uint32]

  Coverage* = object
    glyphs*: seq[uint16]
    ranges*: seq[CoverageRange]
    present*: bool

proc noCoverage*(): Coverage =
  Coverage(glyphs: @[], ranges: @[], present: false)

proc parseCoverage*(bytes: openArray[uint8], off: int): Coverage =
  if off < 0 or off + 4 > bytes.len:
    return noCoverage()
  let format = readU16(bytes, off)
  if format == 1u16:
    let count = int(readU16(bytes, off + 2))
    if off + 4 + count * 2 > bytes.len:
      return noCoverage()
    var glyphs = newSeq[uint16](count)
    for i in 0 ..< count:
      glyphs[i] = readU16(bytes, off + 4 + i * 2)
    Coverage(glyphs: glyphs, ranges: @[], present: true)
  elif format == 2u16:
    let count = int(readU16(bytes, off + 2))
    if off + 4 + count * 6 > bytes.len:
      return noCoverage()
    var ranges = newSeq[CoverageRange](count)
    for i in 0 ..< count:
      let base = off + 4 + i * 6
      ranges[i] = (uint32(readU16(bytes, base)),
        uint32(readU16(bytes, base + 2)), uint32(readU16(bytes, base + 4)))
    Coverage(glyphs: @[], ranges: ranges, present: true)
  else:
    # TODO: coverage formats 3/4 (24-bit glyphs)
    noCoverage()

proc coverageIndex*(c: Coverage, gid: uint32): Option[uint32] =
  if not c.present or gid > 0xFFFFu32:
    return none(uint32)
  if c.glyphs.len > 0 or c.ranges.len == 0:
    let g = uint16(gid)
    var lo = 0
    var hi = c.glyphs.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      if c.glyphs[mid] < g:
        lo = mid + 1
      elif c.glyphs[mid] > g:
        hi = mid
      else:
        return some(uint32(mid))
    return none(uint32)
  var lo = 0
  var hi = c.ranges.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let r = c.ranges[mid]
    if r.last < gid:
      lo = mid + 1
    elif r.first > gid:
      hi = mid
    else:
      return some(r.index + (gid - r.first))
  none(uint32)

proc covers*(c: Coverage, gid: uint32): bool =
  c.coverageIndex(gid).isSome
