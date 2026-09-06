#!/usr/bin/env bash
# Downloads the multilingual-e5-small ONNX model druzhok's embed worker loads.
# Usage: ops/embed-model-fetch.sh <dir>   (e.g. /data/opt/embed-models/multilingual-e5-small)
set -euo pipefail
dir="${1:?target directory}"
base="https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/onnx"
mkdir -p "$dir"
for f in model.onnx tokenizer.json config.json; do
  if [ ! -s "$dir/$f" ]; then
    curl -fsSL "$base/$f" -o "$dir/$f.part"
    mv -f "$dir/$f.part" "$dir/$f"
  fi
done
ls -l "$dir"
