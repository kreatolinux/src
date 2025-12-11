import cligen
when not defined(disableGeneratecmd):
  import commands/generatecmd
import commands/generateManpagecmd
import ../common/version

clCfg.version = "genpkglist "&ver

when not defined(disableGeneratecmd):
  dispatchMulti(
      [
      generate
      ],
      [
      generateManpage
      ]
  )
else:
  dispatchMulti(
      [
      generateManpage
      ]
  )
