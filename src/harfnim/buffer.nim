import std/options
import std/strformat
import std/strutils

import ./direction
import ./language
import ./script
import ./tag
import ./unicode

type
  Mask* = uint32
  GlyphId* = distinct uint32

proc newGlyphId*(v: uint32): GlyphId = GlyphId(v)
proc value*(g: GlyphId): uint32 = uint32(g)
proc `==`*(a, b: GlyphId): bool {.borrow.}

const
  ContextLength* = 5
  MaxLenFactor* = 256
  MaxLenMin* = 65536
  MaxLenDefault* = 0x3FFF_FFFF
  MaxOpsFactor* = 4096
  MaxOpsMin* = 65536
  MaxOpsDefault* = 0x1FFF_FFFF

# --------------------------------------------------------------------------
# GlyphPosition
# --------------------------------------------------------------------------

type
  GlyphPosition* = object
    xAdvance*: int32
    yAdvance*: int32
    xOffset*: int32
    yOffset*: int32
    posVar*: uint32

proc attachChain*(p: GlyphPosition): int16 =
  cast[int16](uint16(p.posVar and 0xFFFFu32))

proc setAttachChain*(p: var GlyphPosition, n: int16) =
  p.posVar = (p.posVar and 0xFFFF0000u32) or uint32(cast[uint16](n))

proc attachType*(p: GlyphPosition): uint8 =
  uint8((p.posVar shr 16) and 0xFFu32)

proc setAttachType*(p: var GlyphPosition, n: uint8) =
  p.posVar = (p.posVar and 0xFF00FFFFu32) or (uint32(n) shl 16)

# --------------------------------------------------------------------------
# GlyphFlags (declared early: GlyphInfo.flagsOf depends on it)
# --------------------------------------------------------------------------

type
  GlyphFlags* = distinct uint32

const
  UnsafeToBreak* = GlyphFlags(0x0000_0001u32)
  UnsafeToConcat* = GlyphFlags(0x0000_0002u32)
  SafeToInsertTatweel* = GlyphFlags(0x0000_0004u32)
  AllGlyphFlags* = GlyphFlags(0x0000_0007u32)
  DefinedGlyphFlagBits* = 0x0000_0007u32

# --------------------------------------------------------------------------
# GlyphInfo
# --------------------------------------------------------------------------

type
  GlyphInfo* = object
    glyphId*: uint32
    mask*: Mask
    cluster*: uint32
    infoVars*: array[2, uint32]

proc flagsOf*(g: GlyphInfo): GlyphFlags =
  GlyphFlags(g.mask)

proc asCodepoint*(g: GlyphInfo): uint32 = g.glyphId
proc asGlyph*(g: GlyphInfo): GlyphId = GlyphId(g.glyphId)

proc asGid16*(g: GlyphInfo): tuple[ok: bool, gid: uint16] =
  if g.glyphId <= uint32(high(uint16)):
    (true, uint16(g.glyphId))
  else:
    (false, 0u16)

# --- packed var-word accessors (layout mirrors harfrust vars: [u32; 2]) ---

proc getVarU8*(g: GlyphInfo, varIndex, index: int): uint8 =
  uint8((g.infoVars[varIndex] shr (index * 8)) and 0xFFu32)

proc setVarU8*(g: var GlyphInfo, varIndex, index: int, v: uint8) =
  let shift = index * 8
  g.infoVars[varIndex] =
    (g.infoVars[varIndex] and not (0xFFu32 shl shift)) or (uint32(v) shl shift)

proc getVarU16*(g: GlyphInfo, varIndex, index: int): uint16 =
  uint16((g.infoVars[varIndex] shr (index * 16)) and 0xFFFFu32)

proc setVarU16*(g: var GlyphInfo, varIndex, index: int, v: uint16) =
  let shift = index * 16
  g.infoVars[varIndex] =
    (g.infoVars[varIndex] and not (0xFFFFu32 shl shift)) or (uint32(v) shl shift)

proc getVarU32*(g: GlyphInfo, varIndex: int): uint32 =
  g.infoVars[varIndex]

proc setVarU32*(g: var GlyphInfo, varIndex: int, v: uint32) =
  g.infoVars[varIndex] = v

# var1 (infoVars[0]): low u16 = glyph props (OT phase) / whole word =
# normalizer glyph index (normalize phase); byte 2 = lig props; byte 3 = syllable
# var2 (infoVars[1]): low u16 = unicode props; bytes 2..3 = shaper scratch

proc unicodeProps*(g: GlyphInfo): uint16 = g.getVarU16(1, 0)
proc setUnicodeProps*(g: var GlyphInfo, v: uint16) = g.setVarU16(1, 0, v)

proc glyphProps*(g: GlyphInfo): uint16 = g.getVarU16(0, 0)
proc setGlyphProps*(g: var GlyphInfo, v: uint16) = g.setVarU16(0, 0, v)

proc ligProps*(g: GlyphInfo): uint8 = g.getVarU8(0, 2)
proc setLigProps*(g: var GlyphInfo, v: uint8) = g.setVarU8(0, 2, v)

proc syllable*(g: GlyphInfo): uint8 = g.getVarU8(0, 3)
proc setSyllable*(g: var GlyphInfo, v: uint8) = g.setVarU8(0, 3, v)

proc normalizerGlyphIndex*(g: GlyphInfo): uint32 = g.getVarU32(0)
proc setNormalizerGlyphIndex*(g: var GlyphInfo, v: uint32) = g.setVarU32(0, v)

proc otShaperCategory*(g: GlyphInfo): uint8 = g.getVarU8(1, 2)
proc setOtShaperCategory*(g: var GlyphInfo, v: uint8) = g.setVarU8(1, 2, v)

proc otShaperAuxiliary*(g: GlyphInfo): uint8 = g.getVarU8(1, 3)
proc setOtShaperAuxiliary*(g: var GlyphInfo, v: uint8) = g.setVarU8(1, 3, v)

# --------------------------------------------------------------------------
# GlyphFlags operators and predicates
# --------------------------------------------------------------------------

proc toBits*(f: GlyphFlags): uint32 = uint32(f)
proc fromBitsTruncate*(bits: uint32): GlyphFlags =
  GlyphFlags(bits and DefinedGlyphFlagBits)

proc contains*(a, b: GlyphFlags): bool = (uint32(a) and uint32(b)) == uint32(b)
proc intersects*(a, b: GlyphFlags): bool = (uint32(a) and uint32(b)) != 0

proc `or`*(a, b: GlyphFlags): GlyphFlags = GlyphFlags(uint32(a) or uint32(b))
proc `and`*(a, b: GlyphFlags): GlyphFlags = GlyphFlags(uint32(a) and uint32(b))
proc `not`*(a: GlyphFlags): GlyphFlags =
  GlyphFlags((not uint32(a)) and DefinedGlyphFlagBits)
proc `==`*(a, b: GlyphFlags): bool {.borrow.}

proc isUnsafeToBreak*(f: GlyphFlags): bool = f.intersects(UnsafeToBreak)
proc isUnsafeToConcat*(f: GlyphFlags): bool = f.intersects(UnsafeToConcat)
proc isSafeToInsertTatweel*(f: GlyphFlags): bool =
  f.intersects(SafeToInsertTatweel)

proc unsafeToBreak*(g: GlyphInfo): bool = g.flagsOf().isUnsafeToBreak()
proc unsafeToConcat*(g: GlyphInfo): bool = g.flagsOf().isUnsafeToConcat()
proc safeToInsertTatweel*(g: GlyphInfo): bool =
  g.flagsOf().isSafeToInsertTatweel()

# --------------------------------------------------------------------------
# GlyphPropsFlags / UnicodeProps / ScratchFlags constants
# --------------------------------------------------------------------------

const
  GlyphPropBaseGlyph* = 0x02u16
  GlyphPropLigature* = 0x04u16
  GlyphPropMark* = 0x08u16
  GlyphPropClassMask* = 0x0Eu16
  GlyphPropSubstituted* = 0x10u16
  GlyphPropLigated* = 0x20u16
  GlyphPropMultiplied* = 0x40u16
  GlyphPropPreserve* = 0x70u16

const
  UnicodePropGeneralCategory* = 0x001Fu16
  UnicodePropIgnorable* = 0x0020u16
  UnicodePropHidden* = 0x0040u16
  UnicodePropContinuation* = 0x0080u16
  UnicodePropCfZwj* = 0x0100u16
  UnicodePropCfZwnj* = 0x0200u16
  UnicodePropCfVs* = 0x0400u16
  UnicodePropCfAatDeleted* = 0x0800u16

const
  ScratchFlagDefault* = 0x0000_0000u32
  ScratchFlagHasFractionSlash* = 0x0000_0001u32
  ScratchFlagHasDefaultIgnorables* = 0x0000_0002u32
  ScratchFlagHasSpaceFallback* = 0x0000_0004u32
  ScratchFlagHasGposAttachment* = 0x0000_0008u32
  ScratchFlagHasCgj* = 0x0000_0010u32
  ScratchFlagHasBrokenSyllable* = 0x0000_0020u32
  ScratchFlagHasVariationSelectorFallback* = 0x0000_0040u32
  ScratchFlagHasContinuations* = 0x0000_0080u32
  ScratchFlagShaper0* = 0x0100_0000u32

# --------------------------------------------------------------------------
# ContentType / ClusterLevel / BufferFlags / SerializeFlags
# --------------------------------------------------------------------------

type
  ContentType* = enum
    contentUnicode
    contentGlyphs

const
  ClusterLevelMonotoneGraphemes* = 0u32
  ClusterLevelMonotoneCharacters* = 1u32
  ClusterLevelCharacters* = 2u32
  ClusterLevelGraphemes* = 3u32
  ClusterLevelDefault* = ClusterLevelMonotoneGraphemes

type
  ClusterLevel* = enum
    clMonotoneGraphemes
    clMonotoneCharacters
    clCharacters
    clGraphemes

proc clusterLevelFromCode*(code: uint32): ClusterLevel =
  case code
  of ClusterLevelMonotoneCharacters: clMonotoneCharacters
  of ClusterLevelCharacters: clCharacters
  of ClusterLevelGraphemes: clGraphemes
  else: clMonotoneGraphemes

proc clusterLevelCode*(l: ClusterLevel): uint32 =
  case l
  of clMonotoneGraphemes: ClusterLevelMonotoneGraphemes
  of clMonotoneCharacters: ClusterLevelMonotoneCharacters
  of clCharacters: ClusterLevelCharacters
  of clGraphemes: ClusterLevelGraphemes

proc isMonotone*(l: ClusterLevel): bool =
  l == clMonotoneGraphemes or l == clMonotoneCharacters

proc isGraphemes*(l: ClusterLevel): bool =
  l == clMonotoneGraphemes or l == clGraphemes

type
  BufferFlags* = distinct uint32

const
  BeginningOfText* = BufferFlags(0x0000_0001u32)
  EndOfText* = BufferFlags(0x0000_0002u32)
  PreserveDefaultIgnorables* = BufferFlags(0x0000_0004u32)
  RemoveDefaultIgnorables* = BufferFlags(0x0000_0008u32)
  DoNotInsertDottedCircle* = BufferFlags(0x0000_0010u32)
  BufferFlagVerify* = BufferFlags(0x0000_0020u32)
  ProduceUnsafeToConcat* = BufferFlags(0x0000_0040u32)
  ProduceSafeToInsertTatweel* = BufferFlags(0x0000_0080u32)
  DefinedBufferFlagBits* = 0x0000_00FFu32

proc toBits*(f: BufferFlags): uint32 = uint32(f)
proc `==`*(a, b: BufferFlags): bool {.borrow.}
proc `or`*(a, b: BufferFlags): BufferFlags =
  BufferFlags(uint32(a) or uint32(b))
proc `and`*(a, b: BufferFlags): BufferFlags =
  BufferFlags(uint32(a) and uint32(b))
proc contains*(a, b: BufferFlags): bool = (uint32(a) and uint32(b)) == uint32(b)

type
  SerializeFlags* = distinct uint8

const
  NoClusters* = SerializeFlags(0b0000_0001u8)
  NoPositions* = SerializeFlags(0b0000_0010u8)
  NoGlyphNames* = SerializeFlags(0b0000_0100u8)
  SerializeGlyphExtents* = SerializeFlags(0b0000_1000u8)
  GlyphFlagsFlag* = SerializeFlags(0b0001_0000u8)
  NoAdvances* = SerializeFlags(0b0010_0000u8)

proc toBits*(f: SerializeFlags): uint8 = uint8(f)
proc `==`*(a, b: SerializeFlags): bool {.borrow.}
proc contains*(a, b: SerializeFlags): bool =
  (uint8(a) and uint8(b)) == uint8(b)

# --------------------------------------------------------------------------
# Buffer variable-bit allocation
# --------------------------------------------------------------------------

type
  BufferVar* = tuple[width, varIndex, index: uint8]

proc varBits*(v: BufferVar): uint8 =
  let start = (v.varIndex - 1) * 4 + v.index * v.width
  let stop = start + v.width
  uint8(((uint16(1) shl stop) - (uint16(1) shl start)) and 0xFFu16)

const
  GlyphPropsVar*: BufferVar = (2u8, 1u8, 0u8)
  LigPropsVar*: BufferVar = (1u8, 1u8, 2u8)
  SyllableVar*: BufferVar = (1u8, 1u8, 3u8)
  UnicodePropsVar*: BufferVar = (2u8, 2u8, 0u8)
  NormalizerGlyphIndexVar*: BufferVar = (4u8, 1u8, 0u8)
  OtShaperCategoryVar*: BufferVar = (1u8, 2u8, 2u8)
  OtShaperAuxiliaryVar*: BufferVar = (1u8, 2u8, 3u8)

# --------------------------------------------------------------------------
# Buffer
# --------------------------------------------------------------------------

type
  Buffer* = object
    flags*: BufferFlags
    clusterLevel*: uint32
    invisible*: Option[GlyphId]
    notFoundVs*: Option[uint32]
    contentType*: Option[ContentType]
    direction*: Direction
    script*: Option[Script]
    language*: Option[Language]
    successful*: bool
    haveOutput*: bool
    haveSeparateOutput*: bool
    havePositions*: bool
    idx*: int
    len*: int
    outLen*: int
    info*: seq[GlyphInfo]
    pos*: seq[GlyphPosition]
    # Nim emulation of harfrust's pos-reinterpreted-as-output trick:
    # dedicated output storage used while haveSeparateOutput is set.
    outInfo*: seq[GlyphInfo]
    context*: array[2, array[ContextLength, uint32]]
    contextLen*: array[2, int]
    allocatedVarBits*: uint8
    serial*: uint8
    scratchFlags*: uint32
    maxLen*: int
    maxOps*: int
    # TODO: SetDigest digest + U32Set glyphSet (need set_digest/font modules)

# Forward declarations (Nim compiles each module in a single pass)
proc mergeClusters*(b: var Buffer, start, stop: int)
proc mergeClustersImpl*(b: var Buffer, start, stop: int)
proc tryMergeClusters*(b: var Buffer, start, stop: int): bool
proc mergeOutClustersImpl*(b: var Buffer, start, stop: int)
proc tryMergeOutClusters*(b: var Buffer, start, stop: int): bool
proc makeRoomFor(b: var Buffer, numIn, numOut: int): bool
proc nextGlyphs*(b: var Buffer, n: int)
proc mergeDeletedCluster*(b: var Buffer): bool
proc reverseGroups*(b: var Buffer,
    group: proc(a, bb: GlyphInfo): bool {.closure.}, mergeClusters: bool)
proc setGlyphFlagsRange*(b: var Buffer, flags: GlyphFlags, start,
    stop: Option[int], interior, fromOutBuffer: Option[bool])
proc setGlyphFlagsImpl*(b: var Buffer, mask: uint32, start, stop: int,
    interior, fromOutBuffer: bool)
proc infosFindMinCluster*(b: Buffer, infos: seq[GlyphInfo], start, stop: int,
    cluster: Option[uint32]): uint32
proc infosSetGlyphFlags*(b: var Buffer, outInfos: bool, start, stop: int,
    cluster: uint32, mask: uint32)
proc unsafeToBreakRange*(b: var Buffer, start, stop: Option[int])
proc shiftForward*(b: var Buffer, count: int): bool
proc copyCurToOut(b: var Buffer, to: int)
proc copyInfosToOut(b: var Buffer, src, dst, count: int)
proc copyOutToInfos(b: var Buffer, src, dst, count: int)
proc setOutGlyph(b: var Buffer, at: int, glyphIndex: uint32)
proc setOutInfo(b: var Buffer, i: int, g: GlyphInfo)
proc setCluster*(g: var GlyphInfo, cluster: uint32, mask: Mask)
proc setClusterFlags*(infos: var seq[GlyphInfo], clusterLevel: uint32,
    start, stop: int, cluster: uint32, mask: Mask): bool
proc ensure*(b: var Buffer, size: int): bool
proc enlarge*(b: var Buffer, size: int): bool
proc ensureOutCap(b: var Buffer, need: int)
proc clearPositions*(b: var Buffer)
proc substituted*(g: GlyphInfo): bool

proc newBuffer*(): Buffer =
  Buffer(
    flags: BufferFlags(0),
    clusterLevel: ClusterLevelDefault,
    direction: dirInvalid,
    successful: true,
    maxLen: MaxLenDefault,
    maxOps: MaxOpsDefault,
  )

proc clear*(b: var Buffer) =
  b.contentType = none(ContentType)
  b.direction = dirInvalid
  b.script = none(Script)
  b.language = none(Language)
  b.successful = true
  b.haveOutput = false
  b.havePositions = false
  b.idx = 0
  b.info.setLen(0)
  b.pos.setLen(0)
  b.len = 0
  b.outLen = 0
  b.haveSeparateOutput = false
  b.context = default(array[2, array[ContextLength, uint32]])
  b.contextLen = [0, 0]
  b.serial = 0
  b.scratchFlags = ScratchFlagDefault

proc reset*(b: var Buffer) =
  b.clear()
  b.flags = BufferFlags(0)
  b.clusterLevel = ClusterLevelDefault
  b.invisible = none(GlyphId)
  b.notFoundVs = none(uint32)

proc contentType*(b: Buffer): Option[ContentType] = b.contentType
proc setContentType*(b: var Buffer, t: Option[ContentType]) = b.contentType = t

proc length*(b: Buffer): int = b.len
proc isEmpty*(b: Buffer): bool = b.len == 0

proc ensure*(b: var Buffer, size: int): bool =
  if size <= b.info.len:
    true
  else:
    b.enlarge(size)

proc enlarge*(b: var Buffer, size: int): bool =
  if size > b.maxLen:
    b.successful = false
    return false
  b.info.setLen(size)
  b.pos.setLen(size)
  true

proc setLength*(b: var Buffer, n: int): bool =
  if not b.ensure(n):
    return false
  if n > b.len:
    for i in b.len ..< n:
      b.info[i] = GlyphInfo()
    if b.havePositions:
      for i in b.len ..< n:
        b.pos[i] = GlyphPosition()
  b.len = n
  true

proc reserve*(b: var Buffer, size: int): bool = b.ensure(size)
proc allocationSuccessful*(b: Buffer): bool = b.successful

proc push*(b: var Buffer, codepoint, cluster: uint32) =
  b.contentType = some(contentUnicode)
  if not b.ensure(b.len + 1):
    return
  b.info[b.len] = GlyphInfo(glyphId: codepoint, cluster: cluster)
  inc b.len

proc pushCodepoints*(b: var Buffer, codepoints: openArray[uint32]) =
  if not b.ensure(b.len + codepoints.len):
    return
  b.contentType = some(contentUnicode)
  for i, c in codepoints:
    b.info[b.len] = GlyphInfo(glyphId: c, cluster: uint32(i))
    inc b.len

proc pushGlyphInfos*(b: var Buffer, infos: openArray[GlyphInfo]): bool =
  if not b.ensure(b.len + infos.len):
    return false
  for i, g in infos:
    b.info[b.len + i] = g
  b.len += infos.len
  true

proc decodeUtf8At(s: string, pos: int): tuple[cp: uint32, size: int] =
  let b0 = uint8(s[pos])
  if b0 < 0x80u8:
    return (uint32(b0), 1)
  var cp: uint32
  var size: int
  var min: uint32
  if (b0 and 0xE0u8) == 0xC0u8:
    cp = uint32(b0 and 0x1Fu8)
    size = 2
    min = 0x80u32
  elif (b0 and 0xF0u8) == 0xE0u8:
    cp = uint32(b0 and 0x0Fu8)
    size = 3
    min = 0x800u32
  elif (b0 and 0xF8u8) == 0xF0u8:
    cp = uint32(b0 and 0x07u8)
    size = 4
    min = 0x10000u32
  else:
    return (0xFFFDu32, 1)
  if pos + size > s.len:
    return (0xFFFDu32, 1)
  for i in 1 ..< size:
    let bx = uint8(s[pos + i])
    if (bx and 0xC0u8) != 0x80u8:
      return (0xFFFDu32, 1)
    cp = (cp shl 6) or uint32(bx and 0x3Fu8)
  if cp < min or cp in 0xD800u32 .. 0xDFFFu32 or cp > 0x10FFFFu32:
    return (0xFFFDu32, 1)
  (cp, size)

proc pushStr*(b: var Buffer, text: string) =
  var count = 0
  var p = 0
  while p < text.len:
    let (_, size) = decodeUtf8At(text, p)
    inc count
    p += size
  if not b.ensure(b.len + count):
    return
  b.contentType = some(contentUnicode)
  p = 0
  while p < text.len:
    let (cp, size) = decodeUtf8At(text, p)
    b.info[b.len] = GlyphInfo(glyphId: cp, cluster: uint32(p))
    inc b.len
    p += size

proc clearContext(b: var Buffer, side: int) =
  b.contextLen[side] = 0

proc setPreContext*(b: var Buffer, text: string) =
  b.clearContext(0)
  var chars: seq[tuple[cp: uint32, size: int]] = @[]
  var p = 0
  while p < text.len:
    chars.add(decodeUtf8At(text, p))
    p += chars[^1].size
  for i in 0 ..< min(chars.len, ContextLength):
    let c = chars[chars.len - 1 - i]
    b.context[0][i] = c.cp
    inc b.contextLen[0]

proc setPreContextCodepoints*(b: var Buffer, codepoints: openArray[uint32]) =
  b.clearContext(0)
  for i in 0 ..< min(codepoints.len, ContextLength):
    b.context[0][i] = codepoints[i]
    inc b.contextLen[0]

proc preContextCodepoints*(b: Buffer): seq[uint32] =
  result = newSeq[uint32](b.contextLen[0])
  for i in 0 ..< b.contextLen[0]:
    result[i] = b.context[0][i]

proc setPostContext*(b: var Buffer, text: string) =
  b.clearContext(1)
  var p = 0
  while p < text.len and b.contextLen[1] < ContextLength:
    let (cp, size) = decodeUtf8At(text, p)
    b.context[1][b.contextLen[1]] = cp
    inc b.contextLen[1]
    p += size

proc setPostContextCodepoints*(b: var Buffer, codepoints: openArray[uint32]) =
  b.clearContext(1)
  for i in 0 ..< min(codepoints.len, ContextLength):
    b.context[1][i] = codepoints[i]
    inc b.contextLen[1]

proc postContextCodepoints*(b: Buffer): seq[uint32] =
  result = newSeq[uint32](b.contextLen[1])
  for i in 0 ..< b.contextLen[1]:
    result[i] = b.context[1][i]

proc direction*(b: Buffer): Direction = b.direction
proc setDirection*(b: var Buffer, d: Direction) = b.direction = d

proc script*(b: Buffer): Option[Script] = b.script
proc setScript*(b: var Buffer, s: Option[Script]) = b.script = s

proc language*(b: Buffer): Option[Language] = b.language
proc setLanguage*(b: var Buffer, l: Option[Language]) = b.language = l

proc flags*(b: Buffer): BufferFlags = b.flags
proc setFlags*(b: var Buffer, f: BufferFlags) = b.flags = f

proc clusterLevel*(b: Buffer): ClusterLevel =
  clusterLevelFromCode(b.clusterLevel)

proc setClusterLevel*(b: var Buffer, l: ClusterLevel) =
  b.clusterLevel = l.clusterLevelCode()

proc invisibleGlyph*(b: Buffer): Option[GlyphId] = b.invisible
proc setInvisibleGlyph*(b: var Buffer, g: Option[GlyphId]) = b.invisible = g

proc notFoundVsGlyph*(b: Buffer): Option[uint32] = b.notFoundVs
proc setNotFoundVsGlyph*(b: var Buffer, g: Option[uint32]) = b.notFoundVs = g

proc glyphInfos*(b: var Buffer): var seq[GlyphInfo] = b.info
proc glyphInfosView*(b: Buffer): seq[GlyphInfo] =
  if b.len <= b.info.len:
    b.info[0 ..< b.len]
  else:
    @[]

proc glyphPositions*(b: Buffer): seq[GlyphPosition] =
  if not b.havePositions:
    return @[]
  if b.len <= b.pos.len:
    b.pos[0 ..< b.len]
  else:
    @[]

proc glyphPositionsMut*(b: var Buffer): var seq[GlyphPosition] =
  if not b.havePositions:
    b.clearPositions()
  b.pos

proc reverseRange*(b: var Buffer, first, last: int) =
  if last - first < 2:
    return
  for i in 0 ..< (last - first) div 2:
    swap(b.info[first + i], b.info[last - 1 - i])
  if b.havePositions:
    for i in 0 ..< (last - first) div 2:
      swap(b.pos[first + i], b.pos[last - 1 - i])

proc reverse*(b: var Buffer) =
  if b.isEmpty():
    return
  b.reverseRange(0, b.len)

proc reverseClusters*(b: var Buffer) =
  b.reverseGroups(
    proc(a, bb: GlyphInfo): bool {.closure.} = a.cluster == bb.cluster, false)

proc resetClusters*(b: var Buffer) =
  for i in 0 ..< b.len:
    b.info[i].cluster = uint32(i)

# --------------------------------------------------------------------------
# Unicode properties (require the unicode module tables)
# --------------------------------------------------------------------------

proc initUnicodeProps*(g: var GlyphInfo, scratch: var uint32) =
  let u = g.asCodepoint()
  let gc = generalCategoryFor(u)
  var props = uint16(uint8(gc))
  if u >= 0x80u32:
    if isDefaultIgnorable(u):
      props = props or UnicodePropIgnorable
      scratch = scratch or ScratchFlagHasDefaultIgnorables
      if u == 0x200Cu32:
        props = props or UnicodePropCfZwnj
      elif u == 0x200Du32:
        props = props or UnicodePropCfZwj
      elif (u >= 0x180Bu32 and u <= 0x180Du32) or u == 0x180Fu32:
        props = props or UnicodePropHidden
      elif u >= 0xE0020u32 and u <= 0xE007Fu32:
        props = props or UnicodePropHidden
      elif u == 0x034Fu32:
        props = props or UnicodePropHidden
        scratch = scratch or ScratchFlagHasCgj
    if gc.isMark():
      scratch = scratch or ScratchFlagHasContinuations
      props = props or UnicodePropContinuation
      props = props or (uint16(modifiedCombiningClass(u)) shl 8)
  g.setUnicodeProps(props)

proc unhide*(g: var GlyphInfo) =
  g.setUnicodeProps(g.unicodeProps() and not UnicodePropHidden)

# --- unicode_props helpers (mirror hb-ot-layout.hh getters) ---

proc generalCategory*(g: GlyphInfo): GeneralCategory =
  GeneralCategory(uint8(g.unicodeProps() and UnicodePropGeneralCategory))

proc setGeneralCategory*(g: var GlyphInfo, cat: GeneralCategory) =
  g.setUnicodeProps((g.unicodeProps() and not UnicodePropGeneralCategory) or
    uint16(uint8(cat)))

proc isUnicodeMark*(g: GlyphInfo): bool =
  g.generalCategory().isMark()

proc setModifiedCombiningClass*(g: var GlyphInfo, c: uint8) =
  if not g.isUnicodeMark():
    return
  g.setUnicodeProps((uint16(c) shl 8) or (g.unicodeProps() and 0xFFu16))

proc modifiedCombiningClass*(g: GlyphInfo): uint8 =
  if g.isUnicodeMark():
    uint8(g.unicodeProps() shr 8)
  else:
    0u8

proc isUnicodeSpace*(g: GlyphInfo): bool =
  g.generalCategory() == GcSpaceSeparator

proc setUnicodeSpaceFallbackType*(g: var GlyphInfo, s: uint8) =
  if not g.isUnicodeSpace():
    return
  g.setUnicodeProps((uint16(s) shl 8) or (g.unicodeProps() and 0xFFu16))

proc unicodeSpaceFallbackType*(g: GlyphInfo): uint8 =
  if g.isUnicodeSpace():
    uint8(g.unicodeProps() shr 8)
  else:
    SpaceNotSpace

proc isUnicodeFormat*(g: GlyphInfo): bool =
  g.generalCategory() == GcFormat

proc isZwnj*(g: GlyphInfo): bool =
  g.isUnicodeFormat() and (g.unicodeProps() and UnicodePropCfZwnj) != 0u16

proc isZwj*(g: GlyphInfo): bool =
  g.isUnicodeFormat() and (g.unicodeProps() and UnicodePropCfZwj) != 0u16

proc isInfoVariationSelector*(g: GlyphInfo): bool =
  g.generalCategory() == GcFormat and
    (g.unicodeProps() and UnicodePropCfVs) != 0u16

proc setVariationSelector*(g: var GlyphInfo, customize: bool) =
  if customize:
    g.setGeneralCategory(GcFormat)
    g.setUnicodeProps(g.unicodeProps() or UnicodePropCfVs)
  else:
    g.setGeneralCategory(GcNonSpacingMark)

proc isInfoDefaultIgnorable*(g: GlyphInfo): bool =
  let n = g.unicodeProps() and UnicodePropIgnorable
  n != 0u16 and not g.substituted()

proc clearDefaultIgnorable*(g: var GlyphInfo) =
  g.setUnicodeProps(g.unicodeProps() and not UnicodePropIgnorable)

proc isHidden*(g: GlyphInfo): bool =
  (g.unicodeProps() and UnicodePropHidden) != 0u16

proc setContinuation*(g: var GlyphInfo, scratch: var uint32) =
  scratch = scratch or ScratchFlagHasContinuations
  g.setUnicodeProps(g.unicodeProps() or UnicodePropContinuation)

proc clearContinuation*(g: var GlyphInfo) =
  g.setUnicodeProps(g.unicodeProps() and not UnicodePropContinuation)

proc isContinuation*(g: GlyphInfo): bool =
  (g.unicodeProps() and UnicodePropContinuation) != 0u16

proc guessSegmentProperties*(b: var Buffer) =
  if b.script.isNone:
    for i in 0 ..< b.len:
      let s = scriptFor(b.info[i].glyphId)
      if s != Common and s != Inherited and s != Unknown:
        b.script = some(s)
        break
  if b.direction == dirInvalid:
    if b.script.isSome:
      let (ok, d) = directionForScript(b.script.get)
      if ok:
        b.direction = d
    if b.direction == dirInvalid:
      b.direction = dirLeftToRight

# --------------------------------------------------------------------------
# Internal shaping machinery
# --------------------------------------------------------------------------

proc allocateVar*(b: var Buffer, v: BufferVar) =
  let bits = v.varBits()
  assert((b.allocatedVarBits and bits) == 0, "Variable already allocated")
  b.allocatedVarBits = b.allocatedVarBits or bits

proc tryAllocateVar*(b: var Buffer, v: BufferVar): bool =
  let bits = v.varBits()
  if (b.allocatedVarBits and bits) != 0:
    return false
  b.allocatedVarBits = b.allocatedVarBits or bits
  true

proc deallocateVar*(b: var Buffer, v: BufferVar) =
  let bits = v.varBits()
  assert((b.allocatedVarBits and bits) == bits, "Deallocating unallocated var")
  b.allocatedVarBits = b.allocatedVarBits and not bits

proc indexFailed*(b: var Buffer) =
  b.successful = false

proc infoSliceMut*(b: var Buffer): var seq[GlyphInfo] = b.info

proc cur*(b: var Buffer, i: int): ptr GlyphInfo =
  let at = b.idx + i
  if at < 0 or at >= b.info.len:
    return nil
  addr b.info[at]

proc curPosMut*(b: var Buffer): ptr GlyphPosition =
  if b.idx < 0 or b.idx >= b.pos.len:
    return nil
  addr b.pos[b.idx]

proc prev*(b: var Buffer): ptr GlyphInfo =
  let at = b.outLen - 1
  if b.outLen == 0:
    return nil
  if b.haveSeparateOutput:
    if at >= b.outInfo.len:
      return nil
    return addr b.outInfo[at]
  if at >= b.info.len:
    return nil
  addr b.info[at]

proc prevMut*(b: var Buffer): ptr GlyphInfo = b.prev()

proc outAt*(b: var Buffer, i: int): ptr GlyphInfo =
  if b.haveSeparateOutput:
    if i < 0 or i >= b.outInfo.len:
      return nil
    return addr b.outInfo[i]
  if i < 0 or i >= b.info.len:
    return nil
  addr b.info[i]

proc setOutInfo(b: var Buffer, i: int, g: GlyphInfo) =
  let slot = b.outAt(i)
  if slot == nil:
    b.indexFailed()
  else:
    slot[] = g

proc copyInfosToOut(b: var Buffer, src, dst, count: int) =
  if b.haveSeparateOutput:
    if dst < 0 or dst + count > b.outInfo.len or src < 0 or
        src + count > b.info.len:
      b.indexFailed()
      return
    for i in 0 ..< count:
      b.outInfo[dst + i] = b.info[src + i]
  else:
    if dst < 0 or src < 0 or dst + count > b.info.len or
        src + count > b.info.len:
      b.indexFailed()
      return
    for i in 0 ..< count:
      b.info[dst + i] = b.info[src + i]

proc copyOutToInfos(b: var Buffer, src, dst, count: int) =
  if b.haveSeparateOutput:
    if src < 0 or src + count > b.outInfo.len or dst < 0 or
        dst + count > b.info.len:
      b.indexFailed()
      return
    for i in 0 ..< count:
      b.info[dst + i] = b.outInfo[src + i]
  else:
    if src < 0 or dst < 0 or dst + count > b.info.len or
        src + count > b.info.len:
      b.indexFailed()
      return
    for i in countdown(count - 1, 0):
      b.info[dst + i] = b.info[src + i]

proc backtrackLen*(b: Buffer): int =
  if b.haveOutput: b.outLen else: b.idx

proc lookaheadLen*(b: Buffer): int = b.len - b.idx

proc nextSerial*(b: var Buffer): uint8 =
  b.serial = uint8((uint16(b.serial) + 1u16) and 0xFFu16)
  if b.serial == 0:
    b.serial += 1
  b.serial

proc groupEnd*(b: Buffer, start: int,
    group: proc(a, bb: GlyphInfo): bool {.closure.}): int =
  result = start + 1
  while result < b.len:
    if result - 1 < 0 or result >= b.info.len:
      break
    if not group(b.info[result - 1], b.info[result]):
      break
    inc result

proc reverseGroups*(b: var Buffer,
    group: proc(a, bb: GlyphInfo): bool {.closure.}, mergeClusters: bool) =
  if b.isEmpty():
    return
  var start = 0
  var i = 1
  while i < b.len:
    if i - 1 < 0 or i >= b.info.len:
      b.indexFailed()
      break
    if not group(b.info[i - 1], b.info[i]):
      if mergeClusters:
        b.mergeClusters(start, i)
      b.reverseRange(start, i)
      start = i
    inc i
  if mergeClusters:
    b.mergeClusters(start, i)
  b.reverseRange(start, i)
  b.reverse()

proc sync*(b: var Buffer): bool =
  assert(b.haveOutput)
  assert(b.idx <= b.len)
  if not b.successful:
    b.haveOutput = false
    b.outLen = 0
    b.idx = 0
    return false
  b.nextGlyphs(b.len - b.idx)
  if b.haveSeparateOutput:
    swap(b.info, b.outInfo)
    b.haveSeparateOutput = false
  b.len = b.outLen
  b.haveOutput = false
  b.outLen = 0
  b.idx = 0
  true

proc clearOutput*(b: var Buffer) =
  b.haveOutput = true
  b.havePositions = false
  b.idx = 0
  b.outLen = 0
  b.haveSeparateOutput = false

proc clearPositions*(b: var Buffer) =
  b.haveOutput = false
  b.havePositions = true
  b.outLen = 0
  b.haveSeparateOutput = false
  for i in 0 ..< b.pos.len:
    b.pos[i] = GlyphPosition()

proc makeRoomFor(b: var Buffer, numIn, numOut: int): bool =
  if not b.ensure(b.outLen + numOut):
    return false
  if b.outLen + numOut > b.maxLen:
    b.successful = false
    return false
  var enteredSeparate = false
  if not b.haveSeparateOutput and b.outLen + numOut > b.idx + numIn:
    assert(b.haveOutput)
    b.haveSeparateOutput = true
    enteredSeparate = true
  if b.haveSeparateOutput:
    b.ensureOutCap(b.outLen + numOut)
    if enteredSeparate:
      b.copyInfosToOut(0, 0, b.outLen)
  true

proc copyCurToOut(b: var Buffer, to: int) =
  if b.idx < 0 or b.idx >= b.info.len:
    b.indexFailed()
    return
  b.setOutInfo(to, b.info[b.idx])

proc setOutGlyph(b: var Buffer, at: int, glyphIndex: uint32) =
  let slot = b.outAt(at)
  if slot == nil:
    b.indexFailed()
  else:
    slot[].glyphId = glyphIndex

proc replaceGlyphs*(b: var Buffer, numIn, numOut: int, glyphData: openArray[uint32]) =
  if not b.makeRoomFor(numIn, numOut):
    return
  assert(b.idx + numIn <= b.len)
  b.mergeClusters(b.idx, b.idx + numIn)
  if b.idx >= b.info.len or glyphData.len < numOut:
    b.indexFailed()
    return
  let origInfo = b.info[b.idx]
  if b.haveSeparateOutput:
    if b.outLen + numOut > b.outInfo.len:
      b.outInfo.setLen(b.outLen + numOut)
  for i in 0 ..< numOut:
    var g = origInfo
    g.glyphId = glyphData[i]
    b.setOutInfo(b.outLen + i, g)
  b.idx += numIn
  b.outLen += numOut

proc replaceGlyph*(b: var Buffer, glyphIndex: uint32) =
  if b.haveSeparateOutput or b.outLen != b.idx:
    if not b.makeRoomFor(1, 1):
      return
    b.copyCurToOut(b.outLen)
  b.setOutGlyph(b.outLen, glyphIndex)
  b.idx += 1
  b.outLen += 1

proc outputGlyph*(b: var Buffer, glyphIndex: uint32) =
  if not b.makeRoomFor(0, 1):
    return
  if b.idx == b.len and b.outLen == 0:
    return
  if b.idx < b.len:
    b.copyCurToOut(b.outLen)
  else:
    let slot = b.outAt(b.outLen - 1)
    if slot == nil:
      b.indexFailed()
      return
    b.setOutInfo(b.outLen, slot[])
  b.setOutGlyph(b.outLen, glyphIndex)
  b.outLen += 1

proc outputInfo*(b: var Buffer, g: GlyphInfo) =
  if not b.makeRoomFor(0, 1):
    return
  b.setOutInfo(b.outLen, g)
  b.outLen += 1

proc copyGlyph*(b: var Buffer) =
  if not b.makeRoomFor(0, 1):
    return
  b.copyCurToOut(b.outLen)
  b.outLen += 1

proc ensureOutCap(b: var Buffer, need: int) =
  if b.haveSeparateOutput and b.outInfo.len < need:
    b.outInfo.setLen(need)

proc nextGlyph*(b: var Buffer) =
  if b.haveOutput:
    if b.haveSeparateOutput or b.outLen != b.idx:
      if not b.ensure(b.outLen + 1):
        return
      b.ensureOutCap(b.outLen + 1)
      b.copyCurToOut(b.outLen)
    b.outLen += 1
  b.idx += 1

proc nextGlyphs*(b: var Buffer, n: int) =
  if b.haveOutput:
    if b.haveSeparateOutput or b.outLen != b.idx:
      if not b.ensure(b.outLen + n):
        return
      b.ensureOutCap(b.outLen + n)
      b.copyInfosToOut(b.idx, b.outLen, n)
    b.outLen += n
  b.idx += n

proc skipGlyph*(b: var Buffer) =
  b.idx += 1

proc setMasks*(b: var Buffer, value, mask: Mask, clusterStart, clusterEnd: uint32) =
  if mask == 0:
    return
  let notMask = not mask
  let v = value and mask
  b.maxOps -= b.len
  if b.maxOps < 0:
    b.successful = false
  if clusterStart == 0 and clusterEnd == high(uint32):
    for i in 0 ..< b.len:
      b.info[i].mask = (b.info[i].mask and notMask) or v
    return
  for i in 0 ..< b.len:
    if clusterStart <= b.info[i].cluster and b.info[i].cluster < clusterEnd:
      b.info[i].mask = (b.info[i].mask and notMask) or v

proc mergeClusters*(b: var Buffer, start, stop: int) =
  if stop - start < 2:
    return
  if not b.clusterLevel.clusterLevelFromCode().isMonotone():
    b.unsafeToBreakRange(some(start), some(stop))
    return
  b.mergeClustersImpl(start, stop)

proc mergeClustersImpl*(b: var Buffer, start, stop: int) =
  b.maxOps -= (stop - start)
  if b.maxOps < 0:
    b.successful = false
  if not b.tryMergeClusters(start, stop):
    b.indexFailed()

proc tryMergeClusters*(b: var Buffer, start, stop: int): bool =
  if start < 0 or stop > b.info.len or start >= stop:
    return false
  var cluster = high(uint32)
  for i in start ..< stop:
    cluster = min(cluster, b.info[i].cluster)
  var s = start
  var e = stop
  if cluster != b.info[e - 1].cluster:
    while e < b.len and b.info[e - 1].cluster == b.info[e].cluster:
      inc e
  if cluster != b.info[s].cluster:
    while b.idx < s and b.info[s - 1].cluster == b.info[s].cluster:
      dec s
  let startCluster = b.info[s].cluster
  if b.idx == s and startCluster != cluster:
    var i = b.outLen
    while i != 0:
      let slot = b.outAt(i - 1)
      if slot == nil:
        return false
      if slot[].cluster != startCluster:
        break
      setCluster(slot[], cluster, 0)
      dec i
  for i in s ..< e:
    setCluster(b.info[i], cluster, 0)
  true

proc mergeGraphemeClusters*(b: var Buffer, start, stop: int) =
  if stop - start < 2:
    return
  if not b.clusterLevel.clusterLevelFromCode().isGraphemes():
    b.unsafeToBreakRange(some(start), some(stop))
    return
  b.mergeClustersImpl(start, stop)

proc mergeOutClusters*(b: var Buffer, start, stop: int) =
  if stop - start < 2:
    return
  if not b.clusterLevel.clusterLevelFromCode().isMonotone():
    return
  b.mergeOutClustersImpl(start, stop)

proc mergeOutGraphemeClusters*(b: var Buffer, start, stop: int) =
  if stop - start < 2:
    return
  if not b.clusterLevel.clusterLevelFromCode().isGraphemes():
    return
  b.mergeOutClustersImpl(start, stop)

proc mergeOutClustersImpl*(b: var Buffer, start, stop: int) =
  b.maxOps -= (stop - start)
  if b.maxOps < 0:
    b.successful = false
  if not b.tryMergeOutClusters(start, stop):
    b.indexFailed()

proc outClusterAt(b: var Buffer, i: int): tuple[ok: bool, c: uint32] =
  let slot = b.outAt(i)
  if slot == nil:
    return (false, 0)
  (true, slot[].cluster)

proc tryMergeOutClusters*(b: var Buffer, start, stop: int): bool =
  if start < 0 or stop <= start:
    return false
  var s = start
  var e = stop
  var cluster = high(uint32)
  var i = s
  while i < e:
    let (ok, c) = b.outClusterAt(i)
    if not ok:
      return false
    cluster = min(cluster, c)
    inc i
  while s != 0:
    let (okPrev, cPrev) = b.outClusterAt(s - 1)
    let (okCur, cCur) = b.outClusterAt(s)
    if not okPrev or not okCur or cPrev != cCur:
      break
    dec s
  while e < b.outLen:
    let (okPrev, cPrev) = b.outClusterAt(e - 1)
    let (okCur, cCur) = b.outClusterAt(e)
    if not okPrev or not okCur or cPrev != cCur:
      break
    inc e
  if e == b.outLen and e > 0:
    let (okEnd, endCluster) = b.outClusterAt(e - 1)
    if not okEnd:
      return false
    var k = b.idx
    while k < b.len:
      if b.info[k].cluster != endCluster:
        break
      setCluster(b.info[k], cluster, 0)
      inc k
  i = s
  while i < e:
    let slot = b.outAt(i)
    if slot == nil:
      return false
    setCluster(slot[], cluster, 0)
    inc i
  true

proc deleteGlyph*(b: var Buffer) =
  if not b.mergeDeletedCluster():
    b.indexFailed()
  b.skipGlyph()

proc mergeDeletedCluster*(b: var Buffer): bool =
  if b.idx < 0 or b.idx >= b.info.len:
    return false
  let cluster = b.info[b.idx].cluster
  let mask = b.info[b.idx].mask
  let nextCluster =
    if b.idx + 1 < b.len: some(b.info[b.idx + 1].cluster)
    else: none(uint32)
  let prevCluster =
    if b.outLen == 0: none(uint32)
    else:
      let slot = b.outAt(b.outLen - 1)
      if slot == nil:
        return false
      some(slot[].cluster)
  if (b.idx + 1 < b.len and nextCluster == some(cluster)) or
      prevCluster == some(cluster):
    return true
  if prevCluster.isSome:
    let oldCluster = prevCluster.get
    if cluster < oldCluster:
      var i = b.outLen
      while i != 0:
        let slot = b.outAt(i - 1)
        if slot == nil:
          return false
        if slot[].cluster != oldCluster:
          break
        setCluster(slot[], cluster, mask)
        dec i
    return true
  if b.idx + 1 < b.len:
    b.mergeClusters(b.idx, b.idx + 2)
  true

proc deleteGlyphsInplace*(b: var Buffer,
    filter: proc(g: GlyphInfo): bool {.closure.}) =
  var j = 0
  for i in 0 ..< b.len:
    let info = b.info[i]
    if filter(info):
      let cluster = info.cluster
      let mask = info.mask
      if i + 1 < b.len and b.info[i + 1].cluster == cluster:
        continue
      if j != 0:
        let oldCluster =
          if j - 1 < b.info.len: b.info[j - 1].cluster else: cluster
        if cluster < oldCluster:
          var k = j
          while k != 0:
            dec k
            if b.info[k].cluster != oldCluster:
              break
            setCluster(b.info[k], cluster, mask)
        continue
      if i + 1 < b.len:
        b.mergeClusters(i, i + 2)
      continue
    if j != i:
      b.info[j] = info
      if i < b.pos.len and j < b.pos.len:
        b.pos[j] = b.pos[i]
    inc j
  b.len = j

proc unsafeToBreakRange*(b: var Buffer, start, stop: Option[int]) =
  b.setGlyphFlagsRange(
    UnsafeToBreak or UnsafeToConcat, start, stop, some(true), none(bool))

proc safeToInsertTatweelRange*(b: var Buffer, start, stop: Option[int]) =
  if not b.flags.contains(ProduceSafeToInsertTatweel):
    b.unsafeToBreakRange(start, stop)
    return
  b.setGlyphFlagsRange(SafeToInsertTatweel, start, stop, some(true), none(bool))

proc unsafeToConcatRange*(b: var Buffer, start, stop: Option[int]) =
  if not b.flags.contains(ProduceUnsafeToConcat):
    return
  b.setGlyphFlagsRange(UnsafeToConcat, start, stop, some(false), none(bool))

proc unsafeToBreakFromOutbuffer*(b: var Buffer, start, stop: Option[int]) =
  b.setGlyphFlagsRange(UnsafeToBreak or UnsafeToConcat, start, stop, some(true),
    some(true))

proc unsafeToConcatFromOutbuffer*(b: var Buffer, start, stop: Option[int]) =
  if not b.flags.contains(ProduceUnsafeToConcat):
    return
  b.setGlyphFlagsRange(UnsafeToConcat, start, stop, some(false), some(true))

proc setGlyphFlagsRange*(b: var Buffer, flags: GlyphFlags, start, stop: Option[int],
    interior, fromOutBuffer: Option[bool]) =
  var s = start
  var e = stop
  if s.isSome and e.isSome:
    if e.get.uint - s.get.uint > 255:
      return
  let si = s.get(0)
  var ei = min(e.get(b.len), b.len)
  let inter = interior.get(false)
  let fromOut = fromOutBuffer.get(false)
  if inter and not fromOut and ei - si < 2:
    return
  b.setGlyphFlagsImpl(uint32(flags), si, ei, inter, fromOut)

proc setGlyphFlagsImpl*(b: var Buffer, mask: uint32, start, stop: int,
    interior, fromOutBuffer: bool) =
  if not fromOutBuffer or not b.haveOutput:
    if not interior:
      for i in start ..< min(stop, b.info.len):
        b.info[i].mask = b.info[i].mask or mask
    else:
      let cluster = b.infosFindMinCluster(b.info, start, stop, none(uint32))
      b.infosSetGlyphFlags(false, start, stop, cluster, mask)
  else:
    assert(start <= b.outLen)
    assert(b.idx <= stop)
    if not interior:
      for i in start ..< b.outLen:
        let slot = b.outAt(i)
        if slot == nil:
          b.indexFailed()
          return
        slot[].mask = slot[].mask or mask
      for i in b.idx ..< min(stop, b.info.len):
        b.info[i].mask = b.info[i].mask or mask
    else:
      var cluster = b.infosFindMinCluster(b.info, b.idx, stop, none(uint32))
      if b.haveSeparateOutput:
        cluster = b.infosFindMinCluster(b.outInfo, start, b.outLen, some(cluster))
      else:
        cluster = b.infosFindMinCluster(b.info, start, b.outLen, some(cluster))
      let ol = b.outLen
      b.infosSetGlyphFlags(true, start, ol, cluster, mask)
      b.infosSetGlyphFlags(false, b.idx, stop, cluster, mask)

proc infosFindMinCluster*(b: Buffer, infos: seq[GlyphInfo], start, stop: int,
    cluster: Option[uint32]): uint32 =
  result = cluster.get(high(uint32))
  if start == stop:
    return
  if start < 0 or stop > infos.len:
    return
  if b.clusterLevel == ClusterLevelCharacters:
    for i in start ..< stop:
      result = min(result, infos[i].cluster)
  let first = infos[start].cluster
  let last = infos[stop - 1].cluster
  result = min(result, min(first, last))

proc infosSetGlyphFlags*(b: var Buffer, outInfos: bool, start, stop: int,
    cluster: uint32, mask: uint32) =
  if start == stop:
    return
  if outInfos:
    if not setClusterFlags(b.outInfo, b.clusterLevel, start, stop, cluster, mask):
      b.indexFailed()
  else:
    if not setClusterFlags(b.info, b.clusterLevel, start, stop, cluster, mask):
      b.indexFailed()

proc moveTo*(b: var Buffer, i: int): bool =
  if not b.haveOutput:
    assert(i <= b.len)
    b.idx = i
    return true
  if not b.successful:
    return false
  assert(i <= b.outLen + (b.len - b.idx))
  if b.outLen < i:
    let count = i - b.outLen
    if not b.makeRoomFor(count, count):
      return false
    b.maxOps -= count
    if b.maxOps < 0:
      b.successful = false
      return false
    b.copyInfosToOut(b.idx, b.outLen, count)
    b.idx += count
    b.outLen += count
  elif b.outLen > i:
    let count = b.outLen - i
    if b.idx < count and not b.shiftForward(count - b.idx):
      return false
    assert(b.idx >= count)
    b.maxOps -= count
    if b.maxOps < 0:
      b.successful = false
      return false
    b.idx -= count
    b.outLen -= count
    b.copyOutToInfos(b.outLen, b.idx, count)
  true

proc shiftForward*(b: var Buffer, count: int): bool =
  assert(b.haveOutput)
  if not b.ensure(b.len + count):
    return false
  b.maxOps -= (b.len - b.idx)
  if b.maxOps < 0:
    b.successful = false
    return false
  let moved = b.len - b.idx
  for i in countdown(moved - 1, 0):
    b.info[b.idx + count + i] = b.info[b.idx + i]
  for i in 0 ..< count:
    if b.idx + i < b.info.len:
      b.info[b.idx + i] = GlyphInfo()
  b.len += count
  b.idx += count
  true

proc sort*(b: var Buffer, start, stop: int,
    cmp: proc(a, bb: GlyphInfo): bool {.closure.}) =
  assert(not b.havePositions)
  for i in start + 1 ..< stop:
    if i >= b.info.len:
      b.indexFailed()
      return
    let item = b.info[i]
    var j = i
    while j > start and cmp(b.info[j - 1], item):
      dec j
    if i == j:
      continue
    b.mergeClusters(j, i + 1)
    for k in countdown(i, j + 1):
      b.info[k] = b.info[k - 1]
    b.info[j] = item

proc setCluster*(g: var GlyphInfo, cluster: uint32, mask: Mask) =
  if g.cluster != cluster:
    g.mask = (g.mask and not DefinedGlyphFlagBits) or (mask and DefinedGlyphFlagBits)
  g.cluster = cluster

proc enter*(b: var Buffer) =
  b.serial = 0
  b.scratchFlags = ScratchFlagDefault
  b.maxLen = max(b.len * MaxLenFactor, MaxLenMin)
  b.maxOps = max(b.len * MaxOpsFactor, MaxOpsMin)

proc leave*(b: var Buffer) =
  b.maxLen = MaxLenDefault
  b.maxOps = MaxOpsDefault
  b.serial = 0

proc allocateLigId*(b: var Buffer): uint8 =
  var ligId = b.nextSerial() and 0x07u8
  if ligId == 0:
    ligId = b.allocateLigId()
  ligId

proc allocateUnicodeVars*(b: var Buffer) =
  b.allocateVar(UnicodePropsVar)

proc deallocateUnicodeVars*(b: var Buffer) =
  b.deallocateVar(UnicodePropsVar)

proc allocateGsubGposVars*(b: var Buffer) =
  b.allocateVar(LigPropsVar)
  b.allocateVar(GlyphPropsVar)

proc deallocateGsubGposVars*(b: var Buffer) =
  b.deallocateVar(LigPropsVar)
  b.deallocateVar(GlyphPropsVar)

proc nextSyllable*(b: Buffer, start: int, maxSyllableLength: int = 64): int =
  if start >= b.len:
    return start
  let stop = start + min(b.len - start, maxSyllableLength)
  if start >= b.info.len:
    return stop
  let s = b.info[start].syllable()
  var count = 0
  for i in start ..< min(stop, b.info.len):
    if b.info[i].syllable() != s:
      break
    inc count
  start + count

# --- ligature / glyph-class helpers (mirror hb-ot-layout.hh) ---

const IsLigBase* = 0x10u8

proc setLigPropsForLigature*(g: var GlyphInfo, ligId, ligNumComps: uint8) =
  g.setLigProps((ligId shl 5) or IsLigBase or (ligNumComps and 0x0Fu8))

proc setLigPropsForMark*(g: var GlyphInfo, ligId, ligComp: uint8) =
  g.setLigProps((ligId shl 5) or (ligComp and 0x0Fu8))

proc setLigPropsForComponent*(g: var GlyphInfo, comp: uint8) =
  g.setLigPropsForMark(0, comp)

proc ligId*(g: GlyphInfo): uint8 = g.ligProps() shr 5

proc ligatedInternal*(g: GlyphInfo): bool = (g.ligProps() and IsLigBase) != 0

proc ligComp*(g: GlyphInfo): uint8 =
  if g.ligatedInternal(): 0u8 else: g.ligProps() and 0x0Fu8

proc ligNumComps*(g: GlyphInfo): uint8 =
  if (g.glyphProps() and GlyphPropLigature) != 0 and g.ligatedInternal():
    g.ligProps() and 0x0Fu8
  else:
    1u8

proc isBaseGlyph*(g: GlyphInfo): bool =
  (g.glyphProps() and GlyphPropBaseGlyph) != 0

proc isLigature*(g: GlyphInfo): bool =
  (g.glyphProps() and GlyphPropLigature) != 0

proc isMarkGlyph*(g: GlyphInfo): bool =
  (g.glyphProps() and GlyphPropMark) != 0

proc substituted*(g: GlyphInfo): bool =
  (g.glyphProps() and GlyphPropSubstituted) != 0

proc ligated*(g: GlyphInfo): bool =
  (g.glyphProps() and GlyphPropLigated) != 0

proc multiplied*(g: GlyphInfo): bool =
  (g.glyphProps() and GlyphPropMultiplied) != 0

proc ligNumCompsInLigation*(g: GlyphInfo): uint8 =
  if g.multiplied() and g.ligComp() != 0: 0u8 else: g.ligNumComps()

proc setClusterFlags*(infos: var seq[GlyphInfo], clusterLevel: uint32,
    start, stop: int, cluster: uint32, mask: Mask): bool =
  if start < 0 or stop > infos.len or start >= stop:
    return false
  let clusterFirst = infos[start].cluster
  let clusterLast = infos[stop - 1].cluster
  if clusterLevel == ClusterLevelCharacters or
      (cluster != clusterFirst and cluster != clusterLast):
    for i in start ..< stop:
      if infos[i].cluster != cluster:
        infos[i].mask = infos[i].mask or mask
    return true
  if cluster == clusterFirst:
    var i = stop
    while start < i:
      if infos[i - 1].cluster == clusterFirst:
        break
      if cluster != infos[i - 1].cluster:
        infos[i - 1].mask = infos[i - 1].mask or mask
      dec i
  else:
    var i = start
    while i < stop:
      if infos[i].cluster == clusterLast:
        break
      if cluster != infos[i].cluster:
        infos[i].mask = infos[i].mask or mask
      inc i
  true

# --------------------------------------------------------------------------
# Serialization (without font: glyph names / extents unavailable)
# --------------------------------------------------------------------------

proc serialize*(b: Buffer, flags: SerializeFlags): string =
  result = ""
  let infos = b.glyphInfosView()
  if b.contentType == some(contentUnicode):
    for i, g in infos:
      result.add(if i == 0: "<" else: "|")
      result.add(fmt"U+{g.glyphId:04X}")
      if not flags.contains(NoClusters):
        result.add(fmt"={g.cluster}")
    if result.len > 0:
      result.add(">")
    return result
  let positions = b.glyphPositions()
  let noPositions = not flags.contains(NoPositions)
  for i, g in infos:
    result.add(if i == 0: "[" else: "|")
    if not flags.contains(NoGlyphNames):
      result.add(fmt"gid{g.glyphId}")
    else:
      result.add($g.glyphId)
    if not flags.contains(NoClusters):
      result.add(fmt"={g.cluster}")
    if positions.len > 0 and noPositions:
      let p = if i < positions.len: positions[i]
              else: GlyphPosition()
      if p.xOffset != 0 or p.yOffset != 0:
        result.add(fmt"@{p.xOffset},{p.yOffset}")
      if not flags.contains(NoAdvances):
        result.add(fmt"+{p.xAdvance}")
        if p.yAdvance != 0:
          result.add(fmt",{p.yAdvance}")
    if flags.contains(GlyphFlagsFlag):
      if (g.mask and DefinedGlyphFlagBits) != 0:
        result.add(fmt"#{(g.mask and DefinedGlyphFlagBits):X}")
  if result.len > 0:
    result.add("]")

proc `$`*(b: Buffer): string =
  fmt"Buffer(contentType={b.contentType}, direction={b.direction}, len={b.len})"
