#!/bin/sh
wrangler=$(command -v wrangler) || wrangler='npx wrangler'
set -e
(
	set -x
	git archive status/pages -o site.tar.gz
)
template="$(basename $0)".XXXXXXXX
set -x
tmpdir=$(mktemp -d "$template")
trap 'rm -rf "$tmpdir"' EXIT
tar xvf site.tar.gz -C "$tmpdir"
$wrangler deploy "$tmpdir" --domain status.rapidcow.org
