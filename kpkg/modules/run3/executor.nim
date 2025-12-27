## Executor/Interpreter for run3 format
## Executes the parsed AST

import sequtils
import strutils
import tables
import ast
import builtins
import macros as run3macros
import variables

const
    # Special exit codes for control flow
    exitContinue* = -100 # Continue to next iteration
    exitBreak* = -101    # Break out of loop

type
    ExecutionError* = object of CatchableError
        ## Runtime execution error
        line*: int

proc newExecutionError(msg: string, line: int): ref ExecutionError =
    result = newException(ExecutionError, msg)
    result.line = line

proc executeFunction*(ctx: ExecutionContext, funcBody: seq[AstNode]): int

proc executeNode*(ctx: ExecutionContext, node: AstNode): int =
    ## Execute a single AST node
    ## Returns exit code (0 = success, negative = control flow)

    case node.kind
    of nkExec:
        return ctx.builtinExec(node.execCmd)

    of nkMacro:
        return executeMacro(ctx, node.macroName, node.macroArgs)

    of nkPrint:
        ctx.builtinPrint(node.printText)
        return 0

    of nkCd:
        if ctx.builtinCd(node.cdPath):
            return 0
        else:
            return 1

    of nkEnv:
        ctx.builtinEnv(node.envVar, node.envValue)
        return 0

    of nkLocal:
        ctx.builtinLocal(node.localVar, node.localValue)
        return 0

    of nkGlobal:
        ctx.builtinGlobal(node.globalVar, node.globalValue)
        return 0

    of nkWrite:
        ctx.builtinWrite(node.writePath, node.writeContent)
        return 0

    of nkAppend:
        ctx.builtinAppend(node.appendPath, node.appendContent)
        return 0

    of nkContinue:
        return exitContinue

    of nkBreak:
        return exitBreak

    of nkIf:
        if ctx.evaluateCondition(node.condition):
            for stmt in node.thenBranch:
                let exitCode = ctx.executeNode(stmt)
                if exitCode != 0:
                    return exitCode
        else:
            for stmt in node.elseBranch:
                let exitCode = ctx.executeNode(stmt)
                if exitCode != 0:
                    return exitCode
        return 0

    of nkFor:
        # Check if we have an inline list literal
        var items: seq[string] = @[]

        if node.iterListLiteral.len > 0:
            # Use inline list literal directly
            items = node.iterListLiteral
        elif node.iterList.startsWith("$") or node.iterList.startsWith("\""):
            # Variable expression - resolve it first
            let resolved = ctx.resolveVariables(node.iterList).strip()
            # Remove surrounding quotes if present
            var cleanResolved = resolved
            if cleanResolved.startsWith("\"") and cleanResolved.endsWith("\""):
                cleanResolved = cleanResolved[1..^2]
            elif cleanResolved.startsWith("'") and cleanResolved.endsWith("'"):
                cleanResolved = cleanResolved[1..^2]
            # Split by newlines or spaces
            if '\n' in cleanResolved:
                items = cleanResolved.splitLines()
            else:
                items = cleanResolved.split(' ')
            # Filter out empty items
            items = items.filterIt(it.strip().len > 0)
        else:
            # Get the list from a variable by name
            items = ctx.getListVariable(node.iterList)
            if items.len == 0:
                # Try to get as a regular variable and split it
                let varValue = ctx.getVariable(node.iterList)
                if varValue != "":
                    if '\n' in varValue:
                        items = varValue.splitLines()
                    else:
                        items = varValue.split(' ')
                    items = items.filterIt(it.strip().len > 0)

        # Iterate over items
        for item in items:
            ctx.builtinLocal(node.iterVar, item)
            var shouldBreak = false
            for stmt in node.forBody:
                let exitCode = ctx.executeNode(stmt)
                if exitCode == exitContinue:
                    break # Break inner loop, continue outer
                elif exitCode == exitBreak:
                    shouldBreak = true
                    break
                elif exitCode != 0:
                    return exitCode
            if shouldBreak:
                break
        return 0

    of nkFuncCall:
        # Execute custom function call
        if ctx.customFuncs.hasKey(node.callName):
            # Resolve arguments in current scope
            var resolvedArgs: seq[string] = @[]
            for arg in node.callArgs:
                resolvedArgs.add(stripQuotes(ctx.resolveVariables(arg)))

            # Save current locals
            let parentLocals = ctx.localVars

            # Create new scope
            ctx.localVars = initTable[string, string]()

            # Set arguments
            ctx.localVars["0"] = node.callName
            for i, arg in resolvedArgs:
                ctx.localVars[$(i + 1)] = arg

            # Execute function body
            let funcBody = ctx.customFuncs[node.callName]
            let res = ctx.executeFunction(funcBody)

            # Restore locals
            ctx.localVars = parentLocals

            return res
        else:
            echo "Warning: Unknown function: " & node.callName
            return 0

    of nkComment:
        # Comments do nothing
        return 0

    of nkBlock:
        for stmt in node.blockBody:
            let exitCode = ctx.executeNode(stmt)
            if exitCode != 0:
                return exitCode
        return 0

    of nkVarManip, nkVarRef:
        # These should be resolved during variable substitution
        return 0

    else:
        echo "Warning: Unhandled node kind: " & $node.kind
        return 0

proc executeFunction*(ctx: ExecutionContext, funcBody: seq[AstNode]): int =
    ## Execute a function body (sequence of statements)
    result = 0
    for node in funcBody:
        result = ctx.executeNode(node)
        if result != 0:
            break

    # Clear local variables when exiting function
    ctx.clearLocalVars()

proc loadVariablesFromParsed*(ctx: ExecutionContext, parsed: ParsedRunfile) =
    ## Load variables from parsed runfile into execution context
    for varNode in parsed.variables:
        case varNode.kind
        of nkVariable:
            case varNode.varOp
            of opSet:
                ctx.setVariable(varNode.varName, varNode.varValue)
            of opAppend:
                if ctx.hasListVariable(varNode.varName):
                    # If it's a list variable, add to list
                    let current = ctx.getListVariable(varNode.varName)
                    ctx.setListVariable(varNode.varName, current & @[
                            varNode.varValue])
                else:
                    # Treat as string concatenation with space
                    let current = ctx.getVariable(varNode.varName)
                    if current == "":
                        ctx.setVariable(varNode.varName, varNode.varValue)
                    else:
                        ctx.setVariable(varNode.varName, current & " " &
                                varNode.varValue)
            of opRemove:
                # String remove?
                let current = ctx.getVariable(varNode.varName)
                ctx.setVariable(varNode.varName, current.replace(
                        varNode.varValue, "").strip())

        of nkListVariable:
            case varNode.listOp
            of opSet:
                ctx.setListVariable(varNode.listName, varNode.listItems)
            of opAppend:
                let current = ctx.getListVariable(varNode.listName)
                ctx.setListVariable(varNode.listName, current &
                        varNode.listItems)
            of opRemove:
                var current = ctx.getListVariable(varNode.listName)
                for itemToRemove in varNode.listItems:
                    current.keepItIf(it != itemToRemove)
                ctx.setListVariable(varNode.listName, current)

        else:
            discard

proc loadCustomFunctions*(ctx: ExecutionContext, parsed: ParsedRunfile) =
    ## Load custom functions from parsed runfile
    for funcNode in parsed.customFuncs:
        if funcNode.kind == nkCustomFunc:
            # Store function name and body nodes
            ctx.customFuncs[funcNode.customFuncName] = funcNode.customFuncBody

proc getFunctionByName*(parsed: ParsedRunfile, name: string): seq[AstNode] =
    ## Get a function's body by name (searches both regular and custom functions)
    # First check regular functions
    for funcNode in parsed.functions:
        if funcNode.kind == nkFunction and funcNode.funcName == name:
            return funcNode.funcBody
    # Then check custom functions
    for funcNode in parsed.customFuncs:
        if funcNode.kind == nkCustomFunc and funcNode.customFuncName == name:
            return funcNode.customFuncBody
    return @[]

proc executeRun3Function*(ctx: ExecutionContext, parsed: ParsedRunfile,
        functionName: string): int =
    ## Execute a specific function from a parsed run3 file
    let funcBody = getFunctionByName(parsed, functionName)
    if funcBody.len == 0:
        echo "Warning: Function '" & functionName & "' not found"
        return 0

    return ctx.executeFunction(funcBody)

proc resolveVarManipulation*(ctx: ExecutionContext, node: AstNode): string =
    ## Resolve a variable manipulation expression to its final value
    if node.kind != nkVarManip:
        return ""

    # Get base variable value
    var baseValue: VarValue
    if ctx.hasListVariable(node.baseVar):
        baseValue = newListValue(ctx.getListVariable(node.baseVar))
    else:
        baseValue = newStringValue(ctx.getVariable(node.baseVar))

    # Apply methods (node.methods is already seq[VarManipMethod])
    let methods = node.methods

    try:
        let res = evaluateVarManipulation(baseValue, methods, node.indexExpr)
        return res.toString()
    except ValueError as e:
        echo "Error in variable manipulation: " & e.msg
        return ""

proc initFromRunfile*(parsed: ParsedRunfile, destDir: string = "",
        srcDir: string = "", buildRoot: string = ""): ExecutionContext =
    ## Initialize execution context from a parsed runfile
    result = initExecutionContext(destDir, srcDir, buildRoot, "")
    result.loadVariablesFromParsed(parsed)
    result.loadCustomFunctions(parsed)

    # Set package name if available
    if result.variables.hasKey("name"):
        result.packageName = result.variables["name"]
