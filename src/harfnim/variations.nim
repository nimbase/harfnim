## Variation coordinates for variable fonts.
##
## Converts user-space axis values (e.g. wght 700) to normalized
## [-1, 1] coordinates using the `fvar` axes, with `avar` segment maps
## applied after normalization, mirroring HarfBuzz. Unknown axis tags
## are ignored and unspecified axes reset to default (0.0).

import ./sfnt

proc normalizeCoords*(axes: seq[FvarAxis], avar: seq[seq[AvarSegment]],
    vars: openArray[tuple[tag: uint32, value: float32]]): seq[float32] =
  result = newSeq[float32](axes.len)
  for i, axis in axes:
    var v = 0.0f32
    var found = false
    for (tag, value) in vars:
      if tag == axis.tag:
        v = normalizeAxisValue(axis, value)
        found = true
        break
    if found and i < avar.len:
      v = applyAvarMap(avar[i], v)
    result[i] = v
