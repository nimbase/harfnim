## TrueType `glyf` outline decoder.
##
## Decodes simple glyphs (points, flags, deltas) and composite glyphs
## (component records with scale/2x2 transforms) into draw ops. Any
## inconsistency inside a glyph makes the decode fail with `none` /
## `false`; out-of-range table access is contained the same way rather
## than raising, mirroring how `glyphBoundsUnscaled` returns `none` for
## bad loca data.

import std/options

import ./draw
import ./gvar

const
  GlyfMaxDepth = 16
  GlyfMaxTotalPoints = 1 shl 20

type
  TTPoint* = tuple[x, y: int32, onCurve: bool]
  TTContour* = seq[TTPoint]

  Reader = object
    bytes: seq[uint8]
    pos: int
    limit: int
    failed: bool

proc rd8(r: var Reader): uint8 =
  if r.pos < 0 or r.pos >= r.limit:
    r.failed = true
    return 0u8
  result = r.bytes[r.pos]
  inc r.pos

proc rdU16(r: var Reader): uint16 =
  let hi = uint16(r.rd8())
  let lo = uint16(r.rd8())
  if r.failed:
    0u16
  else:
    (hi shl 8) or lo

proc rdI16(r: var Reader): int16 =
  cast[int16](r.rdU16())

proc f2dot14(v: int16): float64 =
  float64(v) / 16384.0

proc mid(a, b: int32): int32 =
  (a + b) div 2

proc emitContour*(pts: TTContour, cb: proc(op: DrawOp) {.closure.}) =
  ## Emits one TrueType contour, resolving implied on-curve midpoints
  ## between consecutive off-curve points as quadratic segments.
  let m = pts.len
  if m == 0:
    return
  var sx, sy: int32
  var visit: seq[TTPoint] = @[]
  if pts[0].onCurve:
    sx = pts[0].x
    sy = pts[0].y
    for i in 1 ..< m:
      visit.add(pts[i])
  elif pts[m - 1].onCurve:
    sx = pts[m - 1].x
    sy = pts[m - 1].y
    for i in 0 ..< m - 1:
      visit.add(pts[i])
  else:
    sx = mid(pts[m - 1].x, pts[0].x)
    sy = mid(pts[m - 1].y, pts[0].y)
    for p in pts:
      visit.add(p)
  cb(DrawOp(kind: moveTo, to: (sx, sy)))
  var px, py: int32
  var pending = false
  for p in visit:
    if p.onCurve:
      if pending:
        cb(DrawOp(kind: quadraticTo, qCtrl: (px, py), qTo: (p.x, p.y)))
        pending = false
      else:
        cb(DrawOp(kind: lineTo, to: (p.x, p.y)))
    else:
      if pending:
        let mx = mid(px, p.x)
        let my = mid(py, p.y)
        cb(DrawOp(kind: quadraticTo, qCtrl: (px, py), qTo: (mx, my)))
        px = p.x
        py = p.y
      else:
        px = p.x
        py = p.y
        pending = true
  if pending:
    cb(DrawOp(kind: quadraticTo, qCtrl: (px, py), qTo: (sx, sy)))
  cb(DrawOp(kind: closePath))

proc emitContours*(cs: seq[TTContour],
    cb: proc(op: DrawOp) {.closure.}) =
  for c in cs:
    emitContour(c, cb)

proc decodeSimple(r: var Reader, numContours: int): Option[seq[TTContour]] =
  var ends: seq[int] = @[]
  for _ in 0 ..< numContours:
    ends.add(int(r.rdU16()))
  if r.failed:
    return none(seq[TTContour])
  let instrLen = int(r.rdU16())
  if r.failed:
    return none(seq[TTContour])
  if instrLen < 0 or r.pos + instrLen > r.limit:
    return none(seq[TTContour])
  r.pos += instrLen
  if ends.len == 0:
    return some(newSeq[TTContour]())
  let numPoints = ends[^1] + 1
  if numPoints <= 0 or numPoints > 65536:
    return none(seq[TTContour])
  for i in 1 ..< ends.len:
    if ends[i] < ends[i - 1]:
      return none(seq[TTContour])
  var flags: seq[uint8] = @[]
  while flags.len < numPoints:
    let f = r.rd8()
    if r.failed:
      return none(seq[TTContour])
    flags.add(f)
    if (f and 8u8) != 0u8:
      let n = int(r.rd8())
      if r.failed:
        return none(seq[TTContour])
      for _ in 0 ..< n:
        flags.add(f)
        if flags.len > numPoints:
          return none(seq[TTContour])
  if flags.len != numPoints:
    return none(seq[TTContour])
  var xs = newSeq[int32](numPoints)
  var x = 0i32
  for i in 0 ..< numPoints:
    let f = flags[i]
    if (f and 2u8) != 0u8:
      let b = int32(r.rd8())
      if r.failed:
        return none(seq[TTContour])
      if (f and 16u8) != 0u8:
        x += b
      else:
        x -= b
    elif (f and 16u8) == 0u8:
      x += int32(r.rdI16())
      if r.failed:
        return none(seq[TTContour])
    xs[i] = x
  var ys = newSeq[int32](numPoints)
  var y = 0i32
  for i in 0 ..< numPoints:
    let f = flags[i]
    if (f and 4u8) != 0u8:
      let b = int32(r.rd8())
      if r.failed:
        return none(seq[TTContour])
      if (f and 32u8) != 0u8:
        y += b
      else:
        y -= b
    elif (f and 32u8) == 0u8:
      y += int32(r.rdI16())
      if r.failed:
        return none(seq[TTContour])
    ys[i] = y
  var cs: seq[TTContour] = @[]
  var start = 0
  for e in ends:
    var c: TTContour = @[]
    for i in start .. e:
      c.add((xs[i], ys[i], (flags[i] and 1u8) != 0u8))
    cs.add(c)
    start = e + 1
  some(cs)

proc xformPt(x, y: int32, a, b, c, d, e, f: float64): tuple[x, y: int32] =
  (draw.roundHalfAway(float64(x) * a + float64(y) * b + e),
    draw.roundHalfAway(float64(x) * c + float64(y) * d + f))

proc decodeGlyphOutlines*(bytes: seq[uint8], off, len: int,
    glyphAt: proc(gid: uint32): tuple[ok: bool, off, len: int] {.closure.},
    depth: int = 0, gid: uint32 = 0u32,
    gvar: GvarContext = noGvarContext()): Option[seq[TTContour]] =
  ## Decodes the glyph at `off`/`len` into point contours. Composite
  ## components resolve through `glyphAt`. When `gvar` carries
  ## variation data, per-glyph deltas apply in glyph space before
  ## component transforms. Returns `none` for empty or malformed
  ## glyphs.
  if depth > GlyfMaxDepth:
    return none(seq[TTContour])
  if off < 0 or len < 10 or off + len > bytes.len:
    # Shorter slices are empty (loca start == end) or malformed;
    # either way there is no outline to decode.
    return none(seq[TTContour])
  var r = Reader(bytes: bytes, pos: off, limit: off + len)
  let numContours = int(r.rdI16())
  if r.failed:
    return none(seq[TTContour])
  if numContours == 0:
    return none(seq[TTContour])
  # Skip the bounding box; bounds come from the decoded points.
  r.pos += 8
  if numContours > 0:
    let csOpt = decodeSimple(r, numContours)
    if csOpt.isNone or not gvar.hasData():
      return csOpt
    # Flatten, apply gvar deltas (base kept on malformed data), and
    # rebuild the contours with identical on-curve flags.
    var cs = csOpt.get
    var ends = newSeq[int]()
    var xs = newSeq[int32]()
    var ys = newSeq[int32]()
    var flags = newSeq[bool]()
    for c in cs:
      for p in c:
        xs.add(p.x)
        ys.add(p.y)
        flags.add(p.onCurve)
      ends.add(xs.len - 1)
    if xs.len == 0:
      return csOpt
    discard applyGvarDeltas(gvar, int(gid), xs.len, ends, xs, ys)
    var outCs: seq[TTContour] = @[]
    var start = 0
    for e in ends:
      var nc: TTContour = @[]
      for i in start .. e:
        nc.add((xs[i], ys[i], flags[i]))
      outCs.add(nc)
      start = e + 1
    return some(outCs)
  # Composite glyph.
  var acc: seq[TTContour] = @[]
  var total = 0
  var more = true
  while more:
    let flags = r.rdU16()
    let compGid = r.rdU16()
    if r.failed:
      return none(seq[TTContour])
    var a1, a2: int32
    if (flags and 0x1u16) != 0u16:
      a1 = int32(r.rdI16())
      a2 = int32(r.rdI16())
    else:
      a1 = int32(int8(r.rd8()))
      a2 = int32(int8(r.rd8()))
    if r.failed:
      return none(seq[TTContour])
    var a, b, c, d: float64 = 0.0
    a = 1.0
    d = 1.0
    if (flags and 0x8u16) != 0u16:
      let s = f2dot14(r.rdI16())
      a = s
      d = s
    elif (flags and 0x40u16) != 0u16:
      a = f2dot14(r.rdI16())
      d = f2dot14(r.rdI16())
    elif (flags and 0x80u16) != 0u16:
      a = f2dot14(r.rdI16())
      b = f2dot14(r.rdI16())
      c = f2dot14(r.rdI16())
      d = f2dot14(r.rdI16())
    if r.failed:
      return none(seq[TTContour])
    let ga = glyphAt(uint32(compGid))
    if not ga.ok:
      return none(seq[TTContour])
    # A valid empty component contributes nothing; peek at the header
    # so empties do not fail the whole glyph. (Short slices cannot be
    # valid glyphs and are likewise skipped.)
    var emptyComp = ga.len < 10
    if not emptyComp:
      if ga.off < 0 or ga.off + 2 > bytes.len:
        return none(seq[TTContour])
      emptyComp = cast[int16]((uint16(bytes[ga.off]) shl 8) or
        uint16(bytes[ga.off + 1])) == 0i16
    if emptyComp:
      discard
    else:
      let sub = decodeGlyphOutlines(bytes, ga.off, ga.len, glyphAt,
        depth + 1, uint32(compGid), gvar)
      if sub.isNone:
        return none(seq[TTContour])
      var e, f: float64
      if (flags and 0x2u16) != 0u16:
        e = float64(a1)
        f = float64(a2)
        if (flags and 0x400u16) != 0u16:
          let te = a * e + b * f
          let tf = c * e + d * f
          e = te
          f = tf
      else:
        # Matched points: align this component's point a2 onto the
        # accumulated outline's point a1.
        var flat: seq[TTPoint] = @[]
        for cc in acc:
          for p in cc:
            flat.add(p)
        if flat.len == 0:
          e = 0.0
          f = 0.0
        else:
          if a1 < 0 or a1 >= int32(flat.len):
            return none(seq[TTContour])
          var cflat: seq[TTPoint] = @[]
          for cc in sub.get:
            for p in cc:
              cflat.add(p)
          if a2 < 0 or a2 >= int32(cflat.len):
            return none(seq[TTContour])
          # Component points are pre-transform here; match in the
          # component's own space then translate after transform.
          let t = xformPt(cflat[int(a2)].x, cflat[int(a2)].y, a, b, c, d,
            0.0, 0.0)
          e = float64(flat[int(a1)].x - t.x)
          f = float64(flat[int(a1)].y - t.y)
      for cc in sub.get:
        var nc: TTContour = @[]
        for p in cc:
          let t = xformPt(p.x, p.y, a, b, c, d, e, f)
          nc.add((t.x, t.y, p.onCurve))
          inc total
          if total > GlyfMaxTotalPoints:
            return none(seq[TTContour])
        acc.add(nc)
    more = (flags and 0x20u16) != 0u16
    if not more and (flags and 0x100u16) != 0u16:
      let ilen = int(r.rdU16())
      if r.failed or ilen < 0 or r.pos + ilen > r.limit:
        return none(seq[TTContour])
      r.pos += ilen
  if r.failed:
    return none(seq[TTContour])
  if acc.len == 0:
    return none(seq[TTContour])
  some(acc)

proc drawGlyfGlyph*(bytes: seq[uint8], off, len: int,
    glyphAt: proc(gid: uint32): tuple[ok: bool, off, len: int] {.closure.},
    cb: proc(op: DrawOp) {.closure.}, gid: uint32 = 0u32,
    gvar: GvarContext = noGvarContext()): bool =
  ## Emits draw ops for the glyph at `off`/`len`. Returns false when the
  ## glyph is empty or malformed.
  let cs = decodeGlyphOutlines(bytes, off, len, glyphAt, 0, gid, gvar)
  if cs.isNone or cs.get.len == 0:
    return false
  emitContours(cs.get, cb)
  true
