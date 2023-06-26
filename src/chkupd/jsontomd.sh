#!/bin/sh
# Simple script to convert chkupd json to markdown.
SUCCESSFUL_PKG_COUNT="$(cat $1 | jq -r .successfulPkgCount)"
FAILED_PKG_COUNT="$(cat $1 | jq -r .failedPkgCount)"
FAILED_BUILD_PACKAGES="$(cat $1 | jq -r .failedBuildPackages)"
FAILED_UPD_PACKAGES="$(cat $1 | jq -r .failedUpdPackages)"

echo "# chkupd automatic update report"
echo
echo "$SUCCESSFUL_PKG_COUNT packages autoupdated successfully. $FAILED_PKG_COUNT packages failed to autoupdate."
echo
echo "# Packages that failed to build"
echo "$FAILED_BUILD_PACKAGES"
echo
echo "# Packages that failed to autoupdate"
echo "$FAILED_UPD_PACKAGES"
