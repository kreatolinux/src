#!/bin/sh
# This script has extra commands/replacements for build systems.
# It will be sourced by build/package parts of the runFile.
export KPKG_CONFIGURE_PATH="./configure"

make() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    env make ARCH="$KPKG_ARCH" CROSS_COMPILE="$KPKG_TARGET-" $@
  else
     env make $@
  fi
}

kpkgConfigure() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    $KPKG_CONFIGURE_PATH --prefix=/usr --host="$KPKG_TARGET" --build="$KPKG_HOST_TARGET" $@
  else
    $KPKG_CONFIGURE_PATH --prefix=/usr $@
  fi
}
  

cmake() {
  env cmake -DCMAKE_TOOLCHAIN_FILE=/usr/$KPKG_TARGET/$KPKG_TARGET.cmake $@
}

meson() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    env meson --cross-file "/usr/$KPKG_TARGET/$KPKG_TARGET-meson.txt" $@
  else
    env meson $@
  fi
}