## Bidirectional algorithm (UAX #9) over code points.
##
## Implements paragraph level (P2-P3), explicit embeddings and isolates
## (X1-X8 with overflow counters), weak resolution (W1-W7), bracket
## pairs and neutrals (N0-N2), implicit levels (I1-I2), visual
## reordering (L2), and mirroring (L4) for one pre-split paragraph.
## Line splitting (L1) stays the caller's problem, except trailing
## whitespace and isolate codes collapse to the paragraph level.
## Runs never start with a combining mark (see `visualRuns`).

import std/options

import ./unicode
import ./direction

type
  BaseDirection* = enum
    ## Paragraph base direction for `visualRuns`.
    bdLtr
    ## Left to right paragraph.
    bdRtl
    ## Right to left paragraph.
    bdAuto
    ## First strong character decides, else left to right.

  VisualRun* = object
    ## One visual run into `VisualText.text`.
    first*: int
    ## First byte offset, inclusive.
    last*: int
    ## One past the last byte offset.
    level*: int
    ## Resolved embedding level.
    dir*: Direction
    ## Left to right for even levels, right to left for odd.

  VisualText* = object
    ## Shaped-ready visual paragraph.
    text*: string
    ## Normalized paragraph in visual order.
    map*: seq[int]
    ## Source byte offset per text byte offset, plus a final sentinel.
    runs*: seq[VisualRun]
    ## Visual runs covering `text` in order.

  BidiChar = object
    # One working code point with its resolved state.
    cp: uint32
    # Current code point; L4 mirroring rewrites it.
    cls: BidiClass
    # Current type; overrides and W/N rules rewrite it.
    level: int
    # Explicit then resolved embedding level.
    srcOff: int
    # Source byte offset of this character.
    srcLen: int
    # Source byte length of this character.

  StackEntry = object
    # One directional status stack entry (X1).
    level: int
    # Embedding level for following characters.
    override: uint8
    # 0 neutral, 1 left to right, 2 right to left.
    isolate: bool
    # True when opened by an isolate initiator.

  RunSeq = object
    # One isolating run sequence (BD13).
    idx: seq[int]
    # Character indices in logical order.
    level: int
    # Shared embedding level.
    sos: BidiClass
    # Start-of-sequence type, BidiL or BidiR.
    eos: BidiClass
    # End-of-sequence type, BidiL or BidiR.

const MaxDepth = 125

proc decodeBidiText(text: string): seq[BidiChar] =
  # Decodes UTF-8, using U+FFFD for malformed sequences.
  var i = 0
  while i < text.len:
    let b0 = uint8(text[i])
    var cp = 0xFFFDu32
    var size = 1
    if b0 < 0x80u8:
      cp = uint32(b0)
    elif b0 >= 0xC2u8 and b0 < 0xE0u8 and i + 1 < text.len:
      let b1 = uint8(text[i + 1])
      if b1 >= 0x80u8 and b1 < 0xC0u8:
        cp = (uint32(b0 and 0x1Fu8) shl 6) or uint32(b1 and 0x3Fu8)
        size = 2
    elif b0 < 0xF0u8 and i + 2 < text.len:
      let b1 = uint8(text[i + 1])
      let b2 = uint8(text[i + 2])
      if b1 >= 0x80u8 and b1 < 0xC0u8 and b2 >= 0x80u8 and b2 < 0xC0u8:
        let v = (uint32(b0 and 0x0Fu8) shl 12) or
          (uint32(b1 and 0x3Fu8) shl 6) or uint32(b2 and 0x3Fu8)
        if v >= 0x800u32 and not (v >= 0xD800u32 and v <= 0xDFFFu32):
          cp = v
          size = 3
    elif b0 < 0xF5u8 and i + 3 < text.len:
      let b1 = uint8(text[i + 1])
      let b2 = uint8(text[i + 2])
      let b3 = uint8(text[i + 3])
      if b1 >= 0x80u8 and b1 < 0xC0u8 and b2 >= 0x80u8 and b2 < 0xC0u8 and
          b3 >= 0x80u8 and b3 < 0xC0u8:
        let v = (uint32(b0 and 0x07u8) shl 18) or
          (uint32(b1 and 0x3Fu8) shl 12) or
          (uint32(b2 and 0x3Fu8) shl 6) or uint32(b3 and 0x3Fu8)
        if v >= 0x10000u32 and v <= 0x10FFFFu32:
          cp = v
          size = 4
    result.add(BidiChar(cp: cp, cls: bidiClassFor(cp), level: 0, srcOff: i,
      srcLen: size))
    i += size

proc matchIsolates(chars: seq[BidiChar]): seq[int] =
  # Matching PDI per isolate initiator (BD9), -1 when absent.
  result = newSeq[int](chars.len)
  for i in 0 ..< chars.len:
    result[i] = -1
  for i in 0 ..< chars.len:
    if bidiClassFor(chars[i].cp) in {BidiFSI, BidiLRI, BidiRLI}:
      var depth = 1
      var j = i + 1
      while j < chars.len:
        let c = bidiClassFor(chars[j].cp)
        if c in {BidiFSI, BidiLRI, BidiRLI}:
          inc depth
        elif c == BidiPDI:
          dec depth
          if depth == 0:
            result[i] = j
            break
        inc j

proc paraLevelFor(chars: seq[BidiChar], matches: seq[int], lo,
    hi: int): int =
  # P2/P3 decision over [lo, hi): 1 when the first strong is AL/R.
  var i = lo
  while i < hi:
    if bidiClassFor(chars[i].cp) in {BidiFSI, BidiLRI, BidiRLI}:
      if matches[i] >= 0:
        i = matches[i] + 1
      else:
        break
      continue
    let c = chars[i].cls
    if c == BidiL:
      return 0
    if c == BidiR or c == BidiAL:
      return 1
    inc i
  0

proc raiseLevel(cur: int, wantOdd: bool): int =
  # Least odd or even level greater than the current one.
  if wantOdd:
    if cur mod 2 == 0: cur + 1 else: cur + 2
  else:
    if cur mod 2 == 1: cur + 1 else: cur + 2

proc applyExplicit(chars: var seq[BidiChar], paraLevel: int,
    matches: seq[int]) =
  # X1-X8: explicit levels, override resets, isolate tracking.
  var stack = @[StackEntry(level: paraLevel, override: 0u8, isolate: false)]
  var overflowIsolate = 0
  var overflowEmbedding = 0
  var validIsolate = 0
  for i in 0 ..< chars.len:
    let orig = bidiClassFor(chars[i].cp)
    case orig
    of BidiRLE, BidiLRE, BidiRLO, BidiLRO:
      let wantOdd = orig == BidiRLE or orig == BidiRLO
      let override =
        if orig == BidiRLO: 2u8
        elif orig == BidiLRO: 1u8
        else: 0u8
      if raiseLevel(stack[^1].level, wantOdd) <= MaxDepth and
          overflowIsolate == 0 and overflowEmbedding == 0:
        stack.add(StackEntry(level: raiseLevel(stack[^1].level, wantOdd),
          override: override, isolate: false))
      elif overflowIsolate == 0:
        inc overflowEmbedding
    of BidiRLI, BidiLRI, BidiFSI:
      chars[i].level = stack[^1].level
      if stack[^1].override == 1u8:
        chars[i].cls = BidiL
      elif stack[^1].override == 2u8:
        chars[i].cls = BidiR
      var wantOdd = orig == BidiRLI
      if orig == BidiFSI:
        let stop = if matches[i] >= 0: matches[i] else: chars.len
        wantOdd = paraLevelFor(chars, matches, i + 1, stop) == 1
      if raiseLevel(stack[^1].level, wantOdd) <= MaxDepth and
          overflowIsolate == 0 and overflowEmbedding == 0:
        stack.add(StackEntry(level: raiseLevel(stack[^1].level, wantOdd),
          override: 0u8, isolate: true))
        inc validIsolate
      else:
        inc overflowIsolate
    of BidiPDI:
      if overflowIsolate > 0:
        dec overflowIsolate
      elif validIsolate > 0:
        overflowEmbedding = 0
        while not stack[^1].isolate:
          discard stack.pop()
        discard stack.pop()
        dec validIsolate
      chars[i].level = stack[^1].level
      if stack[^1].override == 1u8:
        chars[i].cls = BidiL
      elif stack[^1].override == 2u8:
        chars[i].cls = BidiR
    of BidiPDF:
      if overflowIsolate == 0:
        if overflowEmbedding > 0:
          dec overflowEmbedding
        elif not stack[^1].isolate and stack.len >= 2:
          discard stack.pop()
      chars[i].level = stack[^1].level
    of BidiB:
      chars[i].level = paraLevel
    of BidiBN:
      chars[i].level = stack[^1].level
    else:
      chars[i].level = stack[^1].level
      if stack[^1].override == 1u8:
        chars[i].cls = BidiL
      elif stack[^1].override == 2u8:
        chars[i].cls = BidiR

proc removeX9(chars: seq[BidiChar]): seq[BidiChar] =
  # Drops RLE/LRE/RLO/LRO/PDF/BN; their levels are already consumed.
  for c in chars:
    if bidiClassFor(c.cp) notin {BidiRLE, BidiLRE, BidiRLO, BidiLRO,
        BidiPDF, BidiBN}:
      result.add(c)

proc isolatingSequences(chars: seq[BidiChar], paraLevel: int,
    matches: seq[int]): seq[RunSeq] =
  # X10/BD13: level runs chained into isolating run sequences.
  if chars.len == 0:
    return @[]
  var runOf = newSeq[int](chars.len)
  var runs: seq[tuple[first, last: int]] = @[]
  var i = 0
  while i < chars.len:
    var j = i
    while j + 1 < chars.len and chars[j + 1].level == chars[i].level:
      inc j
    for k in i .. j:
      runOf[k] = runs.len
    runs.add((i, j))
    i = j + 1
  var pdiMatched = newSeq[bool](chars.len)
  for a in 0 ..< chars.len:
    if matches[a] >= 0:
      pdiMatched[matches[a]] = true
  var r = 0
  while r < runs.len:
    let firstCp = bidiClassFor(chars[runs[r].first].cp)
    if firstCp != BidiPDI or not pdiMatched[runs[r].first]:
      var idx: seq[int] = @[]
      var cur = r
      while true:
        for k in runs[cur].first .. runs[cur].last:
          idx.add(k)
        let lastCp = bidiClassFor(chars[runs[cur].last].cp)
        if lastCp in {BidiFSI, BidiLRI, BidiRLI} and
            matches[runs[cur].last] >= 0:
          cur = runOf[matches[runs[cur].last]]
        else:
          break
      let lvl = chars[idx[0]].level
      var sos = BidiL
      if max(lvl, if idx[0] > 0: chars[idx[0] - 1].level
          else: paraLevel) mod 2 == 1:
        sos = BidiR
      var eosLevel = paraLevel
      let lastIdx = idx[^1]
      let lastIsBareInitiator =
        bidiClassFor(chars[lastIdx].cp) in {BidiFSI, BidiLRI, BidiRLI} and
        matches[lastIdx] < 0
      if not lastIsBareInitiator and lastIdx + 1 < chars.len:
        eosLevel = chars[lastIdx + 1].level
      let eos = if max(lvl, eosLevel) mod 2 == 1: BidiR else: BidiL
      result.add(RunSeq(idx: idx, level: lvl, sos: sos, eos: eos))
    inc r

proc resolveWeak(s: RunSeq, chars: var seq[BidiChar]) =
  # W1-W7 over one isolating run sequence.
  for k in 0 ..< s.idx.len:
    let pos = s.idx[k]
    if chars[pos].cls != BidiNSM:
      continue
    if k == 0:
      chars[pos].cls = s.sos
    else:
      let prev = bidiClassFor(chars[s.idx[k - 1]].cp)
      if prev in {BidiFSI, BidiLRI, BidiRLI, BidiPDI}:
        chars[pos].cls = BidiON
      else:
        chars[pos].cls = chars[s.idx[k - 1]].cls
  for k in 0 ..< s.idx.len:
    let pos = s.idx[k]
    if chars[pos].cls != BidiEN:
      continue
    var j = k - 1
    while j >= 0:
      let t = chars[s.idx[j]].cls
      if t == BidiAL:
        chars[pos].cls = BidiAN
        break
      if t == BidiR or t == BidiL:
        break
      dec j
  for k in 0 ..< s.idx.len:
    if chars[s.idx[k]].cls == BidiAL:
      chars[s.idx[k]].cls = BidiR
  for k in 1 ..< s.idx.len - 1:
    let pos = s.idx[k]
    let t = chars[pos].cls
    if t != BidiES and t != BidiCS:
      continue
    let prev = chars[s.idx[k - 1]].cls
    let next = chars[s.idx[k + 1]].cls
    if t == BidiES and prev == BidiEN and next == BidiEN:
      chars[pos].cls = BidiEN
    elif t == BidiCS and (prev == BidiEN or prev == BidiAN) and
        prev == next:
      chars[pos].cls = prev
  var k = 0
  while k < s.idx.len:
    if chars[s.idx[k]].cls != BidiET:
      inc k
      continue
    var j = k
    while j + 1 < s.idx.len and chars[s.idx[j + 1]].cls == BidiET:
      inc j
    let touchesEN = (k > 0 and chars[s.idx[k - 1]].cls == BidiEN) or
      (j + 1 < s.idx.len and chars[s.idx[j + 1]].cls == BidiEN)
    if touchesEN:
      for m in k .. j:
        chars[s.idx[m]].cls = BidiEN
    k = j + 1
  for k in 0 ..< s.idx.len:
    let pos = s.idx[k]
    if chars[pos].cls in {BidiES, BidiET, BidiCS}:
      chars[pos].cls = BidiON
  for k in 0 ..< s.idx.len:
    let pos = s.idx[k]
    if chars[pos].cls != BidiEN:
      continue
    var j = k - 1
    while j >= 0:
      let t = chars[s.idx[j]].cls
      if t == BidiL:
        chars[pos].cls = BidiL
        break
      if t == BidiR:
        break
      dec j

proc pairedClose(openCp: uint32): tuple[ok: bool, closeCp: uint32] =
  # Canonical closing bracket for an opening bracket.
  for b in bidiBrackets:
    if b.openCp == openCp:
      return (true, b.closeCp)
  (false, 0u32)

proc bracketOpen(cp: uint32): bool =
  # True when some pair opens with this code point.
  pairedClose(cp).ok

proc bracketClose(cp: uint32): bool =
  # True when some pair closes with this code point.
  for b in bidiBrackets:
    if b.closeCp == cp:
      return true
  false

proc closeMatches(closeCp, openCp: uint32): bool =
  # BD16 comparison with U+3009 and U+232A equivalent.
  let (ok, want) = pairedClose(openCp)
  if not ok:
    return false
  if want == closeCp:
    return true
  (want == 0x3009u32 or want == 0x232Au32) and
    (closeCp == 0x3009u32 or closeCp == 0x232Au32)

proc bracketPairs(s: RunSeq,
    chars: seq[BidiChar]): seq[tuple[openPos, closePos: int]] =
  # BD16 bracket pairs over one isolating run sequence.
  var stack: seq[tuple[openCp: uint32, pos: int]] = @[]
  for k in 0 ..< s.idx.len:
    let pos = s.idx[k]
    if chars[pos].cls != BidiON:
      continue
    let cp = chars[pos].cp
    if bracketOpen(cp):
      if stack.len >= 63:
        return @[]
      stack.add((cp, pos))
    elif bracketClose(cp):
      var f = -1
      var d = stack.high
      while d >= 0:
        if closeMatches(cp, stack[d].openCp):
          f = d
          break
        dec d
      if f >= 0:
        result.add((stack[f].pos, pos))
        stack.setLen(f)
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i
    while j > 0 and result[j - 1].openPos > cur.openPos:
      result[j] = result[j - 1]
      dec j
    result[j] = cur

proc strongDir(t: BidiClass): tuple[ok: bool, dir: BidiClass] =
  # L/R directly, EN/AN as R for neutral resolution.
  case t
  of BidiL:
    (true, BidiL)
  of BidiR, BidiEN, BidiAN:
    (true, BidiR)
  else:
    (false, BidiL)

proc isNI(t: BidiClass): bool =
  # Neutral or isolate formatting (UAX #9 Table 3).
  t in {BidiB, BidiS, BidiWS, BidiON, BidiFSI, BidiLRI, BidiRLI, BidiPDI}

proc adoptFollowingNSM(s: RunSeq, chars: var seq[BidiChar], fromK: int,
    use: BidiClass) =
  # N0 trailing rule: original NSMs after a changed bracket follow it.
  var k = fromK + 1
  while k < s.idx.len and
      bidiClassFor(chars[s.idx[k]].cp) == BidiNSM:
    chars[s.idx[k]].cls = use
    inc k

proc resolveNeutrals(s: RunSeq, chars: var seq[BidiChar]) =
  # N0-N2: brackets, then neutrals from surrounding or embedding.
  let e = if s.level mod 2 == 1: BidiR else: BidiL
  for (openPos, closePos) in bracketPairs(s, chars):
    var ko = -1
    var kc = -1
    for k in 0 ..< s.idx.len:
      if s.idx[k] == openPos:
        ko = k
      if s.idx[k] == closePos:
        kc = k
    var use = e
    var foundE = false
    for k in ko + 1 ..< kc:
      let (ok, dir) = strongDir(chars[s.idx[k]].cls)
      if ok and dir == e:
        foundE = true
        break
    if not foundE:
      var ctx = s.sos
      var k = ko - 1
      while k >= 0:
        let (ok, dir) = strongDir(chars[s.idx[k]].cls)
        if ok:
          ctx = dir
          break
        dec k
      use = if ctx != e: ctx else: e
    chars[openPos].cls = use
    chars[closePos].cls = use
    adoptFollowingNSM(s, chars, ko, use)
    adoptFollowingNSM(s, chars, kc, use)
  var k = 0
  while k < s.idx.len:
    if not isNI(chars[s.idx[k]].cls):
      inc k
      continue
    var j = k
    while j + 1 < s.idx.len and isNI(chars[s.idx[j + 1]].cls):
      inc j
    let (leftOk, leftDir) =
      if k > 0: strongDir(chars[s.idx[k - 1]].cls)
      else: (true, s.sos)
    let (rightOk, rightDir) =
      if j + 1 < s.idx.len: strongDir(chars[s.idx[j + 1]].cls)
      else: (true, s.eos)
    if leftOk and rightOk and leftDir == rightDir:
      for m in k .. j:
        chars[s.idx[m]].cls = leftDir
    k = j + 1
  for k in 0 ..< s.idx.len:
    if isNI(chars[s.idx[k]].cls):
      chars[s.idx[k]].cls = e

proc applyImplicit(chars: var seq[BidiChar]) =
  # I1-I2: bump levels from resolved types.
  for c in chars.mitems:
    if c.level mod 2 == 0:
      if c.cls == BidiR:
        inc c.level
      elif c.cls == BidiEN or c.cls == BidiAN:
        c.level += 2
    else:
      if c.cls == BidiL or c.cls == BidiEN or c.cls == BidiAN:
        inc c.level

proc resetTrailing(chars: var seq[BidiChar], paraLevel: int) =
  # Trailing L1 piece: separators, trailing whitespace, and isolate
  # codes collapse to the paragraph level.
  for c in chars.mitems:
    let o = bidiClassFor(c.cp)
    if o == BidiB or o == BidiS:
      c.level = paraLevel
  var i = chars.len - 1
  while i >= 0:
    let o = bidiClassFor(chars[i].cp)
    if o == BidiWS or o in {BidiFSI, BidiLRI, BidiRLI, BidiPDI}:
      chars[i].level = paraLevel
      dec i
    else:
      break

proc reorderVisual(chars: seq[BidiChar]): seq[BidiChar] =
  # L2: descending levels, reversing runs at or above each level.
  result = chars
  var maxLevel = 0
  for c in result:
    maxLevel = max(maxLevel, c.level)
  var k = maxLevel
  while k >= 1:
    var i = 0
    while i < result.len:
      if result[i].level >= k:
        var j = i
        while j + 1 < result.len and result[j + 1].level >= k:
          inc j
        var a = i
        var b = j
        while a < b:
          swap(result[a], result[b])
          inc a
          dec b
        i = j + 1
      else:
        inc i
    dec k

proc encodeBidiCp(cp: uint32): string =
  # Encodes one code point as UTF-8.
  if cp < 0x80u32:
    result = $char(cp)
  elif cp < 0x800u32:
    result = newString(2)
    result[0] = char(0xC0u32 or (cp shr 6))
    result[1] = char(0x80u32 or (cp and 0x3Fu32))
  elif cp < 0x10000u32:
    result = newString(3)
    result[0] = char(0xE0u32 or (cp shr 12))
    result[1] = char(0x80u32 or ((cp shr 6) and 0x3Fu32))
    result[2] = char(0x80u32 or (cp and 0x3Fu32))
  else:
    result = newString(4)
    result[0] = char(0xF0u32 or (cp shr 18))
    result[1] = char(0x80u32 or ((cp shr 12) and 0x3Fu32))
    result[2] = char(0x80u32 or ((cp shr 6) and 0x3Fu32))
    result[3] = char(0x80u32 or (cp and 0x3Fu32))

proc isAttachable(cp: uint32): bool =
  # True for marks, ZWJ, and variation selectors merged into runs.
  generalCategoryFor(cp).isMark() or cp == 0x200Du32 or
    isVariationSelector(cp)

proc buildVisual(chars: seq[BidiChar], srcLen: int): VisualText =
  # L4 mirroring plus text, map, and mark-merged runs. Runs group
  # maximal levels; a run of only attachables merges into the previous
  # run, while attachables followed by their base stay with it.
  var cs = chars
  for c in cs.mitems:
    if c.level mod 2 == 1:
      let m = mirroringFor(c.cp)
      if m.isSome:
        c.cp = m.get
  var groups: seq[tuple[first, last: int]] = @[]
  for i in 0 ..< cs.len:
    if groups.len == 0 or cs[i].level != cs[groups[^1].first].level:
      if groups.len > 0:
        groups[^1].last = i
      groups.add((i, i))
  if groups.len > 0:
    groups[^1].last = cs.len
  var k = 1
  while k < groups.len:
    var hasBase = false
    for j in groups[k].first ..< groups[k].last:
      if not isAttachable(cs[j].cp):
        hasBase = true
        break
    if hasBase:
      inc k
    else:
      groups[k - 1].last = groups[k].last
      groups.del(k)
  result.text = ""
  result.map = @[]
  result.runs = @[]
  for g in groups:
    let start = result.text.len
    for j in g.first ..< g.last:
      let enc = encodeBidiCp(cs[j].cp)
      result.text.add(enc)
      for b in 0 ..< enc.len:
        result.map.add(cs[j].srcOff + min(b, cs[j].srcLen - 1))
    let dir =
      if cs[g.first].level mod 2 == 1: dirRightToLeft
      else: dirLeftToRight
    result.runs.add(VisualRun(first: start, last: result.text.len,
      level: cs[g.first].level, dir: dir))
  result.map.add(srcLen)

proc visualRuns*(text: string, base: BaseDirection): VisualText =
  ## Shapes one pre-split paragraph into visual runs in display order.
  ## Callers split paragraphs and lines first; B and S handling past
  ## the trailing L1 reset is out of scope. X9-removed codes never
  ## reach the output, and odd-level runs carry L4 mirrors, so `text`
  ## is shaping-ready while `map` keeps every byte traceable to its
  ## logical source offset. Runs group maximal levels; attachables
  ## (marks, ZWJ, variation selectors) starting a run merge into the
  ## previous run only when no base follows them in that run, so marks
  ## stay positioned on their bases. A paragraph-initial attachable
  ## run stands alone. Each run shapes with an explicit direction,
  ## bypassing segment guessing.
  var chars = decodeBidiText(text)
  let matches = matchIsolates(chars)
  let paraLevel =
    case base
    of bdLtr: 0
    of bdRtl: 1
    of bdAuto: paraLevelFor(chars, matches, 0, chars.len)
  applyExplicit(chars, paraLevel, matches)
  var kept = removeX9(chars)
  for s in isolatingSequences(kept, paraLevel, matchIsolates(kept)):
    resolveWeak(s, kept)
    resolveNeutrals(s, kept)
  applyImplicit(kept)
  resetTrailing(kept, paraLevel)
  buildVisual(reorderVisual(kept), text.len)
