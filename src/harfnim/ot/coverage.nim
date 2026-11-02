import std/options

import ../sfnt

type
  CoverageRange* = tuple[first, last, index: uint32]

  Coverage* = object
    glyphs*: seq[uint16]
    ranges*: seq[CoverageRange]
    present*: bool

  ClassRange* = tuple[first, last, classId: uint16]

  ClassDef* = object
    start*: uint16
    classes*: seq[uint16]
    ranges*: seq[ClassRange]
    isNone*: bool

proc noCoverage*(): Coverage =
  Coverage(glyphs: @[], ranges: @[], present: false)

proc noClassDef*(): ClassDef =
  ClassDef(start: 0u16, classes: @[], ranges: @[], isNone: true)

proc parseClassDef*(bytes: openArray[uint8], off: int): ClassDef =
  if off <= 0 or off + 2 > bytes.len:
    return noClassDef()
  let format = readU16(bytes, off)
  if format == 1u16:
    if off + 6 > bytes.len:
      return noClassDef()
    let start = readU16(bytes, off + 2)
    let count = int(readU16(bytes, off + 4))
    if off + 6 + count * 2 > bytes.len:
      return noClassDef()
    var cls = newSeq[uint16](count)
    for i in 0 ..< count:
      cls[i] = readU16(bytes, off + 6 + i * 2)
    ClassDef(start: start, classes: cls, ranges: @[], isNone: false)
  elif format == 2u16:
    if off + 4 > bytes.len:
      return noClassDef()
    let rangeCount = int(readU16(bytes, off + 2))
    if off + 4 + rangeCount * 6 > bytes.len:
      return noClassDef()
    var ranges = newSeq[ClassRange](rangeCount)
    for i in 0 ..< rangeCount:
      let base = off + 4 + i * 6
      ranges[i] = (readU16(bytes, base), readU16(bytes, base + 2),
        readU16(bytes, base + 4))
    ClassDef(start: 0u16, classes: @[], ranges: ranges, isNone: false)
  else:
    # TODO: ClassDef formats 3/4 (24-bit glyphs)
    noClassDef()

proc classOf*(c: ClassDef, gid: uint32): uint32 =
  if c.isNone or gid > 0xFFFFu32:
    return 0u32
  let g = uint16(gid)
  if c.classes.len > 0 or c.ranges.len == 0:
    let idx = int(g) - int(c.start)
    if idx < 0 or idx >= c.classes.len:
      return 0u32
    return uint32(c.classes[idx])
  var lo = 0
  var hi = c.ranges.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let r = c.ranges[mid]
    if r.last < g:
      lo = mid + 1
    elif r.first > g:
      hi = mid
    else:
      return uint32(r.classId)
  0u32

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
