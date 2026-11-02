type
  Tag* = distinct uint32

proc makeTag*(a, b, c, d: char): Tag =
  Tag((uint32(uint8(a)) shl 24) or (uint32(uint8(b)) shl 16) or
    (uint32(uint8(c)) shl 8) or uint32(uint8(d)))

proc tagFromBytes*(b: array[4, uint8]): Tag =
  Tag((uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or (uint32(b[2]) shl 8) or
    uint32(b[3]))

proc tagFromStr*(s: string): Tag =
  var b: array[4, uint8]
  for i in 0 ..< 4:
    b[i] = if i < s.len: uint8(s[i]) else: uint8(' ')
  tagFromBytes(b)

proc toBytes*(t: Tag): array[4, uint8] =
  let v = uint32(t)
  [uint8(v shr 24), uint8(v shr 16), uint8(v shr 8), uint8(v)]

proc toStr*(t: Tag): string =
  let b = t.toBytes()
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(b[i])

proc toU32*(t: Tag): uint32 = uint32(t)
proc fromU32*(v: uint32): Tag = Tag(v)

proc `==`*(a, b: Tag): bool {.borrow.}
proc `$`*(t: Tag): string = t.toStr()

proc isNull*(t: Tag): bool = uint32(t) == 0

proc toUpper*(t: Tag): Tag =
  let b = t.toBytes()
  var o: array[4, uint8]
  for i in 0 ..< 4:
    let c = b[i]
    o[i] = if c >= uint8('a') and c <= uint8('z'): c - 32u8 else: c
  tagFromBytes(o)

proc toLower*(t: Tag): Tag =
  let b = t.toBytes()
  var o: array[4, uint8]
  for i in 0 ..< 4:
    let c = b[i]
    o[i] = if c >= uint8('A') and c <= uint8('Z'): c + 32u8 else: c
  tagFromBytes(o)

proc defaultScriptTag*(): Tag = tagFromStr("DFLT")
proc defaultLanguageTag*(): Tag = tagFromStr("dflt")
