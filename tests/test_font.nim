import std/options
import unittest

import harfnim

# --------------------------------------------------------------------------
# Minimal synthetic TTF builder
# --------------------------------------------------------------------------

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

proc putI16(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc putTag(s: var seq[uint8], a, b, c, d: char) =
  s.add(uint8(a))
  s.add(uint8(b))
  s.add(uint8(c))
  s.add(uint8(d))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc buildCmapFormat4(): seq[uint8] =
  result = @[]
  result.putU16(4u16)
  result.putU16(32u16)
  result.putU16(0u16)
  result.putU16(4u16)
  result.putU16(4u16)
  result.putU16(1u16)
  result.putU16(0u16)
  result.putU16(0x43u16)
  result.putU16(0xFFFFu16)
  result.putU16(0u16)
  result.putU16(0x41u16)
  result.putU16(0xFFFFu16)
  result.putI16(-64i16)
  result.putI16(1i16)
  result.putU16(0u16)
  result.putU16(0u16)

proc buildCmapFormat12(): seq[uint8] =
  result = @[]
  result.putU16(12u16)
  result.putU16(0u16)
  result.putU32(28u32)
  result.putU32(0u32)
  result.putU32(1u32)
  result.putU32(0x1F600u32)
  result.putU32(0x1F600u32)
  result.putU32(5u32)

proc buildCmap(subtables: seq[tuple[plat, enc: uint16, data: seq[uint8]]]): seq[
    uint8] =
  result = @[]
  result.putU16(0u16)
  result.putU16(uint16(subtables.len))
  var off = 4 + subtables.len * 8
  for st in subtables:
    result.putU16(st.plat)
    result.putU16(st.enc)
    result.putU32(uint32(off))
    off += st.data.len
  for st in subtables:
    result.add(st.data)

proc buildFont(cmap: seq[uint8]): seq[uint8] =
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
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putI16(1i16)
  hhea.putI16(1i16)
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putI16(0i16)
  hhea.putU16(2u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(3u16)
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putI16(20i16)
  var loca = @[0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8]
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca),
  ]
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    var padded = (data.len + 3) and not 3
    result.putU32(uint32(padded))
    off += padded
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc buildFontWithGlyf(cmap: seq[uint8]): seq[uint8] =
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
  maxp.putU16(3u16)
  var hmtx = newSeq[uint8]()
  hmtx.putU16(500u16)
  hmtx.putI16(0i16)
  hmtx.putU16(600u16)
  hmtx.putI16(10i16)
  hmtx.putI16(20i16)
  var loca = @[0u8, 0u8, 0u8, 0u8, 0u8, 5u8, 0u8, 5u8]
  var glyf = newSeq[uint8]()
  glyf.putU16(1u16)
  glyf.putI16(10i16)
  glyf.putI16(20i16)
  glyf.putI16(30i16)
  glyf.putI16(40i16)
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca), ("glyf", glyf),
  ]
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for c in name:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    var padded = (data.len + 3) and not 3
    result.putU32(uint32(padded))
    off += padded
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc buildTtc(fonts: seq[seq[uint8]]): seq[uint8] =
  # Spec-compliant TTC: each face keeps its own Offset Table, but table
  # offsets are rewritten to be absolute from the start of the TTC file
  # (faces may share tables, as real TTCs do).
  result = @[]
  result.putTag('t', 't', 'c', 'f')
  result.putU16(0x0001u16)
  result.putU16(0x0000u16)
  result.putU32(uint32(fonts.len))
  var faceOff = 12 + fonts.len * 4
  var faceOffs: seq[int] = @[]
  for f in fonts:
    result.putU32(uint32(faceOff))
    faceOffs.add(faceOff)
    faceOff += f.len
  for fi, f in fonts:
    var patched = f
    let numTables = int((uint16(patched[4]) shl 8) or uint16(patched[5]))
    for i in 0 ..< numTables:
      let base = 12 + i * 16
      let rel = (int(patched[base + 8]) shl 24) or
        (int(patched[base + 9]) shl 16) or (int(patched[base + 10]) shl 8) or
        int(patched[base + 11])
      let absOff = faceOffs[fi] + rel
      patched[base + 8] = uint8((absOff shr 24) and 0xFF)
      patched[base + 9] = uint8((absOff shr 16) and 0xFF)
      patched[base + 10] = uint8((absOff shr 8) and 0xFF)
      patched[base + 11] = uint8(absOff and 0xFF)
    result.add(patched)

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

test "scale math":
  let s = defaultScale()
  check s.scaleX(500i32) == 500i32
  check s.scaleY(-300i32) == -300i32
  let s2 = newScale(2000i32, 2000i32, 1000i32)
  check s2.scaleX(500i32) == 1000i32
  check s2.clampXAdvance(-5i32) == 0i32
  let s3 = newScale(-2000i32, -2000i32, 1000i32)
  check s3.clampXAdvance(5i32) == 0i32
  check s3.clampXAdvance(-5i32) == -5i32
  let e = GlyphExtents(xBearing: 10i32, yBearing: 20i32, width: 30i32,
      height: 40i32)
  let se = s2.scaleExtents(e)
  check se == GlyphExtents(xBearing: 20i32, yBearing: 40i32, width: 60i32,
      height: 80i32)

test "cmap format 4":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  let f = parseFont(buildFont(cmap))
  check f.unitsPerEm == 1000u16
  check f.numGlyphs == 3u16
  check f.mapUnicode(0x41u32) == some(newGlyphId(1))
  check f.mapUnicode(0x42u32) == some(newGlyphId(2))
  check f.mapUnicode(0x43u32) == some(newGlyphId(3))
  check f.mapUnicode(0x44u32) == none(GlyphId)
  check f.mapUnicode(0x1F600u32) == none(GlyphId)

test "cmap format 12":
  let cmap = buildCmap(@[(3u16, 10u16, buildCmapFormat12())])
  let f = parseFont(buildFont(cmap))
  check f.mapUnicode(0x1F600u32) == some(newGlyphId(5))
  check f.mapUnicode(0x1F601u32) == none(GlyphId)
  check f.mapUnicode(0x41u32) == none(GlyphId)

test "cmap prefers full unicode subtable":
  var f12 = buildCmapFormat12()
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4()),
    (3u16, 10u16, f12)])
  let f = parseFont(buildFont(cmap))
  check f.isSymbol == false
  check f.mapUnicode(0x41u32) == none(GlyphId)
  check f.mapUnicode(0x1F600u32) == some(newGlyphId(5))

test "hmtx advances":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  let f = parseFont(buildFont(cmap))
  check f.hAdvance(0u32) == 500i32
  check f.hAdvance(1u32) == 600i32
  check f.hAdvance(2u32) == 600i32
  check f.hSideBearing(1u32) == 10i32
  check f.hSideBearing(2u32) == 20i32

test "ttc face selection":
  let f1 = buildFont(buildCmap(@[(3u16, 1u16, buildCmapFormat4())]))
  let f2 = buildFont(buildCmap(@[(3u16, 10u16, buildCmapFormat12())]))
  let ttc = buildTtc(@[f1, f2])
  check numFaces(ttc) == 2
  let a = parseFont(ttc, 0)
  let b = parseFont(ttc, 1)
  check a.mapUnicode(0x41u32) == some(newGlyphId(1))
  check b.mapUnicode(0x1F600u32) == some(newGlyphId(5))

test "shaper font queries":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  var sf = newShaperFont(parseFont(buildFont(cmap)))
  check sf.unitsPerEm == 1000u16
  check sf.nominalGlyph(0x41u32) == some(newGlyphId(1))
  check sf.hasGlyph(0x43u32)
  check (not sf.hasGlyph(0x44u32))
  check sf.hAdvance(newGlyphId(1)) == 600i32
  check sf.vAdvance(newGlyphId(1)) == -1000i32
  sf.setScale(2000i32)
  check sf.hAdvance(newGlyphId(1)) == 1200i32
  check sf.variationGlyph(0x41u32, 0xFE00u32) == none(GlyphId)
  var infos = @[GlyphInfo(glyphId: 0x41u32), GlyphInfo(glyphId: 0x44u32)]
  check sf.nominalGlyphs(infos, 0, 2) == 1
  check infos[0].normalizerGlyphIndex() == 1u32

test "shaper font drives normalize":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  let sf = newShaperFont(parseFont(buildFont(cmap)))
  var b = newBuffer()
  b.push(0x41u32, 0)
  var scratch = 0u32
  b.info[0].initUnicodeProps(scratch)
  b.allocateUnicodeVars()
  var ctx = sf.normalizeContextFor()
  b.normalize(nmComposedDiacritics, false, ctx)
  check b.len == 1
  check b.glyphInfosView()[0].normalizerGlyphIndex() == 1u32
  b.deallocateUnicodeVars()

test "rejects garbage":
  var raised = false
  try:
    discard parseFont([1u8, 2u8, 3u8])
  except FontError:
    raised = true
  check raised
  raised = false
  try:
    discard parseFont(buildTtc(@[]), 3)
  except FontError:
    raised = true
  check raised

test "glyph extents simple bounds":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  let sf = newShaperFont(parseFont(buildFontWithGlyf(cmap)))
  check sf.glyphExtents(newGlyphId(0)) == none(GlyphExtents)
  check sf.glyphExtents(newGlyphId(1)) ==
    some(GlyphExtents(xBearing: 10i32, yBearing: 40i32, width: 20i32,
      height: -20i32))
  check sf.glyphExtents(newGlyphId(2)) == none(GlyphExtents)
  check sf.glyphExtents(newGlyphId(9)) == none(GlyphExtents)

# --------------------------------------------------------------------------
# cmap format 14 (UVS) and name table
# --------------------------------------------------------------------------

proc putU24(s: var seq[uint8], v: uint32) =
  s.add(uint8((v shr 16) and 0xFFu32))
  s.add(uint8((v shr 8) and 0xFFu32))
  s.add(uint8(v and 0xFFu32))

proc buildCmap14(records: seq[tuple[selector: uint32,
    defaultRanges: seq[tuple[first, additional: uint32]],
    mappings: seq[tuple[unicode: uint32, gid: uint16]]]]): seq[uint8] =
  result = @[]
  result.putU16(14u16)
  let lenPos = result.len
  result.putU32(0u32) # length placeholder
  result.putU32(uint32(records.len))
  var recPos: seq[int] = @[]
  for _ in records:
    recPos.add(result.len)
    result.putU24(0u32)
    result.putU32(0u32)
    result.putU32(0u32)
  for i, r in records:
    result[recPos[i]] = uint8((r.selector shr 16) and 0xFFu32)
    result[recPos[i]+1] = uint8((r.selector shr 8) and 0xFFu32)
    result[recPos[i]+2] = uint8(r.selector and 0xFFu32)
    if r.defaultRanges.len > 0:
      let dOff = result.len
      result[recPos[i]+3] = uint8((dOff shr 24) and 0xFF)
      result[recPos[i]+4] = uint8((dOff shr 16) and 0xFF)
      result[recPos[i]+5] = uint8((dOff shr 8) and 0xFF)
      result[recPos[i]+6] = uint8(dOff and 0xFF)
      result.putU32(uint32(r.defaultRanges.len))
      for dr in r.defaultRanges:
        result.putU24(dr.first)
        result.add(uint8(dr.additional and 0xFFu32))
    if r.mappings.len > 0:
      let nOff = result.len
      result[recPos[i]+7] = uint8((nOff shr 24) and 0xFF)
      result[recPos[i]+8] = uint8((nOff shr 16) and 0xFF)
      result[recPos[i]+9] = uint8((nOff shr 8) and 0xFF)
      result[recPos[i]+10] = uint8(nOff and 0xFF)
      result.putU32(uint32(r.mappings.len))
      for m in r.mappings:
        result.putU24(m.unicode)
        result.putU16(m.gid)
  let total = result.len
  result[lenPos] = uint8((total shr 24) and 0xFF)
  result[lenPos+1] = uint8((total shr 16) and 0xFF)
  result[lenPos+2] = uint8((total shr 8) and 0xFF)
  result[lenPos+3] = uint8(total and 0xFF)

proc buildFontSized(cmap: seq[uint8], numGlyphs: int,
    name: seq[uint8] = @[]): seq[uint8] =
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
  hhea.putU16(uint16(numGlyphs))
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(uint16(numGlyphs))
  var hmtx = newSeq[uint8]()
  for _ in 0 ..< numGlyphs:
    hmtx.putU16(500u16)
    hmtx.putI16(0i16)
  var loca = newSeq[uint8]()
  for _ in 0 .. numGlyphs:
    loca.add(0u8)
    loca.add(0u8)
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca),
  ]
  if name.len > 0:
    tables.add(("name", name))
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (tname, data) in tables:
    for c in tname:
      result.add(uint8(c))
    result.putU32(0u32)
    result.putU32(uint32(off))
    var padded = (data.len + 3) and not 3
    result.putU32(uint32(padded))
    off += padded
  for (_, data) in tables:
    result.add(data)
    result.pad4()

proc encodeUtf16Be(s: string): seq[uint8] =
  result = @[]
  for c in s:
    result.putU16(uint16(ord(c)))

proc buildName(records: seq[tuple[plat, enc, lang, id: uint16,
    text: string]]): seq[uint8] =
  result = @[]
  result.putU16(0u16)
  result.putU16(uint16(records.len))
  let stringOff = 6 + records.len * 12
  result.putU16(uint16(stringOff))
  var storage = newSeq[uint8]()
  var offs: seq[int] = @[]
  for r in records:
    result.putU16(r.plat)
    result.putU16(r.enc)
    result.putU16(r.lang)
    result.putU16(r.id)
    let enc = encodeUtf16Be(r.text)
    result.putU16(uint16(enc.len))
    offs.add(storage.len)
    result.putU16(0u16) # patched below
    for b in enc:
      storage.add(b)
  for i, o in offs:
    let pos = 6 + i * 12 + 10
    result[pos] = uint8((o shr 8) and 0xFF)
    result[pos+1] = uint8(o and 0xFF)
  for b in storage:
    result.add(b)

test "cmap14 non-default variant":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4()),
    (0u16, 5u16, buildCmap14(@[(selector: 0xFE00u32,
      defaultRanges: newSeq[tuple[first, additional: uint32]](), mappings: @[(unicode: 0x41u32, gid: 7u16)])]))])
  let sf = newShaperFont(parseFont(buildFontSized(cmap, 10)))
  check sf.nominalGlyph(0x41u32) == some(newGlyphId(1))
  check sf.variationGlyph(0x41u32, 0xFE00u32) == some(newGlyphId(7))
  check sf.variationGlyph(0x42u32, 0xFE00u32) == none(GlyphId)
  check sf.variationGlyph(0x41u32, 0xFE01u32) == none(GlyphId)

test "cmap14 default variant falls back to nominal":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4()),
    (0u16, 5u16, buildCmap14(@[(selector: 0xFE01u32,
      defaultRanges: @[(first: 0x41u32, additional: 1u32)],
      mappings: newSeq[tuple[unicode: uint32, gid: uint16]]()) ]))])
  let sf = newShaperFont(parseFont(buildFontSized(cmap, 10)))
  check sf.variationGlyph(0x41u32, 0xFE01u32) == some(newGlyphId(1))
  check sf.variationGlyph(0x42u32, 0xFE01u32) == some(newGlyphId(2))
  check sf.variationGlyph(0x43u32, 0xFE01u32) == none(GlyphId)

test "cmap14 out-of-range gid is none":
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4()),
    (0u16, 5u16, buildCmap14(@[(selector: 0xFE00u32,
      defaultRanges: newSeq[tuple[first, additional: uint32]](), mappings: @[(unicode: 0x41u32, gid: 99u16)])]))])
  let sf = newShaperFont(parseFont(buildFontSized(cmap, 10)))
  check sf.variationGlyph(0x41u32, 0xFE00u32) == none(GlyphId)

test "cmap14 truncated is contained":
  var bad = buildCmap14(@[(selector: 0xFE00u32, defaultRanges: newSeq[tuple[first, additional: uint32]](),
    mappings: @[(unicode: 0x41u32, gid: 7u16)])])
  bad.setLen(bad.len - 3)
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4()), (0u16, 5u16, bad)])
  let sf = newShaperFont(parseFont(buildFontSized(cmap, 10)))
  check sf.nominalGlyph(0x41u32) == some(newGlyphId(1))
  check sf.variationGlyph(0x41u32, 0xFE00u32) == none(GlyphId)

test "name table lookup":
  let name = buildName(@[(3u16, 1u16, 0x0409u16, 1u16, "TestFam"),
    (3u16, 1u16, 0x0409u16, 2u16, "Regular")])
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  let f = parseFont(buildFontSized(cmap, 3, name))
  check f.names.len == 2
  check f.fontName(1u16) == some("TestFam")
  check f.fontName(2u16) == some("Regular")
  check f.fontName(3u16) == none(string)
  check f.fontName(1u16, languageID = 0x0411u16) == some("TestFam")

test "name table truncated is contained":
  var bad = buildName(@[(3u16, 1u16, 0x0409u16, 1u16, "TestFam")])
  bad.setLen(bad.len - 2)
  let cmap = buildCmap(@[(3u16, 1u16, buildCmapFormat4())])
  let f = parseFont(buildFontSized(cmap, 3, bad))
  check f.mapUnicode(0x41u32) == some(newGlyphId(1))
