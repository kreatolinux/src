import osproc

proc update(repo="https://github.com/kreatolinux/nyaa-repo.git", path="/etc/nyaa"): string =
  ## Update repositories
  if dirExists(path):
    discard execProcess("git pull", path)
  else:
    discard execProcess("git clone "&repo, path)
  
  result = "Updated all repositories."
