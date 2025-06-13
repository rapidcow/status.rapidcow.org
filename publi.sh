#!/bin/sh
# Usage: DATE="..." ./publi.sh
set -euo pipefail
s=$(date -d "${DATE:-"$(date --rfc-email)"}" +%s)
date -d @$s --rfc-email | tee data/$s.dat &&
${EDITOR:-vi} data/$s.dat || rm date/$s.dat
