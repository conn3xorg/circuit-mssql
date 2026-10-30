variable "port" {
  type    = number
  default = 2291
}

variable "sa_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "mssql" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # You've read https://go.microsoft.com/fwlink/?LinkId=746388 and agree.
  accept_eula = true
  edition     = "Developer"
  sa_password = var.sa_password

  memory_limit_mb = 2048
}
