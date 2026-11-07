## Shaper dispatch: script-to-shaper routing and shared predicates.
##
## Ports the `categorize` routing from harfrust `ot/shaper/mod.rs`.
## Only Arabic and Hebrew have dedicated behavior so far; the Indic,
## Khmer, Myanmar, Thai, Hangul, and USE kinds are returned so future
## commits can attach shaping behavior without changing call sites
## (until then they shape through the default path).

import std/options

import ../direction
import ../script
import ../tag
import ./map

type
  ShaperKind* = enum
    skDefault
    skArabic
    skHebrew
    skHangul
    skThai
    skIndic
    skKhmer
    skMyanmar
    skUse

proc gsubScriptTagFor*(gsub: GsubData, scriptTag: Tag): Option[Tag] =
  ## The GSUB script record tag that `scriptTag` resolves to: the exact
  ## script when present, else the DFLT record, else none.
  for s in gsub.scripts:
    if s.tag == scriptTag.toU32():
      return some(fromU32(s.tag))
  let dflt = defaultScriptTag().toU32()
  for s in gsub.scripts:
    if s.tag == dflt:
      return some(fromU32(s.tag))
  none(Tag)

proc isDfltOrLatn(t: Tag): bool =
  t == defaultScriptTag() or t == tagFromStr("latn")

proc isIndy3(t: Tag): bool =
  (t.toU32() and 0xFFu32) == 0x33u32

proc categorizeShaper*(script: Option[Script], isHorizontal: bool,
    gsubScript: Option[Tag] = none(Tag)): ShaperKind =
  ## Mirrors harfrust `categorize`. Indic-family scripts fall back to
  ## the default shaper when the font only targets DFLT/latn (or,
  ## for Indic, route to USE for `xxx3` script tags), matching the
  ## "designer designed for DFLT" rule.
  if script.isNone:
    return skDefault
  let s = script.get
  if s == Arabic or s == Syriac:
    # Arabic fallback shaping applies to horizontal layout only;
    # vertical text uses the generic shaper.
    if isHorizontal:
      return skArabic
    return skDefault
  if s == Thai or s == Lao:
    return skThai
  if s == Hangul:
    return skHangul
  if s == Hebrew:
    return skHebrew
  if s == Bengali or s == Devanagari or s == Gujarati or s == Gurmukhi or
      s == Kannada or s == Malayalam or s == Oriya or s == Tamil or
      s == Telugu:
    if gsubScript.isNone or isDfltOrLatn(gsubScript.get):
      return skDefault
    if isIndy3(gsubScript.get):
      return skUse
    return skIndic
  if s == Khmer:
    return skKhmer
  if s == Myanmar:
    if gsubScript.isNone or isDfltOrLatn(gsubScript.get) or
        gsubScript.get == tagFromStr("mymr"):
      return skDefault
    return skMyanmar
  if s == MyanmarZawgyi:
    # The Zawgyi shaper is default-like (legacy encoding, no OT
    # features); keep it on the default path.
    return skDefault
  # USE catch-all, mirroring harfrust: Tibetan, Mongolian, Sinhala,
  # Buhid, Hanunoo, Tagalog, Tagbanwa, Limbu, TaiLe, Buginese,
  # Kharoshthi, SylotiNagri, Tifinagh, Balinese, Nko, PhagsPa, Cham,
  # KayahLi, Lepcha, Rejang, Saurashtra, Sundanese,
  # EgyptianHieroglyphs, Javanese, Kaithi, MeeteiMayek, TaiTham,
  # TaiViet, Batak, Brahmi, Mandaic, Chakma, Miao, Sharada, Takri,
  # Duployan, Grantha, Khojki, Khudawadi, Mahajani, Manichaean, Modi,
  # PahawhHmong, PsalterPahlavi, Siddham, Tirhuta, Ahom, Multani,
  # Adlam, Bhaiksuki, Marchen, Newa, MasaramGondi, Soyombo,
  # ZanabazarSquare, Dogra, GunjalaGondi, HanifiRohingya, Makasar,
  # Medefaidrin, OldSogdian, Sogdian, Elymaic, Nandinagari,
  # NyiakengPuachueHmong, Wancho, Chorasmian, DivesAkuru,
  # KhitanSmallScript, Yezidi, CyproMinoan, OldUyghur, Tangsa, Toto,
  # Vithkuqi, Kawi, NagMundari, Garay, GurungKhema, KiratRai, OlOnal,
  # Sunuwar, Todhri, TuluTigalari, BeriaErfe, Sidetic, TaiYo,
  # TolongSiki, Jurchen, ProtoCuneiform, Seal.
  if s == Tibetan or s == Mongolian or s == Sinhala or s == Buhid or
      s == Hanunoo or s == Tagalog or s == Tagbanwa or s == Limbu or
      s == TaiLe or s == Buginese or s == Kharoshthi or
      s == SylotiNagri or s == Tifinagh or s == Balinese or s == Nko or
      s == PhagsPa or s == Cham or s == KayahLi or s == Lepcha or
      s == Rejang or s == Saurashtra or s == Sundanese or
      s == EgyptianHieroglyphs or s == Javanese or s == Kaithi or
      s == MeeteiMayek or s == TaiTham or s == TaiViet or s == Batak or
      s == Brahmi or s == Mandaic or s == Chakma or s == Miao or
      s == Sharada or s == Takri or s == Duployan or s == Grantha or
      s == Khojki or s == Khudawadi or s == Mahajani or s == Manichaean or
      s == Modi or s == PahawhHmong or s == PsalterPahlavi or
      s == Siddham or s == Tirhuta or s == Ahom or s == Multani or
      s == Adlam or s == Bhaiksuki or s == Marchen or s == Newa or
      s == MasaramGondi or s == Soyombo or s == ZanabazarSquare or
      s == Dogra or s == GunjalaGondi or s == HanifiRohingya or
      s == Makasar or s == Medefaidrin or s == OldSogdian or
      s == Sogdian or s == Elymaic or s == Nandinagari or
      s == NyiakengPuachueHmong or s == Wancho or s == Chorasmian or
      s == DivesAkuru or s == KhitanSmallScript or s == Yezidi or
      s == CyproMinoan or s == OldUyghur or s == Tangsa or s == Toto or
      s == Vithkuqi or s == Kawi or s == NagMundari or s == Garay or
      s == GurungKhema or s == KiratRai or s == OlOnal or s == Sunuwar or
      s == Todhri or s == TuluTigalari or s == BeriaErfe or s == Sidetic or
      s == TaiYo or s == TolongSiki or s == Jurchen or
      s == ProtoCuneiform or s == Seal:
    if gsubScript.isNone or isDfltOrLatn(gsubScript.get):
      return skDefault
    return skUse
  skDefault

proc gposHasMark*(gpos: GposData, scriptTag, langTag: Tag): bool =
  ## Whether the `mark` feature resolves to lookups for the script.
  ## Mirrors harfrust `plan.has_gpos_mark` (used to gate Hebrew
  ## presentation-form composition).
  gposLookupsForTag(gpos, scriptTag, langTag,
    tagFromStr("mark").toU32()).len > 0
