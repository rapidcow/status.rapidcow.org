#!/bin/sh
# Usage: DATE="..." ./publi.sh
set -euo pipefail
s=$(date -d "$DATE" +%s)
date -d @$s --rfc-email | tee data/$s.dat &&
${EDITOR:-vi} data/$s.dat
