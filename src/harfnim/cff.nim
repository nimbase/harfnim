## CFF table and Type 2 charstring outline decoder.
##
## Parses the CFF table (header, INDEX structures, Top DICT, Private
## DICTs, FDSelect/FDArray for CID-keyed fonts) and executes Type 2
## charstrings into draw ops. Operator semantics follow Adobe TN 5177;
## arg patterns for the hv/vh/hh/vv curve ops cross-checked against the
## OT spec CFF2 charstring chapter (same encoding as Type 2).
##
## Any inconsistency inside the table or a charstring makes the decode
## return `none` / `false` rather than raising. CFF2 tables (major == 2)
## are unsupported and report no outline (TODO).

import std/math
import std/options
import std/strutils

import ./draw

const
  CffMaxStack = 64
  CffMaxSubrDepth = 10
  CffMaxTransient = 32

type
  Index* = object
    ok*: bool
    count*: int
    dataOff*: int
    offBase*: int
    offSize*: int

  DictEntry = tuple[op: int, args: seq[float64]]

  CffFont* = object
    bytes*: seq[uint8]
    base*: int
    limit*: int
    upem*: int32
    topM*: array[6, float64]
    hasTopM*: bool
    charstrings*: Index
    globalSubrs*: Index
    isCID*: bool
    fdArray*: Index
    fdSelectOff*: int
    defaultSubrsOff*: int
    nGlyphs*: int

  ResolvedGlyph = object
    ok: bool
    csStart: int
    csEnd: int
    subrs: Index
    hasSubrs: bool
    mA, mB, mC, mD, mTx, mTy: float64

proc subrBias(count: int): int =
  if count < 1240: 107
  elif count < 33900: 1131
  else: 32768

proc readU16At(bytes: seq[uint8], off, limit: int,
    ok: var bool): uint16 =
  if not ok or off < 0 or off + 2 > limit or off + 2 > bytes.len:
    ok = false
    return 0u16
  (uint16(bytes[off]) shl 8) or uint16(bytes[off + 1])

proc readIndex*(bytes: seq[uint8], off, limit: int): Index =
  ## Reads an INDEX structure at absolute `off`. An empty INDEX (count 0)
  ## is valid with no object data.
  result.ok = false
  if off < 0 or off + 2 > limit or off + 2 > bytes.len:
    return
  let count = int((uint16(bytes[off]) shl 8) or uint16(bytes[off + 1]))
  if count == 0:
    return Index(ok: true, count: 0, dataOff: off + 2, offBase: 0,
      offSize: 0)
  if off + 3 > limit or off + 3 > bytes.len:
    return
  let offSize = int(bytes[off + 2])
  if offSize < 1 or offSize > 4:
    return
  let arrOff = off + 3
  let arrLen = (count + 1) * offSize
  if arrOff + arrLen > limit or arrOff + arrLen > bytes.len:
    return
  var last = 0
  for i in 0 .. count:
    var v = 0
    for k in 0 ..< offSize:
      v = (v shl 8) or int(bytes[arrOff + i * offSize + k])
    if i == 0:
      # Offsets are 1-based; tolerate but require monotonicity.
      if v < 1:
        return
    if v < last:
      return
    last = v
  let dataOff = arrOff + arrLen
  if dataOff + last - 1 > limit or dataOff + last - 1 > bytes.len:
    return
  Index(ok: true, count: count, dataOff: dataOff, offBase: arrOff,
    offSize: offSize)

proc indexBounds*(bytes: seq[uint8], idx: Index, i: int,
    start, finish: var int): bool =
  if not idx.ok or i < 0 or i >= idx.count:
    return false
  var a = 0
  var b = 0
  for k in 0 ..< idx.offSize:
    a = (a shl 8) or int(bytes[idx.offBase + i * idx.offSize + k])
    b = (b shl 8) or int(bytes[idx.offBase + (i + 1) * idx.offSize + k])
  start = idx.dataOff + a - 1
  finish = idx.dataOff + b - 1
  if a < 1 or b < a or finish > bytes.len:
    return false
  true

proc decodeReal(bytes: seq[uint8], pos: var int, limit: int,
    v: var float64): bool =
  ## Decodes a nibble-encoded real starting at pos (after the 30 byte).
  var s = ""
  var done = false
  while pos < limit and pos < bytes.len and not done:
    let b = bytes[pos]
    inc pos
    for shift in [4, 0]:
      let n = int((b shr shift) and 0xF)
      if n <= 9:
        s.add(char(ord('0') + n))
      elif n == 0xA:
        s.add('.')
      elif n == 0xB:
        s.add('E')
      elif n == 0xC:
        s.add("E-")
      elif n == 0xE:
        s.add('-')
      elif n == 0xF:
        done = true
        break
      else:
        return false
  if not done:
    return false
  try:
    v = parseFloat(s)
    true
  except ValueError:
    false

proc decodeDict*(bytes: seq[uint8], start, finish: int): Option[
    seq[DictEntry]] =
  ## Decodes DICT bytes (Top, Font, or Private) into operator entries.
  ## Numbers become float64; multi-byte operators pack as (12 shl 8) | op2.
  var entries: seq[DictEntry] = @[]
  var args: seq[float64] = @[]
  var pos = start
  if start < 0 or finish > bytes.len or start > finish:
    return none(seq[DictEntry])
  while pos < finish:
    if pos >= bytes.len:
      return none(seq[DictEntry])
    let b = bytes[pos]
    inc pos
    if b == 12u8:
      if pos >= finish or pos >= bytes.len:
        return none(seq[DictEntry])
      let op2 = bytes[pos]
      inc pos
      entries.add((((12 shl 8) or int(op2)), args))
      args = @[]
    elif b <= 21u8:
      entries.add((int(b), args))
      args = @[]
    elif b == 28u8:
      if pos + 2 > finish or pos + 2 > bytes.len:
        return none(seq[DictEntry])
      let v = (int(bytes[pos]) shl 8) or int(bytes[pos + 1])
      pos += 2
      args.add(float64(cast[int16](cast[uint16](v))))
    elif b == 29u8:
      if pos + 4 > finish or pos + 4 > bytes.len:
        return none(seq[DictEntry])
      let u = (uint32(bytes[pos]) shl 24) or
        (uint32(bytes[pos + 1]) shl 16) or
        (uint32(bytes[pos + 2]) shl 8) or uint32(bytes[pos + 3])
      pos += 4
      args.add(float64(cast[int32](u)))
    elif b == 30u8:
      var v = 0.0
      if not decodeReal(bytes, pos, finish, v):
        return none(seq[DictEntry])
      args.add(v)
    elif b == 255u8:
      if pos + 4 > finish or pos + 4 > bytes.len:
        return none(seq[DictEntry])
      var u = (uint32(bytes[pos]) shl 24) or
        (uint32(bytes[pos + 1]) shl 16) or
        (uint32(bytes[pos + 2]) shl 8) or uint32(bytes[pos + 3])
      pos += 4
      args.add(float64(cast[int32](u)) / 65536.0)
    elif b >= 32u8 and b <= 246u8:
      args.add(float64(int(b) - 139))
    elif b >= 247u8 and b <= 250u8:
      if pos >= finish or pos >= bytes.len:
        return none(seq[DictEntry])
      let w = bytes[pos]
      inc pos
      args.add(float64((int(b) - 247) * 256 + int(w) + 108))
    elif b >= 251u8 and b <= 254u8:
      if pos >= finish or pos >= bytes.len:
        return none(seq[DictEntry])
      let w = bytes[pos]
      inc pos
      args.add(float64(-(int(b) - 251) * 256 - int(w) - 108))
    else:
      # 22..27 single-byte values are operators in charstrings, never
      # valid inside DICT data; 29/31 likewise.
      return none(seq[DictEntry])
  if args.len != 0:
    return none(seq[DictEntry])
  some(entries)

const
  OpCharstrings = 17
  OpPrivate = 18
  OpFontMatrix = (12 shl 8) or 7
  OpFdArray = (12 shl 8) or 36
  OpFdSelect = (12 shl 8) or 37
  OpRos = (12 shl 8) or 30
  OpSubrs = 19

proc dictArg(e: DictEntry, i: int, ok: var bool): int =
  if not ok or i < 0 or i >= e.args.len:
    ok = false
    return 0
  int(e.args[i])

proc parseCff*(bytes: seq[uint8], cffOff, cffLen: int,
    upem: int32): Option[CffFont] =
  ## Parses the CFF table at `cffOff`/`cffLen`. Returns none for CFF2
  ## data or malformed tables.
  let base = int(cffOff)
  let limit = base + int(cffLen)
  if base < 0 or cffLen < 4 or limit > bytes.len:
    return none(CffFont)
  if bytes[base] != 1u8:
    # Major version 1 only; CFF2 (major 2) is deferred (TODO).
    return none(CffFont)
  let hdrSize = int(bytes[base + 2])
  if hdrSize < 4 or base + hdrSize > limit:
    return none(CffFont)
  var f = CffFont(bytes: bytes, base: base, limit: limit, upem: upem,
    fdSelectOff: -1, defaultSubrsOff: -1)
  f.topM = [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
  var pos = base + hdrSize
  # Name INDEX (skip).
  var idx = readIndex(bytes, pos, limit)
  if not idx.ok:
    return none(CffFont)
  pos = idx.dataOff
  if idx.count > 0:
    var s, e: int
    if not indexBounds(bytes, idx, idx.count - 1, s, e):
      return none(CffFont)
    pos = e
  # Top DICT INDEX.
  idx = readIndex(bytes, pos, limit)
  if not idx.ok or idx.count < 1:
    return none(CffFont)
  var ts, te: int
  if not indexBounds(bytes, idx, 0, ts, te):
    return none(CffFont)
  let topOpt = decodeDict(bytes, ts, te)
  if topOpt.isNone:
    return none(CffFont)
  pos = idx.dataOff
  var s2, e2: int
  if not indexBounds(bytes, idx, idx.count - 1, s2, e2):
    return none(CffFont)
  pos = e2
  # String INDEX (skip).
  idx = readIndex(bytes, pos, limit)
  if not idx.ok:
    return none(CffFont)
  if idx.count > 0:
    var s3, e3: int
    if not indexBounds(bytes, idx, idx.count - 1, s3, e3):
      return none(CffFont)
    pos = e3
  else:
    pos = idx.dataOff
  # Global Subrs INDEX.
  f.globalSubrs = readIndex(bytes, pos, limit)
  if not f.globalSubrs.ok:
    return none(CffFont)
  var ok = true
  var privateSize = 0
  var privateOff = -1
  for e in topOpt.get:
    case e.op
    of OpCharstrings:
      let v = dictArg(e, 0, ok)
      if ok:
        f.charstrings = readIndex(bytes, base + v, limit)
        if not f.charstrings.ok:
          return none(CffFont)
    of OpPrivate:
      privateSize = dictArg(e, 0, ok)
      privateOff = dictArg(e, 1, ok)
    of OpRos:
      f.isCID = true
    of OpFdArray:
      let v = dictArg(e, 0, ok)
      if ok:
        f.fdArray = readIndex(bytes, base + v, limit)
        if not f.fdArray.ok:
          return none(CffFont)
    of OpFdSelect:
      let v = dictArg(e, 0, ok)
      if ok:
        f.fdSelectOff = base + v
    of OpFontMatrix:
      if e.args.len == 6:
        for i in 0 ..< 6:
          f.topM[i] = e.args[i]
        f.hasTopM = true
    else:
      discard
  if not ok or not f.charstrings.ok:
    return none(CffFont)
  f.nGlyphs = f.charstrings.count
  if f.isCID:
    if not f.fdArray.ok or f.fdSelectOff < 0:
      return none(CffFont)
  elif privateOff >= 0:
    let pOff = base + privateOff
    if privateSize < 0 or pOff + privateSize > limit:
      return none(CffFont)
    let pOpt = decodeDict(bytes, pOff, pOff + privateSize)
    if pOpt.isNone:
      return none(CffFont)
    for e in pOpt.get:
      if e.op == OpSubrs and e.args.len == 1:
        f.defaultSubrsOff = pOff + int(e.args[0])
  some(f)

# ---------------------------------------------------------------------------
# Per-glyph resolution
# ---------------------------------------------------------------------------

proc fdFor(f: CffFont, gid: int): tuple[ok: bool, fd: int] =
  let bytes = f.bytes
  if f.fdSelectOff < 0 or f.fdSelectOff + 1 > f.limit:
    return (false, 0)
  let fmt = bytes[f.fdSelectOff]
  if fmt == 0u8:
    if gid < 0 or gid >= f.nGlyphs:
      return (false, 0)
    if f.fdSelectOff + 1 + gid >= f.limit:
      return (false, 0)
    return (true, int(bytes[f.fdSelectOff + 1 + gid]))
  if fmt != 3u8:
    return (false, 0)
  var ok = true
  let n = int(readU16At(bytes, f.fdSelectOff + 1, f.limit, ok))
  if not ok or n < 0:
    return (false, 0)
  var base = f.fdSelectOff + 3
  var prevFirst = -1
  var found = -1
  for _ in 0 ..< n:
    let first = int(readU16At(bytes, base, f.limit, ok))
    if not ok or base + 3 > f.limit or base + 3 > bytes.len:
      return (false, 0)
    let fd = int(bytes[base + 2])
    if first <= prevFirst:
      return (false, 0)
    if first <= gid:
      found = fd
    prevFirst = first
    base += 3
  let sentinel = int(readU16At(bytes, base, f.limit, ok))
  if not ok or gid >= sentinel or found < 0:
    return (false, 0)
  (true, found)

proc privateSubrs(f: CffFont, pOff, pSize: int): tuple[ok: bool, off: int] =
  ## Returns the absolute offset of the local Subrs INDEX, or -1 when the
  ## Private DICT has no Subrs entry. ok=false when malformed.
  if pOff < f.base or pSize < 0 or pOff + pSize > f.limit:
    return (false, -1)
  let d = decodeDict(f.bytes, pOff, pOff + pSize)
  if d.isNone:
    return (false, -1)
  for e in d.get:
    if e.op == OpSubrs and e.args.len == 1:
      let v = int(e.args[0])
      if v < 0 or pOff + v > f.limit:
        return (false, -1)
      return (true, pOff + v)
  (true, -1)

proc combineM(top, sub: array[6, float64]): array[6, float64] =
  ## Affine product applying sub first, then top.
  [top[0] * sub[0] + top[2] * sub[1],
    top[1] * sub[0] + top[3] * sub[1],
    top[0] * sub[2] + top[2] * sub[3],
    top[1] * sub[2] + top[3] * sub[3],
    top[0] * sub[4] + top[2] * sub[5] + top[4],
    top[1] * sub[4] + top[3] * sub[5] + top[5]]

proc resolveGlyph(f: CffFont, gid: uint32): ResolvedGlyph =
  result.ok = false
  let g = int(gid)
  if g < 0 or g >= f.nGlyphs:
    return
  var s, e: int
  if not indexBounds(f.bytes, f.charstrings, g, s, e):
    return
  if s < f.base or e > f.limit or s > e:
    return
  result.csStart = s
  result.csEnd = e
  var m = f.topM
  if f.isCID:
    let (okFd, fd) = fdFor(f, g)
    if not okFd:
      return
    var fs, fe: int
    if not indexBounds(f.bytes, f.fdArray, fd, fs, fe):
      return
    let fdDict = decodeDict(f.bytes, fs, fe)
    if fdDict.isNone:
      return
    var pSize = -1
    var pOffRel = 0
    var sub = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    var hasSub = false
    for en in fdDict.get:
      if en.op == OpPrivate and en.args.len == 2:
        pSize = int(en.args[0])
        pOffRel = int(en.args[1])
      elif en.op == OpFontMatrix and en.args.len == 6:
        for i in 0 ..< 6:
          sub[i] = en.args[i]
        hasSub = true
    if pSize < 0:
      return
    let pOff = f.base + pOffRel
    let (okP, subrsOff) = privateSubrs(f, pOff, pSize)
    if not okP:
      return
    if subrsOff >= 0:
      let ix = readIndex(f.bytes, subrsOff, f.limit)
      if not ix.ok:
        return
      result.subrs = ix
      result.hasSubrs = true
    if hasSub:
      m = combineM(f.topM, sub)
  else:
    if f.defaultSubrsOff >= 0:
      let ix = readIndex(f.bytes, f.defaultSubrsOff, f.limit)
      if not ix.ok:
        return
      result.subrs = ix
      result.hasSubrs = true
  let u = float64(f.upem)
  result.mA = m[0] * u
  result.mB = m[1] * u
  result.mC = m[2] * u
  result.mD = m[3] * u
  result.mTx = m[4] * u
  result.mTy = m[5] * u
  result.ok = true

# ---------------------------------------------------------------------------
# Type 2 charstring interpreter
# ---------------------------------------------------------------------------

type
  ExecResult = enum
    erDone, erReturn

  Exec = object
    res: ResolvedGlyph
    bytes: seq[uint8]
    globalSubrs: Index
    stack: seq[float64]
    stems: int
    first: bool
    x, y: float64
    open: bool
    nops: int
    transient: array[CffMaxTransient, float64]
    randState: uint32
    depth: int
    failed: bool

proc push(e: var Exec, v: float64) =
  if e.stack.len >= CffMaxStack:
    e.failed = true
    return
  e.stack.add(v)

proc pop(e: var Exec): float64 =
  if e.stack.len == 0:
    e.failed = true
    return 0.0
  result = e.stack[^1]
  e.stack.setLen(e.stack.len - 1)

proc takeStack(e: var Exec): seq[float64] =
  ## Takes the argument stack for stem, hintmask, or endchar operators,
  ## dropping a leading width value. Width is present when the stack
  ## holds an odd number of values (these operators take an even
  ## number of stem args, or none for endchar).
  if e.first:
    e.first = false
    if e.stack.len mod 2 == 1 and e.stack.len > 0:
      e.stack.delete(0)
  result = e.stack
  e.stack = @[]

proc takeMoveArgs(e: var Exec, need: int): seq[float64] =
  ## Takes moveto args, dropping a leading width value. Width is present
  ## when the stack holds exactly one more value than the operator
  ## needs; this also covers a width before single-arg hmoveto/vmoveto,
  ## where the total count is even.
  if e.first:
    e.first = false
    if e.stack.len == need + 1:
      e.stack.delete(0)
  result = e.stack
  e.stack = @[]

proc tx(e: Exec, x, y: float64): DrawPoint =
  (roundHalfAway(e.res.mA * x + e.res.mC * y + e.res.mTx),
    roundHalfAway(e.res.mB * x + e.res.mD * y + e.res.mTy))

proc doMove(e: var Exec, x, y: float64,
    cb: proc(op: DrawOp) {.closure.}) =
  if e.open:
    cb(DrawOp(kind: closePath))
    e.open = false
  e.x = x
  e.y = y
  cb(DrawOp(kind: moveTo, to: e.tx(x, y)))
  e.open = true
  inc e.nops

proc doLine(e: var Exec, x, y: float64,
    cb: proc(op: DrawOp) {.closure.}) =
  if not e.open:
    e.failed = true
    return
  e.x = x
  e.y = y
  cb(DrawOp(kind: lineTo, to: e.tx(x, y)))
  inc e.nops

proc doCurve(e: var Exec, dx1, dy1, dx2, dy2, dx3, dy3: float64,
    cb: proc(op: DrawOp) {.closure.}) =
  if not e.open:
    e.failed = true
    return
  let c1x = e.x + dx1
  let c1y = e.y + dy1
  let c2x = c1x + dx2
  let c2y = c1y + dy2
  let px = c2x + dx3
  let py = c2y + dy3
  let p1 = e.tx(c1x, c1y)
  let p2 = e.tx(c2x, c2y)
  e.x = px
  e.y = py
  cb(DrawOp(kind: cubicTo, c1: p1, c2: p2, cTo: e.tx(px, py)))
  inc e.nops

proc execRange(e: var Exec, start, finish: int,
    cb: proc(op: DrawOp) {.closure.}): ExecResult =
  var pos = start
  template need(n: int): bool =
    pos + (n) <= finish and pos + (n) <= e.bytes.len
  while pos < finish and not e.failed:
    if pos >= e.bytes.len:
      e.failed = true
      break
    let b = e.bytes[pos]
    inc pos
    if b == 255u8:
      if not need(4):
        e.failed = true
        break
      let u = (uint32(e.bytes[pos]) shl 24) or
        (uint32(e.bytes[pos + 1]) shl 16) or
        (uint32(e.bytes[pos + 2]) shl 8) or uint32(e.bytes[pos + 3])
      pos += 4
      e.push(float64(cast[int32](u)) / 65536.0)
    elif b >= 32u8 and b <= 246u8:
      e.push(float64(int(b) - 139))
    elif b >= 247u8 and b <= 250u8:
      if not need(1):
        e.failed = true
        break
      let w = e.bytes[pos]
      inc pos
      e.push(float64((int(b) - 247) * 256 + int(w) + 108))
    elif b >= 251u8 and b <= 254u8:
      if not need(1):
        e.failed = true
        break
      let w = e.bytes[pos]
      inc pos
      e.push(float64(-(int(b) - 251) * 256 - int(w) - 108))
    elif b == 28u8:
      if not need(2):
        e.failed = true
        break
      let v = (int(e.bytes[pos]) shl 8) or int(e.bytes[pos + 1])
      pos += 2
      e.push(float64(cast[int16](cast[uint16](v))))
    elif b == 12u8:
      if not need(1):
        e.failed = true
        break
      let op2 = e.bytes[pos]
      inc pos
      case op2
      of 0u8: # dotsection (deprecated; no-op for outlines)
        discard
      of 3u8: # and
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(if b1 != 0.0 and b2 != 0.0: 1.0 else: 0.0)
      of 4u8: # or
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(if b1 != 0.0 or b2 != 0.0: 1.0 else: 0.0)
      of 5u8: # not
        let v = e.pop()
        e.push(if v == 0.0: 1.0 else: 0.0)
      of 9u8: # abs
        e.push(abs(e.pop()))
      of 10u8: # add
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(b1 + b2)
      of 11u8: # sub
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(b1 - b2)
      of 12u8: # div
        let b2 = e.pop()
        let b1 = e.pop()
        if b2 == 0.0:
          e.failed = true
        else:
          e.push(b1 / b2)
      of 14u8: # neg
        e.push(-e.pop())
      of 15u8: # eq
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(if b1 == b2: 1.0 else: 0.0)
      of 18u8: # drop
        discard e.pop()
      of 20u8: # put
        let v = e.pop()
        let i = int(e.pop())
        if i < 0 or i >= CffMaxTransient:
          e.failed = true
        else:
          e.transient[i] = v
      of 21u8: # get
        let i = int(e.pop())
        if i < 0 or i >= CffMaxTransient:
          e.failed = true
        else:
          e.push(e.transient[i])
      of 22u8: # ifelse
        let v2 = e.pop()
        let v1 = e.pop()
        let s2 = e.pop()
        let s1 = e.pop()
        e.push(if v1 <= v2: s1 else: s2)
      of 23u8: # random
        e.randState = e.randState * 1664525u32 + 1013904223u32
        e.push(float64(e.randState) / 4294967296.0 + 1e-9)
      of 24u8: # mul
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(b1 * b2)
      of 26u8: # sqrt
        let v = e.pop()
        if v < 0.0:
          e.failed = true
        else:
          e.push(sqrt(v))
      of 27u8: # dup
        let v = e.pop()
        e.push(v)
        e.push(v)
      of 28u8: # exch
        let b2 = e.pop()
        let b1 = e.pop()
        e.push(b2)
        e.push(b1)
      of 29u8: # index
        let i = int(e.pop())
        if i < 0 or i >= e.stack.len:
          e.failed = true
        else:
          e.push(e.stack[e.stack.len - 1 - i])
      of 30u8: # roll
        let j = int(e.pop())
        let n = int(e.pop())
        if n <= 0 or n > e.stack.len:
          e.failed = true
        else:
          var jj = j mod n
          if jj < 0:
            jj += n
          let base = e.stack.len - n
          var tmp = e.stack[base .. ^1]
          for k in 0 ..< n:
            e.stack[base + (k + jj) mod n] = tmp[k]
      of 34u8: # hflex
        if e.first:
          e.failed = true
        else:
          let a = e.takeStack()
          if a.len != 7:
            e.failed = true
          else:
            e.doCurve(a[0], 0.0, a[1], a[2], a[3], 0.0, cb)
            e.doCurve(a[4], 0.0, a[5], -a[2], a[6], 0.0, cb)
      of 35u8: # flex
        if e.first:
          e.failed = true
        else:
          let a = e.takeStack()
          if a.len != 13:
            e.failed = true
          else:
            e.doCurve(a[0], a[1], a[2], a[3], a[4], a[5], cb)
            e.doCurve(a[6], a[7], a[8], a[9], a[10], a[11], cb)
      of 36u8: # hflex1
        if e.first:
          e.failed = true
        else:
          let a = e.takeStack()
          if a.len != 9:
            e.failed = true
          else:
            e.doCurve(a[0], a[1], a[2], a[3], a[4], 0.0, cb)
            e.doCurve(a[5], 0.0, a[6], a[7], a[8],
              -(a[1] + a[3] + a[7]), cb)
      of 37u8: # flex1
        if e.first:
          e.failed = true
        else:
          let a = e.takeStack()
          if a.len != 11:
            e.failed = true
          else:
            var dx = 0.0
            var dy = 0.0
            for k in countup(0, 8, 2):
              dx += a[k]
              dy += a[k + 1]
            var e6x, e6y: float64
            if abs(dx) > abs(dy):
              e6x = a[10] - dx
              e6y = -dy
            else:
              e6x = -dx
              e6y = a[10] - dy
            e.doCurve(a[0], a[1], a[2], a[3], a[4], a[5], cb)
            e.doCurve(a[6], a[7], a[8], a[9], e6x, e6y, cb)
      else:
        e.failed = true
    else:
      case b
      of 1u8, 3u8, 18u8, 23u8: # stem hints
        let a = e.takeStack()
        if a.len mod 2 != 0:
          e.failed = true
        else:
          e.stems += a.len div 2
      of 4u8: # vmoveto
        let a = e.takeMoveArgs(1)
        if a.len != 1:
          e.failed = true
        else:
          e.doMove(e.x, e.y + a[0], cb)
      of 22u8: # hmoveto
        let a = e.takeMoveArgs(1)
        if a.len != 1:
          e.failed = true
        else:
          e.doMove(e.x + a[0], e.y, cb)
      of 21u8: # rmoveto
        let a = e.takeMoveArgs(2)
        if a.len != 2:
          e.failed = true
        else:
          e.doMove(e.x + a[0], e.y + a[1], cb)
      of 5u8: # rlineto
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          if a.len < 2 or a.len mod 2 != 0:
            e.failed = true
          else:
            for k in countup(0, a.len - 2, 2):
              e.doLine(e.x + a[k], e.y + a[k + 1], cb)
      of 6u8, 7u8: # hlineto / vlineto
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          var horiz = b == 6u8
          for v in a:
            if horiz:
              e.doLine(e.x + v, e.y, cb)
            else:
              e.doLine(e.x, e.y + v, cb)
            horiz = not horiz
      of 8u8: # rrcurveto
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          if a.len < 6 or a.len mod 6 != 0:
            e.failed = true
          else:
            for k in countup(0, a.len - 6, 6):
              e.doCurve(a[k], a[k + 1], a[k + 2], a[k + 3], a[k + 4],
                a[k + 5], cb)
      of 10u8, 29u8: # callsubr / callgsubr
        # Allowed before the first clearing op: a subroutine may
        # contain the stem or moveto operators that consume the width.
        let n = int(e.pop())
        if e.failed:
          discard
        elif e.depth >= CffMaxSubrDepth:
          e.failed = true
        else:
          var subIx: Index
          var hasSub = false
          if b == 10u8:
            subIx = e.res.subrs
            hasSub = e.res.hasSubrs
          else:
            subIx = e.globalSubrs
            hasSub = true
          if not hasSub:
            e.failed = true
          else:
            let sub = n + subrBias(subIx.count)
            var ss, se: int
            if not indexBounds(e.bytes, subIx, sub, ss, se):
              e.failed = true
            else:
              e.depth += 1
              let r = e.execRange(ss, se, cb)
              e.depth -= 1
              if r == erDone:
                return erDone
      of 11u8: # return
        return erReturn
      of 14u8: # endchar
        let a = e.takeStack()
        if a.len == 0:
          if e.open:
            cb(DrawOp(kind: closePath))
            e.open = false
          return erDone
        else:
          # seac (4 args) and any other trailing stack are unsupported.
          e.failed = true
      of 19u8, 20u8: # hintmask / cntrmask
        let a = e.takeStack()
        if a.len mod 2 != 0:
          e.failed = true
        else:
          e.stems += a.len div 2
          let mlen = (e.stems + 7) div 8
          if not need(mlen):
            e.failed = true
          else:
            pos += mlen
      of 24u8: # rcurveline
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          if a.len < 8 or (a.len - 2) mod 6 != 0:
            e.failed = true
          else:
            var k = 0
            while k + 6 <= a.len - 2:
              e.doCurve(a[k], a[k + 1], a[k + 2], a[k + 3], a[k + 4],
                a[k + 5], cb)
              k += 6
            e.doLine(e.x + a[^2], e.y + a[^1], cb)
      of 25u8: # rlinecurve
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          if a.len < 8 or (a.len - 6) mod 2 != 0:
            e.failed = true
          else:
            var k = 0
            while k + 2 <= a.len - 6:
              e.doLine(e.x + a[k], e.y + a[k + 1], cb)
              k += 2
            e.doCurve(a[^6], a[^5], a[^4], a[^3], a[^2], a[^1], cb)
      of 26u8: # vvcurveto dx1? {dya dxb dyb dyc}+
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          var idx = 0
          var firstDx = 0.0
          var odd = false
          if a.len mod 4 == 1 and a.len >= 5:
            firstDx = a[0]
            idx = 1
            odd = true
          elif a.len mod 4 != 0 or a.len < 4:
            e.failed = true
          if not e.failed:
            var k = idx
            var isFirst = true
            while k + 4 <= a.len:
              if isFirst and odd:
                e.doCurve(firstDx, a[k], a[k + 1], a[k + 2], 0.0,
                  a[k + 3], cb)
              else:
                e.doCurve(0.0, a[k], a[k + 1], a[k + 2], 0.0,
                  a[k + 3], cb)
              isFirst = false
              k += 4
      of 27u8: # hhcurveto dy1? {dxa dxb dyb dxc}+
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          var idx = 0
          var firstDy = 0.0
          var odd = false
          if a.len mod 4 == 1 and a.len >= 5:
            firstDy = a[0]
            idx = 1
            odd = true
          elif a.len mod 4 != 0 or a.len < 4:
            e.failed = true
          if not e.failed:
            var k = idx
            var isFirst = true
            while k + 4 <= a.len:
              if isFirst and odd:
                e.doCurve(a[k], firstDy, a[k + 1], a[k + 2], a[k + 3],
                  0.0, cb)
              else:
                e.doCurve(a[k], 0.0, a[k + 1], a[k + 2], a[k + 3],
                  0.0, cb)
              isFirst = false
              k += 4
      of 30u8, 31u8: # vhcurveto / hvcurveto
        if e.first or not e.open:
          e.failed = true
        else:
          e.first = false
          let a = move(e.stack)
          e.stack = @[]
          # Curves alternate starting with the operator's phase; a
          # trailing single arg extends the last curve's endpoint.
          # Totals are 4k or 4k+1 for k >= 1.
          if a.len < 4 or a.len mod 4 > 1:
            e.failed = true
          else:
            let hv = b == 31u8
            let n = a.len div 4
            let extra = a.len mod 4
            var k = 0
            var wantHv = hv
            for i in 0 ..< n:
              let last = i == n - 1
              let cnt = if last and extra == 1: 5 else: 4
              if wantHv:
                if cnt == 4:
                  e.doCurve(a[k], 0.0, a[k + 1], a[k + 2], 0.0,
                    a[k + 3], cb)
                else:
                  e.doCurve(a[k], 0.0, a[k + 1], a[k + 2], a[k + 4],
                    a[k + 3], cb)
              else:
                if cnt == 4:
                  e.doCurve(0.0, a[k], a[k + 1], a[k + 2], a[k + 3],
                    0.0, cb)
                else:
                  e.doCurve(0.0, a[k], a[k + 1], a[k + 2], a[k + 3],
                    a[k + 4], cb)
              k += cnt
              wantHv = not wantHv
      else:
        e.failed = true
  if e.failed:
    erDone
  else:
    erDone

proc drawCffGlyph*(f: CffFont, gid: uint32,
    cb: proc(op: DrawOp) {.closure.}): bool =
  ## Executes the charstring for `gid` into draw ops. Returns false when
  ## the glyph has no usable outline.
  let res = resolveGlyph(f, gid)
  if not res.ok:
    return false
  var e = Exec(res: res, bytes: f.bytes, globalSubrs: f.globalSubrs,
    first: true, randState: 1u32)
  let r = e.execRange(res.csStart, res.csEnd, cb)
  if e.failed or e.nops == 0:
    # No path operators means no outline (e.g. endchar-only .notdef).
    return false
  if r == erReturn:
    # return outside any subroutine is malformed.
    return false
  if e.open:
    cb(DrawOp(kind: closePath))
    e.open = false
  true
