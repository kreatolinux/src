#!/bin/sh
# This script has extra commands/replacements for build systems.
# It will be sourced by build/package parts of the runFile.
export KPKG_CONFIGURE_PATH="./configure"

make() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    export CFLAGS="$CFLAGS -I/usr/$KPKG_TARGET/usr/include"
    export LDFLAGS="$LDFLAGS -L/usr/$KPKG_TARGET/lib"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/$KPKG_TARGET/usr/lib/pkgconfig"
    env make ARCH="$KPKG_ARCH" CROSS_COMPILE="$KPKG_TARGET-" $@
  else
     env make $@
  fi
}

kpkgConfigure() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    export CFLAGS="$CFLAGS -I/usr/$KPKG_TARGET/usr/include"
    export LDFLAGS="$LDFLAGS -L/usr/$KPKG_TARGET/lib"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/$KPKG_TARGET/usr/lib/pkgconfig"
    
    if [ "$KPKG_WITHOUT_SYSROOT" != "1" ]; then
        KPKG_EXTRA_ARGUMENTS="--with-sysroot=/usr/$KPKG_TARGET"
    fi

    $KPKG_CONFIGURE_PATH --prefix=/usr $KPKG_EXTRA_ARGUMENTS --host="$KPKG_TARGET" --build="$KPKG_HOST_TARGET" $@
  else
    $KPKG_CONFIGURE_PATH --prefix=/usr $@
  fi
}
  

cmake() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    export CFLAGS="$CFLAGS -I/usr/$KPKG_TARGET/usr/include"
    export LDFLAGS="$LDFLAGS -L/usr/$KPKG_TARGET/lib"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/$KPKG_TARGET/usr/lib/pkgconfig"
    env cmake -DCMAKE_TOOLCHAIN_FILE=/usr/$KPKG_TARGET/$KPKG_TARGET.cmake $@
  else
    env cmake $@
  fi
}

meson() {
  if [ "$KPKG_ARCH" != "$(uname -m)" ]; then
    export CFLAGS="$CFLAGS -I/usr/$KPKG_TARGET/usr/include"
    export LDFLAGS="$LDFLAGS -L/usr/$KPKG_TARGET/lib"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/$KPKG_TARGET/usr/lib/pkgconfig"
    env meson --cross-file "/usr/$KPKG_TARGET/$KPKG_TARGET-meson.txt" $@
  else
    env meson $@
  fi
}