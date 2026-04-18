# Glue Data Catalog database. Holds metadata pointers for Iceberg tables.
# No tables are created here — Spark creates them via CREATE TABLE IF NOT EXISTS
# so the Iceberg schema, partition spec, and sort order live with the writer.
resource "aws_glue_catalog_database" "this" {
  name        = var.database_name
  description = "Glue catalog namespace for Iceberg tables populated from the gharchive pipeline. Tables are managed by the Spark writer, not Terraform."
}
