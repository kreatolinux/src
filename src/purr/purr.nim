include common
include ../kpkg/info
include ../kpkg/remove
include ../kpkg/upgrade

proc genFiles(tmpdir: string) =
    ## Generates files required for the utility to function.
    ok("Files successfully generated.")
    discard existsOrCreateDir(tmpdir)
    discard existsOrCreateDir(tmpdir&"/root")
    discard existsOrCreateDir(tmpdir&"/root/var")
    discard existsOrCreateDir(tmpdir&"/root/etc")

proc purr(tests = "all", tmpdir = "/tmp/purr") =
    ## kpkg's testing utility.

    if not isAdmin():
        error("You have to be root to run the tests.")

    removeDir("/tmp/purr")
    genFiles(tmpdir)

    # Test update
    discard update()
    # TODO: remove repo from config when successful
    #discard update("https://github.com/kreatolinux/purr-test-repo.git", "/tmp/purr/test")
    #if dirExists(tmpdir&"/test"):
    #    ok("update test completed successfully")
    #else:
    #    error("update test failed")

    # Test build
    #discard build(yes = true, root = tmpdir&"/root", packages = toSeq(["purr"]))
    #if fileExists("/testfile"):
    #    ok("build test completed successfully")
    #else:
    #    error("build test failed")

    # Test remove
    #discard remove(packages = toSeq(["purr"]), yes = true,
    #        root = "/tmp/purr/root")
    #if not fileExists(tmpdir&"root/testfile"):
    #    ok("remove test completed successfully")
    #else:
    #    error("remove test failed")

    if dephandler(toSeq(["sway"])).join(" ") != "pcre openssl zlib libxcrypt python meson samurai expat libxml2 ninja wayland wayland-protocols libpciaccess libdrm xkeyboard-config libxkbcommon libevdev mtdev gmake libudev libinput hwdata seatd pixman libelf python-mako perl m4 autoconf automake libtool libuv libzstd linux-headers libarchive nghttp2 curl cmake flex bison gettext texinfo file binutils gmp isl mpc mpfr gcc llvm mesa wlroots libpng freetype gperf pkgconf fontconfig glib harfbuzz cairo git fribidi pango json-c":
        info_msg("dephandler result: "&dephandler(toSeq(["sway"])).join(" "))
        error("dephandler test failed")
    else:
        ok("dephandler test completed successfully")

    discard info(toSeq(["sway"]), true)
    ok("info test completed")

    # Test install_bin (and the functions it uses)
    #install_bin(["purr"], "http://localhost:8080")

dispatch purr
