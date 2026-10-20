output "connection_name" {
  description = "PROJECT:REGION:INSTANCE, the Cloud SQL Auth Proxy target."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip" {
  description = "Private IP of the instance."
  value       = google_sql_database_instance.this.private_ip_address
}

output "database_name" {
  description = "Application database name."
  value       = google_sql_database.app.name
}

output "iam_user_names" {
  description = "Database user names created for the IAM service accounts."
  value       = [for u in google_sql_user.iam : u.name]
}
