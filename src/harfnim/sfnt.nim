import std/options

import ./buffer
import ./draw
import ./glyf
import ./cff

type
  FontError* = object of CatchableError

  TableEntry* = object
    tag*: uint32
    offset*: int
    length*: int

  NameEntry* = object
    platformID*: uint16
    encodingID*: uint16
    languageID*: uint16
    nameID*: uint16
    bytes*: seq[uint8]

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
    cmap14Offset*: int
    names*: seq[NameEntry]

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
  TagGlyf = 0x676C7966u32
  TagVhea = 0x76686561u32
  TagVmtx = 0x766D7478u32
  TagCff = 0x43464620u32
  TagName = 0x6E616D65u32

proc checkBounds(bytes: openArray[uint8], off, size: int) =
  if off < 0 or size < 0 or off + size > bytes.len:
    raise newException(FontError, "font data out of bounds")

proc u8at(bytes: openArray[uint8], off: int): uint8 =
  checkBounds(bytes, off, 1)
  bytes[off]

proc readU16*(bytes: openArray[uint8], off: int): uint16 =
  checkBounds(bytes, off, 2)
  (uint16(bytes[off]) shl 8) or uint16(bytes[off + 1])

proc readI16*(bytes: openArray[uint8], off: int): int16 =
  cast[int16](readU16(bytes, off))

proc readU32*(bytes: openArray[uint8], off: int): uint32 =
  checkBounds(bytes, off, 4)
  (uint32(bytes[off]) shl 24) or (uint32(bytes[off + 1]) shl 16) or
    (uint32(bytes[off + 2]) shl 8) or uint32(bytes[off + 3])

proc readU24*(bytes: openArray[uint8], off: int): uint32 =
  checkBounds(bytes, off, 3)
  (uint32(bytes[off]) shl 16) or (uint32(bytes[off + 1]) shl 8) or
    uint32(bytes[off + 2])

proc readI24*(bytes: openArray[uint8], off: int): int32 =
  let u = readU24(bytes, off)
  if (u and 0x800000u32) != 0u32:
    int32(u or 0xFF000000u32)
  else:
    int32(u)

proc readOffset24*(bytes: openArray[uint8], off: int): int =
  int(readU24(bytes, off))

proc readOffset32*(bytes: openArray[uint8], off: int): int =
  int(readU32(bytes, off))

proc u16be(bytes: seq[uint8], off: int): uint16 {.used.} =
  readU16(bytes, off)

proc i16be(bytes: seq[uint8], off: int): int16 {.used.} =
  readI16(bytes, off)

proc u24be(bytes: seq[uint8], off: int): uint32 {.used.} =
  checkBounds(bytes, off, 3)
  (uint32(bytes[off]) shl 16) or (uint32(bytes[off + 1]) shl 8) or
    uint32(bytes[off + 2])

proc u32be(bytes: seq[uint8], off: int): uint32 {.used.} =
  readU32(bytes, off)

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

proc findCmap14Offset(bytes: seq[uint8], cmapOff: int): int =
  ## Absolute offset of the first format 14 (UVS) subtable, or -1.
  ## Malformed entries are skipped; never raises beyond the caller's
  ## bounds checking.
  if cmapOff < 0 or cmapOff + 4 > bytes.len:
    return -1
  let numTables = int(readU16(bytes, cmapOff + 2))
  if cmapOff + 4 + numTables * 8 > bytes.len:
    return -1
  for i in 0 ..< numTables:
    let base = cmapOff + 4 + i * 8
    let sub = cmapOff + int(readU32(bytes, base + 4))
    if sub < 0 or sub + 2 > bytes.len:
      continue
    if readU16(bytes, sub) == 14u16:
      return sub
  -1

proc readU24At(bytes: seq[uint8], off: int): uint32 =
  (uint32(bytes[off]) shl 16) or (uint32(bytes[off + 1]) shl 8) or
    uint32(bytes[off + 2])

proc cmap14VariantUncached(bytes: seq[uint8], sub: int, base,
    selector: uint32, numGlyphs: uint16,
    nominal: Option[uint32]): Option[uint32] =
  ## Resolves one (base, selector) pair through a format 14 subtable.
  ## Non-default mappings win; default ranges fall back to the nominal
  ## glyph. Malformed data yields none (contained, like other cmap
  ## lookups) rather than raising.
  if sub < 0 or sub + 10 > bytes.len:
    return none(uint32)
  if readU16(bytes, sub) != 14u16:
    return none(uint32)
  let length = int(readU32(bytes, sub + 2))
  if length < 10 or sub + length > bytes.len:
    return none(uint32)
  let numRecords = int(readU32(bytes, sub + 6))
  if numRecords < 0 or sub + 10 + numRecords * 11 > sub + length:
    return none(uint32)
  # Records are sorted by selector; binary search them.
  var lo = 0
  var hi = numRecords
  var found = -1
  while lo < hi:
    let mid = (lo + hi) shr 1
    let sel = readU24At(bytes, sub + 10 + mid * 11)
    if sel < selector:
      lo = mid + 1
    elif sel > selector:
      hi = mid
    else:
      found = mid
      break
  if found < 0:
    return none(uint32)
  let recOff = sub + 10 + found * 11
  let defaultOff = int(readU32(bytes, recOff + 3))
  let nonDefaultOff = int(readU32(bytes, recOff + 7))
  if nonDefaultOff != 0:
    let t = sub + nonDefaultOff
    if t >= sub and t + 4 <= sub + length and t + 4 <= bytes.len:
      let numMappings = int(readU32(bytes, t))
      if numMappings >= 0 and t + 4 + numMappings * 5 <= sub + length and
          t + 4 + numMappings * 5 <= bytes.len:
        var l2 = 0
        var h2 = numMappings
        while l2 < h2:
          let m2 = (l2 + h2) shr 1
          let u = readU24At(bytes, t + 4 + m2 * 5)
          if u < base:
            l2 = m2 + 1
          elif u > base:
            h2 = m2
          else:
            let gid = readU16(bytes, t + 4 + m2 * 5 + 3)
            if gid == 0u16 or uint32(gid) >= uint32(numGlyphs):
              return none(uint32)
            return some(uint32(gid))
  if defaultOff != 0:
    let t = sub + defaultOff
    if t >= sub and t + 4 <= sub + length and t + 4 <= bytes.len:
      let numRanges = int(readU32(bytes, t))
      if numRanges >= 0 and t + 4 + numRanges * 4 <= sub + length and
          t + 4 + numRanges * 4 <= bytes.len:
        var l3 = 0
        var h3 = numRanges
        while l3 < h3:
          let m3 = (l3 + h3) shr 1
          let s = readU24At(bytes, t + 4 + m3 * 4)
          let e = s + uint32(bytes[t + 4 + m3 * 4 + 3])
          if base < s:
            h3 = m3
          elif base > e:
            l3 = m3 + 1
          else:
            return nominal
  none(uint32)

proc parseNameRecords(bytes: seq[uint8], tableOff, tableLen: int): seq[
    NameEntry] =
  ## Parses the `name` table directory. Format 0 and 1 share the same
  ## record layout; language-tag data after the records is ignored.
  ## Malformed tables yield an empty list (contained).
  result = @[]
  if tableOff < 0 or tableLen < 6 or tableOff + tableLen > bytes.len:
    return
  let format = readU16(bytes, tableOff)
  if format > 1u16:
    return
  let count = int(readU16(bytes, tableOff + 2))
  let stringOffset = int(readU16(bytes, tableOff + 4))
  if stringOffset < 0 or stringOffset > tableLen:
    return
  if tableOff + 6 + count * 12 > tableOff + tableLen:
    return
  if tableOff + 6 + count * 12 > bytes.len:
    return
  let storage = tableOff + stringOffset
  for i in 0 ..< count:
    let base = tableOff + 6 + i * 12
    let length = int(readU16(bytes, base + 8))
    let strOff = int(readU16(bytes, base + 10))
    if strOff < 0 or length < 0 or strOff + length > tableLen - stringOffset:
      continue
    if storage + strOff + length > bytes.len:
      continue
    var raw = newSeq[uint8](length)
    for k in 0 ..< length:
      raw[k] = bytes[storage + strOff + k]
    result.add(NameEntry(platformID: readU16(bytes, base),
      encodingID: readU16(bytes, base + 2),
      languageID: readU16(bytes, base + 4),
      nameID: readU16(bytes, base + 6), bytes: raw))

proc decodeNameUtf16Be(raw: seq[uint8]): string =
  ## Decodes UTF-16BE (Windows/Unicode platform strings) as UTF-8,
  ## using replacement characters for malformed units.
  result = ""
  var i = 0
  while i + 1 < raw.len:
    let u = (uint32(raw[i]) shl 8) or uint32(raw[i + 1])
    i += 2
    var cp = u
    if cp >= 0xD800u32 and cp <= 0xDBFFu32 and i + 1 < raw.len:
      let lo = (uint32(raw[i]) shl 8) or uint32(raw[i + 1])
      if lo >= 0xDC00u32 and lo <= 0xDFFFu32:
        cp = 0x10000u32 + ((cp - 0xD800u32) shl 10) + (lo - 0xDC00u32)
        i += 2
    if cp < 0x80u32:
      result.add(char(cp))
    elif cp < 0x800u32:
      result.add(char(0xC0u32 or (cp shr 6)))
      result.add(char(0x80u32 or (cp and 0x3Fu32)))
    elif cp < 0x10000u32:
      result.add(char(0xE0u32 or (cp shr 12)))
      result.add(char(0x80u32 or ((cp shr 6) and 0x3Fu32)))
      result.add(char(0x80u32 or (cp and 0x3Fu32)))
    elif cp <= 0x10FFFFu32:
      result.add(char(0xF0u32 or (cp shr 18)))
      result.add(char(0x80u32 or ((cp shr 12) and 0x3Fu32)))
      result.add(char(0x80u32 or ((cp shr 6) and 0x3Fu32)))
      result.add(char(0x80u32 or (cp and 0x3Fu32)))
    else:
      result.add("\xEF\xBF\xBD")

proc decodeNameBytes*(e: NameEntry): string =
  ## Decodes a name record to UTF-8. Unicode/Windows platforms are
  ## UTF-16BE; other platforms fall back to a Latin-1 pass-through
  ## (TODO: Mac Roman table).
  if e.platformID == 0u16 or e.platformID == 3u16:
    result = decodeNameUtf16Be(e.bytes)
  else:
    result = ""
    for b in e.bytes:
      let cp = uint32(b)
      if cp < 0x80u32:
        result.add(char(cp))
      else:
        result.add(char(0xC0u32 or (cp shr 6)))
        result.add(char(0x80u32 or (cp and 0x3Fu32)))

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
    # Table offsets are from the start of the file, even inside a TTC.
    let off = int(u32be(bytes, base + 8))
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
    result.cmap14Offset = findCmap14Offset(bytes, cmap.offset)
  else:
    result.cmap14Offset = -1
  let name = result.tableData(TagName)
  if name.ok:
    result.names = parseNameRecords(bytes, name.offset, name.len)
  else:
    result.names = @[]

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

proc mapUnicodeVariant*(f: SfntFont, base,
    selector: uint32): Option[GlyphId] =
  ## Maps a (base, variation selector) pair through cmap format 14.
  ## Default UVS entries resolve to the nominal glyph; non-default
  ## entries resolve to their mapped glyph. Returns none when the font
  ## has no format 14 subtable or the sequence is not covered.
  if f.cmap14Offset < 0:
    return none(GlyphId)
  let nominal =
    block:
      let d = cmapMapUncached(f, base)
      if d.isSome: some(d.get)
      elif f.isSymbol and base < 0x100u32:
        cmapMapUncached(f, base + 0xF000u32)
      else: none(uint32)
  let gid = cmap14VariantUncached(f.bytes, f.cmap14Offset, base, selector,
    f.numGlyphs, nominal)
  if gid.isNone:
    return none(GlyphId)
  some(newGlyphId(gid.get))

proc fontName*(f: SfntFont, nameID: uint16, platformID = 3u16,
    encodingID = 1u16, languageID = 0x0409u16): Option[string] =
  ## Returns the decoded `name` table string for an exact
  ## (platform, encoding, language, nameID) match, falling back to any
  ## record with the same nameID. Unicode/Windows strings decode from
  ## UTF-16BE; other platforms use a Latin-1 pass-through.
  for e in f.names:
    if e.nameID == nameID and e.platformID == platformID and
        e.encodingID == encodingID and e.languageID == languageID:
      return some(decodeNameBytes(e))
  for e in f.names:
    if e.nameID == nameID:
      return some(decodeNameBytes(e))
  none(string)

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

proc glyphOffsets(f: SfntFont): tuple[ok: bool, starts, ends: seq[int]] =
  let loca = f.tableData(TagLoca)
  let glyf = f.tableData(TagGlyf)
  if not loca.ok or not glyf.ok:
    return (false, @[], @[])
  let n = int(f.numGlyphs)
  if n < 0:
    return (false, @[], @[])
  var starts = newSeq[int](n)
  var ends = newSeq[int](n)
  if f.locaFormat == 0i16:
    if loca.len < (n + 1) * 2:
      return (false, @[], @[])
    for i in 0 ..< n:
      let s = int(u16be(f.bytes, loca.offset + i * 2)) * 2
      let e = int(u16be(f.bytes, loca.offset + (i + 1) * 2)) * 2
      if s < 0 or e < s or glyf.offset + e > f.bytes.len:
        return (false, @[], @[])
      starts[i] = glyf.offset + s
      ends[i] = glyf.offset + e
  else:
    if loca.len < (n + 1) * 4:
      return (false, @[], @[])
    for i in 0 ..< n:
      let s = int(u32be(f.bytes, loca.offset + i * 4))
      let e = int(u32be(f.bytes, loca.offset + (i + 1) * 4))
      if s < 0 or e < s or glyf.offset + e > f.bytes.len:
        return (false, @[], @[])
      starts[i] = glyf.offset + s
      ends[i] = glyf.offset + e
  (true, starts, ends)

proc glyphBoundsUnscaled*(f: SfntFont,
    gid: uint32): Option[tuple[xMin, yMin, xMax, yMax: int32]] =
  let (ok, starts, ends) = f.glyphOffsets()
  if not ok or int(gid) >= starts.len:
    return none(tuple[xMin, yMin, xMax, yMax: int32])
  let s = starts[int(gid)]
  let e = ends[int(gid)]
  if e - s < 10:
    return none(tuple[xMin, yMin, xMax, yMax: int32])
  let numContours = readI16(f.bytes, s)
  if numContours == 0i16:
    return none(tuple[xMin, yMin, xMax, yMax: int32])
  if numContours < 0i16:
    # Composite glyphs: no header box; use glyphBoundsComputed, which
    # walks the components.
    return none(tuple[xMin, yMin, xMax, yMax: int32])
  some((int32(readI16(f.bytes, s + 2)), int32(readI16(f.bytes, s + 4)),
    int32(readI16(f.bytes, s + 6)), int32(readI16(f.bytes, s + 8))))

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

# ---------------------------------------------------------------------------
# Outlines (glyf / CFF)
# ---------------------------------------------------------------------------

proc glyphDataRange*(f: SfntFont, gid: uint32): tuple[ok: bool, off,
    len: int] =
  ## Byte range of the `glyf` data for `gid`, or ok=false when the font
  ## has no glyf table or the id is out of range. Empty glyphs report
  ## len 0.
  let (ok, starts, ends) = f.glyphOffsets()
  if not ok or int(gid) >= starts.len:
    return (false, 0, 0)
  let s = starts[int(gid)]
  let e = ends[int(gid)]
  if e < s:
    return (false, 0, 0)
  (true, s, e - s)

proc drawGlyf(f: SfntFont, gid: uint32,
    cb: proc(op: DrawOp) {.closure.}): bool =
  let (ok, starts, ends) = f.glyphOffsets()
  if not ok or int(gid) >= starts.len:
    return false
  let s = starts[int(gid)]
  let e = ends[int(gid)]
  if e - s < 10:
    return false
  proc at(id: uint32): tuple[ok: bool, off: int,
      len: int] {.closure.} =
    if int(id) >= starts.len:
      (false, 0, 0)
    else:
      (true, starts[int(id)], ends[int(id)] - starts[int(id)])
  drawGlyfGlyph(f.bytes, s, e - s, at, cb)

proc drawCff(f: SfntFont, gid: uint32,
    cb: proc(op: DrawOp) {.closure.}): bool =
  let t = f.tableData(TagCff)
  if not t.ok:
    return false
  let c = parseCff(f.bytes, t.offset, t.len, int32(f.unitsPerEm))
  if c.isNone:
    return false
  drawCffGlyph(c.get, gid, cb)

proc drawGlyph*(f: SfntFont, gid: uint32,
    cb: proc(op: DrawOp) {.closure.}): bool =
  ## Emits the outline of `gid` as draw ops. TrueType `glyf` outlines
  ## take precedence when present, otherwise the CFF table is used.
  ## Returns false when the glyph has no usable outline.
  let loca = f.tableData(TagLoca)
  let glyf = f.tableData(TagGlyf)
  if loca.ok and glyf.ok:
    return f.drawGlyf(gid, cb)
  f.drawCff(gid, cb)

proc glyphOutline*(f: SfntFont, gid: uint32): Option[GlyphOutline] =
  ## Collects `drawGlyph` into a value outline.
  var b = OutlineBuilder()
  if not b.collectInto(proc(
      cb: proc(op: DrawOp) {.closure.}): bool = f.drawGlyph(gid, cb)):
    return none(GlyphOutline)
  some(b.finish())

proc glyphBoundsComputed*(f: SfntFont,
    gid: uint32): Option[tuple[xMin, yMin, xMax, yMax: int32]] =
  ## Bounding box computed from the decoded outline. Covers composite
  ## glyphs and CFF outlines, for which the `glyf` header box is
  ## unavailable.
  let o = f.glyphOutline(gid)
  if o.isNone:
    return none(tuple[xMin, yMin, xMax, yMax: int32])
  outlineBounds(o.get)
