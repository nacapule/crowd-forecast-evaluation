#!/bin/sh
# Fetch the ForecastBench files used by this project, pinned to a commit so
# the nightly-updated upstream repository cannot change our inputs.
# Requires git and git-lfs. Files land in data/raw/forecastbench/ and are
# verified against data/manifest.csv by `make fetch`.
set -e

COMMIT=0b82035c8c456ec3e0d582595195ce842c32b085
REPO=https://github.com/forecastingresearch/forecastbench-datasets.git
DEST=data/raw/forecastbench
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --quiet --no-checkout "$REPO" "$TMP/fb"
cd "$TMP/fb"
git checkout --quiet "$COMMIT" -- \
  datasets/question_sets/2024-07-21-human.json \
  datasets/resolution_sets/2024-07-21_resolution_set.json \
  datasets/forecast_sets/2024-07-21
git lfs pull --include "datasets/forecast_sets/2024-07-21/*"
cd - > /dev/null

mkdir -p "$DEST"
cp "$TMP/fb/datasets/question_sets/2024-07-21-human.json" "$DEST/"
cp "$TMP/fb/datasets/resolution_sets/2024-07-21_resolution_set.json" "$DEST/"
cp "$TMP"/fb/datasets/forecast_sets/2024-07-21/*.json "$DEST/"
echo "forecastbench files fetched at commit $COMMIT"
