output "address" {
  description = "host:port for REDIS_ADDR."
  value       = "${google_redis_instance.this.host}:${google_redis_instance.this.port}"
}
