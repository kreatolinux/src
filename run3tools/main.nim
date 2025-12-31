import cligen
when not defined(disableGeneratecmd):
  import commands/generatecmd
import commands/generateManpagecmd
import commands/lintcmd
import commands/fmtcmd
import commands/convertcmd
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
      ],
      [
      fmt
      ],
      [
      convert
      ]
  )
else:
  dispatchMulti(
      [
      generateManpage
      ],
      [
      lint
      ],
      [
      fmt
      ],
      [
      convert
      ]
  )
