## Shared feature-mask bit allocator.
##
## HarfBuzz allocates feature mask bits above the glyph-flag bits:
## valued features occupy as many bits as needed to hold their value.
## Both the default path (shape.nim) and the Indic path used identical
## copies; this module keeps the single implementation.

import std/bitops

proc allocMaskBit*(nextBit: var uint32, value: uint32): tuple[mask, val: uint32] =
  ## Allocates mask bits for a feature value above the glyph flag bits.
  if value == 0u32:
    return (0u32, 0u32)
  var bitsNeeded = 32u32 - uint32(countLeadingZeroBits(value))
  if bitsNeeded == 0u32:
    bitsNeeded = 1u32
  if nextBit + bitsNeeded > 31u32:
    return (0u32, 0u32)
  let mask =
    if nextBit + bitsNeeded >= 32u32: (not 0u32) shl nextBit
    else: ((1u32 shl (nextBit + bitsNeeded)) - (1u32 shl nextBit))
  let vb = value shl nextBit
  nextBit += bitsNeeded
  (mask, vb)
