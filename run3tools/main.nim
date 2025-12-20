import cligen
when not defined(disableGeneratecmd):
  import commands/generatecmd
import commands/generateManpagecmd
import commands/lintcmd
import ../common/version

clCfg.version = "run3tools "&ver

when not defined(disableGeneratecmd):
  dispatchMulti(
      [
      generate
      ],
      [
      generateManpage
      ],
      [
      lint
      ]
  )
else:
  dispatchMulti(
      [
      generateManpage
      ],
      [
      lint
      ]
  )
