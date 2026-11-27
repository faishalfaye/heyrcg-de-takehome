// Raw tables are created by scripts/load_raw.py, not by Dataform.
// Declaring them lets SQLX files use ${ref(constants.RAW, "bookings")} and lets
// Dataform draw them in the dependency graph.
["bookings", "customers", "pos_transactions", "marketing_performance", "file_manifest"].forEach((name) => {
  declare({
    schema: constants.RAW,
    name,
    description: name === "file_manifest"
      ? "One row per loaded file (name, MD5, row count). Written by load_raw.py, processed_at set by incremental_load."
      : `Raw ${name} rows, every source column as STRING, plus _source_file, _source_row, _loaded_at.`,
  });
});
