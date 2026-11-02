import std/strutils

type
  Language* = object
    tag*: string

proc newLanguage*(s: string): tuple[ok: bool, lang: Language] =
  if s.len == 0:
    return (false, Language())
  var n = newString(s.len)
  for i, c in s:
    n[i] = if c == '_': '-' else: c.toLowerAscii()
  (true, Language(tag: n))

proc parseLanguage*(s: string): Language =
  let (ok, lang) = newLanguage(s)
  if not ok:
    raise newException(ValueError, "invalid language")
  lang

proc asStr*(l: Language): string = l.tag
proc `$`*(l: Language): string = l.tag
proc `==`*(a, b: Language): bool = a.tag == b.tag
