## Indic syllable machine: Ragel-table interpreter that tags each
## glyph with its syllable (`serial << 4 | kind`).
##
## Ports harfrust `ot/shaper/indic_machine.rs`, keeping the generated
## tables verbatim (see `indic_machine_data.nim`) and translating the
## Ragel driver loop to Nim.

import ../buffer
import ./indic_machine_data
import ./indic_table

export indic_table

type
  SyllableType* = enum
    ConsonantSyllable = 0
    VowelSyllable
    StandaloneCluster
    SymbolCluster
    BrokenCluster
    NonIndicCluster

const
  MachineStart = 31

proc foundSyllable(buf: var Buffer, start, stop: int,
    serial: var uint8, kind: SyllableType) =
  ## Tags glyphs [start..stop) with the syllable. Out-of-range ends
  ## are clamped (mirroring harfrust's `unwrap_or_default`).
  let s = max(start, 0)
  let e = min(min(stop, buf.len), buf.info.len)
  var i = s
  while i < e:
    buf.info[i].setSyllable((serial shl 4) or uint8(ord(kind)))
    inc i
  inc serial
  if serial == 16u8:
    serial = 1u8

proc findSyllablesIndic*(buf: var Buffer) =
  ## Runs the syllable machine over the buffer, tagging syllables and
  ## setting the broken-syllable scratch flag. Mirrors harfrust
  ## `find_syllables_indic`, including the EOF transition pass.
  var cs = MachineStart
  var ts = 0
  var te = 0
  var act = 0
  var p = 0
  let pe = buf.len
  let eof = buf.len
  var syllableSerial = 1u8
  while p != pe or p == eof:
    case MachineFromStateActions[cs]
    of 10:
      ts = p
    else:
      discard
    var trans = 0
    if p == eof:
      if MachineEofTrans[cs] > 0:
        trans = int(MachineEofTrans[cs]) - 1
    else:
      let keys = cs shl 1
      let inds = int(MachineIndexOffsets[cs])
      let cat =
        if p >= 0 and p < buf.info.len: buf.info[p].indicCategory()
        else: 0u8
      if cat >= 1u8 and cat <= 57u8:
        let ic = int(MachineCharClass[int(cat) - 1])
        if ic <= int(MachineTransKeys[keys + 1]) and
            ic >= int(MachineTransKeys[keys]):
          trans = int(MachineIndices[inds +
            (ic - int(MachineTransKeys[keys]))])
        else:
          trans = int(MachineIndexDefaults[cs])
      else:
        trans = int(MachineIndexDefaults[cs])
    cs = int(MachineCondTargs[trans])
    if MachineCondActions[trans] != 0:
      case MachineCondActions[trans]
      of 2:
        te = p + 1
      of 11:
        te = p + 1
        foundSyllable(buf, ts, te, syllableSerial, NonIndicCluster)
      of 14:
        te = p
        p = p - 1
        foundSyllable(buf, ts, te, syllableSerial, ConsonantSyllable)
      of 15:
        te = p
        p = p - 1
        foundSyllable(buf, ts, te, syllableSerial, VowelSyllable)
      of 18:
        te = p
        p = p - 1
        foundSyllable(buf, ts, te, syllableSerial, StandaloneCluster)
      of 20:
        te = p
        p = p - 1
        foundSyllable(buf, ts, te, syllableSerial, SymbolCluster)
      of 16:
        te = p
        p = p - 1
        foundSyllable(buf, ts, te, syllableSerial, BrokenCluster)
        buf.scratchFlags = buf.scratchFlags or ScratchFlagHasBrokenSyllable
      of 17:
        te = p
        p = p - 1
        foundSyllable(buf, ts, te, syllableSerial, NonIndicCluster)
      of 1:
        p = te - 1
        foundSyllable(buf, ts, te, syllableSerial, ConsonantSyllable)
      of 3:
        p = te - 1
        foundSyllable(buf, ts, te, syllableSerial, VowelSyllable)
      of 7:
        p = te - 1
        foundSyllable(buf, ts, te, syllableSerial, StandaloneCluster)
      of 8:
        p = te - 1
        foundSyllable(buf, ts, te, syllableSerial, SymbolCluster)
      of 4:
        p = te - 1
        foundSyllable(buf, ts, te, syllableSerial, BrokenCluster)
        buf.scratchFlags = buf.scratchFlags or ScratchFlagHasBrokenSyllable
      of 6:
        case act
        of 1:
          p = te - 1
          foundSyllable(buf, ts, te, syllableSerial, ConsonantSyllable)
        of 5:
          p = te - 1
          foundSyllable(buf, ts, te, syllableSerial, NonIndicCluster)
        of 6:
          p = te - 1
          foundSyllable(buf, ts, te, syllableSerial, BrokenCluster)
          buf.scratchFlags = buf.scratchFlags or ScratchFlagHasBrokenSyllable
        of 7:
          p = te - 1
          foundSyllable(buf, ts, te, syllableSerial, NonIndicCluster)
        else:
          discard
      of 19:
        te = p + 1
        act = 1
      of 13:
        te = p + 1
        act = 5
      of 5:
        te = p + 1
        act = 6
      of 12:
        te = p + 1
        act = 7
      else:
        discard
    if p == eof:
      # Both the final-state and the non-final EOF paths leave the
      # driver loop; any pending syllable was already emitted by the
      # transition action above.
      break
    else:
      if MachineToStateActions[cs] == 9:
        ts = 0
      inc p
