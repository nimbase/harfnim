# Getting started

## Install

Requires Nim >= 2.2.0 (see `harfnim.nimble`).

```sh
nimble install harfnim
```

For development inside this repo, `clue` is the build and test wrapper
(`clue.lock` is committed):

```sh
clue test
clue build tools/hr_shape.nim --out:/tmp/hr-shape
```

## Minimal shaping example

```nim
import harfnim

proc readBytes(path: string): seq[uint8] =
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  for i, c in s:
    result[i] = uint8(c)

let font = parseFont(readBytes("Arial.ttf"))
var shaper = newShaperFont(font)
shaper.setScale(1000)

var buf = newBuffer()
buf.pushStr("AVfi")
shaper.shape(buf, @[globalFeature(tagFromStr("kern"), 1),
  globalFeature(tagFromStr("liga"), 1)])

for i in 0 ..< buf.len:
  echo buf.info[i].glyphId, " adv=", buf.pos[i].xAdvance
```

Notes:

* `parseFont` (`src/harfnim/sfnt.nim`) parses SFNT tables from bytes.
* `newShaperFont` (`src/harfnim/font.nim`) wraps the font with scale,
  variation coordinates, outline cache, and lazy layout tables.
* `newBuffer` / `pushStr` (`src/harfnim/buffer.nim`) fill a Unicode buffer.
* `shape` (`src/harfnim/shape.nim`) runs the full pipeline and writes
  glyph ids into `buf.info` plus positions into `buf.pos`.
* Features are `Feature(tag, value, start, stop)` (`src/harfnim/feature.nim`).
  `globalFeature` covers the whole buffer.

## Arabic example

Joining and mark handling are automatic:

```nim
import harfnim

let font = parseFont(readBytes("Arial.ttf"))
var shaper = newShaperFont(font)
shaper.setScale(1000)

var buf = newBuffer()
buf.pushStr("مرحبا")
shaper.shape(buf)
```

## Next

Read [Architecture](architecture.md) for the pipeline, then
[Buffer](buffer.md) and [Fonts](fonts.md).
