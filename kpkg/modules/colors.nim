const resetColor* = "\e[0m"
const cyanColor* = "\e[0;36m"
const blueColor* = "\e[0;34m"

proc colorize*(text: string, color: string, enabled = true): string =
  ## Wrap text in color codes if enabled.
  if enabled:
    return color & text & resetColor
  else:
    return text

proc cyan*(text: string, enabled = true): string =
  ## Shorthand for cyan coloring.
  colorize(text, cyanColor, enabled)

proc blue*(text: string, enabled = true): string =
  ## Shorthand for blue coloring.
  colorize(text, blueColor, enabled)
