% kpkg_run(5)

# NAME
kpkg runfile - Main package format of kpkg

# DESCRIPTION
kpkg runfiles are the main package format of kpkg. They are basic scripts with specific variables and functions that enable kpkg to build packages.

# RUNFILE STRUCTURE
Runfiles are simply named `run3` and must be placed inside the package directory. It is a specialized custom format.

## Example Runfile

```bash
name: "test-v3"
version: "0.0.1"
release: "1"
sources: 
    - "https://test.file/source/testfile.tar.gz"
    - "git::https://github.com/kreatolinux/src::543ee30eda806029fa9ea16a1f9767eda7cab4d1"
    - "https://test.file/sources/v${version.split('.')[0:2].join('.')}/testfile.tar.gz"
depends: 
    - "testpackage1" 
    - "testpackage3" 
    - "testpackage4"
depends_test2: 
    - "testpackage5" 
    - "testpackage6"
no_chkupd: false
replaces: 
    - "test-v2"
backup: 
    - "etc/test-v3/main.conf"
    - "etc/test/settings.conf"
opt_depends:
    - "optional-dependency: This is a test optional dependency"
    - "optional-dependency-2: This is a second optional dependency."
build_depends: 
    - "testpackage5" 
    - "testpackage6" 
    - "testpackage10"
sha256sum: 
    - "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    - "SKIP"
    - "ab37404db60460d548e22546a83fda1eb6061cd8b95e37455149f3baf6c5fd38"
sha512sum:
    - "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e" 
    - "SKIP"  
    - "fce866720603d30cbefe5c0df9c6bacf70cbdb27caef5bcf15f125901cb23a9681ec9f87410a7d2f763af5a89c2b4e43685196ce3b0674868bf81cb3688e47c8"
b2sum: 
    - "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
    - "SKIP" 
    - "64fed8bce19ef14ed2d8434229dc2ec5307e06205610b1859b81b8090ae5ba7001988de896ff4878a15a7b7334e4a06e5889270b2e755fe130f7c80960e66ba2"
description: "Test package"

func custom_func {
    print "This is a test custom function"
}

prepare {
    custom_func # We can run custom functions just like commands
    env TEST=1
    exec tar -xvf testfile.tar.gz
    # Or you can use:
    # macro extract --autocd=true
    # to extract all the archives in sources.
}

build {
    cd testfile
    echo "Insert build instructions here"
}

check {
    macro test --ninja
    # exec ninja -C build test
}

preupgrade {
    echo "run before upgrade"
}

preinstall {
    echo "run before first install"
}

package {
    cd testfile
    macro package --meson
}

package_test2 {
    cd testfile
    exec make install_test2 # External commands require exec
}

postinstall {
    echo "Insert postinstall instructions here"
}

postupgrade {
    echo "run after upgrade"
}

postremove {
    echo "Insert postremove instructions here"
}
```

# SYNTAX AND LANGUAGE FEATURES

## VARIABLES
Variables must be declared at the top of the runfile. They can be any type (list, string, int, bool, etc.). Variables can be referenced in if statements, for loops, and inside functions. On commands, simple referencing is done via `$variable` or `${variable}`. Complex manipulation (splitting, slicing) works via `${variable.method()}` (or `variable.method()` on a non-command context) (see **VARIABLE MANIPULATION** below).

```yaml
test1: true
test2:
    - this is a test
    - test2
# and so on...
```

Variables can be referenced in if statements, for loops, inside variables, and inside functions (including in macros and exec commands).

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
If-else statements can be used inside all functions. You can utilize all variables defined in the runfile.

```bash
build {
    if test1 {
        print hello!
    } else {
        print bye!
    }
}   
```

## VARIABLE MANIPULATION
Variables can be manipulated directly within strings using object-style methods. This is particularly useful for constructing source URLs that require specific version formatting (e.g., extracting "Major.Minor" from a full version string).

The syntax for manipulation is `${variable.method(arguments)}`.

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

### EXAMPLES
Combining methods to construct complex URLs:

```yaml
version: "2.78.1"
sources:
    - "https://download.acme.org/sources/acme/${version.split('.')[0:2].join('.')}/acme-$version.tar.xz"
```

## FOR LOOPS
For loops can be used inside all functions. You can access all variables defined in the runfile.

```bash
build {
    for i in test2 {
        print $i
    }
}
```

## BUILTIN COMMANDS
These are the built-in commands available in the runfile environment:

* **exec**: Spawn shell commands. Usage: `exec [COMMAND]`
* **macro**: Use macros specifically made for extracting, building, packaging, and testing packages. Supported build systems include cmake, ninja, meson, and GNU Automake. Usage: `macro [NAME] [FLAGS]`
* **print**: Print output to stdout. Usage: `print [STRING]`
* **cd**: Change directory. Usage: `cd [DIRECTORY]`
* **echo**: Alias to `print`. Usage: `echo [STRING]`
* **local**: Allows you to set a local variable inside a function (see CUSTOM FUNCTIONS). Usage: `local [VAR]=[VALUE]`
* **global**: Allows you to set and override a global variable inside a function (see CUSTOM FUNCTIONS). Usage: `global [VAR]=[VALUE]`
* **env**: Allows you to set and override environment variables inside a function. Usage: `env [VAR]=[VALUE]`
* **write**: Write content to a file. Overwrites the file if it exists. Usage: `write [FILE] [STRING]`
* **append**: Append content to a file. Creates the file if it does not exist. Usage: `append [FILE] [STRING]`

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
Custom functions are defined at the top level of the runfile. They use standard POSIX-like shell argument handling (`$1`, `$2`, `$@`).

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

```bash
func test_variables {
    local awesome="yes!"
    global name="test2"
    print "Is this local? $awesome"
    print "The package is named: $name"
}
```


## REQUIRED VARIABLES
* **name**: Name of your package. Displayed in info command output.
* **version**: Version of your package. Displayed in info command output. Updating this will trigger package upgrade.
* **release**: Release number of your package. Displayed in info command output. Updating this will trigger package upgrade.
* **description**: Description of the package. Displayed in info command output.

## REQUIRED FUNCTIONS
* **package**: The installation function that defines how the package should be installed.

## SOURCE AND DEPENDENCY VARIABLES
* **sources**: Source URLs of your package. Can be specified as a list. Supports git URLs as shown in the example.
* **depends**: Runtime dependencies of your package. Supports version specifications like:
  - `test<=1.8.1`: Less than or equal to version 1.8.1
  - `test=1.8.1`: Exactly version 1.8.1
  - `test>=1.8.1`: Greater than or equal to version 1.8.1
  - `test<1.8.1`: Less than version 1.8.1
  - `test>1.8.1`: Greater than version 1.8.1
* **build_depends**: Build-time dependencies of your package.
* **depends_packagename**: Specify dependencies for a specific sub-package. Can be modified using:
  - `depends_packagename+: "packagename"` to add a dependency
  - `depends_packagename-: "packagename"` to remove a dependency
  - `depends_packagename: "packagename"` to replaces dependencies completely

## CHECKSUM VARIABLES
* **sha256sum**: SHA-256 checksums of the sources. Should align with the sources in order.
* **sha512sum**: SHA-512 checksums of the sources. Should align with the sources in order.
* **b2sum**: BLAKE2 checksums of the sources. Should align with the sources in order.

Do mind that Git repositories don't have the checksum ability. You can use `SKIP` for git sources as this value is ignored.

## OPTIONAL VARIABLES
* **epoch**: Only use when versioning logic fails for the package.
* **no_chkupd**: Disables auto-updating through chkupd. Default is `false`. 
* **replaces**: Specifies packages that this package replaces.
* **opt_depends**: Optional dependencies for the package, with description after colon.
* **conflicts**: Specifies packages that conflict with this package.
* **is_group**: Indicates if the package is a group package. Default is `false`.
* **backup**: Preserves files (such as configuration files) during upgrades. Don't include leading slash (use `etc/bluetooth/main.conf` instead of `/etc/bluetooth/main.conf`).

## OPTIONAL FUNCTIONS
* **build**: Main build function. Only optional for packages that don't need to be built (e.g., binary-only packages).
* **prepare**: Custom preparation procedure. Files from sources are extracted by default unless this function is defined.
* **check**: Function to test the package.
* **preinstall**: Runs when the package is installed for the first time (not during upgrades).
* **postinstall**: Runs after the package is installed.
* **preupgrade**: Runs before an upgrade occurs.
* **postupgrade**: Runs after an upgrade completes.
* **postremove**: Runs after the package is removed.
* **package_packagename**: Installation function for a sub-package. Allows packaging multiple components in the same runfile.

# NAMING CONVENTIONS
Runfile variables are case-insensitive and support multiple naming styles:
* camelCase (e.g., `buildDepends`)
* PascalCase (e.g., `BuildDepends`)
* kebab-case (e.g., `build-depends`)
* snake_case (e.g., `build_depends`)

snake_case is recommended for most runfiles.

**Important**: Functions are case-sensitive and do not support this flexibility.

# AUTHOR
Written by Kreato.

# COPYRIGHT
kpkg is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

kpkg is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with kpkg.  If not, see <https://www.gnu.org/licenses/>.