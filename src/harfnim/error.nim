import ./tag
import ./script
import ./direction

type
  ShapeErrorKind* = enum
    seAlreadyShaped
    seDirectionUnset
    seDirectionMismatch
    seScriptMismatch

  ShapeError* = object of CatchableError
    kind*: ShapeErrorKind
    planDirection*: Direction
    bufferDirection*: Direction
    planScript*: Script
    bufferScript*: Script

proc alreadyShapedError*(): ref ShapeError =
  (ref ShapeError)(msg: "buffer already holds shaped glyphs", kind: seAlreadyShaped)

proc directionUnsetError*(): ref ShapeError =
  (ref ShapeError)(msg: "buffer has no direction set", kind: seDirectionUnset)

proc directionMismatchError*(plan, buffer: Direction): ref ShapeError =
  (ref ShapeError)(
    msg: "buffer direction does not match plan direction",
    kind: seDirectionMismatch,
    planDirection: plan,
    bufferDirection: buffer,
  )

proc scriptMismatchError*(plan, buffer: Script): ref ShapeError =
  (ref ShapeError)(
    msg: "buffer script does not match plan script",
    kind: seScriptMismatch,
    planScript: plan,
    bufferScript: buffer,
  )
