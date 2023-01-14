proc addUser(name: string, path = "/"): bool =
    ## Adds an user.
    var cmd = "useradd -M -r -s /bin/nologin "&name
    var cmdPasswd = "passwd -d "&name

    if path != "/":
        cmd = "chroot "&path&" /usr/sbin/"&cmd
        cmdPasswd = "chroot "&path&" /usr/sbin/"&cmdPasswd

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
