## Full shaping orchestration: ShapePlan + shape() entry.
##
## Mirrors harfrust shape.rs / ot/layout.rs at a minimal Latin-first scope.
## Complex shapers (arabic, indic, thai, hangul, hebrew, khmer, myanmar,
## USE, syllabic), per-syllable matching, global-bit / F_HAS_FALLBACK map
## parity, fallback mark positioning, space fallback, zero-width marks,
## form_clusters, and native-direction handling stay TODO.

import std/options

import ./buffer
import ./direction
import ./feature
import ./font
import ./normalize
import ./script
import ./tag
import ./unicode
import ./ot/gpos
import ./ot/gsub
import ./ot/map

export buffer
export feature
export font
export tag

type
  ShapePlan* = object
    scriptTag*: Tag
    langTag*: Tag
    features*: seq[Feature]

proc newShapePlan*(scriptTag, langTag: Tag,
    features: openArray[Feature]): ShapePlan =
  var feats: seq[Feature] = @[]
  for f in features:
    feats.add(f)
  ShapePlan(scriptTag: scriptTag, langTag: langTag, features: feats)

proc scriptTagForBuffer(b: Buffer): Tag =
  if b.script.isSome:
    # TODO: full ISO 15924 to OpenType script-tag mapping (harfrust
    # hb_ot_tag_from_script has special cases); lowercasing covers
    # Latin and most scripts in our synthetic fonts.
    b.script.get.tag().toLower()
  else:
    defaultScriptTag()

proc langTagForBuffer(b: Buffer): Tag =
  # TODO: BCP47 to OpenType language-tag mapping (harfrust map language).
  # For now always the default language system.
  discard b
  defaultLanguageTag()

proc insertDottedCircle(b: var Buffer) =
  if b.isEmpty():
    return
  if b.flags.contains(DoNotInsertDottedCircle):
    return
  if b.len > b.info.len:
    return
  if not b.info[0].isUnicodeMark():
    return
  if not b.ensure(b.len + 1):
    return
  let cluster =
    if b.len > 0: b.info[0].cluster
    else: 0u32
  for i in countdown(b.len - 1, 0):
    b.info[i + 1] = b.info[i]
  b.info[0] = GlyphInfo(glyphId: 0x25CCu32, cluster: cluster)
  inc b.len
  var scratch = 0u32
  b.info[0].initUnicodeProps(scratch)

proc setBaseAdvances(b: var Buffer, sf: ShaperFont) =
  if b.direction.isHorizontal():
    for i in 0 ..< b.len:
      if i < b.info.len and i < b.pos.len:
        b.pos[i].xAdvance = sf.hAdvance(newGlyphId(b.info[i].glyphId))
  else:
    # TODO: vertical origin adjustment (needs vOrigin from extents/metrics).
    for i in 0 ..< b.len:
      if i < b.info.len and i < b.pos.len:
        b.pos[i].yAdvance = sf.vAdvance(newGlyphId(b.info[i].glyphId))

proc shapePlan*(font: ShaperFont, buf: var Buffer,
    features: openArray[Feature]): ShapePlan =
  buf.guessSegmentProperties()
  newShapePlan(scriptTagForBuffer(buf), langTagForBuffer(buf), features)

proc shapeWithPlan*(font: ShaperFont, buf: var Buffer, plan: ShapePlan) =
  buf.guessSegmentProperties()
  let sf = font
  buf.allocateUnicodeVars()
  var scratch = 0u32
  for i in 0 ..< buf.len:
    if i < buf.info.len:
      buf.info[i].initUnicodeProps(scratch)
  insertDottedCircle(buf)
  # TODO: form_clusters, ensure_native_direction, shaper preprocess,
  #   per-syllable matching, global-bit map parity.
  var nctx = sf.normalizeContextFor()
  buf.normalize(nmComposedDiacritics, false, nctx)
  buf.deallocateUnicodeVars()
  buf.mapGlyphsFast()
  buf.setContentType(some(contentGlyphs))
  buf.allocateGsubGposVars()
  let gsubOpt = parseGsub(sf.font)
  if gsubOpt.isSome:
    buf.applyGsubFeatures(gsubOpt.get, plan.scriptTag, plan.langTag,
      plan.features)
  buf.clearPositions()
  setBaseAdvances(buf, sf)
  # TODO: zero marks by GDEF, fallback spaces, zero default ignorables.
  let gposOpt = parseGpos(sf.font)
  if gposOpt.isSome:
    buf.applyGposFeatures(gposOpt.get, plan.scriptTag, plan.langTag,
      plan.features, sf.scale)
  # TODO: position_finish_advances, position_finish_offsets,
  #   fallback mark positioning.
  buf.deallocateGsubGposVars()

proc shape*(font: ShaperFont, buf: var Buffer,
    features: openArray[Feature] = []) =
  let plan = shapePlan(font, buf, features)
  shapeWithPlan(font, buf, plan)
