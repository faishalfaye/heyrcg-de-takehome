#!/usr/bin/env python3
"""
split_delta.py: build the "tomorrow's file arrives before today's" test case.

Splits each delta file in two at updated_at = 2024-03-30 00:00:00:
  data/out_of_order/delta_<source>_2024-03-29.csv   rows before the cut ("today")
  data/out_of_order/delta_<source>_2024-03-31.csv   rows from the cut on ("tomorrow")
The scenario then loads and processes the 03-31 file FIRST. See docs/decisions.md D11.

    python3 scripts/split_delta.py
"""
import csv
from pathlib import Path

CUT = "2024-03-30 00:00:00"
OUT = Path("data/out_of_order")

OUT.mkdir(parents=True, exist_ok=True)
for source in ("bookings", "customers"):
    with open(f"data/delta_{source}_2024-04-01.csv", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        header = reader.fieldnames
    early = [r for r in rows if r["updated_at"] < CUT]
    late = [r for r in rows if r["updated_at"] >= CUT]
    for day, part in (("2024-03-29", early), ("2024-03-31", late)):
        with open(OUT / f"delta_{source}_{day}.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
            writer.writeheader()
            writer.writerows(part)
    print(f"{source}: {len(early)} early rows, {len(late)} late rows")
