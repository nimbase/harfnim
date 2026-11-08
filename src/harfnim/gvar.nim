## `gvar` glyph variations for variable TrueType outlines.
##
## Parses the glyph variation data and computes per-point deltas for a
## glyph at normalized coordinates: tuple scalars (with intermediate
## regions, peak-zero axes skipped per the OT spec), packed point
## numbers and deltas (byte/word/long runs, shared tuples/points),
## plus IUP interpolation for untouched points. Phantom-point deltas
## are consumed but not applied to outlines (metric variations via
## HVAR/MVAR are a follow-up; see TODO in `font.glyphExtents`).
##
## Malformed data fails the glyph's variation (base outline kept),
## never raises.

import ./draw

const
  GvarEmbedPeak = 0x8000u16
  GvarIntermediate = 0x4000u16
  GvarPrivatePoints = 0x2000u16
  GvarTupleIndexMask = 0x0FFFu16
  GvarSharedPoints = 0x8000u16
  GvarCountMask = 0x0FFFu16
  GvarPointsAreWords = 0x80u8
  GvarPointRunMask = 0x7Fu8
  GvarDeltasAreZero = 0x80u8
  GvarDeltasAreWords = 0x40u8
  GvarDeltasAreLongs = 0xC0u8
  GvarDeltaSizeMask = 0xC0u8
  GvarDeltaRunMask = 0x3Fu8

type
  GvarTable* = object
    ok*: bool
    axisCount*: int
    sharedTuples*: seq[seq[float64]]
    glyphOffsets*: seq[int]
    bytes*: seq[uint8]
    base*, limit*: int

  GvarContext* = object
    table*: GvarTable
    coords*: seq[float32]

proc noGvarContext*(): GvarContext =
  ## Returns the empty gvar context.
  GvarContext(table: GvarTable(ok: false), coords: @[])

proc hasData*(c: GvarContext): bool =
  ## True when tuning data and coordinates are present.
  c.table.ok and c.coords.len > 0 and c.table.axisCount > 0

type
  Cursor = object
    bytes: seq[uint8]
    pos: int
    limit: int
    failed: bool

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

proc f2dot14(c: var Cursor): float64 =
  # Reads a 2.14 fixed point number.
  float64(c.i16()) / 16384.0

proc parseGvar*(bytes: seq[uint8], off, len: int): GvarTable =
  ## Parses the `gvar` header, shared tuples, and per-glyph offsets.
  ## Malformed headers yield `ok == false` (contained).
  result.ok = false
  if off < 0 or len < 16 or off + len > bytes.len:
    return
  var c = Cursor(bytes: bytes, pos: off, limit: off + len)
  let major = c.u16()
  discard c.u16()
  let axisCount = int(c.u16())
  let sharedCount = int(c.u16())
  let sharedOff = int(c.u32())
  let glyphCount = int(c.u16())
  let flags = c.u16()
  let varDataOff = int(c.u32())
  if c.failed or major != 1u16 or axisCount < 0 or sharedCount < 0 or
      glyphCount < 0:
    return
  let longOffsets = (flags and 1u16) != 0u16
  var shared: seq[seq[float64]] = @[]
  for _ in 0 ..< sharedCount:
    let base = off + sharedOff + shared.len * axisCount * 2
    if sharedOff < 0 or base + axisCount * 2 > off + len or
        base + axisCount * 2 > bytes.len:
      return
    var tup = newSeq[float64](axisCount)
    for a in 0 ..< axisCount:
      tup[a] = float64(cast[int16]((uint16(bytes[base + a * 2]) shl 8) or
        uint16(bytes[base + a * 2 + 1]))) / 16384.0
    shared.add(tup)
  let stride = if longOffsets: 4 else: 2
  if varDataOff < 0 or varDataOff + (glyphCount + 1) * stride > len:
    return
  var offs = newSeq[int](glyphCount + 1)
  for i in 0 .. glyphCount:
    if longOffsets:
      var cc = Cursor(bytes: bytes, pos: off + varDataOff + i * 4,
        limit: off + len)
      offs[i] = off + varDataOff + int(cc.u32())
      if cc.failed:
        return
    else:
      var cc = Cursor(bytes: bytes, pos: off + varDataOff + i * 2,
        limit: off + len)
      offs[i] = off + varDataOff + int(cc.u16()) * 2
      if cc.failed:
        return
    if offs[i] < off + varDataOff or offs[i] > off + len:
      return
  for i in 1 .. glyphCount:
    if offs[i] < offs[i - 1]:
      return
  result = GvarTable(ok: true, axisCount: axisCount, sharedTuples: shared,
    glyphOffsets: offs, bytes: bytes, base: off, limit: off + len)

proc parsePoints(c: var Cursor, numPoints: int): tuple[ok: bool,
    points: seq[int]] =
  ## Unpacks a point list. Count zero means all points including the
  ## four phantom points.
  let b0 = c.u8()
  if c.failed:
    return (false, @[])
  var count = int(b0)
  if (b0 and GvarPointsAreWords) != 0u8:
    count = (count and int(GvarPointRunMask)) shl 8 or int(c.u8())
    if c.failed:
      return (false, @[])
  if count == 0:
    var all = newSeq[int](numPoints + 4)
    for i in 0 ..< numPoints + 4:
      all[i] = i
    return (true, all)
  if count < 0:
    return (false, @[])
  var deltas = newSeq[int]()
  while deltas.len < count:
    let h = c.u8()
    if c.failed:
      return (false, @[])
    let n = int(h and GvarPointRunMask) + 1
    if (h and GvarPointsAreWords) != 0u8:
      if not c.need(n * 2):
        return (false, @[])
      for _ in 0 ..< n:
        deltas.add(int(c.u16()))
        if c.failed:
          return (false, @[])
    else:
      if not c.need(n):
        return (false, @[])
      for _ in 0 ..< n:
        deltas.add(int(c.u8()))
  var pts = newSeq[int](deltas.len)
  var cur = 0
  for i, d in deltas:
    cur += d
    pts[i] = cur
  (true, pts)

proc parseDeltas(c: var Cursor, count: int): tuple[ok: bool,
    vals: seq[int32]] =
  ## Unpacks one axis of packed deltas; runs must sum to exactly
  ## `count` values.
  var vals = newSeq[int32]()
  while vals.len < count:
    let h = c.u8()
    if c.failed:
      return (false, @[])
    let n = int(h and GvarDeltaRunMask) + 1
    if vals.len + n > count:
      return (false, @[])
    case h and GvarDeltaSizeMask
    of GvarDeltasAreZero:
      for _ in 0 ..< n:
        vals.add(0i32)
    of GvarDeltasAreWords:
      if not c.need(n * 2):
        return (false, @[])
      for _ in 0 ..< n:
        vals.add(int32(c.i16()))
        if c.failed:
          return (false, @[])
    of GvarDeltasAreLongs:
      if not c.need(n * 4):
        return (false, @[])
      for _ in 0 ..< n:
        vals.add(c.i32())
        if c.failed:
          return (false, @[])
    else:
      if not c.need(n):
        return (false, @[])
      for _ in 0 ..< n:
        vals.add(int32(cast[int8](c.u8())))
  (true, vals)

proc tupleScalar(peaks, starts, ends: seq[float64],
    coords: openArray[float32]): float64 =
  ## OT tuple scalar: peak-zero axes do not participate, degenerate
  ## or straddling supports are skipped, otherwise the product of
  ## per-axis interpolations.
  result = 1.0
  for a in 0 ..< peaks.len:
    let peak = peaks[a]
    if peak == 0.0:
      continue
    let lower = starts[a]
    let upper = ends[a]
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

proc iupAxis(x1, d1, x2, d2: float64, xs: openArray[float64]): seq[
    float64] =
  ## Interpolates one axis between two reference points, clamping
  ## outside and copying when the references coincide.
  result = newSeq[float64](xs.len)
  if x1 == x2:
    let d = if d1 == d2: d1 else: 0.0
    for i in 0 ..< xs.len:
      result[i] = d
    return
  var lo = x1
  var hi = x2
  var dl = d1
  var dh = d2
  if lo > hi:
    lo = x2
    hi = x1
    dl = d2
    dh = d1
  let scale = (dh - dl) / (hi - lo)
  for i, x in xs:
    if x <= lo:
      result[i] = dl
    elif x >= hi:
      result[i] = dh
    else:
      result[i] = dl + (x - lo) * scale

proc applyGvarDeltas*(ctx: GvarContext, gid, numPoints: int,
    ends: openArray[int], xs, ys: var seq[int32]): bool =
  ## Adds gvar deltas for `gid` to the flat outline points in place.
  ## Contours are delimited by `ends` (last index per contour) for IUP
  ## interpolation of untouched points. Returns false on malformed
  ## data, leaving `xs`/`ys` untouched; empty or missing variation
  ## data is a successful no-op.
  if not ctx.hasData():
    return true
  let g = ctx.table
  if gid < 0 or gid >= g.glyphOffsets.len - 1:
    return true
  let off0 = g.glyphOffsets[gid]
  let off1 = g.glyphOffsets[gid + 1]
  if off0 == off1:
    return true
  if off0 + 4 > g.limit or off0 + 4 > g.bytes.len or off1 > g.limit:
    return false
  var hdr = Cursor(bytes: g.bytes, pos: off0, limit: g.limit)
  let rawCount = hdr.u16()
  let dataRel = int(hdr.u16())
  if hdr.failed:
    return false
  let sharedPts = (rawCount and GvarSharedPoints) != 0u16
  let tupleCount = int(rawCount and GvarCountMask)
  # Header sizes first (peaks live inline or in shared tuples).
  type TupHead = tuple[peak: seq[float64], start, finish: seq[float64],
    priv: bool, index: int]
  var heads = newSeq[TupHead](tupleCount)
  for t in 0 ..< tupleCount:
    let ti = hdr.u16()
    if hdr.failed:
      return false
    let embedded = (ti and GvarEmbedPeak) != 0u16
    let inter = (ti and GvarIntermediate) != 0u16
    let priv = (ti and GvarPrivatePoints) != 0u16
    let index = int(ti and GvarTupleIndexMask)
    var peak = newSeq[float64](g.axisCount)
    var start = newSeq[float64](g.axisCount)
    var finish = newSeq[float64](g.axisCount)
    if embedded:
      for a in 0 ..< g.axisCount:
        peak[a] = hdr.f2dot14()
      if hdr.failed:
        return false
    else:
      if index >= g.sharedTuples.len:
        return false
      peak = g.sharedTuples[index]
    if inter:
      for a in 0 ..< g.axisCount:
        start[a] = hdr.f2dot14()
      for a in 0 ..< g.axisCount:
        finish[a] = hdr.f2dot14()
      if hdr.failed:
        return false
    else:
      for a in 0 ..< g.axisCount:
        start[a] = min(peak[a], 0.0)
        finish[a] = max(peak[a], 0.0)
    heads[t] = (peak, start, finish, priv, index)
  var shared: seq[int] = @[]
  if sharedPts:
    let (ok, pts) = parsePoints(hdr, numPoints)
    if not ok:
      return false
    shared = pts
  var dataPos = off0 + dataRel
  if dataPos < hdr.pos or dataPos > g.limit:
    return false
  var acc = newSeq[float64](numPoints * 2)
  var touched = newSeq[bool](numPoints)
  for t in 0 ..< tupleCount:
    var data = Cursor(bytes: g.bytes, pos: dataPos, limit: g.limit)
    var points: seq[int]
    if heads[t].priv:
      let (ok, pts) = parsePoints(data, numPoints)
      if not ok:
        return false
      points = pts
    elif sharedPts:
      points = shared
    else:
      points = newSeq[int](numPoints + 4)
      for i in 0 ..< numPoints + 4:
        points[i] = i
    let scalar = tupleScalar(heads[t].peak, heads[t].start,
      heads[t].finish, ctx.coords)
    let (okx, dxs) = parseDeltas(data, points.len)
    if not okx:
      return false
    let (oky, dys) = parseDeltas(data, points.len)
    if not oky:
      return false
    dataPos = data.pos
    if scalar == 0.0:
      continue
    for k, pt in points:
      if pt >= 0 and pt < numPoints:
        acc[pt * 2] += scalar * float64(dxs[k])
        acc[pt * 2 + 1] += scalar * float64(dys[k])
        touched[pt] = true
  # IUP per contour, then round once into the outline.
  var start = 0
  for e in ends:
    if e < start or e >= numPoints:
      return false
    var hasTouched = false
    for i in start .. e:
      if touched[i]:
        hasTouched = true
        break
    if hasTouched:
      var idx: seq[int] = @[]
      for i in start .. e:
        if touched[i]:
          idx.add(i)
      # Leading wrap segment [start, idx[0]).
      if idx[0] != start:
        let r1 = idx[0]
        let r2 = idx[^1]
        var segX = newSeq[float64]()
        var segY = newSeq[float64]()
        for i in start ..< r1:
          segX.add(float64(xs[i]))
          segY.add(float64(ys[i]))
        let ix = iupAxis(float64(xs[r1]), acc[r1 * 2],
          float64(xs[r2]), acc[r2 * 2], segX)
        let iy = iupAxis(float64(ys[r1]), acc[r1 * 2 + 1],
          float64(ys[r2]), acc[r2 * 2 + 1], segY)
        var k = 0
        for i in start ..< r1:
          acc[i * 2] = ix[k]
          acc[i * 2 + 1] = iy[k]
          inc k
      # Interior segments, plus the trailing wrap as the last one.
      for s in 0 ..< idx.len:
        let r1 = idx[s]
        let rr2 = if s + 1 >= idx.len: idx[0] else: idx[s + 1]
        let lo = r1 + 1
        let hi = if s + 1 >= idx.len: e + 1 else: rr2
        if lo < hi:
          var segX = newSeq[float64]()
          var segY = newSeq[float64]()
          for i in lo ..< hi:
            segX.add(float64(xs[i]))
            segY.add(float64(ys[i]))
          let ix = iupAxis(float64(xs[r1]), acc[r1 * 2],
            float64(xs[rr2]), acc[rr2 * 2], segX)
          let iy = iupAxis(float64(ys[r1]), acc[r1 * 2 + 1],
            float64(ys[rr2]), acc[rr2 * 2 + 1], segY)
          var k = 0
          for i in lo ..< hi:
            acc[i * 2] = ix[k]
            acc[i * 2 + 1] = iy[k]
            inc k
    start = e + 1
  if start != numPoints:
    return false
  for i in 0 ..< numPoints:
    let dx = roundHalfAway(acc[i * 2])
    let dy = roundHalfAway(acc[i * 2 + 1])
    # Clamp the sum into int32 range before adding.
    var nx = int64(xs[i]) + int64(dx)
    var ny = int64(ys[i]) + int64(dy)
    if nx < int64(low(int32)):
      nx = int64(low(int32))
    elif nx > int64(high(int32)):
      nx = int64(high(int32))
    if ny < int64(low(int32)):
      ny = int64(low(int32))
    elif ny > int64(high(int32)):
      ny = int64(high(int32))
    xs[i] = int32(nx)
    ys[i] = int32(ny)
  true
