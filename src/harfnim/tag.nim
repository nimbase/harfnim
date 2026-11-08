type
  Tag* = distinct uint32
    ## Four byte OpenType tag wrapping a uint32.

proc makeTag*(a, b, c, d: char): Tag =
  ## Builds a tag from four characters.
  Tag((uint32(uint8(a)) shl 24) or (uint32(uint8(b)) shl 16) or
    (uint32(uint8(c)) shl 8) or uint32(uint8(d)))

proc tagFromBytes*(b: array[4, uint8]): Tag =
  ## Builds a tag from four big endian bytes.
  Tag((uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or (uint32(b[2]) shl 8) or
    uint32(b[3]))

proc tagFromStr*(s: string): Tag =
  ## Builds a tag from a string, padding short strings with spaces.
  var b: array[4, uint8]
  for i in 0 ..< 4:
    b[i] = if i < s.len: uint8(s[i]) else: uint8(' ')
  tagFromBytes(b)

proc toBytes*(t: Tag): array[4, uint8] =
  ## Splits a tag into four big endian bytes.
  let v = uint32(t)
  [uint8(v shr 24), uint8(v shr 16), uint8(v shr 8), uint8(v)]

proc toStr*(t: Tag): string =
  ## Renders a tag as a four character string.
  let b = t.toBytes()
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(b[i])

proc toU32*(t: Tag): uint32 =
  ## Returns the raw uint32 value.
  uint32(t)
proc fromU32*(v: uint32): Tag =
  ## Wraps a raw uint32 as a tag.
  Tag(v)

proc `==`*(a, b: Tag): bool =
  ## True when both tags hold the same bytes.
  uint32(a) == uint32(b)
proc `$`*(t: Tag): string =
  ## Renders a tag as a four character string.
  t.toStr()

proc isNull*(t: Tag): bool =
  ## True when the tag is all zero.
  uint32(t) == 0

proc toUpper*(t: Tag): Tag =
  ## Uppercases ASCII letters in the tag.
  let b = t.toBytes()
  var o: array[4, uint8]
  for i in 0 ..< 4:
    let c = b[i]
    o[i] = if c >= uint8('a') and c <= uint8('z'): c - 32u8 else: c
  tagFromBytes(o)

proc toLower*(t: Tag): Tag =
  ## Lowercases ASCII letters in the tag.
  let b = t.toBytes()
  var o: array[4, uint8]
  for i in 0 ..< 4:
    let c = b[i]
    o[i] = if c >= uint8('A') and c <= uint8('Z'): c + 32u8 else: c
  tagFromBytes(o)

proc defaultScriptTag*(): Tag =
  ## The default OpenType script tag.
  tagFromStr("DFLT")
proc defaultLanguageTag*(): Tag =
  ## The default OpenType language tag.
  tagFromStr("dflt")
