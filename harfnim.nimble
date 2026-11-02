# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "Pure Nim port of the HarfBuzz text shaping engine (harfrust reference)"
license       = "MIT"
srcDir        = "src"
bin           = @["hr_shape", "conformance"]


# Dependencies

requires "nim >= 2.4.0"
