## Variable manipulation methods for Kongue format
## Implements string and list manipulation methods used in ${variable.method()} syntax

import strutils
import ast

type
    VarValue* = object
        ## Represents a variable value that can be either a string or a list
        case isList*: bool
        of true:
            listVal*: seq[string]
        of false:
            strVal*: string

proc newStringValue*(s: string): VarValue =
    ## Create a new string value
    VarValue(isList: false, strVal: s)

proc newListValue*(items: seq[string]): VarValue =
    ## Create a new list value
    VarValue(isList: true, listVal: items)

proc toString*(v: VarValue): string =
    ## Convert value to string representation
    if v.isList:
        return v.listVal.join(" ")
    else:
        return v.strVal

proc toList*(v: VarValue): seq[string] =
    ## Convert value to list representation
    if v.isList:
        return v.listVal
    else:
        return @[v.strVal]

proc applyMethod*(value: VarValue, methodName: string, args: seq[
        string]): VarValue =
    ## Apply a manipulation method to a value
    case methodName
    of "split":
        # split(delimiter) - Split string into list
        if not value.isList:
            if args.len == 0:
                raise newException(ValueError, "split() requires 1 argument: delimiter")
            let delimiter = args[0]
            return newListValue(value.strVal.split(delimiter))
        else:
            raise newException(ValueError, "split() can only be called on strings")

    of "join":
        # join(delimiter) - Join list into string
        if value.isList:
            if args.len == 0:
                raise newException(ValueError, "join() requires 1 argument: delimiter")
            let delimiter = args[0]
            return newStringValue(value.listVal.join(delimiter))
        else:
            raise newException(ValueError, "join() can only be called on lists")

    of "cut":
        # cut(start, end) - Substring from start to end (not including end)
        if not value.isList:
            if args.len != 2:
                raise newException(ValueError, "cut() requires 2 arguments: start, end")
            try:
                let startIdx = parseInt(args[0])
                let endIdx = parseInt(args[1])
                let str = value.strVal
                if startIdx < 0 or endIdx > str.len or startIdx > endIdx:
                    raise newException(ValueError, "cut() indices out of range")
                return newStringValue(str[startIdx..<endIdx])
            except ValueError:
                raise newException(ValueError, "cut() arguments must be integers")
        else:
            raise newException(ValueError, "cut() can only be called on strings")

    of "replace":
        # replace(old, new) - Replace all occurrences of old with new
        if not value.isList:
            if args.len != 2:
                raise newException(ValueError, "replace() requires 2 arguments: old, new")
            let oldStr = args[0]
            let newStr = args[1]
            return newStringValue(value.strVal.replace(oldStr, newStr))
        else:
            raise newException(ValueError, "replace() can only be called on strings")

    of "strip":
        # strip() - Remove leading and trailing whitespace
        if not value.isList:
            return newStringValue(value.strVal.strip())
        else:
            raise newException(ValueError, "strip() can only be called on strings")

    of "upper":
        # upper() - Convert to uppercase
        if not value.isList:
            return newStringValue(value.strVal.toUpperAscii())
        else:
            raise newException(ValueError, "upper() can only be called on strings")

    of "lower":
        # lower() - Convert to lowercase
        if not value.isList:
            return newStringValue(value.strVal.toLowerAscii())
        else:
            raise newException(ValueError, "lower() can only be called on strings")

    else:
        raise newException(ValueError, "Unknown method: " & methodName)

proc applyIndex*(value: VarValue, indexExpr: string): VarValue =
    ## Apply indexing or slicing to a value
    ## Supports: [index] or [start:end]
    if not value.isList:
        raise newException(ValueError, "Indexing can only be applied to lists")

    if ':' in indexExpr:
        # Slice: [start:end]
        let parts = indexExpr.split(':')
        if parts.len != 2:
            raise newException(ValueError, "Invalid slice syntax: " & indexExpr)

        try:
            let startIdx = if parts[0].strip() == "": 0 else: parseInt(parts[
                    0].strip())
            let endIdx = if parts[1].strip() ==
                    "": value.listVal.len else: parseInt(parts[1].strip())

            if startIdx < 0 or endIdx > value.listVal.len or startIdx > endIdx:
                raise newException(ValueError, "Slice indices out of range")

            return newListValue(value.listVal[startIdx..<endIdx])
        except ValueError:
            raise newException(ValueError, "Slice indices must be integers")
    else:
        # Single index: [index]
        try:
            let idx = parseInt(indexExpr.strip())
            if idx < 0 or idx >= value.listVal.len:
                raise newException(ValueError, "Index out of range: " & $idx)
            return newStringValue(value.listVal[idx])
        except ValueError:
            raise newException(ValueError, "Index must be an integer")

proc evaluateVarManipulation*(baseValue: VarValue, methods: seq[VarManipMethod],
        indexExpr: string = ""): VarValue =
    ## Apply a chain of methods and optional indexing to a base value
    ## Example: ${version.split('.')[0:2].join('.')}
    result = baseValue

    # First apply indexing if present and no methods
    if methods.len == 0 and indexExpr != "":
        return applyIndex(result, indexExpr)

    # Apply each method in sequence
    for i, m in methods:
        result = applyMethod(result, m.name, m.args)
        # If this is the last method and we have an index, apply it
        if i == methods.len - 1 and indexExpr != "":
            result = applyIndex(result, indexExpr)

    return result

# Helper functions for common operations
proc splitVar*(value: string, delimiter: string): seq[string] =
    ## Helper to split a string variable
    value.split(delimiter)

proc joinVar*(values: seq[string], delimiter: string): string =
    ## Helper to join a list variable
    values.join(delimiter)

proc cutVar*(value: string, start, endPos: int): string =
    ## Helper to cut a substring
    if start < 0 or endPos > value.len or start > endPos:
        raise newException(ValueError, "cut indices out of range")
    value[start..<endPos]

proc replaceVar*(value: string, oldStr, newStr: string): string =
    ## Helper to replace in a string
    value.replace(oldStr, newStr)
