#!/bin/sh
# Usage: DATE="..." ./publi.sh
set -euo pipefail
cd -- "$(dirname -- "$0")"
s=$(date -d "${DATE:-"$(date --rfc-email)"}" +%s)
y=$(date -d @$s +%Y)
f=feed/$y/$s.dat
mkdir -p feed/$y
date -d @$s --rfc-email | tee $f
if ${EDITOR:-vi} $f
then scripts/update-needs
else rm -f $f; rmdir feed/$y 2>/dev/null || :
fi
