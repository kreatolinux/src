import osproc

const homeDir* = "/tmp/kpkg/homedir"

proc addUser*(name: string, path = "/"): bool =
    ## Adds an user.
    var cmd = "useradd -M -r -s /bin/nologin -d "&homeDir&" "&name
    var cmdPasswd = "passwd -d "&name
    var cmdChroot = "chroot "&path&" /bin/sh -c '. /etc/profile && /usr/sbin/"

    if path != "/":
        cmd = cmdChroot&cmd&"'"
        cmdPasswd = cmdChroot&cmdPasswd&"'"

    if execCmdEx(cmd).exitcode == 0 and execCmdEx(cmdPasswd).exitcode == 0:
        return true
    else:
        return false

proc existsUser*(name: string): bool =
    return execCmdEx("id "&name).exitcode == 0

proc sboxWrap*(command: string): string =
    ## Convenience proc, just lets you run the command with _kpkg sandbox user.
    return "su -s /bin/sh _kpkg -c '"&command&"'"