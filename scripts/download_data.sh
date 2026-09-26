#!/usr/bin/env bash
# Downloads the latest BAG exports into data/raw (the archived copies are from 26 September 2026).
set -euo pipefail
cd "$(dirname "$0")/.."
base="https://api.idd.bag.admin.ch/api/v1/export/latest"
for f in INFLUENZA_sentinella RESPVIRUSES_wastewater; do
  curl -fsSL "$base/$f/csv" -o "data/raw/$f.csv"
  curl -fsSL "$base/$f/metadata" -o "data/raw/${f}_metadata.json"
done
