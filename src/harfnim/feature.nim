import std/strutils
import ./tag

type
  Feature* = object
    tag*: Tag
    value*: uint32
    start*: uint32
    stop*: uint32

const
  GlobalStart* = 0u32
  GlobalEnd* = high(uint32)

proc newFeature*(t: Tag, value: uint32, first, last: uint32): Feature =
  Feature(tag: t, value: value, start: first, stop: last)

proc globalFeature*(t: Tag, value: uint32 = 1): Feature =
  Feature(tag: t, value: value, start: GlobalStart, stop: GlobalEnd)

proc isGlobal*(f: Feature): bool =
  f.start == GlobalStart and f.stop == GlobalEnd

proc `==`*(a, b: Feature): bool =
  a.tag == b.tag and a.value == b.value and a.start == b.start and a.stop == b.stop

# --- feature string parsing (hb-feature syntax) ---

type Parser = object
  s: string
  pos: int

proc atEnd(p: Parser): bool = p.pos >= p.s.len
proc curr(p: Parser): char = p.s[p.pos]

proc skipSpaces(p: var Parser) =
  while not p.atEnd() and p.curr() in {' ', '\t', '\n', '\r'}:
    inc p.pos

proc consumeByte(p: var Parser, c: char): bool =
  if not p.atEnd() and p.s[p.pos] == c:
    inc p.pos
    true
  else:
    false

proc consumeQuote(p: var Parser): char =
  if not p.atEnd() and p.curr() in {'\'', '"'}:
    result = p.curr()
    inc p.pos
  else:
    result = '\0'

proc consumeTag(p: var Parser): tuple[ok: bool, tag: Tag] =
  let start = p.pos
  while not p.atEnd() and (p.curr().isAlphaNumeric() or p.curr() == '_'):
    inc p.pos
  let name = p.s[start ..< p.pos]
  if name.len == 0 or name.len > 4:
    return (false, tagFromStr("    "))
  (true, tagFromStr(name))

proc consumeI32(p: var Parser): tuple[ok: bool, v: int32] =
  let start = p.pos
  if not p.atEnd() and p.curr() in {'-', '+'}:
    inc p.pos
  let ds = p.pos
  while not p.atEnd() and p.curr() in {'0' .. '9'}:
    inc p.pos
  if p.pos == ds:
    return (false, 0i32)
  try:
    (true, int32(parseInt(p.s[start ..< p.pos])))
  except ValueError:
    (false, 0i32)

proc consumeBool(p: var Parser): tuple[ok: bool, v: bool] =
  p.skipSpaces()
  let start = p.pos
  while not p.atEnd() and p.curr().isAlphaAscii():
    inc p.pos
  let w = p.s[start ..< p.pos].toLowerAscii()
  if w == "on":
    (true, true)
  elif w == "off":
    (true, false)
  else:
    p.pos = start
    (false, false)

proc parseFeature*(s: string): Feature =
  var p = Parser(s: s, pos: 0)
  if s.len == 0:
    raise newException(ValueError, "invalid feature")
  var value = 1u32
  if not p.atEnd():
    if p.curr() == '-':
      value = 0u32
      inc p.pos
    elif p.curr() == '+':
      value = 1u32
      inc p.pos
  p.skipSpaces()
  let q = p.consumeQuote()
  let (tok, t) = p.consumeTag()
  if not tok:
    raise newException(ValueError, "invalid feature")
  var tag = t
  if q != '\0':
    if not p.consumeByte(q):
      raise newException(ValueError, "invalid feature")
  p.skipSpaces()
  var start = GlobalStart
  var stop = GlobalEnd
  if p.consumeByte('['):
    let (sok, sv) = p.consumeI32()
    start = if sok: cast[uint32](sv) else: 0u32
    if not p.atEnd() and p.curr() in {':', ';'}:
      inc p.pos
      let (eok, ev) = p.consumeI32()
      stop = if eok: cast[uint32](ev) else: GlobalEnd
    else:
      if sok and start != GlobalEnd:
        stop = start + 1
      else:
        stop = GlobalEnd
    if not p.consumeByte(']'):
      raise newException(ValueError, "invalid feature")
  let hadEqual = p.consumeByte('=')
  let (iok, iv) = p.consumeI32()
  let (bok, bv) = if not iok: p.consumeBool() else: (false, false)
  if hadEqual and not iok and not bok:
    raise newException(ValueError, "invalid feature")
  if iok:
    value = cast[uint32](iv)
  elif bok:
    value = if bv: 1u32 else: 0u32
  p.skipSpaces()
  if not p.atEnd():
    raise newException(ValueError, "invalid feature")
  Feature(tag: tag, value: value, start: start, stop: stop)
