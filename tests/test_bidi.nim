import unittest

import harfnim

test "ltr paragraph stays one run":
  let v = visualRuns("hello", bdAuto)
  check v.text == "hello"
  check v.map == @[0, 1, 2, 3, 4, 5]
  check v.runs.len == 1
  check v.runs[0].first == 0
  check v.runs[0].last == 5
  check v.runs[0].level == 0
  check v.runs[0].dir == dirLeftToRight

test "rtl paragraph reverses":
  let v = visualRuns("אבג", bdAuto)
  check v.text == "גבא"
  check v.map == @[4, 5, 2, 3, 0, 1, 6]
  check v.runs.len == 1
  check v.runs[0].level == 1
  check v.runs[0].dir == dirRightToLeft

test "mixed paragraph splits runs":
  let v = visualRuns("a ב c", bdAuto)
  check v.text == "a ב c"
  check v.runs.len == 3
  check v.runs[0].level == 0
  check v.runs[1].level == 1
  check v.runs[2].level == 0
  check v.runs[1].dir == dirRightToLeft

test "european numbers rise in ltr":
  let v = visualRuns("12 b", bdAuto)
  check v.text == "12 b"
  check v.runs.len == 2
  check v.runs[0].level == 2
  check v.runs[1].level == 0

test "numbers after letters stay with them":
  let v = visualRuns("a 12 b", bdAuto)
  check v.text == "a 12 b"
  check v.runs.len == 1
  check v.runs[0].level == 0

test "numbers attach in rtl paragraph":
  let v = visualRuns("א 12", bdAuto)
  check v.text == "12 א"
  check v.runs.len == 2
  check v.runs[0].level == 2
  check v.runs[1].level == 1

test "explicit embedding with x9 removal and map":
  let v = visualRuns("a\u202Bב\u202Cc", bdAuto)
  check v.text == "aבc"
  check v.map == @[0, 4, 5, 9, 10]
  check v.runs.len == 3
  check v.runs[0].level == 0
  check v.runs[1].level == 1
  check v.runs[2].level == 0

test "isolate stays neutral outside":
  let v = visualRuns("a\u2067ב\u2069c", bdAuto)
  check v.text == "a\u2067ב\u2069c"
  check v.runs.len == 3
  check v.runs[0].level == 0
  check v.runs[1].level == 1
  check v.runs[2].level == 0

test "brackets follow embedding in ltr":
  let v = visualRuns("a (ב)", bdAuto)
  check v.text == "a (ב)"
  check v.runs.len == 3
  check v.runs[0].level == 0
  check v.runs[1].level == 1
  check v.runs[2].level == 0
  check v.runs[0].last == 3
  check v.runs[1].first == 3
  check v.runs[1].last == 5
  check v.runs[2].first == 5

test "brackets mirror in rtl":
  let v = visualRuns("(ב)", bdRtl)
  check v.text == "(ב)"
  check v.map == @[3, 1, 2, 0, 4]
  check v.runs.len == 1
  check v.runs[0].level == 1
  check v.runs[0].dir == dirRightToLeft

test "mark stays with its base across levels":
  let v = visualRuns("xב\u05B0", bdAuto)
  check v.text == "x\u05B0ב"
  check v.runs.len == 2
  check v.runs[0].level == 0
  check v.runs[0].first == 0
  check v.runs[0].last == 1
  check v.runs[1].level == 1
  check v.runs[1].first == 1
  check v.runs[1].last == 5

test "leading mark joins following run":
  let v = visualRuns("\u05B0xב", bdAuto)
  check v.runs.len == 2
  check v.runs[0].first == 0
  check v.runs[0].last == 3
  check v.runs[0].level == 0

test "depth overflow caps at max depth":
  var s = ""
  for _ in 0 ..< 130:
    s.add("\u202B")
  s.add("a")
  let v = visualRuns(s, bdAuto)
  check v.text == "a"
  check v.runs.len == 1
  check v.runs[0].level == 126

test "auto detection skips isolates":
  let v = visualRuns("\u2066a\u2069ב", bdAuto)
  check v.text == "ב\u2069a\u2066"
  check v.runs.len == 3
  check v.runs[0].level == 1
  check v.runs[1].level == 2
  check v.runs[2].level == 1

test "empty paragraph":
  let v = visualRuns("", bdAuto)
  check v.text == ""
  check v.runs.len == 0
  check v.map == @[0]

test "rtl base with latin text":
  let v = visualRuns("abc", bdRtl)
  check v.text == "abc"
  check v.runs.len == 1
  check v.runs[0].level == 2
  check v.runs[0].dir == dirLeftToRight
