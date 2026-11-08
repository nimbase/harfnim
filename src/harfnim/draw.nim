import std/options
import std/tables

type
  DrawOpKind* = enum
    ## Path operations, mirroring HarfBuzz draw funcs.
    moveTo
    ## Move the pen without drawing.
    lineTo
    ## Draw a straight segment.
    quadraticTo
    ## Draw a quadratic curve.
    cubicTo
    ## Draw a cubic curve.
    closePath
    ## Close the current subpath.

  DrawPoint* = tuple[x, y: int32]
    ## Integer outline point.

  DrawOp* = object
    ## Path operation with kind-specific points.
    ## Discriminated by kind.
    case kind*: DrawOpKind
    of moveTo, lineTo:
      to*: DrawPoint
      ## Endpoint.
    of quadraticTo:
      qCtrl*, qTo*: DrawPoint
      ## Control point and endpoint.
    of cubicTo:
      c1*, c2*, cTo*: DrawPoint
      ## First control, second control, and endpoint.
    of closePath:
      discard

  OutlinePoint* = object
    ## Contour point.
    x*, y*: int32
    ## Coordinates in font units.
    onCurve*: bool
    ## True for on-curve points.

  OutlineContour* = object
    ## One outline contour.
    points*: seq[OutlinePoint]
    ## Contour points in order.
    closed*: bool
    ## True when the contour is closed.

  GlyphOutline* = object
    ## Decoded glyph outline.
    contours*: seq[OutlineContour]
    ## Outline contours.

  OutlineBuilder* = object
    ## Incremental outline collector.
    contours*: seq[OutlineContour]
    ## Finished contours.
    cur*: seq[OutlinePoint]
    ## Open contour under construction.
    hasCur: bool
    # True while a contour is open.

  OutlineCache* = ref object
    ## Lazily filled per-glyph outlines in font units, shared by copies
    ## of the owning ShaperFont. Failures are cached as none so repeated
    ## queries on malformed data do not re-decode. Bounded FIFO: the
    ## oldest entry is evicted once `maxItems` is exceeded, so CJK-sized
    ## fonts cannot grow the table without limit.
    items*: Table[uint32, Option[GlyphOutline]]
    ## Cached outlines by glyph id.
    order*: seq[uint32]
    ## Insertion order for FIFO eviction.
    maxItems*: int
    ## Maximum entries before eviction.

proc roundHalfAway*(v: float64): int32 =
  ## Rounds half away from zero.
  if v >= 0.0: int32(v + 0.5) else: int32(v - 0.5)

proc newOutlineCache*(maxItems = 256): OutlineCache =
  ## Creates a bounded outline cache.
  OutlineCache(items: initTable[uint32, Option[GlyphOutline]](), order: @[],
    maxItems: maxItems)

proc cacheLookup*(c: OutlineCache,
    gid: uint32): tuple[hit: bool, v: Option[GlyphOutline]] =
  ## Looks up a cached outline, reporting misses including nil caches.
  if c.isNil or not c.items.hasKey(gid):
    (false, none(GlyphOutline))
  else:
    (true, c.items[gid])

proc cacheStore*(c: OutlineCache, gid: uint32, v: Option[GlyphOutline]) =
  ## Stores an outline, evicting the oldest entry when full.
  if c.isNil:
    return
  if c.items.hasKey(gid):
    c.items[gid] = v
    return
  if c.maxItems > 0 and c.order.len >= c.maxItems:
    let oldest = c.order[0]
    c.order.delete(0)
    c.items.del(oldest)
  c.items[gid] = v
  c.order.add(gid)

proc `==`*(a, b: DrawOp): bool =
  ## True when both ops carry the same points.
  if a.kind != b.kind:
    return false
  case a.kind
  of moveTo, lineTo:
    a.to == b.to
  of quadraticTo:
    a.qCtrl == b.qCtrl and a.qTo == b.qTo
  of cubicTo:
    a.c1 == b.c1 and a.c2 == b.c2 and a.cTo == b.cTo
  of closePath:
    true

proc feed*(b: var OutlineBuilder, op: DrawOp) =
  ## Groups a raw op stream into contours, implicitly closing an open
  ## contour on moveTo so emitters may omit closePath between subpaths.
  case op.kind
  of moveTo:
    if b.hasCur and b.cur.len > 0:
      b.contours.add(OutlineContour(points: b.cur, closed: true))
      b.cur = @[]
    b.cur.add(OutlinePoint(x: op.to.x, y: op.to.y, onCurve: true))
    b.hasCur = true
  of lineTo:
    if not b.hasCur:
      return
    b.cur.add(OutlinePoint(x: op.to.x, y: op.to.y, onCurve: true))
  of quadraticTo:
    if not b.hasCur:
      return
    b.cur.add(OutlinePoint(x: op.qCtrl.x, y: op.qCtrl.y, onCurve: false))
    b.cur.add(OutlinePoint(x: op.qTo.x, y: op.qTo.y, onCurve: true))
  of cubicTo:
    if not b.hasCur:
      return
    b.cur.add(OutlinePoint(x: op.c1.x, y: op.c1.y, onCurve: false))
    b.cur.add(OutlinePoint(x: op.c2.x, y: op.c2.y, onCurve: false))
    b.cur.add(OutlinePoint(x: op.cTo.x, y: op.cTo.y, onCurve: true))
  of closePath:
    if b.hasCur and b.cur.len > 0:
      b.contours.add(OutlineContour(points: b.cur, closed: true))
      b.cur = @[]
      b.hasCur = false

proc finish*(b: var OutlineBuilder): GlyphOutline =
  ## Closes any open contour and returns the outline.
  if b.hasCur and b.cur.len > 0:
    b.contours.add(OutlineContour(points: b.cur, closed: true))
    b.cur = @[]
    b.hasCur = false
  GlyphOutline(contours: b.contours)

proc collectInto*(b: var OutlineBuilder,
    emit: proc(cb: proc(op: DrawOp) {.closure.}): bool {.closure.}):
    bool =
  ## Feeds an emitter into this builder, returning the emitter's status;
  ## ops stage through a sequence because closures cannot capture the builder.
  var ops: seq[DrawOp] = @[]
  let ok = emit(proc(op: DrawOp) = ops.add(op))
  for op in ops:
    b.feed(op)
  ok

proc replayOutline*(o: GlyphOutline,
    cb: proc(op: DrawOp) {.closure.}) =
  ## Re-emits a stored outline as ops for cache hits.
  for c in o.contours:
    if c.points.len == 0:
      continue
    cb(DrawOp(kind: moveTo, to: (c.points[0].x, c.points[0].y)))
    var i = 1
    while i < c.points.len:
      if c.points[i].onCurve:
        cb(DrawOp(kind: lineTo, to: (c.points[i].x, c.points[i].y)))
        inc i
      elif i + 1 < c.points.len and not c.points[i + 1].onCurve and
          i + 2 < c.points.len and c.points[i + 2].onCurve:
        cb(DrawOp(kind: cubicTo, c1: (c.points[i].x, c.points[i].y),
          c2: (c.points[i + 1].x, c.points[i + 1].y),
          cTo: (c.points[i + 2].x, c.points[i + 2].y)))
        i += 3
      else:
        # Lone off-curve: quadratic onto the next on-curve point, or
        # onto the contour start when it is the last point.
        let nxt =
          if i + 1 < c.points.len: (c.points[i + 1].x, c.points[i + 1].y)
          else: (c.points[0].x, c.points[0].y)
        cb(DrawOp(kind: quadraticTo, qCtrl: (c.points[i].x, c.points[i].y),
          qTo: nxt))
        i += 2
    cb(DrawOp(kind: closePath))

proc outlineBounds*(o: GlyphOutline): Option[tuple[xMin, yMin, xMax,
    yMax: int32]] =
  ## Computes integer bounds, none for empty outlines.
  var first = true
  var xMin, yMin, xMax, yMax = 0i32
  for c in o.contours:
    for p in c.points:
      if first:
        xMin = p.x
        yMin = p.y
        xMax = p.x
        yMax = p.y
        first = false
      else:
        if p.x < xMin:
          xMin = p.x
        if p.y < yMin:
          yMin = p.y
        if p.x > xMax:
          xMax = p.x
        if p.y > yMax:
          yMax = p.y
  if first:
    none(tuple[xMin, yMin, xMax, yMax: int32])
  else:
    some((xMin, yMin, xMax, yMax))
