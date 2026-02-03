## Kongue - A simple scripting language for automation
##
## Kongue is a domain-specific language designed for build automation and
## scripting tasks. It provides:
## - Variable declarations and manipulation
## - Function definitions
## - Control flow (if/else, for loops)
## - Built-in commands (exec, print, cd, env, local, global, write, append)
## - Extensible through hooks (execHook, macroHook)
##
## Basic usage:
##   import kongue
##
##   let content = readFile("script.kongue")
##   let tokens = tokenize(content)
##   var parser = initParser(tokens)
##   let parsed = parser.parse()
##
##   var ctx = initExecutionContext()
##   ctx.loadVariablesFromParsed(parsed)
##   ctx.loadAllFunctions(parsed)
##   discard ctx.executeFunctionByName(parsed, "build")
##
## For custom execution (e.g., sandboxed execution), set the execHook:
##   ctx.execHook = proc(ctx: ExecutionContext, cmd: string, silent: bool): tuple[output: string, exitCode: int] =
##     # Custom execution logic
##     ...

# Core modules
import ast
import lexer
import parser
import variables
import utils
import context
import builtins
import executor

# Re-export all public symbols
export ast
export lexer
export parser
export variables
export utils
export context
export builtins
export executor
