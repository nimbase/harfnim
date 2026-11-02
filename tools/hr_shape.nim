## hr-shape: minimal hb-shape compatible CLI for harfnim.
##
## Usage: hr-shape [OPTIONS] FONT [TEXT]
##
## Output format matches `hb-shape --no-glyph-names --utf8-clusters`:
## `[gid=cluster@dx,dy+ax,ay|...]` with numeric glyph ids and UTF-8 byte
## cluster offsets. Offsets print only when nonzero, `,ay` only when the
## y advance is nonzero.

import std/options
import std/os
import std/strutils

import harfnim

proc usage(status: int) =
  stderr.writeLine("Usage: hr-shape [OPTIONS] FONT [TEXT]")
  stderr.writeLine("  --font-size=N[,M]|upem   font size (default: upem)")
  stderr.writeLine("  -y, --face-index=N       face index (default: 0)")
  stderr.writeLine("  --features=LIST          comma-separated, repeatable")
  stderr.writeLine("  --direction=ltr|rtl|ttb|btt")
  stderr.writeLine("  --script=XXXX            ISO-15924 tag")
  stderr.writeLine("  --language=TAG           BCP 47 tag")
  stderr.writeLine("  --text=STRING            input text")
  stderr.writeLine("  --text-file=FILE         read text from file")
  stderr.writeLine("  -u, --unicodes=LIST      hex codepoints")
  stderr.writeLine("  --no-glyph-names         accepted (output is numeric)")
  stderr.writeLine("  --utf8-clusters          accepted (clusters are bytes)")
  stderr.writeLine("  --bot, --eot             paragraph boundaries")
  stderr.writeLine("  -h, --help               this help")
  quit(status)

proc readBytes(path: string): seq[uint8] =
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  for i, c in s:
    result[i] = uint8(c)

proc encodeUtf8(cp: uint32): string =
  if cp < 0x80u32:
    result = newString(1)
    result[0] = char(cp)
  elif cp < 0x800u32:
    result = newString(2)
    result[0] = char(0xC0u32 or (cp shr 6))
    result[1] = char(0x80u32 or (cp and 0x3Fu32))
  elif cp < 0x10000u32:
    result = newString(3)
    result[0] = char(0xE0u32 or (cp shr 12))
    result[1] = char(0x80u32 or ((cp shr 6) and 0x3Fu32))
    result[2] = char(0x80u32 or (cp and 0x3Fu32))
  elif cp <= 0x10FFFFu32:
    result = newString(4)
    result[0] = char(0xF0u32 or (cp shr 18))
    result[1] = char(0x80u32 or ((cp shr 12) and 0x3Fu32))
    result[2] = char(0x80u32 or ((cp shr 6) and 0x3Fu32))
    result[3] = char(0x80u32 or (cp and 0x3Fu32))
  else:
    quit("invalid codepoint: " & $cp)

proc parseUnicodes(s: string): string =
  result = ""
  for part in s.split({',', ' ', '\t', '\n', '\r', ';'}):
    let t = part.strip()
    if t.len == 0:
      continue
    var h = t
    if h.len > 2 and (h[0..1] == "U+" or h[0..1] == "u+"):
      h = h[2..^1]
    elif h.len > 2 and (h[0..1] == "0x" or h[0..1] == "0X"):
      h = h[2..^1]
    var cp = 0u32
    try:
      cp = uint32(parseHexInt(h))
    except ValueError:
      quit("invalid codepoint: " & t)
    result &= encodeUtf8(cp)

proc splitFeatures(s: string): seq[string] =
  for part in s.split(','):
    let t = part.strip()
    if t.len > 0:
      result.add(t)

var
  fontPath = ""
  fontFileOpt = ""
  textPos = ""
  textOpt = ""
  textFileOpt = ""
  unicodesOpt = ""
  sizeOpt = ""
  faceIndex = 0
  featureParts: seq[string] = @[]
  dirOverride: Option[Direction] = none(Direction)
  scriptOverride: Option[Script] = none(Script)
  langOverride: Option[Language] = none(Language)
  flagBot = false
  flagEot = false

var i = 1
var positionals: seq[string] = @[]
while i <= paramCount():
  let a = paramStr(i)
  if a == "--":
    for j in i + 1 .. paramCount():
      positionals.add(paramStr(j))
    break
  elif a == "-h" or a == "--help":
    usage(0)
  elif a == "-y" or a == "--face-index":
    inc i
    if i > paramCount():
      quit("--face-index needs a value")
    try:
      faceIndex = parseInt(paramStr(i))
    except ValueError:
      quit("invalid face index: " & paramStr(i))
  elif a.startsWith("--face-index="):
    try:
      faceIndex = parseInt(a.split('=', 1)[1])
    except ValueError:
      quit("invalid face index: " & a)
  elif a == "--font-size":
    inc i
    if i > paramCount():
      quit("--font-size needs a value")
    sizeOpt = paramStr(i)
  elif a.startsWith("--font-size="):
    sizeOpt = a.split('=', 1)[1]
  elif a == "--features":
    inc i
    if i > paramCount():
      quit("--features needs a value")
    featureParts.add(splitFeatures(paramStr(i)))
  elif a.startsWith("--features="):
    featureParts.add(splitFeatures(a.split('=', 1)[1]))
  elif a == "--direction":
    inc i
    if i > paramCount():
      quit("--direction needs a value")
    try:
      dirOverride = some(parseDirection(paramStr(i)))
    except ValueError:
      quit("invalid direction: " & paramStr(i))
  elif a.startsWith("--direction="):
    try:
      dirOverride = some(parseDirection(a.split('=', 1)[1]))
    except ValueError:
      quit("invalid direction: " & a)
  elif a == "--script":
    inc i
    if i > paramCount():
      quit("--script needs a value")
    try:
      scriptOverride = some(parseScript(paramStr(i)))
    except ValueError:
      quit("invalid script: " & paramStr(i))
  elif a.startsWith("--script="):
    try:
      scriptOverride = some(parseScript(a.split('=', 1)[1]))
    except ValueError:
      quit("invalid script: " & a)
  elif a == "--language":
    inc i
    if i > paramCount():
      quit("--language needs a value")
    try:
      langOverride = some(parseLanguage(paramStr(i)))
    except ValueError:
      quit("invalid language: " & paramStr(i))
  elif a.startsWith("--language="):
    try:
      langOverride = some(parseLanguage(a.split('=', 1)[1]))
    except ValueError:
      quit("invalid language: " & a)
  elif a == "--text":
    inc i
    if i > paramCount():
      quit("--text needs a value")
    textOpt = paramStr(i)
  elif a.startsWith("--text="):
    textOpt = a.split('=', 1)[1]
  elif a == "--text-file":
    inc i
    if i > paramCount():
      quit("--text-file needs a value")
    textFileOpt = paramStr(i)
  elif a.startsWith("--text-file="):
    textFileOpt = a.split('=', 1)[1]
  elif a == "-u" or a == "--unicodes":
    inc i
    if i > paramCount():
      quit("--unicodes needs a value")
    unicodesOpt = paramStr(i)
  elif a.startsWith("--unicodes="):
    unicodesOpt = a.split('=', 1)[1]
  elif a == "--no-glyph-names" or a == "--utf8-clusters":
    discard
  elif a == "--bot":
    flagBot = true
  elif a == "--eot":
    flagEot = true
  elif a == "--font-file":
    inc i
    if i > paramCount():
      quit("--font-file needs a value")
    fontFileOpt = paramStr(i)
  elif a.startsWith("--font-file="):
    fontFileOpt = a.split('=', 1)[1]
  elif a.len > 0 and a[0] == '-':
    quit("unknown option: " & a)
  else:
    positionals.add(a)
  inc i

if fontFileOpt != "":
  fontPath = fontFileOpt
if positionals.len >= 1 and fontPath == "":
  fontPath = positionals[0]
if positionals.len >= 2 and textOpt == "" and textFileOpt == "" and
    unicodesOpt == "":
  textPos = positionals[1]
if positionals.len > 2:
  quit("too many positional arguments")
if fontPath == "":
  usage(1)

var feats: seq[Feature] = @[]
var mentioned: seq[uint32] = @[]
for part in featureParts:
  try:
    let f = parseFeature(part)
    mentioned.add(f.tag.toU32())
    if f.value != 0u32:
      feats.add(f)
  except ValueError:
    quit("invalid feature: " & part)

# HarfBuzz enables this set unless the user mentions the tag; mirror
# that so bare invocations match hb-shape output.
const DefaultFeatures = ["abvm", "blwm", "calt", "ccmp", "clig", "curs",
  "dist", "kern", "liga", "locl", "mark", "mkmk", "rlig", "rclt"]
for t in DefaultFeatures:
  let tag = tagFromStr(t)
  if tag.toU32() notin mentioned:
    feats.add(globalFeature(tag, 1))

var sf: ShaperFont
try:
  let bytes = readBytes(fontPath)
  sf = newShaperFont(parseFont(bytes, faceIndex))
except IOError as e:
  quit("cannot read font: " & e.msg)
except FontError as e:
  quit("cannot parse font: " & e.msg)

if sizeOpt != "" and sizeOpt != "upem":
  let parts = sizeOpt.split(',')
  try:
    if parts.len == 1:
      sf.setScale(int32(parseInt(parts[0].strip())))
    elif parts.len == 2:
      sf.setScaleSeparate(int32(parseInt(parts[0].strip())),
        int32(parseInt(parts[1].strip())))
    else:
      quit("invalid font size: " & sizeOpt)
  except ValueError:
    quit("invalid font size: " & sizeOpt)

var texts: seq[string] = @[]
if unicodesOpt != "":
  texts.add(parseUnicodes(unicodesOpt))
elif textOpt != "":
  texts.add(textOpt)
elif textPos != "":
  texts.add(textPos)
elif textFileOpt != "":
  try:
    texts = readFile(textFileOpt).splitLines()
  except IOError as e:
    quit("cannot read text file: " & e.msg)
  if texts.len > 1 and texts[^1] == "":
    texts.setLen(texts.len - 1)
  if texts.len == 0:
    texts.add("")
else:
  var all = ""
  try:
    all = stdin.readAll()
  except IOError as e:
    quit("cannot read stdin: " & e.msg)
  if all == "":
    quit("no text provided")
  texts = all.splitLines()
  if texts.len > 1 and texts[^1] == "":
    texts.setLen(texts.len - 1)

for t in texts:
  var b = newBuffer()
  b.pushStr(t)
  if dirOverride.isSome:
    b.direction = dirOverride.get
  if scriptOverride.isSome:
    b.script = some(scriptOverride.get)
  if langOverride.isSome:
    b.language = some(langOverride.get)
  if flagBot:
    b.flags = b.flags or BeginningOfText
  if flagEot:
    b.flags = b.flags or EndOfText
  sf.shape(b, feats)
  var parts: seq[string] = @[]
  for k in 0 ..< b.len:
    var s = $b.info[k].glyphId & "=" & $b.info[k].cluster
    if k < b.pos.len:
      let p = b.pos[k]
      if p.xOffset != 0i32 or p.yOffset != 0i32:
        s &= "@" & $p.xOffset & "," & $p.yOffset
      s &= "+" & $p.xAdvance
      if p.yAdvance != 0i32:
        s &= "," & $p.yAdvance
    parts.add(s)
  echo "[" & parts.join("|") & "]"
