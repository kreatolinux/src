import sqlite
import config

proc crossCompilerExists*(target: string): bool =
    # Checks if a target is already available.
    return packageExists(target&"-"&getConfigValue("Options", "cc", "cc"))
