import std/strutils

type
  Language* = object
    ## BCP 47 language tag with underscores normalized to dashes.
    tag*: string
    ## Normalized language tag text.

proc newLanguage*(s: string): tuple[ok: bool, lang: Language] =
  ## Normalizes a language string; reports failure on empty input.
  if s.len == 0:
    return (false, Language())
  var n = newString(s.len)
  for i, c in s:
    n[i] = if c == '_': '-' else: c.toLowerAscii()
  (true, Language(tag: n))

proc parseLanguage*(s: string): Language =
  ## Parses a language string; raises ValueError on empty input.
  let (ok, lang) = newLanguage(s)
  if not ok:
    raise newException(ValueError, "invalid language")
  lang

proc asStr*(l: Language): string =
  ## Returns the normalized tag text.
  l.tag
proc `$`*(l: Language): string =
  ## Renders the normalized tag text.
  l.tag
proc `==`*(a, b: Language): bool =
  ## True when both languages hold the same tag.
  a.tag == b.tag
