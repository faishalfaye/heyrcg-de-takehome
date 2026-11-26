#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# split_delta.sh: build the "tomorrow's file arrives before today's" test case.
# Splits each delta file in two at updated_at = 2024-03-30 00:00:00:
#   data/out_of_order/delta_<source>_2024-03-29.csv  (rows before the cut: "today")
#   data/out_of_order/delta_<source>_2024-03-31.csv  (rows from the cut on: "tomorrow")
# The scenario then loads and processes the 03-31 file FIRST. See docs/decisions.md D11.
# -----------------------------------------------------------------------------
set -euo pipefail
CUT="2024-03-30 00:00:00"
OUT=data/out_of_order
mkdir -p "$OUT"
for src in bookings customers; do
  in="data/delta_${src}_2024-04-01.csv"
  # updated_at is the last column in both delta files
  awk -F',' -v cut="$CUT" -v early="$OUT/delta_${src}_2024-03-29.csv" -v late="$OUT/delta_${src}_2024-03-31.csv" '
    NR==1 { print > early; print > late; next }
    { if ($NF < cut) print > early; else print > late }' "$in"
  echo "$src: $(($(wc -l < "$OUT/delta_${src}_2024-03-29.csv")-1)) early rows, $(($(wc -l < "$OUT/delta_${src}_2024-03-31.csv")-1)) late rows"
done
