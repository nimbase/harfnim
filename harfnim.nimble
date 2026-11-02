# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "Pure Nim port of the HarfBuzz text shaping engine (harfrust reference)"
license       = "MIT"
srcDir        = "src"
bin           = @["../tools/hr_shape", "../tools/conformance"]


# Dependencies

requires "nim >= 2.4.0"
