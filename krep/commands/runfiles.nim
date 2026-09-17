## Re-export runfile commands, preserving their integer exit codes.
import ./[lintcmd, fmtcmd, convertcmd]
export lintcmd.lint, fmtcmd.fmt, convertcmd.convert
