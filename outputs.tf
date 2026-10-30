output "port" {
  description = "TCP port SQL Server listens on."
  value       = var.tcp_port
}

output "sqlcmd" {
  description = "Path of sqlcmd on each host, or null when install_tools is off."
  value       = var.install_tools ? "/opt/mssql-tools18/bin/sqlcmd" : null
}
