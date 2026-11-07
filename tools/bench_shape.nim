## bench_shape: minimal shaping micro-benchmark (no external fonts).
##
## Builds a tiny synthetic font (ASCII cmap, no GSUB/GPOS) and times:
## 1. coverage binary search (raw int path)
## 2. full shape() calls on short text
## Use as a before/after guard for perf refactors.

import std/monotimes
import std/options
import std/times

import harfnim
import harfnim/ot/coverage
import harfnim/ot/gsub

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

proc putI16(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc buildCmap(): seq[uint8] =
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.putU16(4u16)
  let segCount = 27
  result.putU16(uint16(16 + segCount * 8))
  result.putU16(0u16)
  result.putU16(uint16(segCount * 2))
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(0u16)
  for i in 0 ..< 26:
    result.putU16(uint16(0x61 + i))
  result.putU16(0xFFFFu16)
  result.putU16(0u16)
  for i in 0 ..< 26:
    result.putU16(uint16(0x61 + i))
  result.putU16(0xFFFFu16)
  for i in 0 ..< 26:
    result.putU16(uint16((int(1 + i) - (0x61 + i)) and 0xFFFF))
  result.putI16(1i16)
  for _ in 0 ..< 26:
    result.putU16(0u16)
  result.putU16(0u16)

proc baseTables(cmap: seq[uint8]): seq[tuple[name: string, data: seq[uint8]]] =
  var head = newSeq[uint8]()
  head.putU32(0x00010000u32)
  head.putU32(0u32)
  head.putU32(0u32)
  head.putU32(0x5F0F3CF5u32)
  head.putU16(0u16)
  head.putU16(1000u16)
  for _ in 0 ..< 4:
    head.putU32(0u32)
  for _ in 0 ..< 4:
    head.putI16(0i16)
  head.putU16(0u16)
  head.putU16(0u16)
  head.putI16(0i16)
  head.putI16(0i16)
  head.putU16(0u16)
  var hhea = newSeq[uint8]()
  hhea.putU32(0x00010000u32)
  hhea.putI16(800i16)
  hhea.putI16(-200i16)
  hhea.putI16(0i16)
  hhea.putU16(600u16)
  for _ in 0 ..< 11:
    hhea.putI16(0i16)
  hhea.putU16(2u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(30u16)
  var hmtx = newSeq[uint8]()
  for _ in 0 ..< 30:
    hmtx.putU16(500u16)
    hmtx.putI16(0i16)
  var loca = newSeq[uint8](10)
  @[("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca)]

proc buildFontRaw(tables: seq[tuple[name: string, data: seq[uint8]]]): seq[
    uint8] =
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(64u16)
  result.putU16(2u16)
  result.putU16(48u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    result.putU32(uint32((data.len + 3) and not 3))
    off += (data.len + 3) and not 3
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc benchCoverage(cov: Coverage, n: int): float =
  let t0 = getMonoTime()
  var acc = 0
  for i in 0 ..< n:
    acc += cov.coverageIndexRaw(uint32(1 + (i mod 30)))
  let dt = (getMonoTime() - t0).inNanoseconds.float / 1e9
  # Prevent optimization.
  if acc < 0:
    echo acc
  dt

proc benchShape(fontBytes: seq[uint8], text: string, n: int): float =
  let f = parseFont(fontBytes)
  var sf = newShaperFont(f)
  let t0 = getMonoTime()
  for _ in 0 ..< n:
    var b = newBuffer()
    b.pushStr(text)
    sf.shape(b, @[])
  let dt = (getMonoTime() - t0).inNanoseconds.float / 1e9
  dt

proc putTag(s: var seq[uint8], t: string) =
  for c in t:
    s.add(uint8(c))

proc putU16At(s: var seq[uint8], pos: int, v: uint16) =
  s[pos] = uint8(v shr 8)
  s[pos + 1] = uint8(v and 0xFFu16)

proc covBytes(glyphs: seq[uint16]): seq[uint8] =
  result = @[]
  result.putU16(1u16)
  result.putU16(uint16(glyphs.len))
  for g in glyphs:
    result.putU16(g)

proc singleSubstBytes(first, rep: uint16): seq[uint8] =
  result = @[]
  result.putU16(2u16)
  let covPos = result.len
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(rep)
  let covOff = result.len
  result.putU16At(covPos, uint16(covOff))
  for b in covBytes(@[first]):
    result.add(b)

proc buildGsubMany(n: int): seq[uint8] =
  ## GSUB with `n` single-subst lookups; only lookup 0 is referenced
  ## by the ccmp feature. Eager parsing pays for all `n`; lazy parses
  ## headers plus lookup 0 on demand.
  var lookups: seq[tuple[typ, flag: uint16, sub: seq[uint8]]] = @[]
  for i in 0 ..< n:
    lookups.add((1u16, 0u16,
      singleSubstBytes(uint16(1 + (i mod 200)), uint16(300 + i))))
  result = @[]
  result.putU32(0x00010000u32)
  let scriptLen = 2 + 6 + (2 + 2 + 2 + 2 + 2 + 1 * 2)
  let featLen = 2 + 1 * 6 + 1 * 6
  let featOff = 10 + scriptLen
  let lookupOff = featOff + featLen
  result.putU16(10u16)
  result.putU16(uint16(featOff))
  result.putU16(uint16(lookupOff))
  result.putU16(1u16)
  result.putTag("DFLT")
  result.putU16(8u16)
  result.putU16(4u16)
  result.putU16(0u16)
  result.putU16(0u16)
  result.putU16(0xFFFFu16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(1u16)
  result.putTag("ccmp")
  result.putU16(uint16(2 + 1 * 6))
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(uint16(lookups.len))
  var loff = 2 + lookups.len * 2
  for i in 0 ..< lookups.len:
    result.putU16(uint16(loff))
    loff += 8 + lookups[i].sub.len
  for lk in lookups:
    result.putU16(lk.typ)
    result.putU16(lk.flag)
    result.putU16(1u16)
    result.putU16(8u16)
    for b in lk.sub:
      result.add(b)

proc benchLazy(fontBytes: seq[uint8], nLookups: int) =
  let f = parseFont(fontBytes)
  let t0 = getMonoTime()
  let g = parseGsub(f)
  let dtParse = (getMonoTime() - t0).inNanoseconds.float / 1e9
  if g.isNone:
    echo "lazy gsub: parse failed"
    return
  let t1 = getMonoTime()
  discard getGsubLookup(g.get, 0)
  let dtOne = (getMonoTime() - t1).inNanoseconds.float / 1e9
  let t2 = getMonoTime()
  var acc = 0
  for i in 0 ..< nLookups:
    acc += getGsubLookup(g.get, i).lookupType.int
  let dtAll = (getMonoTime() - t2).inNanoseconds.float / 1e9
  if acc < 0:
    echo acc
  echo "lazy gsub (", nLookups, " lookups): header-only parse ", dtParse,
    "s, first lookup ", dtOne, "s, all lookups ", dtAll, "s"

proc main() =
  let fontBytes = buildFontRaw(baseTables(buildCmap()))
  var glyphs = newSeq[uint32](30)
  for i in 0 ..< 30:
    glyphs[i] = uint32(1 + i)
  let cov = Coverage(glyphs: glyphs, ranges: @[], present: true)
  let nCov = 500_000
  let dtCov = benchCoverage(cov, nCov)
  echo "coverage raw: ", nCov, " lookups in ", dtCov, "s (",
    int(nCov.float / max(dtCov, 1e-9)), "/s)"
  let nShape = 5_000
  let dtShape = benchShape(fontBytes, "hello world hello world", nShape)
  echo "shape ascii: ", nShape, " shapes in ", dtShape, "s (",
    int(nShape.float / max(dtShape, 1e-9)), "/s)"
  let nLazy = 200
  var many = baseTables(buildCmap())
  many.add(("GSUB", buildGsubMany(nLazy)))
  benchLazy(buildFontRaw(many), nLazy)

main()
