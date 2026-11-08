import ./tag

type
  Script* = distinct Tag
    ## ISO 15924 script wrapping an OpenType tag.

proc scriptFromBytes*(b: array[4, uint8]): Script =
  ## Builds a script from four big endian bytes.
  Script(tagFromBytes(b))
proc tag*(s: Script): Tag =
  ## Returns the underlying OpenType tag.
  Tag(s)
proc `==`*(a, b: Script): bool =
  ## True when both scripts hold the same tag.
  uint32(a) == uint32(b)
const Common*: Script = Script(tagFromStr("Zyyy"))
    ## Common script (Zyyy).
const Inherited*: Script = Script(tagFromStr("Zinh"))
    ## Inherited script (Zinh).
const Arabic*: Script = Script(tagFromStr("Arab"))
    ## Arabic script (Arab).
const Armenian*: Script = Script(tagFromStr("Armn"))
    ## Armenian script (Armn).
const Bengali*: Script = Script(tagFromStr("Beng"))
    ## Bengali script (Beng).
const Cyrillic*: Script = Script(tagFromStr("Cyrl"))
    ## Cyrillic script (Cyrl).
const Devanagari*: Script = Script(tagFromStr("Deva"))
    ## Devanagari script (Deva).
const Georgian*: Script = Script(tagFromStr("Geor"))
    ## Georgian script (Geor).
const Greek*: Script = Script(tagFromStr("Grek"))
    ## Greek script (Grek).
const Gujarati*: Script = Script(tagFromStr("Gujr"))
    ## Gujarati script (Gujr).
const Gurmukhi*: Script = Script(tagFromStr("Guru"))
    ## Gurmukhi script (Guru).
const Hangul*: Script = Script(tagFromStr("Hang"))
    ## Hangul script (Hang).
const Han*: Script = Script(tagFromStr("Hani"))
    ## Han script (Hani).
const Hebrew*: Script = Script(tagFromStr("Hebr"))
    ## Hebrew script (Hebr).
const Hiragana*: Script = Script(tagFromStr("Hira"))
    ## Hiragana script (Hira).
const Kannada*: Script = Script(tagFromStr("Knda"))
    ## Kannada script (Knda).
const Katakana*: Script = Script(tagFromStr("Kana"))
    ## Katakana script (Kana).
const Lao*: Script = Script(tagFromStr("Laoo"))
    ## Lao script (Laoo).
const Latin*: Script = Script(tagFromStr("Latn"))
    ## Latin script (Latn).
const Malayalam*: Script = Script(tagFromStr("Mlym"))
    ## Malayalam script (Mlym).
const Oriya*: Script = Script(tagFromStr("Orya"))
    ## Oriya script (Orya).
const Tamil*: Script = Script(tagFromStr("Taml"))
    ## Tamil script (Taml).
const Telugu*: Script = Script(tagFromStr("Telu"))
    ## Telugu script (Telu).
const Thai*: Script = Script(tagFromStr("Thai"))
    ## Thai script (Thai).
const Tibetan*: Script = Script(tagFromStr("Tibt"))
    ## Tibetan script (Tibt).
const Bopomofo*: Script = Script(tagFromStr("Bopo"))
    ## Bopomofo script (Bopo).
const Braille*: Script = Script(tagFromStr("Brai"))
    ## Braille script (Brai).
const CanadianSyllabics*: Script = Script(tagFromStr("Cans"))
    ## Canadian Syllabics script (Cans).
const Cherokee*: Script = Script(tagFromStr("Cher"))
    ## Cherokee script (Cher).
const Ethiopic*: Script = Script(tagFromStr("Ethi"))
    ## Ethiopic script (Ethi).
const Khmer*: Script = Script(tagFromStr("Khmr"))
    ## Khmer script (Khmr).
const Mongolian*: Script = Script(tagFromStr("Mong"))
    ## Mongolian script (Mong).
const Myanmar*: Script = Script(tagFromStr("Mymr"))
    ## Myanmar script (Mymr).
const Ogham*: Script = Script(tagFromStr("Ogam"))
    ## Ogham script (Ogam).
const Runic*: Script = Script(tagFromStr("Runr"))
    ## Runic script (Runr).
const Sinhala*: Script = Script(tagFromStr("Sinh"))
    ## Sinhala script (Sinh).
const Syriac*: Script = Script(tagFromStr("Syrc"))
    ## Syriac script (Syrc).
const Thaana*: Script = Script(tagFromStr("Thaa"))
    ## Thaana script (Thaa).
const Yi*: Script = Script(tagFromStr("Yiii"))
    ## Yi script (Yiii).
const Deseret*: Script = Script(tagFromStr("Dsrt"))
    ## Deseret script (Dsrt).
const Gothic*: Script = Script(tagFromStr("Goth"))
    ## Gothic script (Goth).
const OldItalic*: Script = Script(tagFromStr("Ital"))
    ## Old Italic script (Ital).
const Buhid*: Script = Script(tagFromStr("Buhd"))
    ## Buhid script (Buhd).
const Hanunoo*: Script = Script(tagFromStr("Hano"))
    ## Hanunoo script (Hano).
const Tagalog*: Script = Script(tagFromStr("Tglg"))
    ## Tagalog script (Tglg).
const Tagbanwa*: Script = Script(tagFromStr("Tagb"))
    ## Tagbanwa script (Tagb).
const Cypriot*: Script = Script(tagFromStr("Cprt"))
    ## Cypriot script (Cprt).
const Limbu*: Script = Script(tagFromStr("Limb"))
    ## Limbu script (Limb).
const LinearB*: Script = Script(tagFromStr("Linb"))
    ## Linear B script (Linb).
const Osmanya*: Script = Script(tagFromStr("Osma"))
    ## Osmanya script (Osma).
const Shavian*: Script = Script(tagFromStr("Shaw"))
    ## Shavian script (Shaw).
const TaiLe*: Script = Script(tagFromStr("Tale"))
    ## Tai Le script (Tale).
const Ugaritic*: Script = Script(tagFromStr("Ugar"))
    ## Ugaritic script (Ugar).
const Buginese*: Script = Script(tagFromStr("Bugi"))
    ## Buginese script (Bugi).
const Coptic*: Script = Script(tagFromStr("Copt"))
    ## Coptic script (Copt).
const Glagolitic*: Script = Script(tagFromStr("Glag"))
    ## Glagolitic script (Glag).
const Kharoshthi*: Script = Script(tagFromStr("Khar"))
    ## Kharoshthi script (Khar).
const NewTaiLue*: Script = Script(tagFromStr("Talu"))
    ## New Tai Lue script (Talu).
const OldPersian*: Script = Script(tagFromStr("Xpeo"))
    ## Old Persian script (Xpeo).
const SylotiNagri*: Script = Script(tagFromStr("Sylo"))
    ## Syloti Nagri script (Sylo).
const Tifinagh*: Script = Script(tagFromStr("Tfng"))
    ## Tifinagh script (Tfng).
const Unknown*: Script = Script(tagFromStr("Zzzz"))
    ## Unknown script (Zzzz).
const Balinese*: Script = Script(tagFromStr("Bali"))
    ## Balinese script (Bali).
const Cuneiform*: Script = Script(tagFromStr("Xsux"))
    ## Cuneiform script (Xsux).
const Nko*: Script = Script(tagFromStr("Nkoo"))
    ## Nko script (Nkoo).
const PhagsPa*: Script = Script(tagFromStr("Phag"))
    ## Phags Pa script (Phag).
const Phoenician*: Script = Script(tagFromStr("Phnx"))
    ## Phoenician script (Phnx).
const Carian*: Script = Script(tagFromStr("Cari"))
    ## Carian script (Cari).
const Cham*: Script = Script(tagFromStr("Cham"))
    ## Cham script (Cham).
const KayahLi*: Script = Script(tagFromStr("Kali"))
    ## Kayah Li script (Kali).
const Lepcha*: Script = Script(tagFromStr("Lepc"))
    ## Lepcha script (Lepc).
const Lycian*: Script = Script(tagFromStr("Lyci"))
    ## Lycian script (Lyci).
const Lydian*: Script = Script(tagFromStr("Lydi"))
    ## Lydian script (Lydi).
const OlChiki*: Script = Script(tagFromStr("Olck"))
    ## Ol Chiki script (Olck).
const Rejang*: Script = Script(tagFromStr("Rjng"))
    ## Rejang script (Rjng).
const Saurashtra*: Script = Script(tagFromStr("Saur"))
    ## Saurashtra script (Saur).
const Sundanese*: Script = Script(tagFromStr("Sund"))
    ## Sundanese script (Sund).
const Vai*: Script = Script(tagFromStr("Vaii"))
    ## Vai script (Vaii).
const Avestan*: Script = Script(tagFromStr("Avst"))
    ## Avestan script (Avst).
const Bamum*: Script = Script(tagFromStr("Bamu"))
    ## Bamum script (Bamu).
const EgyptianHieroglyphs*: Script = Script(tagFromStr("Egyp"))
    ## Egyptian Hieroglyphs script (Egyp).
const ImperialAramaic*: Script = Script(tagFromStr("Armi"))
    ## Imperial Aramaic script (Armi).
const InscriptionalPahlavi*: Script = Script(tagFromStr("Phli"))
    ## Inscriptional Pahlavi script (Phli).
const InscriptionalParthian*: Script = Script(tagFromStr("Prti"))
    ## Inscriptional Parthian script (Prti).
const Javanese*: Script = Script(tagFromStr("Java"))
    ## Javanese script (Java).
const Kaithi*: Script = Script(tagFromStr("Kthi"))
    ## Kaithi script (Kthi).
const Lisu*: Script = Script(tagFromStr("Lisu"))
    ## Lisu script (Lisu).
const MeeteiMayek*: Script = Script(tagFromStr("Mtei"))
    ## Meetei Mayek script (Mtei).
const OldSouthArabian*: Script = Script(tagFromStr("Sarb"))
    ## Old South Arabian script (Sarb).
const OldTurkic*: Script = Script(tagFromStr("Orkh"))
    ## Old Turkic script (Orkh).
const Samaritan*: Script = Script(tagFromStr("Samr"))
    ## Samaritan script (Samr).
const TaiTham*: Script = Script(tagFromStr("Lana"))
    ## Tai Tham script (Lana).
const TaiViet*: Script = Script(tagFromStr("Tavt"))
    ## Tai Viet script (Tavt).
const Batak*: Script = Script(tagFromStr("Batk"))
    ## Batak script (Batk).
const Brahmi*: Script = Script(tagFromStr("Brah"))
    ## Brahmi script (Brah).
const Mandaic*: Script = Script(tagFromStr("Mand"))
    ## Mandaic script (Mand).
const Chakma*: Script = Script(tagFromStr("Cakm"))
    ## Chakma script (Cakm).
const MeroiticCursive*: Script = Script(tagFromStr("Merc"))
    ## Meroitic Cursive script (Merc).
const MeroiticHieroglyphs*: Script = Script(tagFromStr("Mero"))
    ## Meroitic Hieroglyphs script (Mero).
const Miao*: Script = Script(tagFromStr("Plrd"))
    ## Miao script (Plrd).
const Sharada*: Script = Script(tagFromStr("Shrd"))
    ## Sharada script (Shrd).
const SoraSompeng*: Script = Script(tagFromStr("Sora"))
    ## Sora Sompeng script (Sora).
const Takri*: Script = Script(tagFromStr("Takr"))
    ## Takri script (Takr).
const BassaVah*: Script = Script(tagFromStr("Bass"))
    ## Bassa Vah script (Bass).
const CaucasianAlbanian*: Script = Script(tagFromStr("Aghb"))
    ## Caucasian Albanian script (Aghb).
const Duployan*: Script = Script(tagFromStr("Dupl"))
    ## Duployan script (Dupl).
const Elbasan*: Script = Script(tagFromStr("Elba"))
    ## Elbasan script (Elba).
const Grantha*: Script = Script(tagFromStr("Gran"))
    ## Grantha script (Gran).
const Khojki*: Script = Script(tagFromStr("Khoj"))
    ## Khojki script (Khoj).
const Khudawadi*: Script = Script(tagFromStr("Sind"))
    ## Khudawadi script (Sind).
const LinearA*: Script = Script(tagFromStr("Lina"))
    ## Linear A script (Lina).
const Mahajani*: Script = Script(tagFromStr("Mahj"))
    ## Mahajani script (Mahj).
const Manichaean*: Script = Script(tagFromStr("Mani"))
    ## Manichaean script (Mani).
const MendeKikakui*: Script = Script(tagFromStr("Mend"))
    ## Mende Kikakui script (Mend).
const Modi*: Script = Script(tagFromStr("Modi"))
    ## Modi script (Modi).
const Mro*: Script = Script(tagFromStr("Mroo"))
    ## Mro script (Mroo).
const Nabataean*: Script = Script(tagFromStr("Nbat"))
    ## Nabataean script (Nbat).
const OldNorthArabian*: Script = Script(tagFromStr("Narb"))
    ## Old North Arabian script (Narb).
const OldPermic*: Script = Script(tagFromStr("Perm"))
    ## Old Permic script (Perm).
const PahawhHmong*: Script = Script(tagFromStr("Hmng"))
    ## Pahawh Hmong script (Hmng).
const Palmyrene*: Script = Script(tagFromStr("Palm"))
    ## Palmyrene script (Palm).
const PauCinHau*: Script = Script(tagFromStr("Pauc"))
    ## Pau Cin Hau script (Pauc).
const PsalterPahlavi*: Script = Script(tagFromStr("Phlp"))
    ## Psalter Pahlavi script (Phlp).
const Siddham*: Script = Script(tagFromStr("Sidd"))
    ## Siddham script (Sidd).
const Tirhuta*: Script = Script(tagFromStr("Tirh"))
    ## Tirhuta script (Tirh).
const WarangCiti*: Script = Script(tagFromStr("Wara"))
    ## Warang Citi script (Wara).
const Ahom*: Script = Script(tagFromStr("Ahom"))
    ## Ahom script (Ahom).
const AnatolianHieroglyphs*: Script = Script(tagFromStr("Hluw"))
    ## Anatolian Hieroglyphs script (Hluw).
const Hatran*: Script = Script(tagFromStr("Hatr"))
    ## Hatran script (Hatr).
const Multani*: Script = Script(tagFromStr("Mult"))
    ## Multani script (Mult).
const OldHungarian*: Script = Script(tagFromStr("Hung"))
    ## Old Hungarian script (Hung).
const Signwriting*: Script = Script(tagFromStr("Sgnw"))
    ## Signwriting script (Sgnw).
const Adlam*: Script = Script(tagFromStr("Adlm"))
    ## Adlam script (Adlm).
const Bhaiksuki*: Script = Script(tagFromStr("Bhks"))
    ## Bhaiksuki script (Bhks).
const Marchen*: Script = Script(tagFromStr("Marc"))
    ## Marchen script (Marc).
const Osage*: Script = Script(tagFromStr("Osge"))
    ## Osage script (Osge).
const Tangut*: Script = Script(tagFromStr("Tang"))
    ## Tangut script (Tang).
const Newa*: Script = Script(tagFromStr("Newa"))
    ## Newa script (Newa).
const MasaramGondi*: Script = Script(tagFromStr("Gonm"))
    ## Masaram Gondi script (Gonm).
const Nushu*: Script = Script(tagFromStr("Nshu"))
    ## Nushu script (Nshu).
const Soyombo*: Script = Script(tagFromStr("Soyo"))
    ## Soyombo script (Soyo).
const ZanabazarSquare*: Script = Script(tagFromStr("Zanb"))
    ## Zanabazar Square script (Zanb).
const Dogra*: Script = Script(tagFromStr("Dogr"))
    ## Dogra script (Dogr).
const GunjalaGondi*: Script = Script(tagFromStr("Gong"))
    ## Gunjala Gondi script (Gong).
const HanifiRohingya*: Script = Script(tagFromStr("Rohg"))
    ## Hanifi Rohingya script (Rohg).
const Makasar*: Script = Script(tagFromStr("Maka"))
    ## Makasar script (Maka).
const Medefaidrin*: Script = Script(tagFromStr("Medf"))
    ## Medefaidrin script (Medf).
const OldSogdian*: Script = Script(tagFromStr("Sogo"))
    ## Old Sogdian script (Sogo).
const Sogdian*: Script = Script(tagFromStr("Sogd"))
    ## Sogdian script (Sogd).
const Elymaic*: Script = Script(tagFromStr("Elym"))
    ## Elymaic script (Elym).
const Nandinagari*: Script = Script(tagFromStr("Nand"))
    ## Nandinagari script (Nand).
const NyiakengPuachueHmong*: Script = Script(tagFromStr("Hmnp"))
    ## Nyiakeng Puachue Hmong script (Hmnp).
const Wancho*: Script = Script(tagFromStr("Wcho"))
    ## Wancho script (Wcho).
const Chorasmian*: Script = Script(tagFromStr("Chrs"))
    ## Chorasmian script (Chrs).
const DivesAkuru*: Script = Script(tagFromStr("Diak"))
    ## Dives Akuru script (Diak).
const KhitanSmallScript*: Script = Script(tagFromStr("Kits"))
    ## Khitan Small Script script (Kits).
const Yezidi*: Script = Script(tagFromStr("Yezi"))
    ## Yezidi script (Yezi).
const CyproMinoan*: Script = Script(tagFromStr("Cpmn"))
    ## Cypro Minoan script (Cpmn).
const OldUyghur*: Script = Script(tagFromStr("Ougr"))
    ## Old Uyghur script (Ougr).
const Tangsa*: Script = Script(tagFromStr("Tnsa"))
    ## Tangsa script (Tnsa).
const Toto*: Script = Script(tagFromStr("Toto"))
    ## Toto script (Toto).
const Vithkuqi*: Script = Script(tagFromStr("Vith"))
    ## Vithkuqi script (Vith).
const Kawi*: Script = Script(tagFromStr("Kawi"))
    ## Kawi script (Kawi).
const NagMundari*: Script = Script(tagFromStr("Nagm"))
    ## Nag Mundari script (Nagm).
const Garay*: Script = Script(tagFromStr("Gara"))
    ## Garay script (Gara).
const GurungKhema*: Script = Script(tagFromStr("Gukh"))
    ## Gurung Khema script (Gukh).
const KiratRai*: Script = Script(tagFromStr("Krai"))
    ## Kirat Rai script (Krai).
const OlOnal*: Script = Script(tagFromStr("Onao"))
    ## Ol Onal script (Onao).
const Sunuwar*: Script = Script(tagFromStr("Sunu"))
    ## Sunuwar script (Sunu).
const Todhri*: Script = Script(tagFromStr("Todr"))
    ## Todhri script (Todr).
const TuluTigalari*: Script = Script(tagFromStr("Tutg"))
    ## Tulu Tigalari script (Tutg).
const BeriaErfe*: Script = Script(tagFromStr("Berf"))
    ## Beria Erfe script (Berf).
const Sidetic*: Script = Script(tagFromStr("Sidt"))
    ## Sidetic script (Sidt).
const TaiYo*: Script = Script(tagFromStr("Tayo"))
    ## Tai Yo script (Tayo).
const TolongSiki*: Script = Script(tagFromStr("Tols"))
    ## Tolong Siki script (Tols).
const Jurchen*: Script = Script(tagFromStr("Jurc"))
    ## Jurchen script (Jurc).
const ProtoCuneiform*: Script = Script(tagFromStr("Pcun"))
    ## Proto Cuneiform script (Pcun).
const Seal*: Script = Script(tagFromStr("Seal"))
    ## Seal script (Seal).
const Math*: Script = Script(tagFromStr("Zmth"))
    ## Math script (Zmth).
const MyanmarZawgyi*: Script = Script(tagFromStr("Qaag"))
    ## Myanmar Zawgyi script (Qaag).

proc fromIso15924Tag*(t: Tag): tuple[ok: bool, script: Script] =
  ## Maps an ISO 15924 tag to a script, normalizing aliases.
  let v = t.toU32()
  if v == 0:
    return (false, Unknown)
  let norm = (v and 0xDFDFDFDFu32) or 0x00202020u32
  if (norm and 0xE0E0E0E0u32) != 0x40606060u32:
    return (true, Unknown)
  let s = Tag(norm).toStr()
  case s
  of "Aran": (true, Arabic)
  of "Cyrs": (true, Cyrillic)
  of "Geok": (true, Georgian)
  of "Hans", "Hant": (true, Han)
  of "Jamo": (true, Hangul)
  of "Latf", "Latg": (true, Latin)
  of "Syre", "Syrj", "Syrn": (true, Syriac)
  else: (true, Script(t))

proc parseScript*(s: string): Script =
  ## Parses an ISO 15924 code; raises ValueError when empty.
  let (ok, sc) = fromIso15924Tag(tagFromStr(s))
  if not ok:
    raise newException(ValueError, "invalid script")
  sc
