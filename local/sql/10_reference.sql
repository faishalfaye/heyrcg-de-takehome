-- Port of definitions/reference/*.sqlx (same values)
CREATE OR REPLACE TABLE heyrcg_stg.ref_hotel AS
SELECT * FROM (VALUES
  ('ALAYA_UBUD', 'Alaya Ubud'), ('BISMA_EIGHT', 'Bisma Eight'), ('KATAMAMA_RESORT', 'Katamama Resort'),
  ('KOMANEKA_BISMA', 'Komaneka Bisma'), ('THE_LAYAR_SEMINYAK', 'The Layar Seminyak'),
  ('THE_MULIA_NUSA_DUA', 'The Mulia Nusa Dua')
) AS v(hotel_code, hotel_name);

CREATE OR REPLACE TABLE heyrcg_stg.ref_outlet_hotel AS
SELECT * FROM (VALUES
  ('Alaya Cafe', 'Alaya Ubud'), ('Alaya Sky Bar', 'Alaya Ubud'),
  ('Bisma Restaurant', 'Bisma Eight'), ('Bisma Rooftop', 'Bisma Eight'),
  ('Katamama Dining', 'Katamama Resort'), ('Katamama Lobby Bar', 'Katamama Resort'),
  ('Komaneka Kitchen', 'Komaneka Bisma'), ('Komaneka Tea Lounge', 'Komaneka Bisma'),
  ('Mulia Gelato', 'The Mulia Nusa Dua'), ('Mulia Lounge', 'The Mulia Nusa Dua'), ('Mulia Soleil', 'The Mulia Nusa Dua'),
  ('The Layar - Main Bar', 'The Layar Seminyak'), ('The Layar - Pool Bar', 'The Layar Seminyak'),
  ('The Layar - Restaurant', 'The Layar Seminyak')
) AS v(outlet_name, hotel_name);

CREATE OR REPLACE TABLE heyrcg_stg.ref_booking_status AS
SELECT * FROM (VALUES
  ('confirmed', 'CONFIRMED'), ('confirm', 'CONFIRMED'),
  ('checked in', 'CHECKED_IN'), ('checkedin', 'CHECKED_IN'), ('checked_in', 'CHECKED_IN'), ('checked-in', 'CHECKED_IN'),
  ('checked out', 'CHECKED_OUT'), ('checkedout', 'CHECKED_OUT'), ('checked_out', 'CHECKED_OUT'),
  ('completed', 'CHECKED_OUT'),
  ('cancelled', 'CANCELLED'), ('canceled', 'CANCELLED'), ('cancel', 'CANCELLED'), ('cnx', 'CANCELLED'),
  ('no_show', 'NO_SHOW'), ('noshow', 'NO_SHOW'), ('no-show', 'NO_SHOW'), ('no show', 'NO_SHOW')
) AS v(status_key, booking_status);

CREATE OR REPLACE TABLE heyrcg_stg.ref_pos_item AS
SELECT * FROM (VALUES
  ('beefburger', 'Beef Burger', 'Food'), ('caesarsalad', 'Caesar Salad', 'Food'),
  ('clubsandwich', 'Club Sandwich', 'Food'), ('fishchips', 'Fish & Chips', 'Food'),
  ('nasigoreng', 'Nasi Goreng', 'Food'), ('nasigorengspesial', 'Nasi Goreng Spesial', 'Food'),
  ('pastacarbonara', 'Pasta Carbonara', 'Food'),
  ('bintangbeer', 'Bintang Beer', 'Beverage'), ('cocktail', 'Cocktail', 'Beverage'), ('coctail', 'Cocktail', 'Beverage'),
  ('coffee', 'Coffee', 'Beverage'), ('coffeehot', 'Coffee', 'Beverage'), ('coffie', 'Coffee', 'Beverage'),
  ('kopi', 'Coffee', 'Beverage'), ('freshjuice', 'Fresh Juice', 'Beverage'), ('smoothie', 'Smoothie', 'Beverage'),
  ('sparklingwater', 'Sparkling Water', 'Beverage'),
  ('chocolatelavacake', 'Chocolate Lava Cake', 'Dessert'), ('icecream', 'Ice Cream', 'Dessert'),
  ('tiramisu', 'Tiramisu', 'Dessert')
) AS v(item_key, item_name, category);

CREATE OR REPLACE TABLE heyrcg_stg.ref_payment_method AS
SELECT * FROM (VALUES
  ('cash', 'CASH', 'CASH'), ('cc', 'CREDIT_CARD', 'CARD'), ('creditcard', 'CREDIT_CARD', 'CARD'),
  ('gopay', 'GOPAY', 'E_WALLET'), ('ovo', 'OVO', 'E_WALLET'), ('dana', 'DANA', 'E_WALLET')
) AS v(payment_key, payment_method, payment_type);

CREATE OR REPLACE TABLE heyrcg_stg.ref_fx_rate AS
SELECT currency, CAST(idr_per_unit AS DECIMAL(38, 9)) AS idr_per_unit FROM (VALUES
  ('IDR', 1), ('USD', 15800), ('AUD', 10200), ('SGD', 11700)
) AS v(currency, idr_per_unit);
