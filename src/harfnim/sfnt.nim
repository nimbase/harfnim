import std/options

import ./buffer

type
  FontError* = object of CatchableError

  TableEntry* = object
    tag*: uint32
    offset*: int
    length*: int

  SfntFont* = object
    bytes*: seq[uint8]
    tables*: seq[TableEntry]
    unitsPerEm*: uint16
    numGlyphs*: uint16
    numHMetrics*: uint16
    locaFormat*: int16
    hasVMetrics*: bool
    numVMetrics*: uint16
    isSymbol*: bool
    cmapOffset*: int

proc tagOf(a, b, c, d: char): uint32 =
  (uint32(uint8(a)) shl 24) or (uint32(uint8(b)) shl 16) or
    (uint32(uint8(c)) shl 8) or uint32(uint8(d))

const
  TagHead = 0x68656164u32
  TagHhea = 0x68686561u32
  TagMaxp = 0x6D617870u32
  TagHmtx = 0x686D7478u32
  TagCmap = 0x636D6170u32
  TagLoca = 0x6C6F6361u32
  TagVhea = 0x76686561u32
  TagVmtx = 0x766D7478u32

proc checkBounds(bytes: seq[uint8], off, size: int) =
  if off < 0 or size < 0 or off + size > bytes.len:
    raise newException(FontError, "font data out of bounds")

proc u8at(bytes: seq[uint8], off: int): uint8 =
  checkBounds(bytes, off, 1)
  bytes[off]

proc u16be(bytes: seq[uint8], off: int): uint16 =
  checkBounds(bytes, off, 2)
  (uint16(bytes[off]) shl 8) or uint16(bytes[off + 1])

proc i16be(bytes: seq[uint8], off: int): int16 =
  cast[int16](u16be(bytes, off))

proc u24be(bytes: seq[uint8], off: int): uint32 =
  checkBounds(bytes, off, 3)
  (uint32(bytes[off]) shl 16) or (uint32(bytes[off + 1]) shl 8) or
    uint32(bytes[off + 2])

proc u32be(bytes: seq[uint8], off: int): uint32 =
  checkBounds(bytes, off, 4)
  (uint32(bytes[off]) shl 24) or (uint32(bytes[off + 1]) shl 16) or
    (uint32(bytes[off + 2]) shl 8) or uint32(bytes[off + 3])

proc findTable(f: SfntFont, tag: uint32): int =
  for i, t in f.tables:
    if t.tag == tag:
      return i
  -1

proc hasTable*(f: SfntFont, tag: uint32): bool =
  f.findTable(tag) >= 0

proc tableData*(f: SfntFont, tag: uint32): tuple[ok: bool, offset, len: int] =
  let i = f.findTable(tag)
  if i < 0:
    (false, 0, 0)
  else:
    (true, f.tables[i].offset, f.tables[i].length)

proc parseCmapSelection(bytes: seq[uint8], cmapOff: int): tuple[
    subtable: int, isSymbol: bool] =
  let numTables = int(u16be(bytes, cmapOff + 2))
  type Rec = tuple[plat, enc: uint16, off: int]
  var recs: seq[Rec] = @[]
  for i in 0 ..< numTables:
    let base = cmapOff + 4 + i * 8
    recs.add((u16be(bytes, base), u16be(bytes, base + 2),
      cmapOff + int(u32be(bytes, base + 4))))
  const pref: array[6, tuple[p, e: uint16]] = [
    (3u16, 10u16), (0u16, 4u16), (3u16, 1u16), (0u16, 3u16), (0u16, 0u16),
    (3u16, 0u16),
  ]
  for (p, e) in pref:
    for r in recs:
      if r.plat == p and r.enc == e:
        return (r.off, p == 3u16 and e == 0u16)
  (-1, false)

proc parseFontData(bytes: seq[uint8], faceIndex: int): SfntFont =
  if bytes.len < 12:
    raise newException(FontError, "font too small for offset table")
  let magic = u32be(bytes, 0)
  var fontOff = 0
  if magic == 0x74746366u32:
    let numFonts = int(u32be(bytes, 8))
    if faceIndex < 0 or faceIndex >= numFonts:
      raise newException(FontError, "face index out of range")
    fontOff = int(u32be(bytes, 12 + faceIndex * 4))
  elif magic notin [0x00010000u32, 0x4F54544Fu32, 0x74727565u32, 0x74797031u32]:
    raise newException(FontError, "not a TrueType/OpenType font")
  let numTables = int(u16be(bytes, fontOff + 4))
  if bytes.len < fontOff + 12 + numTables * 16:
    raise newException(FontError, "font too small for table directory")
  var tables: seq[TableEntry] = @[]
  for i in 0 ..< numTables:
    let base = fontOff + 12 + i * 16
    let tag = u32be(bytes, base)
    let off = fontOff + int(u32be(bytes, base + 8))
    let len = int(u32be(bytes, base + 12))
    if off < 0 or len < 0 or off + len > bytes.len:
      raise newException(FontError, "table out of bounds")
    tables.add(TableEntry(tag: tag, offset: off, length: len))
  result.bytes = bytes
  result.tables = tables
  result.cmapOffset = -1
  let head = result.tableData(TagHead)
  if not head.ok or head.len < 54:
    raise newException(FontError, "missing or short head table")
  result.unitsPerEm = u16be(bytes, head.offset + 18)
  result.locaFormat = i16be(bytes, head.offset + 50)
  let maxp = result.tableData(TagMaxp)
  if not maxp.ok or maxp.len < 6:
    raise newException(FontError, "missing or short maxp table")
  result.numGlyphs = u16be(bytes, maxp.offset + 4)
  let hhea = result.tableData(TagHhea)
  if not hhea.ok or hhea.len < 36:
    raise newException(FontError, "missing or short hhea table")
  result.numHMetrics = u16be(bytes, hhea.offset + 34)
  let vhea = result.tableData(TagVhea)
  if vhea.ok and vhea.len >= 36:
    result.hasVMetrics = true
    result.numVMetrics = u16be(bytes, vhea.offset + 34)
  let cmap = result.tableData(TagCmap)
  if cmap.ok and cmap.len >= 4:
    let (sub, sym) = parseCmapSelection(bytes, cmap.offset)
    result.cmapOffset = sub
    result.isSymbol = sym

proc parseFont*(data: openArray[uint8], faceIndex: int = 0): SfntFont =
  var bytes = newSeq[uint8](data.len)
  for i, b in data:
    bytes[i] = b
  parseFontData(bytes, faceIndex)

proc parseFontString*(data: string, faceIndex: int = 0): SfntFont =
  var bytes = newSeq[uint8](data.len)
  for i, c in data:
    bytes[i] = uint8(c)
  parseFontData(bytes, faceIndex)

proc cmapFormat4Map(bytes: seq[uint8], off: int, cp: uint32): Option[uint32] =
  if cp > 0xFFFFu32:
    return none(uint32)
  let c = uint16(cp)
  let segCount = int(u16be(bytes, off + 6)) div 2
  if segCount <= 0 or bytes.len < off + 16 + segCount * 8:
    raise newException(FontError, "short cmap format 4")
  let endBase = off + 14
  var seg = -1
  for i in 0 ..< segCount:
    if c <= u16be(bytes, endBase + i * 2):
      seg = i
      break
  if seg < 0:
    return none(uint32)
  let startBase = endBase + segCount * 2 + 2
  let start = u16be(bytes, startBase + seg * 2)
  if c < start:
    return none(uint32)
  let delta = i16be(bytes, startBase + segCount * 2 + seg * 2)
  let rangeBase = startBase + segCount * 4
  let rangeOff = u16be(bytes, rangeBase + seg * 2)
  var gid: uint32
  if rangeOff == 0u16:
    gid = (uint32(c) + uint32(int32(delta))) and 0xFFFFu32
  else:
    let p = rangeBase + seg * 2 + int(rangeOff) + int(c - start) * 2
    let raw = u16be(bytes, p)
    if raw == 0u16:
      return none(uint32)
    gid = (uint32(raw) + uint32(int32(delta))) and 0xFFFFu32
  if gid == 0u32:
    none(uint32)
  else:
    some(gid)

proc cmapFormat12Map(bytes: seq[uint8], off: int, cp: uint32): Option[uint32] =
  let numGroups = int(u32be(bytes, off + 12))
  if bytes.len < off + 16 + numGroups * 12:
    raise newException(FontError, "short cmap format 12/13")
  let is12 = u16be(bytes, off) == 12u16
  var lo = 0
  var hi = numGroups
  while lo < hi:
    let mid = (lo + hi) shr 1
    let base = off + 16 + mid * 12
    let first = u32be(bytes, base)
    let last = u32be(bytes, base + 4)
    if cp < first:
      hi = mid
    elif cp > last:
      lo = mid + 1
    else:
      let glyph = u32be(bytes, base + 8)
      if is12:
        let gid = glyph + (cp - first)
        return if gid == 0u32: none(uint32) else: some(gid)
      else:
        return if glyph == 0u32: none(uint32) else: some(glyph)
  none(uint32)

proc cmapMapUncached(f: SfntFont, cp: uint32): Option[uint32] =
  if f.cmapOffset < 0:
    return none(uint32)
  let bytes = f.bytes
  let off = f.cmapOffset
  let format = u16be(bytes, off)
  case format
  of 0u16:
    if cp > 0xFFu32 or bytes.len < off + 262:
      return none(uint32)
    let gid = uint32(u8at(bytes, off + 6 + int(cp)))
    if gid == 0u32: none(uint32) else: some(gid)
  of 4u16:
    cmapFormat4Map(bytes, off, cp)
  of 6u16:
    let first = uint32(u16be(bytes, off + 8))
    let count = int(u16be(bytes, off + 10))
    if cp < first or cp - first >= uint32(count):
      return none(uint32)
    if bytes.len < off + 12 + count * 2:
      raise newException(FontError, "short cmap format 6")
    let gid = uint32(u16be(bytes, off + 12 + int(cp - first) * 2))
    if gid == 0u32: none(uint32) else: some(gid)
  of 10u16:
    let first = u32be(bytes, off + 8)
    let count = int(u32be(bytes, off + 12))
    if cp < first or cp - first >= uint32(count):
      return none(uint32)
    if bytes.len < off + 16 + count * 2:
      raise newException(FontError, "short cmap format 10")
    let gid = uint32(u16be(bytes, off + 16 + int(cp - first) * 2))
    if gid == 0u32: none(uint32) else: some(gid)
  of 12u16, 13u16:
    cmapFormat12Map(bytes, off, cp)
  else:
    none(uint32)

proc mapUnicode*(f: SfntFont, cp: uint32): Option[GlyphId] =
  let direct = cmapMapUncached(f, cp)
  if direct.isSome:
    return some(newGlyphId(direct.get))
  if f.isSymbol and cp < 0x100u32:
    let shifted = cmapMapUncached(f, cp + 0xF000u32)
    if shifted.isSome:
      return some(newGlyphId(shifted.get))
  # TODO: legacy Arabic PUA pages (0xB200/0xB300) with arabic shaper tables
  none(GlyphId)

proc hAdvanceRaw(f: SfntFont, gid: uint32): tuple[adv: uint16, lsb: int16] =
  let hmtx = f.tableData(TagHmtx)
  if not hmtx.ok:
    raise newException(FontError, "missing hmtx table")
  let bytes = f.bytes
  let n = int(f.numHMetrics)
  let g = int(gid)
  if n <= 0:
    raise newException(FontError, "no horizontal metrics")
  if g < n:
    let base = hmtx.offset + g * 4
    (u16be(bytes, base), i16be(bytes, base + 2))
  else:
    let base = hmtx.offset + (n - 1) * 4
    let adv = u16be(bytes, base)
    let lsbOff = hmtx.offset + n * 4 + (g - n) * 2
    let lsb =
      if lsbOff + 2 <= hmtx.offset + hmtx.len: i16be(bytes, lsbOff)
      else: 0i16
    (adv, lsb)

proc hAdvance*(f: SfntFont, gid: uint32): int32 =
  int32(hAdvanceRaw(f, gid).adv)

proc hSideBearing*(f: SfntFont, gid: uint32): int32 =
  int32(hAdvanceRaw(f, gid).lsb)

proc vAdvance*(f: SfntFont, gid: uint32): int32 =
  if f.hasVMetrics:
    let vmtx = f.tableData(TagVmtx)
    if vmtx.ok:
      let n = int(f.numVMetrics)
      let g = int(gid)
      if n > 0:
        if g < n:
          return int32(u16be(f.bytes, vmtx.offset + g * 4))
        return int32(u16be(f.bytes, vmtx.offset + (n - 1) * 4))
  int32(f.unitsPerEm)

proc numFaces*(data: openArray[uint8]): int =
  if data.len < 12:
    raise newException(FontError, "font too small")
  var magic = (uint32(data[0]) shl 24) or (uint32(data[1]) shl 16) or
    (uint32(data[2]) shl 8) or uint32(data[3])
  if magic == 0x74746366u32:
    if data.len < 12:
      raise newException(FontError, "font too small")
    int((uint32(data[8]) shl 24) or (uint32(data[9]) shl 16) or
      (uint32(data[10]) shl 8) or uint32(data[11]))
  else:
    1
