#!/bin/sh
set -e
git archive status/pages -o site.tar.gz
hut pages publish site.tar.gz -d status.rapidcow.org
