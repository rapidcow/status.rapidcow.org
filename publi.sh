#!/usr/bin/env bash
# Usage: DATE="..." ./publi.sh
set -euo pipefail
cd -- "$(dirname -- "$0")"
# ugh whose idea was it to use set -u?! >:c
if [ -z "${GNU_DATE:-}" ]; then
	GNU_DATE=$(command -v gdate || command -v date)
fi
${GNU_DATE} --version 2>/dev/null | grep -F 'date (GNU coreutils)' >/dev/null ||
	{ echo >&2 "E: GNU date not found"; exit 1; }
s=$(${GNU_DATE} -d "${DATE:-"$(${GNU_DATE} --rfc-email)"}" +%s)
y=$(${GNU_DATE} -d @$s +%Y)
f=feed/$y/$s.dat
mkdir -p feed/$y
${GNU_DATE} -d @$s --rfc-email | tee $f
if ${EDITOR:-vi} $f
then
	scripts/update-needs
else
	rm -f $f
	rmdir feed/$y 2>/dev/null || :
fi
