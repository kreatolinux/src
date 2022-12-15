proc dephandler(pkg: string, repo: string): string =
    var deps: string
    try:
        for i in lines repo&"/"&pkg&"/deps":
            deps = dephandler(i, repo)&" "&i&" "&deps
        return deps
    except Exception:
        discard
