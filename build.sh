#!/bin/sh
prefix="./out"
# https://stackoverflow.com/questions/29832037/how-to-get-script-directory-in-posix-sh
srcdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
projects=""
buildType="release"
branch="master"
installDeps="0"
target=""
args=""

err() {
	echo "error: $@"
	exit 1
}

# Build flags from environment variables
buildFlags() {
	passC=""
	passL=""
	[ -n "$CFLAGS" ] && passC="--passC:$CFLAGS"
	[ -n "$LDFLAGS" ] && passL="--passL:$LDFLAGS"
}

# Unified build function
# $1: project name
# $2: source file (relative to project dir or full path)
# $3: output path
# $4: threads setting (on/off)
# $5: extra flags (optional)
# $6: use deepcopy (1 or empty)
# $7: use archive (1 or empty)
# $8: use branch/ssl (1 or empty)
buildNim() {
	cd "$srcdir" || err "Failed to change to source directory"
	buildFlags

	project="$1"
	sourceFile="$2"
	outputPath="$3"
	threads="$4"
	extraFlags="$5"
	useDeepcopy="$6"
	useArchive="$7"
	useBranchSsl="$8"

	# Determine source path
	case "$sourceFile" in
		/*)
			sourcePath="$sourceFile"
			;;
		*)
			sourcePath="$srcdir/$project/$sourceFile"
			;;
	esac

	# Build command arguments
	set -- nim c -d:$buildType
	[ -n "$args" ] && set -- "$@" $args
	[ -n "$target" ] && set -- "$@" $target
	[ -n "$passC" ] && set -- "$@" $passC
	[ -n "$passL" ] && set -- "$@" $passL
	[ -n "$useDeepcopy" ] && set -- "$@" --deepcopy:on
	[ -n "$useArchive" ] && set -- "$@" --passL:-larchive
	[ -n "$useBranchSsl" ] && set -- "$@" -d:branch=$branch -d:ssl
	set -- "$@" --threads:$threads -o:"$outputPath"
	[ -n "$extraFlags" ] && set -- "$@" $extraFlags
	set -- "$@" "$sourcePath"

	"$@" || err "building $project failed"

	cd - > /dev/null
}

printHelp() {
	printf "Usage: './build.sh [ARGUMENTS]'
Options:
	-d, --debug: Enable debug on built projects
	-t, --target [ARCHITECTURE]: Set architecture for built binary
	-p, --projects [PROJECTS]: Enable projects, separate by comma
	-i, --installDeps: Install dependencies before continuing
	-c, --clean: Clean binaries
	-b, --branch [BRANCH]: Set default branch for repositories. 'master' by default.
	-a, --args [ARGUMENTS]: Set arguments for nimc.
"
}

echo "Kreato Linux - Source tree build script"

if [ "$#" = "0" ]; then
	printHelp
	exit 0
fi

while [ "$#" -gt 0 ]; do
	case $1 in
		-t|--target)
			shift
			[ -z "$1" ] && err "--target requires an argument"
			target="--cpu:$1"
			;;
		-d|--debug)
			buildType="debug"
			;;
		-p|--projects)
			shift
			[ -z "$1" ] && err "--projects requires an argument"
			projects="$1"
			;;
		-i|--installDeps)
			installDeps="1"
			;;
		-c|--clean)
			echo "Cleaning binaries"
			rm -rf "$prefix"
			rm -f "$srcdir/kreastrap/kreastrap"
			rm -f "$srcdir/kreaiso/kreaiso"
			;;
		-b|--branch)
			shift
			[ -z "$1" ] && err "--branch requires an argument"
			branch="$1"
			;;
		-a|--args)
			shift
			[ -z "$1" ] && err "--args requires an argument"
			args="$1"
			;;
		*)
			printHelp
			exit 1
			;;
	esac
	shift
done

if [ "$installDeps" = "1" ]; then
	nimble install fuzzy futhark@0.12.5 cligen nimcrypto norm fusion regex -y \
		|| err "Installing dependencies failed"
fi

[ -z "$projects" ] && exit 0

IFS=","
for v in $projects; do
	echo "building $v"
	case $v in
		kpkg|purr)
			buildNim "$v" "$v.nim" "$prefix/$v" "on" "" "1" "1" "1"
			;;
		chkupd)
			buildNim "$v" "$v.nim" "$prefix/$v" "on" "" "" "" "1"
			;;
		jumpstart)
			buildNim "jumpstart" "jumpstart.nim" "$prefix/jumpstart" "on" "--mm:refc" "1" "" ""
			buildNim "jumpstart" "jumpctl.nim" "$prefix/jumpctl" "off" "" "1" "" ""
			;;
		genpkglist)
			buildNim "genpkglist" "main.nim" "$prefix/genpkglist" "off" "" "1" "" ""
			;;
		kreastrap)
			buildNim "kreastrap" "kreastrap.nim" "$srcdir/kreastrap/kreastrap" \
				"on" "" "1" "1" "1"
			;;
		kreaiso)
			buildNim "kreaiso" "kreaiso.nim" "$srcdir/kreaiso/kreaiso" \
				"on" "" "1" "1" "1"
			;;
		install_klinstaller)
			[ ! -d "$DESTDIR" ] && mkdir -p "$DESTDIR"
			cp "$srcdir/installer/klinstaller" "$DESTDIR/bin/klinstaller"
			chmod +x "$DESTDIR/bin/klinstaller"
			;;
		*)
			echo "Unknown project: $v" >&2
			;;
	esac
done
