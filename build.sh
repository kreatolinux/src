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
platform=""
testProject=""
# Jumpstart's compile-time library directory.  The daemon derives the system
# core root ($JUMPSTART_LIBDIR/jumpstart/cores) and the Kongue runner
# ($JUMPSTART_LIBDIR/jumpstart/kongue-runner) from it (spec §7.2, §16.1).
# `make install_jumpstart` passes its LIBDIR so built and installed paths agree.
JUMPSTART_LIBDIR="${JUMPSTART_LIBDIR:-/usr/lib}"
# Build OS; overridable only so the packaging test can exercise both branches.
buildOS="${JUMPSTART_BUILD_OS:-$(uname -s)}"

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

# Set up platform-specific library paths
setupPlatform() {
	if [ "$platform" = "darwin" ]; then
		opensslPrefix=$(brew --prefix openssl)
		libarchivePrefix=$(brew --prefix libarchive)
		export LDFLAGS="-L$opensslPrefix/lib -L$libarchivePrefix/lib"
		export CFLAGS="-I$opensslPrefix/include -I$libarchivePrefix/include"
		export PKG_CONFIG_PATH="$opensslPrefix/lib/pkgconfig:$libarchivePrefix/lib/pkgconfig"
	fi
}

# Unified build function
# $1: project name
# $2: source file (relative to project dir or full path)
# $3: output path
# $4: threads setting (on/off)
# $5: extra flags (optional)
# $6: use deepcopy (1 or empty)
# $7: use branch/ssl (1 or empty)
buildNim() {
	cd "$srcdir" || err "Failed to change to source directory"
	buildFlags

	project="$1"
	sourceFile="$2"
	outputPath="$3"
	threads="$4"
	extraFlags="$5"
	useDeepcopy="$6"
	useBranchSsl="$7"

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
	[ -n "$CC" ] && set -- "$@" --cc:$CC
	[ -n "$args" ] && set -- "$@" $args
	[ -n "$target" ] && set -- "$@" $target
	[ -n "$passC" ] && set -- "$@" "$passC"
	[ -n "$passL" ] && set -- "$@" "$passL"
	[ -n "$useDeepcopy" ] && set -- "$@" --deepcopy:on
	[ -n "$useBranchSsl" ] && set -- "$@" -d:branch=$branch -d:ssl
	set -- "$@" --threads:$threads -o:"$outputPath"
	if [ -n "$extraFlags" ]; then
		# The caller may have changed IFS (the project loop uses commas), so
		# split extra flags explicitly on whitespace.
		savedIFS="$IFS"
		IFS=' '
		for extraFlag in $extraFlags; do
			set -- "$@" "$extraFlag"
		done
		IFS="$savedIFS"
	fi
	set -- "$@" "$sourcePath"

	"$@" || err "building $project failed"

	cd - > /dev/null
}

# pam_jumpstart.so (spec §7.6, §25).  It is a shared library without a Nim main;
# PAM itself is resolved dynamically, so no PAM headers are needed to build it.
buildPamModule() {
	buildNim "jumpstart" "pam_jumpstart.nim" "$prefix/pam_jumpstart.so" "off" \
		"--app:lib --noMain:on -d:pamJumpstartModule" "1" ""
}

# Keep the build-tree layout identical to the installed share/krep layout.
# Replace only our staged resources, including any overlay removed from source.
stageKrepAssets() {
	dataRoot="$srcdir/out/share/krep"
	mkdir -p "$dataRoot" || err "Creating krep data directory failed"
	rm -rf "$dataRoot/rootfs" "$dataRoot/iso" || err "Cleaning staged krep assets failed"
	mkdir -p "$dataRoot/rootfs" "$dataRoot/iso" || err "Creating krep asset directories failed"
	cp -R -P "$srcdir/krep/data/rootfs/arch" "$dataRoot/rootfs/" \
		|| err "Staging krep rootfs configurations failed"
	if [ -d "$srcdir/krep/data/rootfs/overlay" ]; then
		cp -R -P "$srcdir/krep/data/rootfs/overlay" "$dataRoot/rootfs/" \
			|| err "Staging krep rootfs overlay failed"
	fi
	cp -R -P "$srcdir/krep/data/iso/overlay" \
		"$srcdir/krep/data/iso/grub.cfg" "$dataRoot/iso/" \
		|| err "Staging krep ISO assets failed"
	if [ -d "$srcdir/krep/data/iso/overlays" ]; then
		cp -R -P "$srcdir/krep/data/iso/overlays" "$dataRoot/iso/" \
			|| err "Staging krep init overlays failed"
	fi
}

# Run tests for a project
# $1: project name
runTests() {
	cd "$srcdir" || err "Failed to change to source directory"
	buildFlags

	project="$1"
	testDir="$srcdir/tests/$project"

	if [ ! -d "$testDir" ]; then
		err "Test directory not found: $testDir"
	fi

	# Find all test files
	if [ "$project" = "kpkg" ]; then
		testFiles=$(find "$testDir" -name '*.nim' -type f 2>/dev/null | sort)
	else
		testFiles=$(find "$testDir" -name 'test_*.nim' -type f 2>/dev/null | sort)
	fi
	if [ -z "$testFiles" ]; then
		err "No test files found in $testDir"
	fi

	echo "Running tests for $project"
	echo "================================"

	testCount=0
	failCount=0

	for testFile in $testFiles; do
		testRelative=${testFile#"$testDir"/}
		testName=${testRelative%.nim}
		testBinary="$srcdir/out/tests/$project/$testName"

		echo ""
		echo "--- $testName ---"

		# Ensure output directory exists
		mkdir -p "$(dirname "$testBinary")"

		# Keep project-specific features isolated: Jumpstart does not use TLS or
		# kpkg's libarchive/install-channel test hooks.
		set -- nim c -d:debug
		case "$project" in
			kpkg)
				set -- "$@" -d:ssl -d:run3NoLibArchive -d:kpkgInstallChannelTest
				;;
			krep)
				set -- "$@" -d:ssl -d:run3NoLibArchive
				;;
		esac
		[ -n "$passC" ] && set -- "$@" "$passC"
		[ -n "$passL" ] && set -- "$@" "$passL"
		set -- "$@" --threads:on --deepcopy:on -o:"$testBinary" "$testFile"

		if ! "$@"; then
			echo "FAIL: $testName (compilation failed)"
			failCount=$((failCount + 1))
			testCount=$((testCount + 1))
			continue
		fi

		# Run the test
		if "$testBinary"; then
			echo "PASS: $testName"
		else
			echo "FAIL: $testName (execution failed)"
			failCount=$((failCount + 1))
		fi
		testCount=$((testCount + 1))
	done

	echo ""
	echo "================================"
	echo "Tests: $testCount, Passed: $((testCount - failCount)), Failed: $failCount"

	if [ "$failCount" -gt 0 ]; then
		exit 1
	fi

	cd - > /dev/null
}

printHelp() {
	printf "Usage: './build.sh [ARGUMENTS]'
Options:
	-d, --debug: Enable debug on built projects
	-t, --target [ARCHITECTURE]: Set architecture for built binary
	-p, --projects [PROJECTS]: Enable projects, separate by comma
	   (kpkg, krep, jumpstart, pam_jumpstart, install_klinstaller)
	-P, --platform [PLATFORM]: Set platform for library paths (e.g., darwin for macOS)
	-T, --test [PROJECT]: Run tests for a project (kpkg, krep, jumpstart, jumpstartcore, kongue)
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
		-P|--platform)
			shift
			[ -z "$1" ] && err "--platform requires an argument"
			platform="$1"
			;;
		-i|--installDeps)
			installDeps="1"
			;;
		-c|--clean)
			echo "Cleaning binaries"
			rm -rf "$prefix"
			rm -f "$srcdir/krep/krep"
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
		-T|--test)
			shift
			[ -z "$1" ] && err "--test requires a project name"
			testProject="$1"
			;;
		*)
			printHelp
			exit 1
			;;
	esac
	shift
done

if [ "$installDeps" = "1" ]; then
	nimble install cligen nimcrypto norm fusion regex -y \
		|| err "Installing dependencies failed"
fi

# Run tests if requested
if [ -n "$testProject" ]; then
	case "$testProject" in
		kpkg|krep) setupPlatform ;;
	esac
	runTests "$testProject"
	exit 0
fi

[ -z "$projects" ] && exit 0

case "$JUMPSTART_LIBDIR" in
	/*) ;;
	*) err "JUMPSTART_LIBDIR must be an absolute path: $JUMPSTART_LIBDIR" ;;
esac
case "$JUMPSTART_LIBDIR" in
	*[[:space:]]*) err "JUMPSTART_LIBDIR must not contain whitespace" ;;
esac
jumpstartDefines="-d:jumpstartLibDir=$JUMPSTART_LIBDIR"

IFS=","
for v in $projects; do
	echo "building $v"
	case $v in
		kpkg)
			setupPlatform
			buildNim "$v" "$v.nim" "$prefix/$v" "on" "" "1" "1"
			;;
		jumpstart)
			# Fail before building anything if a required artifact's source is
			# missing (see the §25 note below).
			[ -f "$srcdir/jumpstart/kongue_runner.nim" ] \
				|| err "jumpstart/kongue_runner.nim is missing; kongue-runner is required"
			if [ "$buildOS" = "Linux" ]; then
				[ -f "$srcdir/jumpstart/pam_jumpstart.nim" ] \
					|| err "jumpstart/pam_jumpstart.nim is missing; pam_jumpstart.so is required on Linux"
			fi
			mkdir -p "$srcdir/out" || err "Creating jumpstart output directory failed"
			buildNim "jumpstart" "jumpstart.nim" "$prefix/jumpstart" "on" "--mm:refc $jumpstartDefines" "1" ""
			buildNim "jumpstart" "jumpctl.nim" "$prefix/jumpctl" "off" "$jumpstartDefines" "1" ""

			# §25: the package ships /usr/lib/jumpstart/kongue-runner and
			# pam_jumpstart.so.  Both are required; a missing source is an error,
			# never a silently smaller package.  The PAM module is Linux-only (PAM
			# session stacks and pidfd peer checks, §7.6), so non-Linux development
			# builds (macOS) produce everything except pam_jumpstart.so.
			rm -f "$prefix/kongue-runner" "$prefix/pam_jumpstart.so"
			# Nim module names cannot contain hyphens, so the runner is built from
			# kongue_runner.nim and only the output carries the specified name.
			buildNim "jumpstart" "kongue_runner.nim" "$prefix/kongue-runner" "off" "$jumpstartDefines" "1" ""
			if [ "$buildOS" = "Linux" ]; then
				buildPamModule
			else
				echo "skipping pam_jumpstart.so: the PAM module is Linux-only (build OS: $buildOS)"
			fi
			;;
		pam_jumpstart)
			# The PAM module alone, e.g. for the musl/Alpine validation stage.
			[ -f "$srcdir/jumpstart/pam_jumpstart.nim" ] \
				|| err "jumpstart/pam_jumpstart.nim is missing"
			mkdir -p "$srcdir/out" || err "Creating jumpstart output directory failed"
			rm -f "$prefix/pam_jumpstart.so"
			buildPamModule
			;;
		krep)
			setupPlatform
			mkdir -p "$srcdir/out" || err "Creating krep output directory failed"
			buildNim "krep" "krep.nim" "$srcdir/out/krep" "on" "" "1" "1"
			stageKrepAssets
			;;
		kickoff)
			setupPlatform
			mkdir -p "$srcdir/out" || err "Creating kickoff output directory failed"
			# The builder is an ordinary host program.
			buildNim "kickoff" "kickoff.nim" "$srcdir/out/kickoff" "off" "" "1" ""
			# The initramfs init ends up inside an archive that has no dynamic
			# linker of its own beyond the one kickoff copies in, so it is built
			# exactly like the other freestanding pieces: no threads, no ssl.
			buildNim "kickoff" "init/kickoff_init.nim" "$srcdir/out/kickoff-init" \
				"off" "" "1" ""
			;;
		install_klinstaller)
			[ ! -d "$DESTDIR" ] && mkdir -p "$DESTDIR"
			cp "$srcdir/installer/klinstaller" "$DESTDIR/bin/klinstaller"
			chmod +x "$DESTDIR/bin/klinstaller"
			;;
		*)
			err "Unknown project: $v"
			;;
	esac
done
