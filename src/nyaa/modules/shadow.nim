proc addUser(name: string, path = "/"): bool =
    ## Adds an user.
    var cmd = "useradd -M -r -s /bin/nologin "&name
    var cmdPasswd = "passwd -d "&name
    var cmdChroot = "chroot "&path&" /bin/sh -c '. /etc/profile && /usr/sbin/"

    if path != "/":
        cmd = cmdChroot&cmd&"'"
        cmdPasswd = cmdChroot&cmdPasswd&"'"

    if execShellCmd(cmd) == 0 and execShellCmd(cmdPasswd) == 0:
        return true
    else:
        return false


proc existsUser(name: string): bool =
    ## Checks if an user exists.
    if execShellCmd("id "&name) == 0:
        return true
    else:
        return false
