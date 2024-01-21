import cligen
import commands/generatecmd
import commands/generateManpagecmd
import ../common/version

clCfg.version = "genpkglist "&ver

dispatchMulti(
    [
    generate
    ],
    [
    generateManpage
    ]
)
