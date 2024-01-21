import cligen
import commands/generatecmd
import commands/generateManpage
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
