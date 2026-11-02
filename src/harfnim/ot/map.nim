import std/options

import std/bitops
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
  # Feature mask bits start above the glyph-flag bits, mirroring
  # harfrust's bit allocation: valued features occupy as many bits as
  # needed to hold their value so lookups can read it back.
  var nextBit = 8u32
  for f in features:
    if f.value == 0u32:
      continue
    let bitsNeeded = 32u32 - uint32(countLeadingZeroBits(f.value))
    if nextBit + bitsNeeded > 31u32:
      break
    let mask =
      if nextBit + bitsNeeded >= 32u32: (not 0u32) shl nextBit
      else: ((1u32 shl (nextBit + bitsNeeded)) - (1u32 shl nextBit))
    let valueBits = f.value shl nextBit
    nextBit += bitsNeeded
    var lookups: seq[uint16] = @[]
    for (tag, lks) in available:
      if tag == f.tag.toU32():
        lookups = lks
        break
    if lookups.len == 0:
      continue
    buf.setMasks(valueBits, mask, f.start, f.stop)
    applySubstLookups(buf, gsub, lookups, mask)
