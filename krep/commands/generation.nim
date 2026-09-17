## File generation adapters. No CLI dispatch occurs when imported.
import ./matrixcmd
import ./generatecmd
import ./generateManpagecmd

proc matrix*(repo: string, limit = 256, splitIfLimit = true,
    output = "out.json") =
  ## Generate a CI build matrix for a repository.
  generateJson(repo, limit, splitIfLimit, output)

proc markdown*(pkgPath = "", output = "", all = false, verbose = false) =
  ## Generate package documentation in Markdown.
  generate(pkgPath, output, all, verbose)

proc manpage*(file: string, output: string) =
  ## Generate website Markdown from a Markdown manpage.
  generateManpage(file, output)
