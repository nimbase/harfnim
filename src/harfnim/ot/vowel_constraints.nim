## Vowel-letter constraints: dotted-circle insertion inside
## vowel sequences that look like another vowel.
##
## Ports the Indic-script sections of the generated harfrust
## `ot/shaper/vowel_constraints.rs` (data collected from the USE
## script development spec). Sinhala/Brahmi/Khojki/Khudawadi/Tirhuta/
## Modi/Takri sections stay TODO with their shapers.

import std/options

import ../buffer
import ../script

type
  VowelPair* = tuple[first: uint32, seconds: seq[uint32]]

const
  DevanagariVowels*: seq[VowelPair] = @[
    (0x0905u32, @[0x093Au32, 0x093Bu32, 0x093Eu32, 0x0945u32, 0x0946u32,
      0x0949u32, 0x094Au32, 0x094Bu32, 0x094Cu32, 0x094Fu32, 0x0956u32,
      0x0957u32]),
    (0x0906u32, @[0x093Au32, 0x0945u32, 0x0946u32, 0x0947u32, 0x0948u32]),
    (0x0909u32, @[0x0941u32]),
    (0x090Fu32, @[0x0945u32, 0x0946u32, 0x0947u32]),
  ]
  BengaliVowels*: seq[VowelPair] = @[
    (0x0985u32, @[0x09BEu32]),
    (0x098Bu32, @[0x09C3u32]),
    (0x098Cu32, @[0x09E2u32]),
  ]
  GurmukhiVowels*: seq[VowelPair] = @[
    (0x0A05u32, @[0x0A3Eu32, 0x0A48u32, 0x0A4Cu32]),
    (0x0A72u32, @[0x0A3Fu32, 0x0A40u32, 0x0A47u32]),
    (0x0A73u32, @[0x0A41u32, 0x0A42u32, 0x0A4Bu32]),
  ]
  GujaratiVowels*: seq[VowelPair] = @[
    (0x0A85u32, @[0x0ABEu32, 0x0AC5u32, 0x0AC7u32, 0x0AC8u32, 0x0AC9u32,
      0x0ACBu32, 0x0ACCu32]),
    (0x0AC5u32, @[0x0ABEu32]),
  ]
  OriyaVowels*: seq[VowelPair] = @[
    (0x0B05u32, @[0x0B3Eu32]),
    (0x0B0Fu32, @[0x0B57u32]),
    (0x0B13u32, @[0x0B57u32]),
  ]
  TeluguVowels*: seq[VowelPair] = @[
    (0x0C12u32, @[0x0C4Cu32, 0x0C55u32]),
    (0x0C3Fu32, @[0x0C55u32]),
    (0x0C46u32, @[0x0C55u32]),
    (0x0C4Au32, @[0x0C55u32]),
  ]
  KannadaVowels*: seq[VowelPair] = @[
    (0x0C89u32, @[0x0CBEu32]),
    (0x0C8Bu32, @[0x0CBEu32]),
    (0x0C92u32, @[0x0CCCu32]),
  ]
  MalayalamVowels*: seq[VowelPair] = @[
    (0x0D07u32, @[0x0D57u32]),
    (0x0D09u32, @[0x0D57u32]),
    (0x0D0Eu32, @[0x0D46u32]),
    (0x0D12u32, @[0x0D3Eu32, 0x0D57u32]),
  ]

proc curGlyphAt(buf: Buffer, i: int): uint32 =
  # Reads the codepoint at a cursor offset, 0 when out of range.
  if buf.idx + i < 0 or buf.idx + i >= buf.info.len:
    return 0u32
  buf.info[buf.idx + i].glyphId

proc outputDottedCircle(buf: var Buffer) =
  # Emits a dotted circle placeholder.
  buf.outputGlyph(0x25CCu32)
  let slot = buf.outAt(buf.outLen - 1)
  if slot == nil:
    buf.indexFailed()
  else:
    slot[].clearContinuation()

proc outputWithDottedCircle(buf: var Buffer) =
  # Emits the current glyph followed by a dotted circle.
  outputDottedCircle(buf)
  buf.nextGlyph()

proc preprocessVowelConstraints*(buf: var Buffer) =
  ## Inserts dotted circles into ambiguous vowel sequences for the
  ## Indic scripts, on codepoints pre-normalize. Other scripts pass
  ## through unchanged (clear + sync is identity).
  if buf.flags.contains(DoNotInsertDottedCircle):
    return
  buf.clearOutput()
  if buf.script.isSome:
    let s = buf.script.get
    var table: seq[VowelPair] = @[]
    var isTamilAu = false
    var isDevaRa = false
    if s == Devanagari:
      table = DevanagariVowels
      isDevaRa = true
    elif s == Bengali:
      table = BengaliVowels
    elif s == Gurmukhi:
      table = GurmukhiVowels
    elif s == Gujarati:
      table = GujaratiVowels
    elif s == Oriya:
      table = OriyaVowels
    elif s == Tamil:
      isTamilAu = true
    elif s == Telugu:
      table = TeluguVowels
    elif s == Kannada:
      table = KannadaVowels
    elif s == Malayalam:
      table = MalayalamVowels
    buf.idx = 0
    while buf.idx + 1 < buf.len and buf.successful:
      var matched = false
      let c0 = curGlyphAt(buf, 0)
      if isDevaRa and c0 == 0x0930u32 and curGlyphAt(buf, 1) == 0x094Du32 and
          buf.idx + 2 < buf.len and curGlyphAt(buf, 2) == 0x0907u32:
        buf.nextGlyph()
        buf.nextGlyph()
        outputDottedCircle(buf)
      elif isTamilAu and c0 == 0x0B85u32 and curGlyphAt(buf, 1) == 0x0BC2u32:
        buf.nextGlyph()
        outputDottedCircle(buf)
      else:
        for (first, seconds) in table:
          if c0 != first:
            continue
          let c1 = curGlyphAt(buf, 1)
          for sc in seconds:
            if c1 == sc:
              matched = true
              break
          if matched:
            break
      buf.nextGlyph()
      if matched:
        outputWithDottedCircle(buf)
  discard buf.sync()
