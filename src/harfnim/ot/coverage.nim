import std/options

import ../sfnt

type
  CoverageRange* = tuple[first, last, index: uint32]

  Coverage* = object
    glyphs*: seq[uint32]
    ranges*: seq[CoverageRange]
    present*: bool

  ClassRange* = tuple[first, last, classId: uint32]

  ClassDef* = object
    start*: uint32
    classes*: seq[uint32]
    ranges*: seq[ClassRange]
    isNone*: bool

proc noCoverage*(): Coverage =
  Coverage(glyphs: @[], ranges: @[], present: false)

proc noClassDef*(): ClassDef =
  ClassDef(start: 0u32, classes: @[], ranges: @[], isNone: true)

proc parseClassDef*(bytes: openArray[uint8], off: int): ClassDef =
  if off <= 0 or off + 2 > bytes.len:
    return noClassDef()
  let format = readU16(bytes, off)
  if format == 1u16:
    if off + 6 > bytes.len:
      return noClassDef()
    let start = uint32(readU16(bytes, off + 2))
    let count = int(readU16(bytes, off + 4))
    if off + 6 + count * 2 > bytes.len:
      return noClassDef()
    var cls = newSeq[uint32](count)
    for i in 0 ..< count:
      cls[i] = uint32(readU16(bytes, off + 6 + i * 2))
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
      ranges[i] = (uint32(readU16(bytes, base)),
        uint32(readU16(bytes, base + 2)), uint32(readU16(bytes, base + 4)))
    ClassDef(start: 0u32, classes: @[], ranges: ranges, isNone: false)
  elif format == 3u16:
    # 24-bit glyphs and classes: start u24, count u24, classes u24[].
    if off + 8 > bytes.len:
      return noClassDef()
    let start = readU24(bytes, off + 2)
    let count = int(readU24(bytes, off + 5))
    if count < 0 or off + 8 + count * 3 > bytes.len:
      return noClassDef()
    var cls = newSeq[uint32](count)
    for i in 0 ..< count:
      cls[i] = readU24(bytes, off + 8 + i * 3)
    ClassDef(start: start, classes: cls, ranges: @[], isNone: false)
  elif format == 4u16:
    # 24-bit ranges with 16-bit classes.
    if off + 5 > bytes.len:
      return noClassDef()
    let rangeCount = int(readU24(bytes, off + 2))
    if rangeCount < 0 or off + 5 + rangeCount * 8 > bytes.len:
      return noClassDef()
    var ranges = newSeq[ClassRange](rangeCount)
    for i in 0 ..< rangeCount:
      let base = off + 5 + i * 8
      ranges[i] = (readU24(bytes, base), readU24(bytes, base + 3),
        uint32(readU16(bytes, base + 6)))
    ClassDef(start: 0u32, classes: @[], ranges: ranges, isNone: false)
  else:
    noClassDef()

proc classOf*(c: ClassDef, gid: uint32): uint32 =
  if c.isNone or gid > 0xFFFFFFu32:
    return 0u32
  if c.classes.len > 0 or c.ranges.len == 0:
    if gid < c.start:
      return 0u32
    let idx = int(gid - c.start)
    if idx < 0 or idx >= c.classes.len:
      return 0u32
    return c.classes[idx]
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
      return r.classId
  0u32

proc parseCoverage*(bytes: openArray[uint8], off: int): Coverage =
  if off < 0 or off + 4 > bytes.len:
    return noCoverage()
  let format = readU16(bytes, off)
  if format == 1u16:
    let count = int(readU16(bytes, off + 2))
    if off + 4 + count * 2 > bytes.len:
      return noCoverage()
    var glyphs = newSeq[uint32](count)
    for i in 0 ..< count:
      glyphs[i] = uint32(readU16(bytes, off + 4 + i * 2))
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
  elif format == 3u16:
    if off + 5 > bytes.len:
      return noCoverage()
    let count = int(readU24(bytes, off + 2))
    if count < 0 or off + 5 + count * 3 > bytes.len:
      return noCoverage()
    var glyphs = newSeq[uint32](count)
    for i in 0 ..< count:
      glyphs[i] = readU24(bytes, off + 5 + i * 3)
    Coverage(glyphs: glyphs, ranges: @[], present: true)
  elif format == 4u16:
    if off + 5 > bytes.len:
      return noCoverage()
    let count = int(readU24(bytes, off + 2))
    if count < 0 or off + 5 + count * 9 > bytes.len:
      return noCoverage()
    var ranges = newSeq[CoverageRange](count)
    for i in 0 ..< count:
      let base = off + 5 + i * 9
      ranges[i] = (readU24(bytes, base), readU24(bytes, base + 3),
        readU24(bytes, base + 6))
    Coverage(glyphs: @[], ranges: ranges, present: true)
  else:
    noCoverage()

proc coverageIndexRaw*(c: Coverage, gid: uint32): int =
  ## Hot-path coverage lookup without Option overhead.
  ## Returns coverage index, or -1 on miss.
  if not c.present or gid > 0xFFFFFFu32:
    return -1
  if c.glyphs.len > 0 or c.ranges.len == 0:
    var lo = 0
    var hi = c.glyphs.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      if c.glyphs[mid] < gid:
        lo = mid + 1
      elif c.glyphs[mid] > gid:
        hi = mid
      else:
        return mid
    return -1
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
      return int(r.index + (gid - r.first))
  -1

proc coverageIndex*(c: Coverage, gid: uint32): Option[uint32] =
  let idx = c.coverageIndexRaw(gid)
  if idx < 0:
    none(uint32)
  else:
    some(uint32(idx))

proc covers*(c: Coverage, gid: uint32): bool =
  c.coverageIndexRaw(gid) >= 0
