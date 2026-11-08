import std/strutils
import ./tag
import ./script

type
  Direction* = enum
    ## Text flow direction.
    dirInvalid = 0
    ## Unset direction.
    dirLeftToRight = 1
    ## Left to right.
    dirRightToLeft = 2
    ## Right to left.
    dirTopToBottom = 3
    ## Top to bottom.
    dirBottomToTop = 4
    ## Bottom to top.

proc directionForScript*(s: Script): tuple[ok: bool, dir: Direction] =
  ## Looks up the default direction for a script.
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
  ## True for left to right and right to left.
  d == dirLeftToRight or d == dirRightToLeft

proc isVertical*(d: Direction): bool =
  ## True for top to bottom and bottom to top.
  not d.isHorizontal() and d != dirInvalid

proc isForward*(d: Direction): bool =
  ## True for left to right and top to bottom.
  case d
  of dirLeftToRight, dirTopToBottom: true
  else: false

proc isBackward*(d: Direction): bool =
  ## True for right to left and bottom to top.
  not d.isForward()

proc reverse*(d: Direction): Direction =
  ## Returns the opposite direction.
  case d
  of dirLeftToRight: dirRightToLeft
  of dirRightToLeft: dirLeftToRight
  of dirTopToBottom: dirBottomToTop
  of dirBottomToTop: dirTopToBottom
  of dirInvalid: dirInvalid

proc parseDirection*(s: string): Direction =
  ## Parses ltr, rtl, ttb, and btt prefixes; raises ValueError otherwise.
  if s.len == 0:
    raise newException(ValueError, "invalid direction")
  case s[0].toLowerAscii()
  of 'l': dirLeftToRight
  of 'r': dirRightToLeft
  of 't': dirTopToBottom
  of 'b': dirBottomToTop
  else: raise newException(ValueError, "invalid direction")
