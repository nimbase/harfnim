import unittest

import harfnim

test "tag roundtrip":
  check tagFromStr("latn").toStr() == "latn"
  check tagFromStr("ab").toStr() == "ab  "
  check tagFromStr("abcd").toUpper().toStr() == "ABCD"
  check tagFromStr("ABCD").toLower().toStr() == "abcd"

test "direction basics":
  check dirLeftToRight.isHorizontal()
  check dirRightToLeft.isHorizontal()
  check (not dirTopToBottom.isHorizontal())
  check dirLeftToRight.isForward()
  check (not dirRightToLeft.isForward())
  check dirLeftToRight.reverse() == dirRightToLeft
  check parseDirection("ltr") == dirLeftToRight
  check parseDirection("rtl") == dirRightToLeft

test "direction for script":
  check directionForScript(Arabic) == (true, dirRightToLeft)
  check directionForScript(Latin) == (true, dirLeftToRight)

test "script iso15924":
  check parseScript("Latn") == Latin
  check parseScript("Arab") == Arabic
  let (ok, sc) = fromIso15924Tag(tagFromStr("Latf"))
  check ok and sc == Latin

test "language normalizes":
  let (ok, lang) = newLanguage("EN_US")
  check ok and lang.asStr() == "en-us"
  let (emptyOk, _) = newLanguage("")
  check (not emptyOk)

test "feature parsing":
  check parseFeature("kern") == globalFeature(tagFromStr("kern"), 1)
  check parseFeature("+kern") == globalFeature(tagFromStr("kern"), 1)
  check parseFeature("-kern") == globalFeature(tagFromStr("kern"), 0)
  check parseFeature("kern=0") == globalFeature(tagFromStr("kern"), 0)
  check parseFeature("kern[3:5]=2") ==
    newFeature(tagFromStr("kern"), 2, 3, 5)
  check parseFeature("kern=on") == globalFeature(tagFromStr("kern"), 1)
  check parseFeature("kern=off") == globalFeature(tagFromStr("kern"), 0)
