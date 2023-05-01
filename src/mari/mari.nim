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
import options, asyncdispatch, httpbeast, os, strutils

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    var path = getEnv("path", "/var/cache/kpkg/archives")
    if fileExists(path & $req.path.get()):
      req.send(readFile(path & $req.path.get()))
    else:
      req.send(Http404)

run(onRequest, initSettings(port = Port(parseInt(getEnv("port", "8080")))))
