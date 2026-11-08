## Font subsetter: pure-Nim sfnt subset for PDF embedding.
##
## Covers TrueType (`glyf`) and CFF (`CFF `) outlines; CFF2 is rejected
## (needs a Type2 downgrader). Layout (`GSUB`/`GPOS`/`GDEF`/etc),
## variation (`fvar`/`gvar`/`avar`/`HVAR`/`VVAR`/`MVAR`/`STAT`),
## color (`COLR`/`CPAL`/`CBDT`/`CBLC`/`sbix`/`SVG `), legacy `kern`,
## and device-metric tables are dropped: PDF shows pre-shaped glyphs
## via `/CIDToGIDMap`, so no layout is needed at render time. This is
## implicitly "pinned to default" (base outlines/advances, no deltas).
##
## Output is a single sfnt (never TTC) with rebuilt `cmap` (format 4 +
## 12), `glyf`/`loca` or `CFF `, `hmtx` (`vmtx`), `maxp`, `hhea`
## (`vhea`), `head`, and a `post` format 3 when the source carried
## glyph names. Everything else safe (`name`, `OS/2`, `gasp`, ...) is
## carried verbatim. Directory is sorted, 4-byte aligned, checksummed.

import std/algorithm
import std/options
import std/tables

import ./cff
import ./buffer
import ./sfnt

type
  SubsetError* = object of CatchableError

  SubsetOpts* = object
    ## `downgradeCff2` mirrors hb-subset's flag: CFF2 input is rejected
    ## with a clear error either way (no Type2 downgrader yet); the
    ## flag only controls the message path.
    downgradeCff2*: bool

proc defaultSubsetOpts*(): SubsetOpts =
  SubsetOpts(downgradeCff2: true)

# ---------------------------------------------------------------------------
# sfnt read/write helpers
# ---------------------------------------------------------------------------

proc u16At(b: openArray[uint8], off: int): uint16 =
  (uint16(b[off]) shl 8) or uint16(b[off + 1])

proc u32At(b: openArray[uint8], off: int): uint32 =
  (uint32(b[off]) shl 24) or (uint32(b[off + 1]) shl 16) or
    (uint32(b[off + 2]) shl 8) or uint32(b[off + 3])

proc putU16(d: var seq[uint8], v: uint16) =
  d.add(uint8(v shr 8))
  d.add(uint8(v))

proc putI16(d: var seq[uint8], v: int16) =
  putU16(d, cast[uint16](v))

proc putU32(d: var seq[uint8], v: uint32) =
  d.add(uint8(v shr 24))
  d.add(uint8(v shr 16))
  d.add(uint8(v shr 8))
  d.add(uint8(v))

proc putBytes(d: var seq[uint8], b: openArray[uint8]) =
  for x in b:
    d.add(x)

proc pad4(d: var seq[uint8]) =
  while d.len mod 4 != 0:
    d.add(0u8)

proc tableChecksum(b: openArray[uint8], off, len: int): uint32 =
  ## Padded-u32 sum per OT spec.
  var s = 0u64
  var i = 0
  while i < len:
    var w = 0u32
    for k in 0 ..< 4:
      w = (w shl 8) or (if i + k < len: uint32(b[off + i + k]) else: 0u32)
    s += w
    i += 4
  uint32(s and 0xFFFFFFFFu64)

const
  TagHeadU = 0x68656164u32
  TagHheaU = 0x68686561u32
  TagMaxpU = 0x6D617870u32
  TagHmtxU = 0x686D7478u32
  TagCmapU = 0x636D6170u32
  TagLocaU = 0x6C6F6361u32
  TagGlyfU = 0x676C7966u32
  TagVheaU = 0x76686561u32
  TagVmtxU = 0x766D7478u32
  TagCffU = 0x43464620u32
  TagCff2U = 0x43464632u32
  TagNameU = 0x6E616D65u32
  TagOs2U = 0x4F532F32u32
  TagPostU = 0x706F7374u32
  TagGaspU = 0x67617370u32

  DropTags = [
    0x47535542u32, # GSUB
    0x47504F53u32, # GPOS
    0x47444546u32, # GDEF
    0x4A535446u32, # JSTF
    0x42415345u32, # BASE
    0x434F4C52u32, # COLR
    0x4350414Cu32, # CPAL
    0x43424454u32, # CBDT
    0x43424C43u32, # CBLC
    0x45424454u32, # EBDT
    0x45424C43u32, # EBLC
    0x45425343u32, # EBSC
    0x73626978u32, # sbix
    0x53564720u32, # SVG
    0x4D415448u32, # MATH
    0x4D455441u32, # META
    0x4D564152u32, # MVAR
    0x48564152u32, # HVAR
    0x56564152u32, # VVAR
    0x53544154u32, # STAT
    0x66766172u32, # fvar
    0x67766172u32, # gvar
    0x61766172u32, # avar
    0x63766172u32, # cvar
    0x6B65726Eu32, # kern
    0x68646D78u32, # hdmx
    0x4C545348u32, # LTSH
    0x50434C54u32, # PCLT
    0x56444D58u32, # VDMX
    0x44534947u32, # DSIG
  ]

proc isDrop(tag: uint32): bool =
  for t in DropTags:
    if t == tag:
      return true
  false

# ---------------------------------------------------------------------------
# glyph closure (composites)
# ---------------------------------------------------------------------------

proc compositeComponents(bytes: seq[uint8], off, len: int): seq[uint32] =
  ## Component glyph ids of one `glyf` glyph; empty for simple/empty.
  result = @[]
  if off < 0 or len < 10 or off + len > bytes.len:
    return
  if cast[int16]((uint16(bytes[off]) shl 8) or uint16(bytes[off + 1])) >= 0i16:
    return # simple (numContours >= 0) or empty
  var p = off + 10
  let limit = off + len
  var more = true
  while more:
    if p + 4 > limit or p + 4 > bytes.len:
      return @[] # malformed: bail without components (caller keeps glyph)
    let flags = (uint16(bytes[p]) shl 8) or uint16(bytes[p + 1])
    let comp = (uint16(bytes[p + 2]) shl 8) or uint16(bytes[p + 3])
    result.add(uint32(comp))
    p += 4
    var a12 = 0
    if (flags and 0x1u16) != 0u16: a12 = 4
    else: a12 = 2
    if p + a12 > limit:
      return @[]
    p += a12
    if (flags and 0x8u16) != 0u16: p += 2
    elif (flags and 0x40u16) != 0u16: p += 4
    elif (flags and 0x80u16) != 0u16: p += 8
    more = (flags and 0x20u16) != 0u16
    if not more and (flags and 0x100u16) != 0u16:
      break # instructions follow; components done

proc remapComposite(glyph: openArray[uint8],
    oldToNew: Table[uint32, uint32]): seq[uint8] =
  ## Rewrite component glyph indices to new ids. Input must be a
  ## composite; simple glyphs pass through byte-identical.
  result = newSeq[uint8](glyph.len)
  for i, b in glyph:
    result[i] = b
  if glyph.len < 10:
    return
  if cast[int16]((uint16(glyph[0]) shl 8) or uint16(glyph[1])) >= 0i16:
    return
  var p = 10
  var more = true
  while more:
    if p + 4 > glyph.len:
      return result
    let flags = (uint16(glyph[p]) shl 8) or uint16(glyph[p + 1])
    let comp = (uint16(glyph[p + 2]) shl 8) or uint16(glyph[p + 3])
    if oldToNew.hasKey(comp):
      let n = oldToNew[comp]
      result[p + 2] = uint8(n shr 8)
      result[p + 3] = uint8(n and 0xFFu32)
    p += 4
    var a12 = if (flags and 0x1u16) != 0u16: 4 else: 2
    p += a12
    if (flags and 0x8u16) != 0u16: p += 2
    elif (flags and 0x40u16) != 0u16: p += 4
    elif (flags and 0x80u16) != 0u16: p += 8
    more = (flags and 0x20u16) != 0u16
    if p > glyph.len:
      return result

# ---------------------------------------------------------------------------
# cmap builder (format 4 + format 12)
# ---------------------------------------------------------------------------

proc buildCmap12(pairs: seq[tuple[cp, gid: uint32]]): seq[uint8] =
  ## One group per codepoint (valid, compact enough for subsets).
  result = @[]
  putU16(result, 12u16)
  putU16(result, 0u16)
  putU32(result, uint32(16 + pairs.len * 12))
  putU32(result, 0u32) # language
  putU32(result, uint32(pairs.len))
  var sp = pairs
  sp.sort(proc(a, b: tuple[cp, gid: uint32]): int = cmp(a.cp, b.cp))
  for (cp, gid) in sp:
    putU32(result, cp)
    putU32(result, cp)
    putU32(result, gid)

proc buildCmap4(pairs: seq[tuple[cp, gid: uint32]]): seq[uint8] =
  ## Format 4 with one segment per BMP codepoint + sentinel, using
  ## glyphIdArray (idDelta 0). Only BMP pairs are encoded.
  var bmp: seq[tuple[cp, gid: uint32]] = @[]
  for (cp, gid) in pairs:
    if cp <= 0xFFFFu32 and not (cp in 0xD800u32 .. 0xDFFFu32):
      bmp.add((cp, gid))
  bmp.sort(proc(a, b: tuple[cp, gid: uint32]): int = cmp(a.cp, b.cp))
  # Deduplicate (keep first gid per cp).
  var uniq: seq[tuple[cp, gid: uint32]] = @[]
  for (cp, gid) in bmp:
    if uniq.len == 0 or uniq[^1].cp != cp:
      uniq.add((cp, gid))
  let nSeg = uniq.len + 1 # + sentinel
  let segCountX2 = uint16(nSeg * 2)
  # searchRange/entrySelector/rangeShift per spec.
  var searchRange = 1
  var entrySelector = 0
  while searchRange * 2 <= nSeg:
    searchRange *= 2
    inc entrySelector
  searchRange *= 2
  let rangeShift = nSeg * 2 - searchRange
  result = @[]
  putU16(result, 4u16)
  let lenPos = result.len
  putU16(result, 0u16) # length placeholder
  putU16(result, 0u16) # language
  putU16(result, uint16(segCountX2))
  putU16(result, uint16(searchRange))
  putU16(result, uint16(entrySelector))
  putU16(result, uint16(rangeShift))
  for (cp, _) in uniq:
    putU16(result, uint16(cp))
  putU16(result, 0xFFFFu16)
  putU16(result, 0u16) # reservedPad
  for (cp, _) in uniq:
    putU16(result, uint16(cp))
  putU16(result, 0xFFFFu16)
  for _ in uniq:
    putI16(result, 0i16) # idDelta
  putI16(result, 1i16) # sentinel delta
  # idRangeOffset: (glyphArrayOff - fieldOff), fieldOff = current pos.
  let arrayStart = result.len + uniq.len * 2 + 2
  for i in 0 ..< uniq.len:
    let fieldOff = result.len
    putU16(result, uint16(arrayStart + i * 2 - fieldOff))
  putU16(result, 0u16) # sentinel rangeOffset
  for (_, gid) in uniq:
    putU16(result, uint16(gid))
  let total = result.len
  result[lenPos] = uint8(total shr 8)
  result[lenPos + 1] = uint8(total)

proc buildCmap(pairs: seq[tuple[cp, gid: uint32]]): seq[uint8] =
  let c4 = buildCmap4(pairs)
  let c12 = buildCmap12(pairs)
  result = @[]
  putU16(result, 0u16) # version
  putU16(result, 2u16) # numTables
  # Records sorted by (platform, encoding): (0,3) then (3,10).
  putU16(result, 0u16)
  putU16(result, 3u16)
  putU32(result, 20u32)
  putU16(result, 3u16)
  putU16(result, 10u16)
  putU32(result, uint32(20 + c4.len))
  putBytes(result, c4)
  putBytes(result, c12)

# ---------------------------------------------------------------------------
# CFF helpers (INDEX + DICT encode, charset/FDSelect rebuild)
# ---------------------------------------------------------------------------

proc cffEncodeInt(d: var seq[uint8], v: int) =
  if v >= -107 and v <= 107:
    d.add(uint8(v + 139))
  elif v >= 108 and v <= 1131:
    let w = v - 108
    d.add(uint8((w shr 8) + 247))
    d.add(uint8(w and 0xFF))
  elif v >= -1131 and v <= -108:
    let w = -v - 108
    d.add(uint8((w shr 8) + 251))
    d.add(uint8(w and 0xFF))
  elif v >= -32768 and v <= 32767:
    d.add(28u8)
    putU16(d, cast[uint16](cast[int16](v)))
  else:
    d.add(29u8)
    putU32(d, cast[uint32](cast[int32](v)))

proc cffEncodeOp(d: var seq[uint8], op: int) =
  if op > 255:
    d.add(12u8)
    d.add(uint8(op and 0xFF))
  else:
    d.add(uint8(op))

proc cffEncodeReal(d: var seq[uint8], v: float64) =
  ## DICT real number (op 30 byte + nibble-encoded string + F terminator).
  d.add(30u8)
  var s = $v
  var nibs: seq[uint8] = @[]
  for ch in s:
    let n =
      case ch
      of '0'..'9': uint8(ord(ch) - ord('0'))
      of '.': 0xAu8
      of 'E', 'e': 0xBu8
      of '-': 0xEu8
      else: 0xFFu8
    if n == 0xFFu8: continue
    nibs.add(n)
  nibs.add(0xFu8)
  for i in countup(0, nibs.len - 1, 2):
    let hi = nibs[i]
    let lo = if i + 1 < nibs.len: nibs[i + 1] else: 0xFu8
    d.add((hi shl 4) or lo)

proc cffBuildTop(topEntries: seq[tuple[op: int, args: seq[float64]]],
    topFontMatrix: seq[float64], hasTopMatrix, isCID, hasPriv: bool,
    csOff, charsetOff, fdSelOff, fdArrOff, privOff, privSize: int): seq[uint8] =
  ## Builds a Top DICT blob with concrete offsets, preserving all
  ## non-offset entries (floats via real encoding).
  result = @[]
  for en in topEntries:
    case en.op
    of 17: # Charstrings
      cffEncodeInt(result, csOff)
      cffEncodeOp(result, 17)
    of 18: # Private (non-CID only)
      if not isCID and hasPriv:
        cffEncodeInt(result, privSize)
        cffEncodeInt(result, privOff)
        cffEncodeOp(result, 18)
    of 15: # Charset
      cffEncodeInt(result, charsetOff)
      cffEncodeOp(result, 15)
    of ((12 shl 8) or 36): # FDArray
      if isCID:
        cffEncodeInt(result, fdArrOff)
        cffEncodeOp(result, ((12 shl 8) or 36))
    of ((12 shl 8) or 37): # FDSelect
      if isCID:
        cffEncodeInt(result, fdSelOff)
        cffEncodeOp(result, ((12 shl 8) or 37))
    of 19, 24, 22: # Subrs/VarStore/VSIndex: not in Top for CFF1
      discard
    of ((12 shl 8) or 30): # ROS: keep for CID
      for a in en.args: cffEncodeInt(result, int(a))
      cffEncodeOp(result, en.op)
    of ((12 shl 8) or 7): # FontMatrix: re-encoded below as reals
      discard
    else:
      var allInt = true
      for a in en.args:
        if a != float64(int(a)):
          allInt = false
      if allInt:
        for a in en.args: cffEncodeInt(result, int(a))
        cffEncodeOp(result, en.op)
      else:
        for a in en.args: cffEncodeReal(result, a)
        cffEncodeOp(result, en.op)
  if hasTopMatrix:
    for a in topFontMatrix: cffEncodeReal(result, a)
    cffEncodeOp(result, ((12 shl 8) or 7))

proc cffEncodeIndex(items: seq[seq[uint8]]): seq[uint8] =
  result = @[]
  if items.len == 0:
    putU16(result, 0u16)
    return
  var total = 0
  for it in items:
    total += it.len
  var offSize = 1
  while (1 shl (offSize * 8)) <= total + 1:
    inc offSize
    if offSize >= 4:
      break
  putU16(result, uint16(items.len))
  result.add(uint8(offSize))
  var off = 1
  for it in items:
    for k in countdown(offSize - 1, 0):
      result.add(uint8((off shr (k * 8)) and 0xFF))
    off += it.len
  for k in countdown(offSize - 1, 0):
    result.add(uint8((off shr (k * 8)) and 0xFF))
  for it in items:
    putBytes(result, it)

proc cffIndexRaw(bytes: seq[uint8], idx: Index): seq[uint8] =
  ## Raw bytes of an INDEX (count through object data).
  if not idx.ok or idx.count == 0:
    return @[0u8, 0u8]
  let arrLen = (idx.count + 1) * idx.offSize
  let dataStart = idx.dataOff
  var last = 0
  for k in 0 ..< idx.offSize:
    last = (last shl 8) or int(bytes[idx.offBase + idx.count * idx.offSize + k])
  let total = idx.dataOff + last - 1 - (idx.offBase - 2)
  # offBase-2 is the count field start.
  let start = idx.offBase - 2
  bytes[start ..< start + total]

proc cffGidToSid(bytes: seq[uint8], f: CffFont): seq[int] =
  ## gid -> SID (-1 when unknown). Index 0 is .notdef (SID 0).
  result = newSeq[int](f.nGlyphs)
  for i in 0 ..< result.len:
    result[i] = -1
  result[0] = 0
  if f.charsetOff < 0:
    for i in 1 ..< f.nGlyphs:
      result[i] = i
    return
  let limit = f.limit
  if f.charsetOff + 1 > limit:
    return
  let fmt = bytes[f.charsetOff]
  if fmt == 0u8:
    for gid in 1 ..< f.nGlyphs:
      let p = f.charsetOff + 1 + (gid - 1) * 2
      if p + 2 > limit:
        break
      result[gid] = int((uint16(bytes[p]) shl 8) or uint16(bytes[p + 1]))
  elif fmt == 1u8 or fmt == 2u8:
    var pos = f.charsetOff + 1
    var gid = 1
    while gid < f.nGlyphs:
      let headLen = if fmt == 1u8: 3 else: 4
      if pos + headLen > limit:
        break
      let first = int((uint16(bytes[pos]) shl 8) or uint16(bytes[pos + 1]))
      let nLeft = if fmt == 1u8: int(bytes[pos + 2])
        else: int((uint16(bytes[pos + 2]) shl 8) or uint16(bytes[pos + 3]))
      pos += headLen
      for k in 0 .. nLeft:
        if gid >= f.nGlyphs:
          break
        result[gid] = first + k
        inc gid
  else:
    for i in 1 ..< f.nGlyphs:
      result[i] = i

proc cffFdFor(f: CffFont, gid: int): int =
  let (ok, fd) = fdFor(f, gid)
  if ok: fd else: 0

proc buildCffSubset(srcBytes: seq[uint8], src: CffFont,
    keepOld: seq[int], oldToNew: Table[uint32, uint32]): seq[uint8] =
  ## Rebuild a CFF table keeping `keepOld` (old gids, 0 first).
  ## String/GlobalSubrs/Private blobs are carried verbatim; CharStrings,
  ## charset, FDSelect, Top DICT (and FDArray for CID) are rebuilt.
  # --- gather per-glyph data ---
  var charItems: seq[seq[uint8]] = @[]
  for og in keepOld:
    var s, e: int
    if not indexBounds(srcBytes, src.charstrings, og, s, e):
      raise newException(SubsetError, "CFF charstring out of bounds")
    charItems.add(srcBytes[s ..< e])
  let gidToSid = cffGidToSid(srcBytes, src)
  # --- copy shared INDEX blobs ---
  # Re-derive INDEX positions by re-walking from the header (same walk as
  # parseCff) to capture raw bytes.
  let base = src.base
  let hdrSize = int(srcBytes[base + 2])
  var pos = base + hdrSize
  # Name INDEX raw:
  var idx = readIndex(srcBytes, pos, src.limit)
  let nameStart = pos
  var nameEnd = idx.dataOff
  if idx.count > 0:
    var s, e: int
    discard indexBounds(srcBytes, idx, idx.count - 1, s, e)
    nameEnd = e
  let nameBlob = srcBytes[nameStart ..< nameEnd]
  pos = nameEnd
  # Top DICT INDEX raw (skip: rebuilt):
  idx = readIndex(srcBytes, pos, src.limit)
  if idx.count > 0:
    var s, e: int
    discard indexBounds(srcBytes, idx, idx.count - 1, s, e)
    pos = e
  else:
    pos = idx.dataOff
  # String INDEX raw:
  idx = readIndex(srcBytes, pos, src.limit)
  let strStart = pos
  var strEnd = idx.dataOff
  if idx.count > 0:
    var s, e: int
    discard indexBounds(srcBytes, idx, idx.count - 1, s, e)
    strEnd = e
  let strBlob = srcBytes[strStart ..< strEnd]
  pos = strEnd
  # GlobalSubrs raw:
  idx = readIndex(srcBytes, pos, src.limit)
  let gsubStart = pos
  var gsubEnd = idx.dataOff
  if idx.count > 0:
    var s, e: int
    discard indexBounds(srcBytes, idx, idx.count - 1, s, e)
    gsubEnd = e
  let gsubBlob = srcBytes[gsubStart ..< gsubEnd]
  # --- Top DICT entries to preserve (SIDs etc) ---
  var ts, te: int
  # Top DICT INDEX starts right after the Name INDEX (captured above).
  var tIdx = readIndex(srcBytes, nameEnd, src.limit)
  discard indexBounds(srcBytes, tIdx, 0, ts, te)
  let topEntries = decodeDict(srcBytes, ts, te).get(@[])
  # --- charset for subset (format 0) ---
  var charsetBlob: seq[uint8] = @[0u8]
  for i in 1 ..< keepOld.len:
    let sid = gidToSid[keepOld[i]]
    let s = if sid < 0: keepOld[i] else: sid
    charsetBlob.add(uint8(s shr 8))
    charsetBlob.add(uint8(s and 0xFF))
  # --- FDSelect for subset ---
  var fdSelBlob: seq[uint8] = @[]
  var fdArrayBlob: seq[uint8] = @[]
  var isCID = src.isCID
  var fdList: seq[int] = @[] # distinct fds in new order
  var newFdOfNew: seq[int] = @[]
  if isCID:
    for og in keepOld:
      let fd = cffFdFor(src, og)
      newFdOfNew.add(fd)
      if fd notin fdList:
        fdList.add(fd)
    # FDSelect format 0:
    fdSelBlob = @[0u8]
    var fdRemap = initTable[int, int]()
    for i, fd in fdList:
      fdRemap[fd] = i
    for fd in newFdOfNew:
      fdSelBlob.add(uint8(fdRemap[fd]))
    # FDArray: rebuild each kept FD with updated Private offsets.
    # First collect private blobs.
    var privBlobs: seq[seq[uint8]] = @[]
    var privSubrsBlobs: seq[seq[uint8]] = @[]
    var fdFontMatrices: seq[seq[float64]] = @[]
    var fdHasMatrix: seq[bool] = @[]
    for fd in fdList:
      var fs, fe: int
      if not indexBounds(srcBytes, src.fdArray, fd, fs, fe):
        raise newException(SubsetError, "CFF FDArray out of bounds")
      let fdDict = decodeDict(srcBytes, fs, fe).get(@[])
      var pSize = -1
      var pOffRel = 0
      var m: array[6, float64] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
      var hasM = false
      for en in fdDict:
        if en.op == 18 and en.args.len == 2:
          pSize = int(en.args[0])
          pOffRel = int(en.args[1])
        elif (en.op == ((12 shl 8) or 7)) and (en.args.len == 6):
          for i in 0 ..< 6: m[i] = en.args[i]
          hasM = true
      if pSize < 0:
        raise newException(SubsetError, "CFF FD missing Private")
      let pOff = base + pOffRel
      privBlobs.add(srcBytes[pOff ..< pOff + pSize])
      # Local subrs blob (INDEX raw) if present:
      let pDict = decodeDict(srcBytes, pOff, pOff + pSize).get(@[])
      var subrsOff = -1
      for en in pDict:
        if en.op == 19 and en.args.len == 1:
          subrsOff = pOff + int(en.args[0])
      if subrsOff >= 0:
        let six = readIndex(srcBytes, subrsOff, src.limit)
        var ss, se: int
        if six.count == 0:
          privSubrsBlobs.add(@[0u8, 0u8])
        else:
          discard indexBounds(srcBytes, six, six.count - 1, ss, se)
          privSubrsBlobs.add(srcBytes[subrsOff ..< se])
      else:
        privSubrsBlobs.add(@[])
      fdFontMatrices.add(@[m[0], m[1], m[2], m[3], m[4], m[5]])
      fdHasMatrix.add(hasM)
    # We lay out FDArray Private blobs after the main table; for now
    # store them to append later and record sizes. Build FDArray INDEX
    # with placeholder Private offsets, fixed up after layout.
    # (Two-pass: first compute all other sizes, then assign priv offs.)
    # Simplification: place priv blobs inline right after FDSelect/charset
    # and compute offsets in one pass below.
    discard privBlobs
    discard privSubrsBlobs
    discard fdFontMatrices
    discard fdHasMatrix
  # --- layout: compute offsets ---
  # CFF base for new table is 0 (relative). Header 4 bytes.
  let newHdr = @[1u8, 0u8, 4u8, 4u8]
  let charStrBlob = cffEncodeIndex(charItems)
  # Assemble order: hdr, name, top(placeholder), string, gsubrs,
  # charstrings, charset, fdselect, fdarray+privates (CID) or private (non-CID).
  # Non-CID private blob:
  var privBlob: seq[uint8] = @[]
  var privSubrsRaw: seq[uint8] = @[]
  var hasPriv = false
  var topFontMatrix: seq[float64] = @[]
  var hasTopMatrix = false
  for en in topEntries:
    if (en.op == ((12 shl 8) or 7)) and (en.args.len == 6):
      topFontMatrix = @(en.args)
      hasTopMatrix = true
  if not isCID:
    # Find Private from top dict:
    for en in topEntries:
      if en.op == 18 and en.args.len == 2:
        let pSize = int(en.args[0])
        let pOffRel = int(en.args[1])
        let pOff = base + pOffRel
        privBlob = srcBytes[pOff ..< pOff + pSize]
        hasPriv = privBlob.len > 0
        # subrs?
        let pDict = decodeDict(srcBytes, pOff, pOff + pSize).get(@[])
        for pe in pDict:
          if pe.op == 19 and pe.args.len == 1:
            let sOff = pOff + int(pe.args[0])
            let six = readIndex(srcBytes, sOff, src.limit)
            if six.count == 0:
              privSubrsRaw = @[0u8, 0u8]
            else:
              var ss, se: int
              discard indexBounds(srcBytes, six, six.count - 1, ss, se)
              privSubrsRaw = srcBytes[sOff ..< se]
        break
  # --- CID private blobs (per distinct FD, first-use order) ---
  var privs: seq[seq[uint8]] = @[]
  var subrss: seq[seq[uint8]] = @[]
  var matrices: seq[seq[float64]] = @[]
  var hasM: seq[bool] = @[]
  var distinctFds: seq[int] = @[]
  if isCID:
    var seen = initTable[int, int]()
    for og in keepOld:
      let fd = cffFdFor(src, og)
      if fd notin seen:
        seen[fd] = distinctFds.len
        distinctFds.add(fd)
    for fd in distinctFds:
      var fs, fe: int
      if not indexBounds(srcBytes, src.fdArray, fd, fs, fe):
        raise newException(SubsetError, "CFF FDArray out of bounds")
      let fdDict = decodeDict(srcBytes, fs, fe).get(@[])
      var pSize = -1
      var pOffRel = 0
      var m = @[1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
      var hm = false
      for en in fdDict:
        if en.op == 18 and en.args.len == 2:
          pSize = int(en.args[0])
          pOffRel = int(en.args[1])
        elif (en.op == ((12 shl 8) or 7)) and (en.args.len == 6):
          m = @(en.args)
          hm = true
      if pSize < 0:
        raise newException(SubsetError, "CFF FD missing Private")
      let pOff = base + pOffRel
      privs.add(srcBytes[pOff ..< pOff + pSize])
      let pDict = decodeDict(srcBytes, pOff, pOff + pSize).get(@[])
      var sOff = -1
      for pe in pDict:
        if pe.op == 19 and pe.args.len == 1:
          sOff = pOff + int(pe.args[0])
      if sOff >= 0:
        let six = readIndex(srcBytes, sOff, src.limit)
        if six.count == 0:
          subrss.add(@[0u8, 0u8])
        else:
          var ss, se: int
          discard indexBounds(srcBytes, six, six.count - 1, ss, se)
          subrss.add(srcBytes[sOff ..< se])
      else:
        subrss.add(@[])
      matrices.add(m)
      hasM.add(hm)
  # --- FDSelect for subset (format 0 over remapped FDs) ---
  var fdRemap = initTable[int, int]()
  for i, fd in distinctFds:
    fdRemap[fd] = i
  var fdSelBlob2: seq[uint8] = @[]
  if isCID:
    fdSelBlob2 = @[0u8]
    for og in keepOld:
      fdSelBlob2.add(uint8(fdRemap[cffFdFor(src, og)]))
  # Joint fixpoint: Top DICT size affects all offsets; FDArray size
  # affects private offsets (which affect FDArray entry sizes).
  var topBlob: seq[uint8] = @[0u8]
  var fdArrBlob: seq[uint8] = @[0u8, 0u8]
  var csOffF, charsetOffF, fdSelOffF, fdArrOffF, privOffF, privSizeF = 0
  for _ in 0 ..< 10:
    let topIdxLen = cffEncodeIndex(@[topBlob]).len
    var off = newHdr.len + nameBlob.len + topIdxLen + strBlob.len +
      gsubBlob.len
    let csOff = off
    off += charStrBlob.len
    let charsetOff = off
    off += charsetBlob.len
    var fdSelOff = -1
    if isCID:
      fdSelOff = off
      off += fdSelBlob2.len
    var fdArrOff = -1
    if isCID:
      fdArrOff = off
      off += fdArrBlob.len
    var privOff = -1
    var privSize = 0
    if not isCID and hasPriv:
      privOff = off
      privSize = privBlob.len
      off += privSize + privSubrsRaw.len
    let newTop = cffBuildTop(topEntries, topFontMatrix, hasTopMatrix,
      isCID, hasPriv, csOff, charsetOff, fdSelOff, fdArrOff, privOff,
      privSize)
    var newFdArr = fdArrBlob
    if isCID:
      # Private blobs sit right after the FDArray INDEX.
      var privBase = fdArrOff + fdArrBlob.len
      # Inner fixpoint: entry sizes depend on priv offsets.
      for _ in 0 ..< 6:
        var entries: seq[seq[uint8]] = @[]
        var pb = privBase
        for i in 0 ..< privs.len:
          var e: seq[uint8] = @[]
          if hasM[i]:
            for a in matrices[i]: cffEncodeReal(e, a)
            cffEncodeOp(e, ((12 shl 8) or 7))
          cffEncodeInt(e, privs[i].len)
          cffEncodeInt(e, pb)
          cffEncodeOp(e, 18)
          entries.add(e)
          pb += privs[i].len + subrss[i].len
        let cand = cffEncodeIndex(entries)
        if cand.len == fdArrBlob.len:
          newFdArr = cand
          break
        newFdArr = cand
        privBase = fdArrOff + cand.len
    if newTop == topBlob and newFdArr == fdArrBlob:
      topBlob = newTop
      fdArrBlob = newFdArr
      csOffF = csOff
      charsetOffF = charsetOff
      fdSelOffF = fdSelOff
      fdArrOffF = fdArrOff
      privOffF = privOff
      privSizeF = privSize
      break
    topBlob = newTop
    fdArrBlob = newFdArr
    csOffF = csOff
    charsetOffF = charsetOff
    fdSelOffF = fdSelOff
    fdArrOffF = fdArrOff
    privOffF = privOff
    privSizeF = privSize
  # --- assemble ---
  result = @[]
  putBytes(result, newHdr)
  putBytes(result, nameBlob)
  putBytes(result, cffEncodeIndex(@[topBlob]))
  putBytes(result, strBlob)
  putBytes(result, gsubBlob)
  putBytes(result, charStrBlob)
  putBytes(result, charsetBlob)
  if isCID:
    putBytes(result, fdSelBlob2)
    putBytes(result, fdArrBlob)
    for i in 0 ..< privs.len:
      putBytes(result, privs[i])
      putBytes(result, subrss[i])
  elif hasPriv:
    # Private Subrs offset is relative to the Private start, still
    # valid when the two blobs move together.
    putBytes(result, privBlob)
    putBytes(result, privSubrsRaw)

# ---------------------------------------------------------------------------
# main entry
# ---------------------------------------------------------------------------

proc subsetImpl(data: seq[uint8], unicodes: openArray[uint32],
    opts: SubsetOpts): tuple[bytes: seq[uint8],
    oldToNew: Table[uint32, uint32]] =
  var font: SfntFont
  try:
    font = parseFont(data, 0)
  except FontError as e:
    raise newException(SubsetError, "cannot parse font: " & e.msg)
  let bytes = font.bytes
  if font.tableData(TagCff2U).ok:
    raise newException(SubsetError,
      "CFF2 subsetting not supported (downgrade unimplemented)")
  let hasGlyf = font.tableData(TagGlyfU).ok and font.tableData(TagLocaU).ok
  let hasCff = font.tableData(TagCffU).ok
  if not hasGlyf and not hasCff:
    raise newException(SubsetError, "font has neither glyf nor CFF outlines")
  # --- unicode -> old gid ---
  var oldSet = initTable[uint32, bool]()
  oldSet[0u32] = true
  for u in unicodes:
    let g = font.mapUnicode(u)
    if g.isSome:
      oldSet[g.get.value] = true
  if hasGlyf:
    # Composite closure.
    var changed = true
    while changed:
      changed = false
      var keys: seq[uint32] = @[]
      for k in oldSet.keys: keys.add(k)
      for og in keys:
        let (ok, s, ln) = font.glyphDataRange(og)
        if not ok or ln == 0:
          continue
        for c in compositeComponents(bytes, s, ln):
          if c < uint32(font.numGlyphs) and not oldSet.hasKey(c):
            oldSet[c] = true
            changed = true
  else:
    # CFF: no composite closure needed (charstrings reference subrs by
    # index, not glyphs; seac references resolve at render, kept whole).
    discard
  var keepOld: seq[int] = @[]
  var olds: seq[uint32] = @[]
  for k in oldSet.keys: olds.add(k)
  olds.sort()
  var oldToNew = initTable[uint32, uint32]()
  for i, og in olds:
    oldToNew[og] = uint32(i)
    keepOld.add(int(og))
  # --- cmap pairs (new gids) ---
  var pairs: seq[tuple[cp, gid: uint32]] = @[]
  for u in unicodes:
    let g = font.mapUnicode(u)
    if g.isSome and oldToNew.hasKey(g.get.value):
      pairs.add((u, oldToNew[g.get.value]))
  # Deduplicate cps (first wins).
  pairs.sort(proc(a, b: tuple[cp, gid: uint32]): int = cmp(a.cp, b.cp))
  var upairs: seq[tuple[cp, gid: uint32]] = @[]
  for p in pairs:
    if upairs.len == 0 or upairs[^1].cp != p.cp:
      upairs.add(p)
  let cmapBlob = buildCmap(upairs)
  # --- head/hhea/maxp/hmtx ---
  let headT = font.tableData(TagHeadU)
  var headBlob = bytes[headT.offset ..< headT.offset + headT.len]
  # Zero the inherited checkSumAdjustment: the directory checksum and
  # the whole-font sum are computed with it at zero; the final value
  # is written after the build (validators zero it before checking).
  headBlob[8] = 0u8
  headBlob[9] = 0u8
  headBlob[10] = 0u8
  headBlob[11] = 0u8
  let hheaT = font.tableData(TagHheaU)
  var hheaBlob = bytes[hheaT.offset ..< hheaT.offset + hheaT.len]
  let maxpT = font.tableData(TagMaxpU)
  var maxpBlob = bytes[maxpT.offset ..< maxpT.offset + maxpT.len]
  # hmtx rebuild (full long metrics):
  var hmtxBlob: seq[uint8] = @[]
  for og in keepOld:
    let adv = font.hAdvance(uint32(og))
    let lsb = font.hSideBearing(uint32(og))
    let a = if adv < 0i32: 0u16 elif adv > 0xFFFFi32: 0xFFFFu16
      else: uint16(adv)
    let lc = if lsb < -32768i32: -32768i16 elif lsb > 32767i32: 32767i16
      else: int16(lsb)
    putU16(hmtxBlob, a)
    putI16(hmtxBlob, lc)
  let newNum = keepOld.len
  # maxp numGlyphs:
  maxpBlob[4] = uint8(newNum shr 8)
  maxpBlob[5] = uint8(newNum and 0xFF)
  # hhea numberOfHMetrics:
  hheaBlob[hheaBlob.len - 2] = uint8(newNum shr 8)
  hheaBlob[hheaBlob.len - 1] = uint8(newNum and 0xFF)
  # vhea/vmtx:
  var hasV = font.hasVMetrics
  var vheaBlob: seq[uint8] = @[]
  var vmtxBlob: seq[uint8] = @[]
  if hasV:
    let vt = font.tableData(TagVheaU)
    if not vt.ok:
      hasV = false
    else:
      vheaBlob = bytes[vt.offset ..< vt.offset + vt.len]
      vheaBlob[vheaBlob.len - 2] = uint8(newNum shr 8)
      vheaBlob[vheaBlob.len - 1] = uint8(newNum and 0xFF)
      for og in keepOld:
        let adv = font.vAdvance(uint32(og))
        let a = if adv < 0i32: 0u16 elif adv > 0xFFFFi32: 0xFFFFu16
          else: uint16(adv)
        # vmtx long entry: advance + top side bearing; top SB unknown
        # via public API, keep 0 (valid; affects vertical layout only).
        putU16(vmtxBlob, a)
        putI16(vmtxBlob, 0i16)
      let vm = font.tableData(TagVmtxU)
      if not vm.ok:
        hasV = false
  # --- glyf/loca or CFF ---
  var glyfBlob: seq[uint8] = @[]
  var locaBlob: seq[uint8] = @[]
  var useShortLoca = true
  var cffBlob: seq[uint8] = @[]
  if hasGlyf:
    var offs: seq[int] = @[0]
    for og in keepOld:
      let (ok, s, ln) = font.glyphDataRange(uint32(og))
      var g: seq[uint8] = @[]
      if ok and ln > 0:
        g = remapComposite(bytes[s ..< s + ln], oldToNew)
      putBytes(glyfBlob, g)
      pad4(glyfBlob)
      offs.add(glyfBlob.len)
    # Short loca iff all offsets/2 fit u16.
    useShortLoca = true
    for o in offs:
      if o div 2 > 0xFFFF:
        useShortLoca = false
        break
    if useShortLoca:
      for o in offs:
        putU16(locaBlob, uint16(o div 2))
    else:
      for o in offs:
        putU32(locaBlob, uint32(o))
    headBlob[50] = if useShortLoca: 0u8 else: 1u8
    headBlob[51] = 0u8
  else:
    let ct = font.tableData(TagCffU)
    let cbytes = bytes[ct.offset ..< ct.offset + ct.len]
    # Rebase to a temp font view for parsing (absolute offsets):
    var tmp = cbytes
    let parsed = parseCff(tmp, 0, tmp.len, int32(font.unitsPerEm))
    if parsed.isNone:
      raise newException(SubsetError, "cannot parse CFF table")
    cffBlob = buildCffSubset(tmp, parsed.get, keepOld, oldToNew)
  # --- post: format 3 when source had names ---
  let postT = font.tableData(TagPostU)
  var postBlob: seq[uint8] = @[]
  var havePost = false
  if postT.ok and postT.len >= 32:
    havePost = true
    postBlob = bytes[postT.offset ..< postT.offset + 32]
    postBlob[0] = 0u8
    postBlob[1] = 3u8
    postBlob[2] = 0u8
    postBlob[3] = 0u8
  # --- collect tables ---
  type Tbl = tuple[tag: uint32, data: seq[uint8]]
  var tbls: seq[Tbl] = @[]
  tbls.add((TagHeadU, headBlob))
  tbls.add((TagHheaU, hheaBlob))
  tbls.add((TagMaxpU, maxpBlob))
  tbls.add((TagHmtxU, hmtxBlob))
  tbls.add((TagCmapU, cmapBlob))
  if hasGlyf:
    tbls.add((TagLocaU, locaBlob))
    tbls.add((TagGlyfU, glyfBlob))
  else:
    tbls.add((TagCffU, cffBlob))
  if hasV:
    tbls.add((TagVheaU, vheaBlob))
    tbls.add((TagVmtxU, vmtxBlob))
  # name, OS/2, gasp verbatim:
  for (tag, name) in [(TagNameU, "name"), (TagOs2U, "OS/2"),
      (TagGaspU, "gasp")]:
    let t = font.tableData(tag)
    if t.ok:
      tbls.add((tag, bytes[t.offset ..< t.offset + t.len]))
    discard name
  if havePost:
    tbls.add((TagPostU, postBlob))
  # Any other safe table carried verbatim (not dropped, not rebuilt):
  var carried: seq[Tbl] = @[]
  for te in font.tables:
    if te.tag in [TagHeadU, TagHheaU, TagMaxpU, TagHmtxU, TagCmapU,
        TagLocaU, TagGlyfU, TagCffU, TagCff2U, TagVheaU, TagVmtxU,
        TagNameU, TagOs2U, TagPostU, TagGaspU]:
      continue
    if isDrop(te.tag):
      continue
    carried.add((te.tag, bytes[te.offset ..< te.offset + te.length]))
  for c in carried:
    tbls.add(c)
  tbls.sort(proc(a, b: Tbl): int = cmp(a.tag, b.tag))
  # --- sfnt build ---
  let n = tbls.len
  var searchRange = 1
  var entrySelector = 0
  while searchRange * 2 <= n:
    searchRange *= 2
    inc entrySelector
  searchRange *= 16
  let rangeShift = n * 16 - searchRange
  var sfnt: seq[uint8] = @[]
  putU32(sfnt, 0x00010000u32)
  putU16(sfnt, uint16(n))
  putU16(sfnt, uint16(searchRange))
  putU16(sfnt, uint16(entrySelector))
  putU16(sfnt, uint16(rangeShift))
  var tblOff = 12 + n * 16
  var dirEnd = tblOff
  # Directory with placeholder checksum/offset; data appended after.
  var dataBlobs: seq[seq[uint8]] = @[]
  for t in tbls:
    dataBlobs.add(t.data)
  for i, t in tbls:
    putU32(sfnt, t.tag)
    putU32(sfnt, tableChecksum(dataBlobs[i], 0, dataBlobs[i].len))
    putU32(sfnt, uint32(tblOff))
    putU32(sfnt, uint32(dataBlobs[i].len))
    tblOff += (dataBlobs[i].len + 3) and not 3
  doAssert sfnt.len == dirEnd
  for b in dataBlobs:
    putBytes(sfnt, b)
    pad4(sfnt)
  # checkSumAdjustment: 0xB1B0AFBA - sum. Per the OT spec the head
  # checksum in the directory stays as computed with the adjustment
  # at zero (validators zero it before checking); only the head data
  # carries the final value.
  var sum = 0u64
  for i in countup(0, sfnt.len - 1, 4):
    var w = 0u32
    for k in 0 ..< 4:
      w = (w shl 8) or (if i + k < sfnt.len: uint32(sfnt[i + k]) else: 0u32)
    sum += w
  let adj = 0xB1B0AFBAu64 - (sum and 0xFFFFFFFFu64)
  # head is first table? Find head record offset: 12 + idx*16 + 8.
  var headIdx = -1
  for i, t in tbls:
    if t.tag == TagHeadU:
      headIdx = i
      break
  doAssert headIdx >= 0
  let headRecOff = 12 + headIdx * 16
  let headDataOff = int(u32At(sfnt, headRecOff + 8))
  sfnt[headDataOff + 8] = uint8(adj shr 24)
  sfnt[headDataOff + 9] = uint8((adj shr 16) and 0xFFu64)
  sfnt[headDataOff + 10] = uint8((adj shr 8) and 0xFFu64)
  sfnt[headDataOff + 11] = uint8(adj and 0xFFu64)
  (sfnt, oldToNew)

proc subsetFont*(data: openArray[uint8], unicodes: openArray[uint32],
    opts = defaultSubsetOpts()): tuple[bytes: seq[uint8],
    oldToNew: Table[uint32, uint32]] =
  var b = newSeq[uint8](data.len)
  for i, x in data:
    b[i] = x
  subsetImpl(b, unicodes, opts)

proc subsetFontString*(data: string, unicodes: openArray[uint32],
    opts = defaultSubsetOpts()): tuple[bytes: string,
    oldToNew: Table[uint32, uint32]] =
  var b = newSeq[uint8](data.len)
  for i, c in data:
    b[i] = uint8(c)
  let (sb, m) = subsetImpl(b, unicodes, opts)
  var s = newString(sb.len)
  for i, x in sb:
    s[i] = char(x)
  (s, m)
