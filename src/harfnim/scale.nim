import std/math

type
  GlyphExtents* = object
    ## Scaled glyph bounding box.
    xBearing*: int32
    ## Horizontal origin to the left edge.
    yBearing*: int32
    ## Baseline to the top edge.
    width*: int32
    ## Advance width of the box.
    height*: int32
    ## Height of the box.

  Scale* = object
    ## Integer font scale factors.
    xMult: int64
    # Fixed point horizontal multiplier.
    yMult: int64
    # Fixed point vertical multiplier.
    xMultF: float32
    # Float horizontal multiplier.
    yMultF: float32
    # Float vertical multiplier.

proc defaultScale*(): Scale =
  ## Returns the identity scale.
  Scale(xMult: 1i64 shl 16, yMult: 1i64 shl 16, xMultF: 1.0f32, yMultF: 1.0f32)

proc multFromScale(scale, upem: int32): int64 =
  # Converts a point size into a 16.16 fixed point multiplier.
  if scale < 0i32:
    -(((-int64(scale)) shl 16) div int64(upem))
  else:
    (int64(scale) shl 16) div int64(upem)

proc newScale*(xScale, yScale: int32, upem: int32): Scale =
  ## Builds separate horizontal and vertical scales.
  Scale(
    xMult: multFromScale(xScale, upem),
    yMult: multFromScale(yScale, upem),
    xMultF: float32(xScale) / float32(upem),
    yMultF: float32(yScale) / float32(upem),
  )

proc identityScale*(upem: int32): Scale =
  ## Builds the scale matching font units, guarding zero upem.
  if upem == 0i32:
    defaultScale()
  else:
    Scale(
      xMult: multFromScale(upem, upem),
      yMult: multFromScale(upem, upem),
      xMultF: 1.0f32,
      yMultF: 1.0f32,
    )

proc scaleByMult(value: int32, mult: int64): int32 =
  # Applies a 16.16 fixed point multiplier with rounding.
  int32((int64(value) * mult + 32768i64) shr 16)

proc scaleX*(s: Scale, x: int32): int32 =
  ## Scales a horizontal font unit value.
  scaleByMult(x, s.xMult)

proc scaleY*(s: Scale, y: int32): int32 =
  ## Scales a vertical font unit value.
  scaleByMult(y, s.yMult)

proc scaleXF*(s: Scale, x: float32): int32 =
  ## Scales a horizontal float value with rounding.
  round(float64(x * s.xMultF)).int32

proc scaleYF*(s: Scale, y: float32): int32 =
  ## Scales a vertical float value with rounding.
  round(float64(y * s.yMultF)).int32

proc clampAdvance(advance: int32, multF: float32): int32 =
  # Keeps advances from going negative against the scale direction.
  if multF < 0.0f32:
    min(advance, 0i32)
  else:
    max(advance, 0i32)

proc clampXAdvance*(s: Scale, advance: int32): int32 =
  ## Clamps a horizontal advance to the scale direction.
  clampAdvance(advance, s.xMultF)

proc clampYAdvance*(s: Scale, advance: int32): int32 =
  ## Clamps a vertical advance to the scale direction.
  clampAdvance(advance, s.yMultF)

proc scaleExtents*(s: Scale, e: GlyphExtents): GlyphExtents =
  ## Scales a bounding box, flooring the origin and ceiling the far edge.
  let x1 = float64(e.xBearing) * float64(s.xMultF)
  let y1 = float64(e.yBearing) * float64(s.yMultF)
  let x2 = float64(int64(e.xBearing) + int64(e.width)) * float64(s.xMultF)
  let y2 = float64(int64(e.yBearing) + int64(e.height)) * float64(s.yMultF)
  let rx1 = floor(x1)
  let ry1 = floor(y1)
  let rx2 = ceil(x2)
  let ry2 = ceil(y2)
  GlyphExtents(
    xBearing: int32(rx1),
    yBearing: int32(ry1),
    width: int32(rx2 - rx1),
    height: int32(ry2 - ry1),
  )
