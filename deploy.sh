#!/bin/sh
set -e -x
git archive status/pages -o site.tar.gz
hut pages publish site.tar.gz -d status.rapidcow.org
