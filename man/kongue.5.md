% kongue(5)

# NAME
Kongue - Scripting langauge of Kreato Linux

# DESCRIPTION
Kongue is the main scripting language made for use in Kreato Linux projects. It is inspired by YAML and sh among many other languages. It is currently used by kpkg as the main package format (see kpkg_run(5) for specific details).

# KONGUE STRUCTURE
Kongue scripts don't have a global file extension, though `.kg` or `.kongue` might be used.

## Example Kongue script

```bash
global_var_string: "test"
global_var_bool: true
global_var_array:
    - "hello"
    - "test"
    - "test2"

func custom_func {
    print "This is a test custom function, hello $1"
}

# Different projects will have different main functions, such as build for kpkg_run(5). This is just an example.
main { 
    custom_func "Kreato" # Can run custom functions just like commands
    print "Test"
    exec "command -v bash"
}
```

# SYNTAX AND LANGUAGE FEATURES

## VARIABLES
Variables must be declared at the top of the script. They can be any type (list, string, int, bool, etc.). Variables can be referenced in if statements, for loops, and inside functions. On commands, simple referencing is done via `$variable` or `${variable}`. Complex manipulation (splitting, slicing) works via `${variable.method()}` (or `variable.method()` on a non-command context) (see **VARIABLE MANIPULATION** below).

```yaml
test1: true
test2:
    - this is a test
    - test2
# and so on...
```

Variables can be referenced in if statements, for loops, inside variables, and inside functions (including in commands).

```yaml
test1: true

# Additional stuff...

echo $test1
# Result: true
```

List variables can be filtered using `[start:end]` and can be indexed using `[index]`. Note that this cannot be used with the `$variable` syntax, only inside `${variable}`. See the example below.

```yaml
test2:
    - IGNORE1
    - IGNORE2
    - IGNORE3

echo ${test2[0:3].join('')}
# Result: IGNORE1IGNORE2IGNORE3

echo ${test2[0]}
# Result: IGNORE1
```

## IF ELSE STATEMENTS
If-else statements can be used inside all functions. You can utilize all variables defined in the script.

```bash
build {
    if test1 {
        print hello!
    } else {
        print bye!
    }
}   
```

You can also use any variable manipulation methods in if statements, including inline exec to execute commands and use their output or exit code in conditions. See **VARIABLE MANIPULATION** for details on available methods.

### CONDITION OPERATORS

The following operators are supported in conditions:

* **==** (equality): `if "$var" == "value" { ... }`
* **!=** (inequality): `if "$var" != "value" { ... }`
* **=~** (regex match): `if "$var" =~ e"pattern" { ... }`
* **||** (OR): `if "$var" == "a" || "$var" == "b" { ... }`
* **&&** (AND): `if "$var1" == "a" && "$var2" == "b" { ... }`

### REGEX MATCHING

Use the `=~` operator with `e"pattern"` syntax for regex matching. The pattern uses standard regex syntax with `|` for alternatives.

```bash
package {
    for APPLET in applets {
        # Skip applets provided by other packages
        if "$APPLET" =~ e"clear|grep|egrep|fgrep|tar|bzip2" {
            continue
        }
        exec "ln -s /bin/busybox $ROOT/bin/$APPLET"
    }
}
```

### COMBINING CONDITIONS

You can combine multiple conditions using `||` (OR) and `&&` (AND):

```bash
build {
    # OR: true if any condition is true
    if "$ARCH" == "x86_64" || "$ARCH" == "amd64" {
        print "Building for 64-bit x86"
    }
    
    # AND: true only if all conditions are true
    if "$DEBUG" == "true" && "$VERBOSE" == "true" {
        print "Debug mode with verbose output"
    }
}
```

## VARIABLE MANIPULATION
Variables can be manipulated directly within strings using object-style methods. This is particularly useful for constructing source URLs that require specific version formatting (e.g., extracting "Major.Minor" from a full version string). You can also use inline exec to execute commands and use their output or exit code.

The syntax for manipulation is `${variable.method(arguments)}` or `${exec("command").method()}`.

**Note**: Global variables (defined at the top of the kongue script) cannot use exec directly. Exec can only be used within function blocks (like `build`, `prepare`, `package`, etc.) or inside custom functions.

### AVAILABLE METHODS

* **join(delimiter)**
  Joins a list into a string using the given delimiter. Only works with lists.
  * *Example:* `version: "2.78.1"`
  * `${version.split('.').join('!')}` returns `2!78!1`
  * `${version.split('.')[0:2].join('.')}` returns `2.78`

* **split(delimiter)**
  Splits the string by the given delimiter and returns the segments as a list. Only works with strings.
  * *Example:* `version: "2.78.1"`
  * `${version.split('.')[0]}` returns `2`
  * `${version.split('.')[1]}` returns `78`

* **cut(start, end)**
  Slices the string from the `start` index up to (but not including) the `end` index. Only works with strings.
  * *Example:* `commit: "543ee30eda80..."`
  * `${commit.cut(0, 7)}` returns `543ee30`

* **replace(old, new)**
  Replaces all occurrences of `old` substring with `new`. Only works with strings.
  * *Example:* `version: "1.0.5"`
  * `${version.replace('.', '_')}` returns `1_0_5`

* **exec(command).output()**
  Executes a shell command and returns its output. Can be used in conditionals, variable assignments, and string interpolation. Only works within function blocks, not in global variable definitions.
  * *Example:* `build { if ${exec("test -f config.h").output()} { print "config.h exists" } }`
  * `${exec("ls -1 | head -n 1").output()}` returns the first line of directory listing

* **exec(command).exit()**
  Executes a shell command and returns its exit code (0 for success, non-zero for failure). Can be used in conditionals and comparisons. Only works within function blocks, not in global variable definitions.
  * *Example:* `build { if ${exec("test -f config.h").exit()} == 0 { print "config.h exists" } }`
  * `${exec("ls nonexistent").exit()}` returns a non-zero exit code if the file doesn't exist

### EXAMPLES
Combining methods to construct complex URLs:

```yaml
version: "2.78.1"
sources:
    - "https://download.acme.org/sources/acme/${version.split('.')[0:2].join('.')}/acme-$version.tar.xz"
```

Using inline exec in conditionals and variable assignments:

```bash
build {
    if ${exec("test -f config.h").exit()} == 0 {
        print "config.h exists"
    }
    
    local first_file = ${exec("ls -1 | head -n 1").output()}
    print "First file: $first_file"
}
```

## FOR LOOPS
For loops can be used inside all functions. You can access all variables defined in the script.

```bash
build {
    for i in test2 {
        print $i
    }
}
```

You can also use inline list literals directly in for loops:

```bash
package {
    for file in ["tzselect", "zdump", "zic"] {
        exec "rm -f $ROOT/usr/bin/$file"
    }
}
```

### VARIABLE EXPRESSIONS IN FOR LOOPS

For loops support variable expressions that resolve to lists. This is useful when iterating over dynamic content like command output:

```bash
package {
    # Iterate over lines from command output
    for APPLET in "${exec(\"$ROOT/bin/busybox --list\").output()}" {
        print "Processing applet: $APPLET"
    }
    
    # Iterate over a variable that contains newline-separated values
    local items: "${exec(\"ls -1\").output()}"
    for item in "$items" {
        print "Item: $item"
    }
}
```

### LOOP CONTROL: CONTINUE AND BREAK

Use `continue` to skip to the next iteration and `break` to exit the loop entirely:

```bash
package {
    for APPLET in applets {
        # Skip certain applets
        if "$APPLET" =~ e"grep|tar|bzip2" {
            continue
        }
        
        # Stop processing if we hit a specific applet
        if "$APPLET" == "STOP" {
            break
        }
        
        exec "ln -s /bin/busybox $ROOT/bin/$APPLET"
    }
}
```

## BUILTIN COMMANDS
These are the built-in commands available in all kongue environments:

* **exec**: Spawn shell commands. Usage: `exec [COMMAND]`
* **print**: Print output to stdout. Usage: `print [STRING]`
* **cd**: Change directory. Usage: `cd [DIRECTORY]`
* **echo**: Alias to `print`. Usage: `echo [STRING]`
* **local**: Allows you to set a local variable inside a function (see CUSTOM FUNCTIONS). Usage: `local [VAR]=[VALUE]`
* **global**: Allows you to set and override a global variable inside a function (see CUSTOM FUNCTIONS). Usage: `global [VAR]=[VALUE]`
* **env**: Allows you to set and override environment variables inside a function. Usage: `env [VAR]=[VALUE]`
* **write**: Write content to a file. Overwrites the file if it exists. Usage: `write [FILE] [STRING]`
* **append**: Append content to a file. Creates the file if it does not exist. Usage: `append [FILE] [STRING]`
* **continue**: Skip to the next iteration in a for loop. Usage: `continue`
* **break**: Exit from a for loop immediately. Usage: `break`

See **STRINGS** for information on multi-line content.

The rest of the shell commands (should you need them) can only be accessed using the `exec` parameter.

## STRINGS
Strings can be enclosed in double quotes (`"`) or single quotes (`'`). 

For multi-line strings, use triple quotes (`"""`).

```bash
write "file.txt" """
Line 1
Line 2
"""
```



# VARIABLES AND FUNCTIONS

## CUSTOM FUNCTIONS
Users can define their own reusable functions to avoid repetition. These function blocks follow the same syntax as lifecycle functions (like `build` or `prepare`) but require the `func` keyword.

### SYNTAX
Custom functions are defined at the top level of the script. They use standard POSIX-like shell argument handling (`$1`, `$2`, `$@`).

```bash
func test_function {
    print "Hello $1"
}
```

### USAGE
Once defined, custom functions can be called inside any other function block (`build`, `prepare`, `package`, etc.) by simply typing their name and arguments.

```bash
build {
    test_function "Kreato"
}
```

### SCOPE AND VARIABLES
* Global Variables: Custom functions can access (and modify using the `global` keyword) all variables defined in the YAML header. This way you can create subpackages that have different properties to the main package.
* Local Variables: You can define local variables inside a function using the `local` keyword to prevent exposing them to the rest of the script.
* Environment Variables: You can define environment variables inside a function using the `env` keyword to pass that automatically.

```bash
func test_variables {
    local awesome="yes!"
    global name="test2"
    env EXAMPLE="test"
    print "Is this local? $awesome"
    print "The package is named: $name"
    exec "echo you know this is a \$EXAMPLE right?"
}
```

# NAMING CONVENTIONS
Kongue variables are case-insensitive and support multiple naming styles:
* camelCase (e.g., `buildDepends`)
* PascalCase (e.g., `BuildDepends`)
* kebab-case (e.g., `build-depends`)
* snake_case (e.g., `build_depends`)

snake_case is recommended for most scripts.

**Important**: Functions are case-sensitive and do not support this flexibility.

# AUTHOR
Written by Kreato.

# COPYRIGHT
Kreato Linux src is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Kreato Linux src is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Kreato Linux src.  If not, see <https://www.gnu.org/licenses/>.
