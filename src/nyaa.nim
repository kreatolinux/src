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
include cmd/build
include cmd/install
include cmd/update
include cmd/upgrade
include cmd/remove
include cmd/info

clCfg.version = "nyaa v3.0.0-alpha"

dispatchMulti([build, help={"repo": "The nyaa repository", "packages": "The package names"}, short = { "repo": 'R'}], [install], [info], [info, cmdName="I"] ,[remove], [update], [upgrade])
