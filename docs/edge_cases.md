# Edge-case specification for the 2024-04-01 delta

Written **before** the incremental pipeline. Every row of both delta files is labelled with a
case and the result the mart must show after the delta is processed. The same expectations are
enforced by the assertion `definitions/tests/expected_outcomes.sqlx`, and were calculated
independently by `tests/reference/reference_model.py` (plain Python, straight from the CSV files).

Starting watermark for both sources: `2024-03-28 00:00:00` (extraction time of the initial files).
"Customer version at booking" = the `dim_customer` version valid on the booking's `created_at`
date (ASSUMPTION K3).

## Booking cases

| Case | What it is | Rows | How it is handled | Why |
|---|---|---|---|---|
| B1 | Exact duplicate row (same booking, same `updated_at`, same content) | BKG-10004, BKG-10018 (twice each) | Collapsed to one row before the MERGE | A resend must not create a second booking |
| B2 | Several versions of one booking in the same file | BKG-00002: `confirmed` at 03-28 15:00, then `cnx` at 03-29 09:12 | Keep the newest `updated_at` per booking, MERGE that one | The source's latest state is the truth; order inside the file is irrelevant |
| B3 | Row older than the watermark | BKG-00012, `updated_at` 2024-03-20 | Not read (watermark filter); also blocked by the `source_updated_at` guard during a backfill | It would turn a CHECKED_IN stay back into "confirmed": stale data must not overwrite newer data |
| B4 | Update to a booking from the initial load | BKG-00003, -00006, -00010, -00011, -00013 | MERGE `WHEN MATCHED AND newer` updates in place | Merge, not overwrite: one row per booking keeps its key |
| B5 | Late-arriving fact: new booking whose stay is in March | BKG-10048, -10049, -10050 | INSERT; March revenue changes | This is why the March number moves after the increment |
| B6 | New future booking | 40 rows, check-in April/May | INSERT | Normal daily growth |
| B7 | Booking for a customer the CRM never sent | BKG-10047 → CUST19999 | Inferred member created in `dim_customer` (`is_inferred = TRUE`) and used | The fact keeps its link to the real customer_id; when the CRM row arrives, the same row is filled in place (same key) |
| B8 | Booking for a customer who is new in the same batch | BKG-10041 to BKG-10046 → CUST10001 to CUST10006 | Customers are processed before bookings in the same transaction; the first version of a customer starts in 1900, so a booking created on 03-28 finds the customer whose CRM row is dated 03-29 | Load-order dependency inside one batch |
| B9 | Customer's tier changes after the booking was made | BKG-10017 (created 03-19) → CUST00001 (Bronze since 03-29) | Fact points at the **earlier** version (no tier) | "Join to the customer version valid at booking time" |
| B10 | New status spellings | `completed`, `cnx`, `CANCELLED`, `Checked Out` | `ref_booking_status`; an unmapped spelling would be quarantined, not guessed | |
| B11 | Revenue definition differs | New delta bookings have `TotalRevenue_IDR` **net** of `discount_pct`; initial rows are **gross**; BKG-00013 is re-sent with the discount applied | Kept as the PMS reports it, documented as ASSUMPTION K4 and question to the client | Changing revenue on our own would hide a source-system issue |

Totals: 60 rows → 57 distinct booking ids → 1 stale (B3) → 56 merged: **50 inserts, 6 updates**.
`fact_bookings` goes from 3,200 to **3,250** rows.

## Customer cases

| Case | What it is | Rows | How it is handled |
|---|---|---|---|
| C1 | Brand-new customer | CUST10001–10006 | First version inserted, valid from 1900-01-01 |
| C2 | Tier change | CUST00012 Silver→Gold, CUST00016 Bronze→Silver, CUST00020 Bronze→Silver, CUST00024 Gold→Platinum | Current version closed (`valid_to` = `updated_at`, `is_current = FALSE`), new version opened |
| C3 | Two tier changes in one batch | CUST00006 Silver→Gold (03-30 10:30)→Platinum (03-31 18:10) | Two new versions, the Gold one is kept in history. A plain "latest row wins" or a `dbt snapshot` would lose it |
| C4 | Rows out of order and duplicated | CUST00010: Platinum 03-31, Gold 03-28, Platinum 03-31 again | Sorted by `updated_at`; duplicate dropped; Gold equals the current tier so it creates nothing; one change to Platinum |
| C5 | Row that changes nothing | CUST00010's Gold row; CUST00002 (email `  customer 2@hotmail.com  ` vs `customer.2@hotmail.com`, identical after cleaning) | Nothing created, nothing updated, `updated_at` untouched |
| C6 | Type 1 change only | CUST00011: phone was empty, now `08134455667` | Updated in place on every version of the customer; no new version |
| C7 | No tier → tier | CUST00001 NULL→Bronze | Treated as a tier change (ASSUMPTION K6) |
| C8 | Tier in odd casing | `gold`, `SILVER` | `INITCAP` before comparison, so it is a real change only when the tier actually differs |
| C9 | Dirty emails in new customers | ` Customer10001@Yahoo.com ` | Cleaned the same way as the initial dump |

Totals: 18 rows → 15 customers → `dim_customer` gets **8 new versions + 6 new customers**; plus 1 inferred
member from B7. `dim_customer` goes from 801 to **816** rows (including the unknown member `-1`).

## Every row, one by one

### delta_bookings_2024-04-01.csv (line = line number in the file, header is line 1)

| Line | BookingID | updated_at | Case | Expected result in the mart |
|---|---|---|---|---|
| 2 | BKG-10032 | 2024-03-30 22:00:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-09, recognised 3,697,500; customer version at booking: no tier |
| 3 | BKG-10015 | 2024-03-31 11:27:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-16, recognised 2,890,000; customer version at booking: Gold |
| 4 | BKG-10021 | 2024-03-31 09:08:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-25, recognised 850,000; customer version at booking: Silver |
| 5 | BKG-10037 | 2024-03-30 11:23:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-05, recognised 17,100,000; customer version at booking: Gold |
| 6 | BKG-00002 | 2024-03-28 15:00:00 | B2 older version in same file | Superseded by the newer row of the same booking (dedup keeps the newest); customer version at booking: Bronze |
| 7 | BKG-00006 | 2024-03-29 11:02:00 | B4 update of an initial booking | UPDATE: status CONFIRMED->CHECKED_OUT. Recognised 26,630,805; customer version at booking: Bronze |
| 8 | BKG-10018 | 2024-03-30 18:23:00 | B1 exact duplicate (first copy) | Same row twice: one booking. INSERT CONFIRMED, 6,840,000; customer version at booking: Silver |
| 9 | BKG-00003 | 2024-03-29 10:40:00 | B4 update of an initial booking | UPDATE: status CONFIRMED->CHECKED_OUT. Recognised 39,150,734; customer version at booking: Silver |
| 10 | BKG-10047 | 2024-03-30 19:40:00 | B7 customer not in CRM | INSERT CONFIRMED, check-in 2024-04-12, recognised 15,600,000; customer version at booking: inferred member |
| 11 | BKG-10013 | 2024-03-31 16:27:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-14, recognised 17,100,000; customer version at booking: no tier |
| 12 | BKG-10017 | 2024-03-29 11:57:00 | B9 customer tier changes after booking | INSERT CONFIRMED, check-in 2024-04-01, recognised 3,600,000; customer version at booking: no tier |
| 13 | BKG-10045 | 2024-03-30 14:15:00 | B8 customer is new in this batch | INSERT CONFIRMED, check-in 2024-04-12, recognised 7,200,000; customer version at booking: Silver |
| 14 | BKG-10036 | 2024-03-31 10:52:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-12, recognised 22,680,000; customer version at booking: Gold |
| 15 | BKG-00012 | 2024-03-20 07:45:00 | B3 stale: older than watermark | Ignored. Fact keeps the initial row (CHECKED_IN, 9,754,688); customer version at booking: Bronze |
| 16 | BKG-10009 | 2024-03-29 11:28:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-25, recognised 5,200,000; customer version at booking: Bronze |
| 17 | BKG-10048 | 2024-03-29 08:05:00 | B5 late-arriving March stay | INSERT CHECKED_OUT, check-in 2024-03-22, recognised 15,600,000; customer version at booking: no tier |
| 18 | BKG-10040 | 2024-03-30 17:06:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-07, recognised 20,800,000; customer version at booking: no tier |
| 19 | BKG-10025 | 2024-03-31 20:55:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-10, recognised 5,950,000; customer version at booking: Bronze |
| 20 | BKG-10007 | 2024-03-31 17:59:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-04, recognised 1,450,000; customer version at booking: Gold |
| 21 | BKG-10019 | 2024-03-31 20:57:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-01, recognised 6,887,500; customer version at booking: Bronze |
| 22 | BKG-10020 | 2024-03-29 18:30:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-11, recognised 21,600,000; customer version at booking: Bronze |
| 23 | BKG-10028 | 2024-03-29 21:39:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-11, recognised 807,500; customer version at booking: Bronze |
| 24 | BKG-10004 | 2024-03-31 11:54:00 | B1 exact duplicate (first copy) | Same row twice: one booking. INSERT CONFIRMED, 722,500; customer version at booking: Silver |
| 25 | BKG-10034 | 2024-03-30 17:28:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-08, recognised 13,685,000; customer version at booking: Bronze |
| 26 | BKG-10029 | 2024-03-29 10:07:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-05, recognised 10,150,000; customer version at booking: Gold |
| 27 | BKG-10008 | 2024-03-29 13:52:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-23, recognised 20,800,000; customer version at booking: no tier |
| 28 | BKG-10030 | 2024-03-29 08:48:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-28, recognised 3,400,000; customer version at booking: Platinum |
| 29 | BKG-10001 | 2024-03-30 22:18:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-03, recognised 24,700,000; customer version at booking: Platinum |
| 30 | BKG-10002 | 2024-03-30 22:13:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-19, recognised 1,232,500; customer version at booking: Silver |
| 31 | BKG-10044 | 2024-03-30 13:15:00 | B8 customer is new in this batch | INSERT CONFIRMED, check-in 2024-04-14, recognised 1,700,000; customer version at booking: Silver |
| 32 | BKG-10006 | 2024-03-31 11:30:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-04, recognised 15,600,000; customer version at booking: Platinum |
| 33 | BKG-10010 | 2024-03-29 22:31:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-05, recognised 1,450,000; customer version at booking: Silver |
| 34 | BKG-10024 | 2024-03-29 15:02:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-03, recognised 2,422,500; customer version at booking: Gold |
| 35 | BKG-10049 | 2024-03-29 09:05:00 | B5 late-arriving March stay | INSERT CHECKED_OUT, check-in 2024-03-25, recognised 7,200,000; customer version at booking: no tier |
| 36 | BKG-10023 | 2024-03-30 20:18:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-23, recognised 4,600,000; customer version at booking: no tier |
| 37 | BKG-10046 | 2024-03-30 15:15:00 | B8 customer is new in this batch | INSERT CONFIRMED, check-in 2024-04-23, recognised 14,040,000; customer version at booking: Bronze |
| 38 | BKG-00010 | 2024-03-30 08:20:00 | B4 update of an initial booking | UPDATE: status CHECKED_IN->CHECKED_OUT, nights 4->6, revenue 14,529,476->21,794,214. Recognised 21,794,214; customer version at booking: no tier |
| 39 | BKG-10050 | 2024-03-29 10:05:00 | B5 late-arriving March stay | INSERT CHECKED_OUT, check-in 2024-03-27, recognised 19,760,000; customer version at booking: Silver |
| 40 | BKG-10031 | 2024-03-30 08:14:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-22, recognised 2,610,000; customer version at booking: Platinum |
| 41 | BKG-10042 | 2024-03-30 11:15:00 | B8 customer is new in this batch | INSERT CONFIRMED, check-in 2024-04-24, recognised 4,250,000; customer version at booking: Bronze |
| 42 | BKG-10026 | 2024-03-30 10:40:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-15, recognised 25,200,000; customer version at booking: Silver |
| 43 | BKG-10005 | 2024-03-30 17:02:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-17, recognised 10,260,000; customer version at booking: Bronze |
| 44 | BKG-10011 | 2024-03-30 08:17:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-02, recognised 13,260,000; customer version at booking: Bronze |
| 45 | BKG-00011 | 2024-03-30 14:55:00 | B4 update of an initial booking | UPDATE: status CONFIRMED->CANCELLED, revenue 8,019,426->0. Recognised 0; customer version at booking: no tier |
| 46 | BKG-10016 | 2024-03-29 11:44:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-18, recognised 1,615,000; customer version at booking: no tier |
| 47 | BKG-10012 | 2024-03-29 19:58:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-24, recognised 3,400,000; customer version at booking: Silver |
| 48 | BKG-00002 | 2024-03-29 09:12:00 | B2 newest of several versions | Wins: UPDATE to CANCELLED, recognised revenue 0; customer version at booking: Bronze |
| 49 | BKG-10004 | 2024-03-31 11:54:00 | B1 exact duplicate | Collapses into the row above. INSERT CONFIRMED, 722,500; customer version at booking: Silver |
| 50 | BKG-10027 | 2024-03-31 09:54:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-11, recognised 4,940,000; customer version at booking: no tier |
| 51 | BKG-10039 | 2024-03-31 10:24:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-26, recognised 13,680,000; customer version at booking: Platinum |
| 52 | BKG-10022 | 2024-03-29 22:55:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-23, recognised 3,697,500; customer version at booking: Bronze |
| 53 | BKG-10035 | 2024-03-31 15:28:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-09, recognised 6,162,500; customer version at booking: Silver |
| 54 | BKG-10041 | 2024-03-30 10:15:00 | B8 customer is new in this batch | INSERT CONFIRMED, check-in 2024-04-13, recognised 7,200,000; customer version at booking: Bronze |
| 55 | BKG-10033 | 2024-03-31 08:33:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-02, recognised 24,700,000; customer version at booking: Gold |
| 56 | BKG-10014 | 2024-03-30 08:33:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-14, recognised 13,800,000; customer version at booking: Gold |
| 57 | BKG-00013 | 2024-03-30 16:30:00 | B4 update of an initial booking | UPDATE: status CONFIRMED->CHECKED_OUT, revenue 32,509,812->29,258,830.8. Recognised 29,258,830.8; customer version at booking: no tier |
| 58 | BKG-10003 | 2024-03-30 09:11:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-04, recognised 9,180,000; customer version at booking: Gold |
| 59 | BKG-10043 | 2024-03-30 12:15:00 | B8 customer is new in this batch | INSERT CONFIRMED, check-in 2024-04-14, recognised 10,400,000; customer version at booking: Bronze |
| 60 | BKG-10038 | 2024-03-29 18:22:00 | B6 new future booking | INSERT CONFIRMED, check-in 2024-04-28, recognised 9,642,500; customer version at booking: Bronze |
| 61 | BKG-10018 | 2024-03-30 18:23:00 | B1 exact duplicate | Collapses into the row above. INSERT CONFIRMED, 6,840,000; customer version at booking: Silver |

### delta_customers_2024-04-01.csv

| Line | customer_id | updated_at | Tier in file | Case | Expected result in dim_customer |
|---|---|---|---|---|---|
| 2 | CUST10003 | 2024-03-29 12:00:00 | 'Bronze' | C1 new customer | versions: Bronze |
| 3 | CUST00006 | 2024-03-30 10:30:00 | 'Gold' | C3 two tier changes in one batch | versions: Silver > Gold > Platinum |
| 4 | CUST00011 | 2024-03-30 15:20:00 | 'Bronze' | C6 Type 1 change: phone filled in | versions: Bronze |
| 5 | CUST00012 | 2024-03-29 12:30:00 | 'gold' | C2 tier change (odd casing C8) | versions: Silver > Gold |
| 6 | CUST10005 | 2024-03-29 14:00:00 | 'Silver' | C1 new customer | versions: Silver |
| 7 | CUST00016 | 2024-03-30 13:30:00 | 'Silver' | C2 tier change | versions: Bronze > Silver |
| 8 | CUST10004 | 2024-03-29 13:00:00 | 'Silver' | C1 new customer | versions: Silver |
| 9 | CUST10001 | 2024-03-29 10:00:00 | 'Bronze' | C1 new customer | versions: Bronze |
| 10 | CUST00001 | 2024-03-29 09:30:00 | 'Bronze' | C7 no tier -> tier (K6) | versions: no tier > Bronze |
| 11 | CUST00006 | 2024-03-31 18:10:00 | 'Platinum' | C3 two tier changes in one batch | versions: Silver > Gold > Platinum |
| 12 | CUST00010 | 2024-03-31 11:30:00 | 'Platinum' | C4 exact duplicate | versions: Gold > Platinum |
| 13 | CUST10002 | 2024-03-29 11:00:00 | 'Bronze' | C1 new customer | versions: Bronze |
| 14 | CUST00010 | 2024-03-28 08:00:00 | 'Gold' | C4 out of order + C5 changes nothing | versions: Gold > Platinum |
| 15 | CUST00010 | 2024-03-31 11:30:00 | 'Platinum' | C4 exact duplicate | versions: Gold > Platinum |
| 16 | CUST00020 | 2024-03-31 14:30:00 | 'SILVER' | C2 tier change (odd casing C8) | versions: Bronze > Silver |
| 17 | CUST00002 | 2024-03-29 13:00:00 | 'Gold' | C5 only the email spelling differs; identical after cleaning | versions: Gold |
| 18 | CUST00024 | 2024-03-29 15:30:00 | 'Platinum' | C2 tier change | versions: Gold > Platinum |
| 19 | CUST10006 | 2024-03-29 15:00:00 | 'Bronze' | C1 new customer | versions: Bronze |

## Expected effect on March 2024 room revenue (check-in month, cancellations = 0)

| Hotel | Before | After | Change | Caused by |
|---|---:|---:|---:|---|
| Alaya Ubud | 1,910,826,147 | 1,918,090,885 | +7,264,738 | BKG-00010 extended from 4 to 6 nights |
| Bisma Eight | 1,979,115,598 | 1,960,167,118 | −18,948,480 | BKG-00002 cancelled (−26,148,480), BKG-10049 late stay (+7,200,000) |
| Katamama Resort | 2,234,059,430 | 2,234,059,430 | 0 | |
| Komaneka Bisma | 1,976,391,037 | 1,976,391,037 | 0 | |
| The Layar Seminyak | 1,745,556,533 | 1,745,556,533 | 0 | |
| The Mulia Nusa Dua | 2,029,483,376 | 2,064,843,376 | +35,360,000 | BKG-10048 (+15,600,000) and BKG-10050 (+19,760,000), late stays |
| **Total** | **11,875,432,121** | **11,899,108,379** | **+23,676,258** | |

Not in this table: BKG-00011 (cancelled) and BKG-00013 (discount applied, −3,250,981.2) change
**January**, not March. BKG-00012 would have changed nothing even if processed (same month), but it
is stale and is ignored.
