include common
include ../nyaa/info
include ../nyaa/remove
include ../nyaa/upgrade

proc genFiles(tmpdir: string) =
    ## Generates files required for the utility to function.
    ok("Files successfully generated.")
    discard existsOrCreateDir(tmpdir)
    discard existsOrCreateDir(tmpdir&"/root")
    discard existsOrCreateDir(tmpdir&"/root/etc")

proc purr(tests = "all", tmpdir = "/tmp/purr") =
    ## nyaa3's testing utility.

    if not isAdmin():
        error("You have to be root to run the tests.")

    removeDir("/tmp/purr")
    genFiles(tmpdir)

    # Test update
    # TODO: remove repo from config when successful
    discard update("https://github.com/kreatolinux/purr-test-repo.git", "/tmp/purr/test")
    if dirExists(tmpdir&"/test"):
        ok("update test completed succesfully")
    else:
        error("update test failed")

    # Test build
    discard build(yes = true, root = tmpdir&"/root", packages = toSeq(["purr"]),
            offline = true)
    if fileExists("/testfile"):
        ok("build test completed successfully")
    else:
        error("build test failed")

    # Test remove
    discard remove(packages = toSeq(["purr"]), yes = true,
            root = "/tmp/purr/root")
    if not fileExists(tmpdir&"root/testfile"):
        ok("remove test completed succesfully")
    else:
        error("remove test failed")

    if dephandler(toSeq(["sway"])).join(" ") != "pcre expat openssl zlib libxcrypt python libxml2 ninja meson wayland samurai wayland-protocols libpciaccess libdrm xkeyboard-config libxkbcommon libevdev mtdev gmake libudev libinput seatd pixman libelf python-mako m4 gmp isl libzstd flex perl texinfo file binutils mpc mpfr linux-headers gcc autoconf automake libtool libuv libarchive nghttp2 curl cmake llvm mesa wlroots libpng freetype-harfbuzz pkgconf cairo git glib fribidi gperf fontconfig pango json-c":
        error("dephandler test failed")
    else:
        ok("dephandler test completed successfully")

    discard info(toSeq(["purr"]))
    ok("info test completed")

    # Test install_bin (and the functions it uses)
    #install_bin(["purr"], "http://localhost:8080")

dispatch purr
