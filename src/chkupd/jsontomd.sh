#!/bin/sh
# Simple script to convert chkupd json to markdown.
echo "# chkupd automatic update report"
echo
echo "$(cat $1 | jq -r .[].successfulPkgCount) packages updated successfully. $(cat $1 | jq -r .[].failedPkgCount) packages failed to autoupdate."
echo
echo "# Packages that failed to build"
for i in $(cat $1 | jq -r .[].failedBuildPackages[]); do
        echo "* $(basename $i)"
done
echo
echo "# Packages that failed to autoupdate"
for i in $(cat $1 | jq -r .[].failedUpdPackages[]); do
        echo "* $(basename $i)"
done
