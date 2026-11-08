import ./tag
import ./script
import ./direction

type
  ShapeErrorKind* = enum
    ## Classifies shaping failures.
    seAlreadyShaped
    ## Buffer already holds shaped glyphs.
    seDirectionUnset
    ## Buffer has no direction set.
    seDirectionMismatch
    ## Buffer direction does not match the plan direction.
    seScriptMismatch
    ## Buffer script does not match the plan script.

  ShapeError* = object of CatchableError
    ## Shaping failure carrying plan and buffer context.
    kind*: ShapeErrorKind
    ## Which shaping check failed.
    planDirection*: Direction
    ## Plan direction for mismatch errors.
    bufferDirection*: Direction
    ## Buffer direction for mismatch errors.
    planScript*: Script
    ## Plan script for mismatch errors.
    bufferScript*: Script
    ## Buffer script for mismatch errors.

proc alreadyShapedError*(): ref ShapeError =
  ## Builds the already shaped error.
  (ref ShapeError)(msg: "buffer already holds shaped glyphs", kind: seAlreadyShaped)

proc directionUnsetError*(): ref ShapeError =
  ## Builds the direction unset error.
  (ref ShapeError)(msg: "buffer has no direction set", kind: seDirectionUnset)

proc directionMismatchError*(plan, buffer: Direction): ref ShapeError =
  ## Builds a direction mismatch error from plan and buffer directions.
  (ref ShapeError)(
    msg: "buffer direction does not match plan direction",
    kind: seDirectionMismatch,
    planDirection: plan,
    bufferDirection: buffer,
  )

proc scriptMismatchError*(plan, buffer: Script): ref ShapeError =
  ## Builds a script mismatch error from plan and buffer scripts.
  (ref ShapeError)(
    msg: "buffer script does not match plan script",
    kind: seScriptMismatch,
    planScript: plan,
    bufferScript: buffer,
  )
