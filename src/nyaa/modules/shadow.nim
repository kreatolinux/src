import osproc

proc addUser(name: string, path = "/"): bool =
    ## Adds an user.
    var cmd = "useradd -M -r -s /bin/nologin "&name
    var cmdPasswd = "passwd -d "&name
    var cmdChroot = "chroot "&path&" /bin/sh -c '. /etc/profile && /usr/sbin/"

    if path != "/":
        cmd = cmdChroot&cmd&"'"
        cmdPasswd = cmdChroot&cmdPasswd&"'"

    if execCmdEx(cmd).exitcode == 0 and execCmdEx(cmdPasswd).exitcode == 0:
        return true
    else:
        return false


proc existsUser(name: string): bool =
    ## Checks if an user exists.
    if execCmdEx("id "&name).exitcode == 0:
        return true
    else:
        return false
