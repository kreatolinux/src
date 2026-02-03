## AST (Abstract Syntax Tree) node definitions for Kongue format
## This module defines the structure of parsed Kongue scripts

type
  NodeKind* = enum
    ## Types of nodes in the AST
    nkVariable,     # name: "value"
    nkListVariable, # depends:\n  - "item"
    nkFunction,     # build { ... }
    nkCustomFunc,   # func name { ... }
    nkExec,         # exec command
    nkMacro,        # macro name --flag
    nkPrint,        # print "text"
    nkCd,           # cd path
    nkEnv,          # env VAR=value
    nkLocal,        # local var="value"
    nkGlobal,       # global var="value"
    nkWrite,        # write path "content"
    nkAppend,       # append path "content"
    nkIf,           # if condition { } else { }
    nkFor,          # for i in list { }
    nkVarRef,       # $variable or ${variable}
    nkVarManip,     # ${variable.method(args)}
    nkBlock,        # { statements }
    nkComment,      # # comment
    nkFuncCall,     # custom_function arg1 arg2
    nkContinue,     # continue (skip to next iteration in for loop)
    nkBreak         # break (exit for loop)

  VarManipMethod* = object
    ## A single method call in a variable manipulation chain
    name*: string
    args*: seq[string]

  VarOp* = enum
    ## Variable operation types
    opSet,    # = or :
    opAppend, # +:
    opRemove  # -:

  AstNode* = ref object
    ## Main AST node type
    line*: int                      # Line number for error reporting
    case kind*: NodeKind
    of nkVariable:
      varName*: string
      varValue*: string
      varOp*: VarOp
    of nkListVariable:
      listName*: string
      listItems*: seq[string]
      listOp*: VarOp
    of nkFunction:
      funcName*: string
      funcBody*: seq[AstNode]
    of nkCustomFunc:
      customFuncName*: string
      customFuncBody*: seq[AstNode]
    of nkExec:
      execCmd*: string
    of nkMacro:
      macroName*: string
      macroArgs*: seq[string]
    of nkPrint:
      printText*: string
    of nkCd:
      cdPath*: string
    of nkEnv:
      envVar*: string
      envValue*: string
    of nkLocal:
      localVar*: string
      localValue*: string
    of nkGlobal:
      globalVar*: string
      globalValue*: string
    of nkWrite:
      writePath*: string
      writeContent*: string
    of nkAppend:
      appendPath*: string
      appendContent*: string
    of nkIf:
      condition*: string
      thenBranch*: seq[AstNode]
      elseBranch*: seq[AstNode]
    of nkFor:
      iterVar*: string
      iterList*: string             # Variable name to iterate over
      iterListLiteral*: seq[string] # Inline list literal (e.g., ["a", "b", "c"])
      forBody*: seq[AstNode]
    of nkVarRef:
      refName*: string
    of nkVarManip:
      baseVar*: string
      methods*: seq[VarManipMethod]
      indexExpr*: string            # For [index] or [start:end]
    of nkBlock:
      blockBody*: seq[AstNode]
    of nkComment:
      commentText*: string
    of nkFuncCall:
      callName*: string
      callArgs*: seq[string]
    of nkContinue:
      discard                       # No additional fields needed
    of nkBreak:
      discard                       # No additional fields needed

  ParsedScript* = object
    ## Represents a complete parsed Kongue script
    variables*: seq[AstNode]   # Variable declarations (header)
    functions*: seq[AstNode]   # Function definitions
    customFuncs*: seq[AstNode] # Custom function definitions

proc newVariableNode*(name, value: string, op: VarOp = opSet,
        line: int = 0): AstNode =
  ## Create a new variable node
  AstNode(kind: nkVariable, varName: name, varValue: value, varOp: op, line: line)

proc newListVariableNode*(name: string, items: seq[string], op: VarOp = opSet,
        line: int = 0): AstNode =
  ## Create a new list variable node
  AstNode(kind: nkListVariable, listName: name, listItems: items, listOp: op, line: line)

proc newFunctionNode*(name: string, body: seq[AstNode],
        line: int = 0): AstNode =
  ## Create a new function node
  AstNode(kind: nkFunction, funcName: name, funcBody: body, line: line)

proc newCustomFuncNode*(name: string, body: seq[AstNode],
        line: int = 0): AstNode =
  ## Create a new custom function node
  AstNode(kind: nkCustomFunc, customFuncName: name, customFuncBody: body, line: line)

proc newExecNode*(cmd: string, line: int = 0): AstNode =
  ## Create a new exec command node
  AstNode(kind: nkExec, execCmd: cmd, line: line)

proc newMacroNode*(name: string, args: seq[string], line: int = 0): AstNode =
  ## Create a new macro command node
  AstNode(kind: nkMacro, macroName: name, macroArgs: args, line: line)

proc newPrintNode*(text: string, line: int = 0): AstNode =
  ## Create a new print command node
  AstNode(kind: nkPrint, printText: text, line: line)

proc newCdNode*(path: string, line: int = 0): AstNode =
  ## Create a new cd command node
  AstNode(kind: nkCd, cdPath: path, line: line)

proc newEnvNode*(varName, value: string, line: int = 0): AstNode =
  ## Create a new env command node
  AstNode(kind: nkEnv, envVar: varName, envValue: value, line: line)

proc newLocalNode*(varName, value: string, line: int = 0): AstNode =
  ## Create a new local command node
  AstNode(kind: nkLocal, localVar: varName, localValue: value, line: line)

proc newGlobalNode*(varName, value: string, line: int = 0): AstNode =
  ## Create a new global command node
  AstNode(kind: nkGlobal, globalVar: varName, globalValue: value, line: line)

proc newWriteNode*(path, content: string, line: int = 0): AstNode =
  ## Create a new write command node
  AstNode(kind: nkWrite, writePath: path, writeContent: content, line: line)

proc newAppendNode*(path, content: string, line: int = 0): AstNode =
  ## Create a new append command node
  AstNode(kind: nkAppend, appendPath: path, appendContent: content, line: line)

proc newIfNode*(cond: string, thenBr, elseBr: seq[AstNode],
        line: int = 0): AstNode =
  ## Create a new if node
  AstNode(kind: nkIf, condition: cond, thenBranch: thenBr, elseBranch: elseBr, line: line)

proc newForNode*(iter, list: string, body: seq[AstNode],
        line: int = 0, listLiteral: seq[string] = @[]): AstNode =
  ## Create a new for loop node
  ## If listLiteral is non-empty, it's an inline list literal; otherwise iterList is a variable name
  AstNode(kind: nkFor, iterVar: iter, iterList: list,
      iterListLiteral: listLiteral, forBody: body, line: line)

proc newVarRefNode*(name: string, line: int = 0): AstNode =
  ## Create a new variable reference node
  AstNode(kind: nkVarRef, refName: name, line: line)

proc newVarManipNode*(base: string, methods: seq[VarManipMethod],
        index: string = "", line: int = 0): AstNode =
  ## Create a new variable manipulation node
  AstNode(kind: nkVarManip, baseVar: base, methods: methods, indexExpr: index, line: line)

proc newBlockNode*(body: seq[AstNode], line: int = 0): AstNode =
  ## Create a new block node
  AstNode(kind: nkBlock, blockBody: body, line: line)

proc newCommentNode*(text: string, line: int = 0): AstNode =
  ## Create a new comment node
  AstNode(kind: nkComment, commentText: text, line: line)

proc newFuncCallNode*(name: string, args: seq[string], line: int = 0): AstNode =
  ## Create a new function call node
  AstNode(kind: nkFuncCall, callName: name, callArgs: args, line: line)

proc newContinueNode*(line: int = 0): AstNode =
  ## Create a new continue node
  AstNode(kind: nkContinue, line: line)

proc newBreakNode*(line: int = 0): AstNode =
  ## Create a new break node
  AstNode(kind: nkBreak, line: line)

proc hasFunction*(parsed: ParsedScript, name: string): bool =
  ## Check if a function exists in the parsed script (searches both regular and custom functions)
  for funcNode in parsed.functions:
    if funcNode.kind == nkFunction and funcNode.funcName == name:
      return true
  for funcNode in parsed.customFuncs:
    if funcNode.kind == nkCustomFunc and funcNode.customFuncName == name:
      return true
  return false
