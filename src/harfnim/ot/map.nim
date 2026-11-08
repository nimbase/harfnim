import std/options

import ../buffer
import ../feature
import ../scale
import ../tag
import ../varstore
import ./apply
import ./maskbits

export apply

proc findScript*(gsub: GsubData, scriptTag: Tag): Option[int] =
  ## Finds the script record, falling back to DFLT.
  for i, s in gsub.scripts:
    if s.tag == scriptTag.toU32():
      return some(i)
  let dflt = defaultScriptTag().toU32()
  for i, s in gsub.scripts:
    if s.tag == dflt:
      return some(i)
  none(int)

proc findScriptGpos*(gpos: GposData, scriptTag: Tag): Option[int] =
  ## Finds the GPOS script record, falling back to DFLT.
  for i, s in gpos.scripts:
    if s.tag == scriptTag.toU32():
      return some(i)
  let dflt = defaultScriptTag().toU32()
  for i, s in gpos.scripts:
    if s.tag == dflt:
      return some(i)
  none(int)

proc resolveLangSys*(script: ScriptTable, langTag: Tag): Option[LangSys] =
  ## Resolves the language system, falling back to default.
  for l in script.langSys:
    if l.tag == langTag.toU32():
      return some(l.lang)
  script.defaultLang

proc gsubLangSys*(gsub: GsubData, scriptTag, langTag: Tag): Option[LangSys] =
  ## Resolves the LangSys once per shape; callers reuse it for every
  ## feature tag instead of rebuilding the full feature list.
  let si = findScript(gsub, scriptTag)
  if si.isNone:
    return none(LangSys)
  resolveLangSys(gsub.scripts[si.get].script, langTag)

proc gposLangSys*(gpos: GposData, scriptTag, langTag: Tag): Option[LangSys] =
  ## Resolves the GPOS LangSys once per shape.
  let si = findScriptGpos(gpos, scriptTag)
  if si.isNone:
    return none(LangSys)
  resolveLangSys(gpos.scripts[si.get].script, langTag)

proc gsubLookupsForLang*(gsub: GsubData, lang: LangSys,
    tagU32: uint32): seq[uint16] =
  ## Direct tag lookup without building the intermediate available list.
  ## Accumulates across duplicate tags like the old lookupsForTag.
  result = @[]
  if lang.requiredFeature != 0xFFFFu16 and
      int(lang.requiredFeature) < gsub.features.len:
    let f = gsub.features[int(lang.requiredFeature)]
    if f.tag == tagU32:
      result.add(f.lookups)
  for fi in lang.featureIndices:
    if int(fi) < gsub.features.len:
      let f = gsub.features[int(fi)]
      if f.tag == tagU32:
        result.add(f.lookups)

proc gposLookupsForLang*(gpos: GposData, lang: LangSys,
    tagU32: uint32): seq[uint16] =
  ## Direct GPOS tag lookup without intermediate lists.
  result = @[]
  if lang.requiredFeature != 0xFFFFu16 and
      int(lang.requiredFeature) < gpos.features.len:
    let f = gpos.features[int(lang.requiredFeature)]
    if f.tag == tagU32:
      result.add(f.lookups)
  for fi in lang.featureIndices:
    if int(fi) < gpos.features.len:
      let f = gpos.features[int(fi)]
      if f.tag == tagU32:
        result.add(f.lookups)

proc gsubLookupsForTag*(gsub: GsubData, scriptTag, langTag: Tag,
    tagU32: uint32): seq[uint16] =
  ## Resolves the LangSys and looks up one feature tag.
  let lang = gsubLangSys(gsub, scriptTag, langTag)
  if lang.isNone:
    return @[]
  gsubLookupsForLang(gsub, lang.get, tagU32)

proc gposLookupsForTag*(gpos: GposData, scriptTag, langTag: Tag,
    tagU32: uint32): seq[uint16] =
  ## Resolves the GPOS LangSys and looks up one feature tag.
  let lang = gposLangSys(gpos, scriptTag, langTag)
  if lang.isNone:
    return @[]
  gposLookupsForLang(gpos, lang.get, tagU32)

proc gsubFeaturesFor*(gsub: GsubData, scriptTag, langTag: Tag): seq[
    tuple[tag: uint32, lookups: seq[uint16]]] =
  ## Lists features with lookups; kept for compat, off the hot path.
  let si = findScript(gsub, scriptTag)
  if si.isNone:
    return @[]
  let lang = resolveLangSys(gsub.scripts[si.get].script, langTag)
  if lang.isNone:
    return @[]
  let ls = lang.get
  result = @[]
  if ls.requiredFeature != 0xFFFFu16 and int(ls.requiredFeature) <
      gsub.features.len:
    let f = gsub.features[int(ls.requiredFeature)]
    result.add(f)
  for fi in ls.featureIndices:
    if int(fi) < gsub.features.len:
      result.add(gsub.features[int(fi)])

proc applyGsubFeatures*(buf: var Buffer, gsub: GsubData, scriptTag,
    langTag: Tag, features: openArray[Feature]) =
  ## Applies requested GSUB features with fresh masks.
  if features.len == 0:
    return
  let langOpt = gsubLangSys(gsub, scriptTag, langTag)
  if langOpt.isNone:
    return
  let lang = langOpt.get
  # Feature mask bits start above the glyph-flag bits, mirroring
  # harfrust's bit allocation: valued features occupy as many bits as
  # needed to hold their value so lookups can read it back.
  var nextBit = 8u32
  for f in features:
    if f.value == 0u32:
      continue
    let (mask, valueBits) = allocMaskBit(nextBit, f.value)
    if mask == 0u32:
      break
    let lookups = gsubLookupsForLang(gsub, lang, f.tag.toU32())
    if lookups.len == 0:
      continue
    buf.setMasks(valueBits, mask, f.start, f.stop)
    applySubstLookups(buf, gsub, lookups, mask)

proc gposFeaturesFor*(gpos: GposData, scriptTag, langTag: Tag): seq[
    tuple[tag: uint32, lookups: seq[uint16]]] =
  ## Lists GPOS features with lookups; kept for compat, off the hot path.
  let si = findScriptGpos(gpos, scriptTag)
  if si.isNone:
    return @[]
  let lang = resolveLangSys(gpos.scripts[si.get].script, langTag)
  if lang.isNone:
    return @[]
  let ls = lang.get
  result = @[]
  if ls.requiredFeature != 0xFFFFu16 and int(ls.requiredFeature) <
      gpos.features.len:
    let f = gpos.features[int(ls.requiredFeature)]
    result.add(f)
  for fi in ls.featureIndices:
    if int(fi) < gpos.features.len:
      result.add(gpos.features[int(fi)])

proc applyGposFeatures*(buf: var Buffer, gpos: GposData, scriptTag,
    langTag: Tag, features: openArray[Feature], scale: Scale,
    store: VarStore = VarStore(),
    coords: seq[float32] = @[]) =
  ## Applies requested GPOS features with fresh masks.
  if features.len == 0:
    return
  let langOpt = gposLangSys(gpos, scriptTag, langTag)
  if langOpt.isNone:
    return
  let lang = langOpt.get
  if not buf.havePositions:
    buf.clearPositions()
  var nextBit = 8u32
  for f in features:
    if f.value == 0u32:
      continue
    let (mask, valueBits) = allocMaskBit(nextBit, f.value)
    if mask == 0u32:
      break
    let lookups = gposLookupsForLang(gpos, lang, f.tag.toU32())
    if lookups.len == 0:
      continue
    buf.setMasks(valueBits, mask, f.start, f.stop)
    applyPosLookups(buf, gpos, lookups, mask, scale, store, coords)
