#!/bin/sh
# Build/install logic for Jumpstart's package (spec §25), using a fake nim.
set -eu

srcdir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
tmp=${TMPDIR:-/tmp}/jumpstart-packaging-test.$$
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/build/jumpstart" "$tmp/build/tests/jumpstart" "$tmp/build/tests/jumpstartcore" "$tmp/build/fake-bin"
cp "$srcdir/build.sh" "$srcdir/Makefile" "$tmp/build/"
: > "$tmp/build/jumpstart/jumpstart.nim"
: > "$tmp/build/jumpstart/jumpctl.nim"
: > "$tmp/build/jumpstart/kongue_runner.nim"
: > "$tmp/build/jumpstart/pam_jumpstart.nim"
: > "$tmp/build/tests/jumpstart/test_smoke.nim"
: > "$tmp/build/tests/jumpstartcore/test_smoke.nim"

cat > "$tmp/build/fake-bin/nim" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NIM_LOG"
output=
for arg do
  case $arg in
    -o:*) output=${arg#-o:} ;;
  esac
done
[ -n "$output" ] || exit 1
# Simulate a build step that "succeeds" without producing its artifact.
case ${FAKE_NIM_SKIP:-} in
  ?*) case $output in *"$FAKE_NIM_SKIP") exit 0 ;; esac ;;
esac
mkdir -p "$(dirname -- "$output")"
printf '#!/bin/sh\nexit 0\n' > "$output"
chmod +x "$output"
EOF
chmod +x "$tmp/build/fake-bin/nim"
cat > "$tmp/build/fake-bin/brew" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$tmp/build/fake-bin/brew"

fail() {
  echo "test-jumpstart-packaging: $*" >&2
  exit 1
}

# run_build OS [build.sh args...]
run_build() {
  os=$1
  shift
  (
    cd "$tmp/build"
    NIM_LOG="$tmp/nim.log" JUMPSTART_BUILD_OS="$os" \
      PATH="$tmp/build/fake-bin:$PATH" sh build.sh "$@"
  )
}

# run_install OS
run_install() {
  rm -rf "$tmp/stage"
  NIM_LOG="$tmp/nim.log" PATH="$tmp/build/fake-bin:$PATH" \
    make -s -C "$tmp/build" PREFIX=/usr LIBDIR=/usr/lib JUMPSTART_BUILD_OS="$1" \
    DESTDIR="$tmp/stage" install_jumpstart >/dev/null
}

# Jumpstart tests need neither TLS feature flags nor Darwin package-manager
# library discovery.  A failing fake brew makes accidental discovery visible.
: > "$tmp/nim.log"
run_build Darwin -P darwin -T jumpstart
if grep -E -- '-d:ssl|-d:run3NoLibArchive|-d:kpkgInstallChannelTest' \
    "$tmp/nim.log" >/dev/null; then
  fail 'Jumpstart tests received unrelated project flags'
fi

# The core library has its own test project (source-only: nothing to install).
: > "$tmp/nim.log"
run_build Linux -T jumpstartcore >/dev/null
grep -F -- 'tests/jumpstartcore/test_smoke.nim' "$tmp/nim.log" >/dev/null \
  || fail 'jumpstartcore tests were not built'
if grep -E -- '-d:ssl|-d:run3NoLibArchive|-d:kpkgInstallChannelTest' \
    "$tmp/nim.log" >/dev/null; then
  fail 'jumpstartcore tests received unrelated project flags'
fi

# Linux: every §25 artifact is built and installed.
: > "$tmp/nim.log"
run_build Linux -p jumpstart
test -f "$tmp/build/out/kongue-runner" || fail 'Linux build lacks kongue-runner'
test -f "$tmp/build/out/pam_jumpstart.so" || fail 'Linux build lacks pam_jumpstart.so'
grep -F -- '--app:lib --noMain:on -d:pamJumpstartModule' "$tmp/nim.log" >/dev/null \
  || fail 'PAM module not built as a shared library'
grep -F -- 'jumpstart/kongue_runner.nim' "$tmp/nim.log" >/dev/null \
  || fail 'runner not built from kongue_runner.nim'
# The library directory is compiled in; build.sh alone defaults to /usr/lib.
test "$(grep -c -F -- '-d:jumpstartLibDir=/usr/lib ' "$tmp/nim.log")" -eq 3 \
  || fail 'jumpstart, jumpctl and kongue-runner must all get -d:jumpstartLibDir'

run_install Linux
test -x "$tmp/stage/usr/bin/jumpstart" || fail 'jumpstart not installed'
test -x "$tmp/stage/usr/bin/jumpctl" || fail 'jumpctl not installed'
test -x "$tmp/stage/usr/lib/jumpstart/kongue-runner" || fail 'kongue-runner not installed'
test -x "$tmp/stage/usr/lib/security/pam_jumpstart.so" || fail 'PAM module not installed'
# §25 does not ask the package to create the core root (a missing root
# contributes nothing, §8.2); extension packages create their own directory.
test ! -e "$tmp/stage/usr/lib/jumpstart/cores" || fail 'core root must not be created'

# make passes its LIBDIR through to the compiled-in define.
: > "$tmp/nim.log"
NIM_LOG="$tmp/nim.log" PATH="$tmp/build/fake-bin:$PATH" \
  make -s -C "$tmp/build" LIBDIR=/opt/js/lib JUMPSTART_BUILD_OS=Linux jumpstart >/dev/null
grep -F -- '-d:jumpstartLibDir=/opt/js/lib ' "$tmp/nim.log" >/dev/null \
  || fail 'make did not pass LIBDIR to build.sh'
if (cd "$tmp/build" && JUMPSTART_LIBDIR=relative/lib PATH="$tmp/build/fake-bin:$PATH" \
    NIM_LOG="$tmp/nim.log" sh build.sh -p jumpstart >/dev/null 2>&1); then
  fail 'relative JUMPSTART_LIBDIR must be rejected'
fi

# Non-Linux (macOS development builds): no PAM module, everything else required.
: > "$tmp/nim.log"
run_build Darwin -p jumpstart
test -f "$tmp/build/out/kongue-runner" || fail 'Darwin build lacks kongue-runner'
test ! -e "$tmp/build/out/pam_jumpstart.so" || fail 'Darwin build left a PAM module'
run_install Darwin
test -x "$tmp/stage/usr/lib/jumpstart/kongue-runner" || fail 'Darwin install lacks kongue-runner'
test ! -e "$tmp/stage/usr/lib/security/pam_jumpstart.so" || fail 'Darwin install has a PAM module'

# The PAM module can be built on its own (musl validation stage).
rm -f "$tmp/build/out/pam_jumpstart.so"
run_build Linux -p pam_jumpstart >/dev/null
test -f "$tmp/build/out/pam_jumpstart.so" || fail 'pam_jumpstart project did not build'

# Missing required sources fail the build instead of shrinking the package.
mv "$tmp/build/jumpstart/pam_jumpstart.nim" "$tmp/pam_jumpstart.nim"
if run_build Linux -p jumpstart >/dev/null 2>&1; then
  fail 'Linux build without pam_jumpstart.nim must fail'
fi
run_build Darwin -p jumpstart >/dev/null || fail 'Darwin build must not need the PAM source'
mv "$tmp/pam_jumpstart.nim" "$tmp/build/jumpstart/pam_jumpstart.nim"

mv "$tmp/build/jumpstart/kongue_runner.nim" "$tmp/kongue_runner.nim"
for os in Linux Darwin; do
  if run_build "$os" -p jumpstart >/dev/null 2>&1; then
    fail "$os build without kongue_runner.nim must fail"
  fi
done
mv "$tmp/kongue_runner.nim" "$tmp/build/jumpstart/kongue_runner.nim"

# A missing artifact fails the install rather than being skipped.
for case_ in Linux:pam_jumpstart.so Linux:kongue-runner Darwin:kongue-runner; do
  os=${case_%%:*}
  artifact=${case_#*:}
  rm -rf "$tmp/stage"
  if FAKE_NIM_SKIP="/$artifact" NIM_LOG="$tmp/nim.log" PATH="$tmp/build/fake-bin:$PATH" \
      make -s -C "$tmp/build" PREFIX=/usr LIBDIR=/usr/lib JUMPSTART_BUILD_OS="$os" \
      DESTDIR="$tmp/stage" install_jumpstart >/dev/null 2>&1; then
    fail "$os install without $artifact must fail"
  fi
done

printf '%s\n' 'jumpstart build/install validation passed'
