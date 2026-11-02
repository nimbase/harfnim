import std/strutils
import ./tag
import ./script

type
  Direction* = enum
    dirInvalid = 0
    dirLeftToRight = 1
    dirRightToLeft = 2
    dirTopToBottom = 3
    dirBottomToTop = 4

proc directionForScript*(s: Script): tuple[ok: bool, dir: Direction] =
  let t = s.tag().toStr()
  case t
  of "Arab", "Hebr", "Syrc", "Thaa", "Cprt", "Khar", "Phnx", "Nkoo", "Lydi",
      "Avst", "Armi", "Phli", "Prti", "Sarb", "Orkh", "Samr", "Mand", "Merc",
      "Mero", "Mani", "Mend", "Nbat", "Narb", "Palm", "Phlp", "Hatr", "Adlm",
      "Rohg", "Sogo", "Sogd", "Elym", "Chrs", "Yezi", "Ougr", "Gara", "Sidt":
    (true, dirRightToLeft)
  of "Hung", "Ital", "Runr", "Tfng":
    (false, dirInvalid)
  else:
    (true, dirLeftToRight)

proc isHorizontal*(d: Direction): bool =
  d == dirLeftToRight or d == dirRightToLeft

proc isVertical*(d: Direction): bool =
  not d.isHorizontal() and d != dirInvalid

proc isForward*(d: Direction): bool =
  case d
  of dirLeftToRight, dirTopToBottom: true
  else: false

proc isBackward*(d: Direction): bool =
  not d.isForward()

proc reverse*(d: Direction): Direction =
  case d
  of dirLeftToRight: dirRightToLeft
  of dirRightToLeft: dirLeftToRight
  of dirTopToBottom: dirBottomToTop
  of dirBottomToTop: dirTopToBottom
  of dirInvalid: dirInvalid

proc parseDirection*(s: string): Direction =
  if s.len == 0:
    raise newException(ValueError, "invalid direction")
  case s[0].toLowerAscii()
  of 'l': dirLeftToRight
  of 'r': dirRightToLeft
  of 't': dirTopToBottom
  of 'b': dirBottomToTop
  else: raise newException(ValueError, "invalid direction")
