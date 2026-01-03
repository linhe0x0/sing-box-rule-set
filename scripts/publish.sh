#!/usr/bin/env bash
set -e

rm -rf publish
mkdir -p publish/srs publish/json

# Copy all srs files from build/srs/, using geosite-original_filename format
if [ -d "build/srs" ]; then
  for file in build/srs/*.srs; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      cp "$file" "publish/srs/geosite-${filename}"
    fi
  done
fi

# Copy all json files from build/json, using geosite-original_filename format
if [ -d "build/json" ]; then
  for file in build/json/*.json; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      cp "$file" "publish/json/geosite-${filename}"
    fi
  done
fi

# Copy all srs files from source/upstream/geoip/srs, using geoip-original_filename format
if [ -d "source/upstream/geoip/srs" ]; then
  for file in source/upstream/geoip/srs/*.srs; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      cp "$file" "publish/srs/geoip-${filename}"
    fi
  done
fi

cd publish/srs && sha256sum *.srs >sha256sum.txt
