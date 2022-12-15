# nyaa3 - Simple, efficient and fast package manager
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
include nyaa/build
include nyaa/update
include nyaa/upgrade
include nyaa/remove
include nyaa/info

clCfg.version = "nyaa v3.0.0-rc2"

dispatchMulti([build, help = {"repo": "The nyaa repository",
    "packages": "The package names"}, short = {"repo": 'R'}], [install], [info],
    [remove], [update], [upgrade])
