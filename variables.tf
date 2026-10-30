variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["ubuntu", "rocky", "almalinux", "rhel", "centos"], try(h.os, "ubuntu"))])
    error_message = "A host object's os must be one of ubuntu, rocky, almalinux, rhel or centos."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "accept_eula" {
  type        = bool
  description = "Whether you accept the SQL Server licence terms, and those of the ODBC driver when install_tools is on. Read them first; the circuit won't set SQL Server up unless this is true."

  validation {
    condition     = var.accept_eula == true
    error_message = "SQL Server won't set up without accepting its licence terms. Read them at https://go.microsoft.com/fwlink/?LinkId=746388, then set accept_eula = true if you agree."
  }
}

variable "edition" {
  type        = string
  default     = "Developer"
  description = "Edition to set up, as MSSQL_PID: \"Developer\", \"EnterpriseDeveloper\" or \"StandardDeveloper\" for non-production use, \"Express\" for small production databases, \"Evaluation\" for a 180-day trial, or \"Standard\", \"Enterprise\" or \"EnterpriseCore\", which need a licence you've bought. Changing it restarts SQL Server."

  validation {
    condition     = contains(["Developer", "EnterpriseDeveloper", "StandardDeveloper", "Express", "Evaluation", "Standard", "Enterprise", "EnterpriseCore"], var.edition)
    error_message = "edition must be one of Developer, EnterpriseDeveloper, StandardDeveloper, Express, Evaluation, Standard, Enterprise or EnterpriseCore."
  }
}

variable "sa_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for the sa login. Pass it at run time with -var or TF_VAR_sa_password; it never reaches state or the plan. SQL Server wants 8 to 128 characters from at least three of: capitals, small letters, digits and symbols. Changing it restarts SQL Server."

  validation {
    condition = length(var.sa_password) >= 8 && length(var.sa_password) <= 128 && length([
      for re in ["[A-Z]", "[a-z]", "[0-9]", "[^A-Za-z0-9]"] : re if can(regex(re, var.sa_password))
    ]) >= 3
    error_message = "sa_password must be 8 to 128 characters long, with characters from at least three of: capitals, small letters, digits and symbols. SQL Server refuses anything weaker."
  }
}

variable "tcp_port" {
  type        = number
  default     = 1433
  description = "TCP port SQL Server listens on. Changing it restarts SQL Server."

  validation {
    condition     = var.tcp_port >= 1 && var.tcp_port <= 65535 && floor(var.tcp_port) == var.tcp_port
    error_message = "tcp_port must be a port number from 1 to 65535."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "IPv4 address SQL Server listens on, such as \"127.0.0.1\", \"10.0.0.5\" or \"0.0.0.0\" for every address. Changing it restarts SQL Server."

  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$", var.listen_address))
    error_message = "listen_address must be one IPv4 address, such as \"127.0.0.1\" or \"0.0.0.0\". SQL Server on Linux takes one address, IPv4 only."
  }
}

variable "memory_limit_mb" {
  type        = number
  default     = null
  description = "Physical memory SQL Server may use, in MB. When null, SQL Server takes 80% of the host's memory. Changing it restarts SQL Server."

  validation {
    condition     = var.memory_limit_mb == null || (coalesce(var.memory_limit_mb, 0) >= 2048 && floor(coalesce(var.memory_limit_mb, 0)) == coalesce(var.memory_limit_mb, 0))
    error_message = "memory_limit_mb must be a whole number of MB, 2048 or more."
  }
}

variable "settings" {
  type        = map(string)
  default     = {}
  description = "Other mssql-conf settings, as section.name, such as { \"sqlagent.enabled\" = \"true\", \"filelocation.defaultbackupdir\" = \"/srv/backup\" }. Changing them restarts SQL Server."

  validation {
    condition     = alltrue([for k, v in var.settings : can(regex("^[a-z]+\\.[a-z0-9]+$", k)) && can(regex("^[A-Za-z0-9_./:-]+$", v))])
    error_message = "Setting names are section.name in lowercase, such as \"sqlagent.enabled\", and values use letters, digits and _ . / : - only."
  }

  validation {
    condition     = length(setintersection(keys(var.settings), ["network.tcpport", "network.ipaddress", "memory.memorylimitmb"])) == 0
    error_message = "Set network.tcpport, network.ipaddress and memory.memorylimitmb with tcp_port, listen_address and memory_limit_mb."
  }
}

variable "install_tools" {
  type        = bool
  default     = true
  description = "Install sqlcmd and bcp from mssql-tools18, with the Microsoft ODBC driver they need."
}
