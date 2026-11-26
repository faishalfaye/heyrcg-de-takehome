"""
Independent reference model ("oracle") for the HeyRCG pipeline.

Why this file exists
--------------------
The Dataform/BigQuery pipeline is the real implementation. This script re-implements
the same business rules in plain Python, straight from the CSV files, so that we have a
second, independent answer to compare against. If BigQuery and this script agree on the
numbers, we can trust both a lot more than either one alone.

It prints:
  1. the expected outcome for every row in the two delta files (used in docs/edge_cases.md)
  2. expected row counts for the mart after the initial load and after the increment
  3. monthly room revenue by hotel for March 2024, before and after the increment
  4. an out-of-order check: delta processed in reverse order + backfill == in-order

Run:  python3 tests/reference/reference_model.py
No dependencies beyond the Python standard library.
"""
import csv
import re
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

DATA = Path(__file__).resolve().parents[2] / "data"
SNAPSHOT_TS = datetime(2024, 3, 28, 0, 0, 0)   # initial extraction time = starting watermark
LOW_TS, HIGH_TS = datetime(1900, 1, 1), datetime(9999, 12, 31)
FX = {"IDR": 1, "USD": 15800, "AUD": 10200, "SGD": 11700}  # implied by the source data

STATUS_MAP = {
    "confirmed": "CONFIRMED", "confirm": "CONFIRMED",
    "checked in": "CHECKED_IN", "checkedin": "CHECKED_IN", "checked_in": "CHECKED_IN", "checked-in": "CHECKED_IN",
    "checked out": "CHECKED_OUT", "checkedout": "CHECKED_OUT", "checked_out": "CHECKED_OUT",
    "completed": "CHECKED_OUT",                      # ASSUMPTION K7: completed = stay finished
    "cancelled": "CANCELLED", "canceled": "CANCELLED", "cancel": "CANCELLED", "cnx": "CANCELLED",
    "no_show": "NO_SHOW", "noshow": "NO_SHOW", "no-show": "NO_SHOW", "no show": "NO_SHOW",
}
NON_REVENUE_STATUSES = {"CANCELLED", "NO_SHOW"}       # ASSUMPTION K5
TIERS = {"bronze": "Bronze", "silver": "Silver", "gold": "Gold", "platinum": "Platinum"}
EMAIL_RE = re.compile(r"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$")


def read(name):
    with open(DATA / name, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def blank(v):
    v = (v or "").strip()
    return v or None


# --------------------------------------------------------------------------- customers
def clean_email(raw):
    v = blank(raw)
    if v is None:
        return None, False
    v = re.sub(r"\s+", ".", v.lower())               # 'customer 2@x.com' -> 'customer.2@x.com'
    return (v, True) if EMAIL_RE.match(v) else (None, False)


def clean_customer(r):
    email, ok = clean_email(r["email"])
    tier = blank(r["loyalty_tier"])
    return {
        "customer_id": blank(r["customer_id"]).upper(),
        "full_name": blank(r["full_name"]),
        "email": email,
        "email_valid": ok,
        "phone": blank(r["phone"]),
        "city": blank(r["city"]),
        "nationality": blank(r["nationality"]),
        "loyalty_tier": TIERS.get(tier.lower()) if tier else None,
        "joined_date": blank(r["joined_date"]),
        "updated_at": datetime.fromisoformat(r["updated_at"]) if blank(r.get("updated_at")) else None,
    }


TYPE1 = ("full_name", "email", "phone", "city", "nationality", "joined_date")


def initial_customers():
    """One row per customer_id. Ranking: valid email, most complete row, then email A-Z."""
    by_id = defaultdict(list)
    for r in read("raw_customers.csv"):
        c = clean_customer(r)
        by_id[c["customer_id"]].append(c)
    out = {}
    for cid, rows in by_id.items():
        rows.sort(key=lambda c: (not c["email_valid"],
                                 -sum(c[k] is not None for k in TYPE1 + ("loyalty_tier",)),
                                 c["email"] or "~"))
        out[cid] = rows[0]
    return out, sum(len(v) - 1 for v in by_id.values())


def build_versions(history):
    """history: list of (ts, cleaned_row) for ONE customer. Returns SCD2 versions.

    Same rule as the SQL: sort by time, a new version starts whenever loyalty_tier differs
    from the previous row (NULL is a real value), the first version starts at 1900-01-01,
    and Type 1 attributes always come from the latest row."""
    history = sorted(history, key=lambda x: x[0])
    latest = history[-1][1]
    versions, prev_tier = [], object()
    for ts, row in history:
        if row["loyalty_tier"] != prev_tier:
            versions.append({"valid_from": LOW_TS if not versions else ts, "loyalty_tier": row["loyalty_tier"]})
            prev_tier = row["loyalty_tier"]
    for i, v in enumerate(versions):
        v["valid_to"] = versions[i + 1]["valid_from"] if i + 1 < len(versions) else HIGH_TS
        v["is_current"] = i + 1 == len(versions)
        v.update({k: latest[k] for k in TYPE1})
    return versions


# --------------------------------------------------------------------------- bookings
def clean_booking(r):
    status_raw = r["booking_status"].strip()
    status = STATUS_MAP.get(status_raw.lower())
    ci, co, n = date.fromisoformat(r["CheckInDate"]), date.fromisoformat(r["check_out_date"]), int(r["nights"])
    fix = None
    if co < ci:
        if (ci - co).days == n:
            ci, co, fix = co, ci, "DATES_SWAPPED"
        else:
            co, fix = ci + timedelta(days=n), "CHECKOUT_RECOMPUTED"
    total = float(r["TotalRevenue_IDR"]) if blank(r["TotalRevenue_IDR"]) else None
    derived = total is None
    if derived:
        total = round(float(r["RatePerNight"]) * n * FX[r["Currency"].strip().upper()], 2)
    recognised = 0.0 if status in NON_REVENUE_STATUSES else total
    return {
        "booking_id": r["BookingID"].strip().upper(), "hotel": r["hotel_name"].strip(),
        "customer_id": (blank(r["customer_id"]) or "").upper() or None,
        "check_in": ci, "check_out": co, "nights": n, "status": status, "status_raw": status_raw,
        "room_revenue": total, "recognised_revenue": recognised, "revenue_derived": derived,
        "date_fix": fix, "created": date.fromisoformat(r["created_at"]),
        "updated_at": datetime.fromisoformat(r["updated_at"]) if blank(r.get("updated_at")) else None,
    }


def content(b):
    """Business content of a row (same idea as row_hash in SQL): ignores timestamps and raw spellings."""
    return tuple(v for k, v in sorted(b.items()) if k not in ("updated_at", "status_raw"))


# --------------------------------------------------------------------------- pipeline
class Mart:
    def __init__(self):
        snap, self.customer_dupes = initial_customers()
        self.snapshot = snap
        self.cust_delta_rows = defaultdict(list)          # customer_id -> [(ts,row)] received so far
        self.dim = {cid: build_versions([(SNAPSHOT_TS, row)]) for cid, row in snap.items()}
        self.inferred = set()
        self.facts = {}                                   # booking_id -> (source_ts, booking)
        for r in read("raw_bookings.csv"):
            b = clean_booking(r)
            self.facts[b["booking_id"]] = (SNAPSHOT_TS, b)
        self.wm = {"bookings": SNAPSHOT_TS, "customers": SNAPSHOT_TS}

    def run_incremental(self, cust_rows, book_rows, backfill_from=None):
        log = []
        wm_c = backfill_from or self.wm["customers"]
        wm_b = backfill_from or self.wm["bookings"]
        # 1) customers: every received row is kept; customers touched by this batch are recomputed
        batch_c = [clean_customer(r) for r in cust_rows]
        batch_c = [c for c in batch_c if c["updated_at"] > wm_c]
        affected = set()
        for c in batch_c:
            key = (c["updated_at"], content({k: v for k, v in c.items()}))
            if key not in {(t, content(x)) for t, x in self.cust_delta_rows[c["customer_id"]]}:
                self.cust_delta_rows[c["customer_id"]].append((c["updated_at"], c))
            affected.add(c["customer_id"])
        for cid in affected:
            hist = [(SNAPSHOT_TS, self.snapshot[cid])] if cid in self.snapshot else []
            hist += [(t, x) for t, x in self.cust_delta_rows[cid] if t > SNAPSHOT_TS]
            self.dim[cid] = build_versions(hist)
            self.inferred.discard(cid)
        if batch_c:
            self.wm["customers"] = max(self.wm["customers"], max(c["updated_at"] for c in batch_c))
        # 2) bookings: dedup to latest row per key, then guarded upsert
        batch_b = [clean_booking(r) for r in book_rows]
        candidates = [b for b in batch_b if b["updated_at"] > wm_b]
        latest = {}
        for b in sorted(candidates, key=lambda b: (b["updated_at"], str(content(b)))):
            latest[b["booking_id"]] = b
        for bid, b in latest.items():
            if b["customer_id"] and b["customer_id"] not in self.dim:
                self.dim[b["customer_id"]] = build_versions([(SNAPSHOT_TS, {**{k: None for k in TYPE1}, "loyalty_tier": None})])
                self.inferred.add(b["customer_id"])
            old = self.facts.get(bid)
            if old is None:
                self.facts[bid] = (b["updated_at"], b); log.append((bid, "INSERT"))
            elif b["updated_at"] > old[0]:
                changed = content(b) != content(old[1])
                self.facts[bid] = (b["updated_at"], b); log.append((bid, "UPDATE" if changed else "TOUCH"))
            else:
                log.append((bid, "IGNORED_OLDER"))
        if candidates:
            self.wm["bookings"] = max(self.wm["bookings"], max(b["updated_at"] for b in candidates))
        return log

    def customer_version_at(self, cid, ts):
        for v in self.dim.get(cid, []):
            if v["valid_from"] <= ts < v["valid_to"]:
                return v
        return None

    def revenue_by_hotel_month(self, year, month):
        out = defaultdict(float)
        for _, b in self.facts.values():
            if b["check_in"].year == year and b["check_in"].month == month:
                out[b["hotel"]] += b["recognised_revenue"]
        return dict(out)

    def fingerprint(self):
        dim = tuple(sorted(
            (cid, tuple(tuple(sorted((k, str(val)) for k, val in v.items())) for v in vs))
            for cid, vs in self.dim.items()))
        facts = tuple(sorted((bid, str(ts), content(b)) for bid, (ts, b) in self.facts.items()))
        return dim, tuple(sorted(self.inferred)), facts


def fmt(x):
    return f"{x:,.0f}".replace(",", ".")


def main():
    dc, db = read("delta_customers_2024-04-01.csv"), read("delta_bookings_2024-04-01.csv")
    m = Mart()
    print(f"Initial: customers in CRM file={len(read('raw_customers.csv'))}, duplicate rows removed={m.customer_dupes}, "
          f"dim_customer rows={sum(len(v) for v in m.dim.values())}, fact_bookings rows={len(m.facts)}")
    fixes = defaultdict(int)
    for _, b in m.facts.values():
        if b["date_fix"]: fixes[b["date_fix"]] += 1
    print("  date fixes:", dict(fixes), " derived revenue:", sum(b["revenue_derived"] for _, b in m.facts.values()))
    disc = sum(float(r["RatePerNight"]) * int(r["nights"]) * FX[r["Currency"]] * float(r["discount_pct"] or 0)
               for r in read("raw_bookings.csv") if STATUS_MAP[r["booking_status"].strip().lower()] not in NON_REVENUE_STATUSES)
    print("  discount NOT subtracted in initial TotalRevenue_IDR (non-cancelled):", fmt(disc))

    before = m.revenue_by_hotel_month(2024, 3)
    log = m.run_incremental(dc, db)
    after = m.revenue_by_hotel_month(2024, 3)
    print("\nBooking actions:", sorted(log))
    print("Watermarks after run 1:", m.wm)
    for cid in sorted({r["customer_id"] for r in dc} | m.inferred):
        print(" ", cid, "inferred" if cid in m.inferred else "",
              [(v["loyalty_tier"], str(v["valid_from"]), str(v["valid_to"]), v["email"]) for v in m.dim[cid]])
    print("After increment: dim_customer rows=", sum(len(v) for v in m.dim.values()), " fact_bookings rows=", len(m.facts))
    print("\nMarch 2024 recognised room revenue by hotel (check-in month):")
    for h in sorted(set(before) | set(after)):
        print(f"  {h:22s} before={fmt(before.get(h,0)):>15s} after={fmt(after.get(h,0)):>15s} delta={fmt(after.get(h,0)-before.get(h,0)):>13s}")
    print(f"  {'TOTAL':22s} before={fmt(sum(before.values())):>15s} after={fmt(sum(after.values())):>15s} delta={fmt(sum(after.values())-sum(before.values())):>13s}")

    fp1 = m.fingerprint(); m.run_incremental(dc, db); fp2 = m.fingerprint()
    print("\nIdempotent (run twice):", fp1 == fp2)

    # out-of-order: split delta at 2024-03-30 00:00, process the later half first, then the earlier half with backfill
    cut = "2024-03-30 00:00:00"
    late_c, early_c = [r for r in dc if r["updated_at"] >= cut], [r for r in dc if r["updated_at"] < cut]
    late_b, early_b = [r for r in db if r["updated_at"] >= cut], [r for r in db if r["updated_at"] < cut]
    m2 = Mart(); m2.run_incremental(late_c, late_b); m2.run_incremental(early_c, early_b, backfill_from=SNAPSHOT_TS)
    m3 = Mart(); m3.run_incremental(late_c, late_b); m3.run_incremental(early_c, early_b)  # no backfill
    print("Out-of-order + backfill == in-order:", m2.fingerprint() == fp1)
    print("Out-of-order WITHOUT backfill == in-order:", m3.fingerprint() == fp1)


if __name__ == "__main__":
    main()
