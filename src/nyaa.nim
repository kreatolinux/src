# depper - dependency handler for nyaa
# Copyright 2022 Kreato
#
# This file is part of Kreato Linux.
#
# Kreato Linux is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Kreato Linux is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Kreato Linux.  If not, see <https://www.gnu.org/licenses/>.
import cligen
import sequtils
include dephandler
clCfg.version = "nyaa v3.0.0-alpha"

proc install(packages: seq[string]): string =
  ## Fast and efficient package manager
  echo packages

proc build(repo="/etc/nyaa", packages: seq[string]): int =
  ## Build and install packages
  var deps: seq[string]
  var res: string
  for i in packages:
    deps = deduplicate(dephandler(i, repo).split(" "))
    res = res & deps.join(" ") & " " & i
  echo res
  result = 0

proc remove(packages: seq[string]): string = 
  ## Remove packages
  return ""

proc info(packages: seq[string]): string = 
  ## Get information about packages
  return ""

proc update(repo="/etc/nyaa"): string =
  ## Update repositories
  return ""

proc upgrade(packages="all"): string =
  ## Upgrade packages
  return ""

dispatchMulti([build, help={"repo": "The nyaa repository", "packages": "The package names"}, short = { "repo": 'R'}], [install], [info],[remove], [update], [upgrade])
