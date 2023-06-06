#!/bin/sh

SCRIPTDIR=$(dirname "$0")

"${SCRIPTDIR}/soundness.sh"

if [ "$(uname)" = Darwin ]; then
    swift test
else
    swift build
fi