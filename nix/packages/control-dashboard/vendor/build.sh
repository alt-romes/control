#!/bin/sh
# Rebuild ../app/js: nix-shell -p nodejs --run ./build.sh
set -e
cd "$(dirname "$0")"
npm ci --no-audit --no-fund
rm -rf ../app/js
npx esbuild vendor.js --bundle --format=esm --minify --legal-comments=none --outdir=../app/js
touch ../app/Views.hs # embedDir only notices changed files, not new ones
