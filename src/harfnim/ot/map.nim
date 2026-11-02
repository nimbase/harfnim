import std/options

import ../buffer
import ../feature
import ../tag
import ./apply

export apply

proc findScript*(gsub: GsubData, scriptTag: Tag): Option[int] =
  for i, s in gsub.scripts:
    if s.tag == scriptTag.toU32():
      return some(i)
  let dflt = defaultScriptTag().toU32()
  for i, s in gsub.scripts:
    if s.tag == dflt:
      return some(i)
  none(int)

proc resolveLangSys*(script: ScriptTable, langTag: Tag): Option[LangSys] =
  for l in script.langSys:
    if l.tag == langTag.toU32():
      return some(l.lang)
  script.defaultLang

proc gsubFeaturesFor*(gsub: GsubData, scriptTag, langTag: Tag): seq[
    tuple[tag: uint32, lookups: seq[uint16]]] =
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
  let available = gsubFeaturesFor(gsub, scriptTag, langTag)
  if available.len == 0 or features.len == 0:
    return
  var bitNo = 0
  for f in features:
    if f.value == 0u32:
      continue
    if bitNo >= 31:
      break
    let maskBit = 1u32 shl uint32(bitNo)
    inc bitNo
    var lookups: seq[uint16] = @[]
    for (tag, lks) in available:
      if tag == f.tag.toU32():
        lookups = lks
        break
    if lookups.len == 0:
      continue
    buf.setMasks(maskBit, maskBit, f.start, f.stop)
    applySingleSubstLookups(buf, gsub, lookups, maskBit)
