#!/bin/sh
wrangler=$(command -v wrangler) || wrangler='npx wrangler'
set -e
(
	set -x
	git archive pages -o site.tar.gz
)
template="$(basename $0)".XXXXXXXX
set -x
tmpdir=$(mktemp -d "$template")
trap 'rm -rf "$tmpdir"' EXIT
tar xvf site.tar.gz -C "$tmpdir"
$wrangler deploy --assets "$tmpdir" \
	--compatibility-date 2026-05-27 \
	--domain status.rapidcow.org \
	--name rc-status
