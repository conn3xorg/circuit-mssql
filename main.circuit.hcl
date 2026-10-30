# Facts give each host's distribution, which picks Microsoft's repository
# and its signing key, its architecture, since Microsoft builds SQL Server
# for x86-64 only, and its memory, since SQL Server won't set up with less
# than 2 GB.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
    postcondition {
      condition     = contains(keys(local.release), self.os_family == "debian" ? "${self.os_id}-${self.os_version}" : "el-${split(".", self.os_version)[0]}")
      error_message = "Host ${each.key} is ${self.os_id} ${self.os_version}. Microsoft publishes SQL Server 2025 for Ubuntu 22.04 and 24.04 and Enterprise Linux 9 and 10 only."
    }
    postcondition {
      condition     = self.arch == "x86_64"
      error_message = "Host ${each.key} is ${self.arch}. Microsoft builds SQL Server on Linux for x86-64 only."
    }
    postcondition {
      condition     = self.memory_mb >= 2000
      error_message = "Host ${each.key} has ${self.memory_mb} MiB of memory. SQL Server needs at least 2000 MB to set up."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  # Microsoft signs Ubuntu's repositories with both its 2015 and 2025 keys,
  # and apt wants both. Enterprise Linux 10 packages carry the 2025 key and
  # Enterprise Linux 9 ones the 2015 key. files/microsoft.asc holds both.
  release = {
    "ubuntu-24.04" = { path = "ubuntu/24.04", suite = "noble" }
    "ubuntu-22.04" = { path = "ubuntu/22.04", suite = "jammy" }
    "el-10"        = { path = "rhel/10", suite = null }
    "el-9"         = { path = "rhel/9", suite = null }
  }
  repo = { for name, f in data.conn3x_host.facts : name => local.release[f.os_family == "debian" ? "${f.os_id}-${f.os_version}" : "el-${split(".", f.os_version)[0]}"] }

  conf_file = "/var/opt/mssql/mssql.conf"
  password  = "/etc/conn3x/mssql/sa_password"

  # mssql-conf takes section.name; mssql.conf holds name = value under
  # [section].
  settings = merge(
    var.settings,
    { "network.tcpport" = tostring(var.tcp_port) },
    { "network.ipaddress" = var.listen_address },
    var.memory_limit_mb == null ? {} : { "memory.memorylimitmb" = tostring(var.memory_limit_mb) },
  )
}

circuit "mssql" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Microsoft's CU repository for SQL Server 2025: the newest cumulative
  # update on install, and later ones through apt or dnf.
  step "repo" {
    repository {
      name   = "mssql-server-2025"
      url    = "https://packages.microsoft.com/${local.repo[each.key].path}/mssql-server-2025"
      key    = file("${path.module}/files/microsoft.asc")
      suites = local.repo[each.key].suite == null ? null : [local.repo[each.key].suite]
    }
  }

  step "server" {
    package {
      name = "mssql-server"
    }
  }

  step "password_dir" {
    directory {
      path = dirname(local.password)
      mode = "0700"
    }
  }

  # The password lands in a root-only file, never in state or the plan.
  step "password" {
    file {
      path       = local.password
      content_wo = var.sa_password
    }
  }

  # Settings go in with SQL Server stopped: mssql-conf won't set a port the
  # running server holds, even its own. It's one step, since two mssql-conf
  # runs at once each rewrite mssql.conf and one loses the other's change.
  # A setting mssql-conf refuses still exits 0, so unless, which reads the
  # file, is what catches it. The setup step below starts the server again,
  # so it starts once per apply: stopping one that is still starting can
  # hang for the unit's 30-minute timeout.
  step "settings" {
    command {
      command = join("\n", concat(
        ["set -e", "systemctl stop mssql-server"],
        [for k, v in local.settings : "/opt/mssql/bin/mssql-conf set ${k} ${v}"],
      ))
      unless = join(" && ", [
        for k, v in local.settings :
        "awk -F ' *= *' -v s='${split(".", k)[0]}' -v k='${split(".", k)[1]}' -v v='${v}' '/^\\[/ { sec = substr($1, 2, length($1) - 2) } sec == s && $1 == k && $2 == v { f = 1 } END { exit !f }' ${local.conf_file}"
      ])
    }
    depends_on = [conn3x_package.mssql__server]
  }

  # mssql-conf reads the password from its environment, so it never shows
  # in ps. The first run sets SQL Server up and starts it. Later runs, when
  # the password, edition or settings changed, set the password and edition
  # on the stopped server and start it. reset-failed clears systemd's
  # three-starts-in-two-minutes limit, which a quick second apply can hit.
  step "setup" {
    command {
      command = <<-EOT
        set -e
        ACCEPT_EULA=Y
        MSSQL_PID='${var.edition}'
        MSSQL_SA_PASSWORD=$(cat ${local.password})
        export ACCEPT_EULA MSSQL_PID MSSQL_SA_PASSWORD
        if [ -e /var/opt/mssql/data/master.mdf ]; then
          systemctl stop mssql-server
          /opt/mssql/bin/mssql-conf -n set-sa-password
          /opt/mssql/bin/mssql-conf -n set-edition
          systemctl reset-failed mssql-server
          systemctl start mssql-server
        else
          /opt/mssql/bin/mssql-conf -n setup
        fi
      EOT
      triggers = {
        password = conn3x_file.mssql__password[each.key].revision
        edition  = var.edition
        settings = conn3x_command.mssql__settings[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "mssql-server"
      state   = "started"
      enabled = true
    }
  }
}

# sqlcmd and bcp. Both come from Microsoft's general repository, and the
# ODBC driver they pull in asks for its own licence through ACCEPT_EULA.
circuit "mssql_tools" {
  hosts = var.install_tools ? var.hosts : {}

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # After the server's repository and package, since apt-get update while
  # the other repository's files are being written fails.
  step "repo" {
    depends_on = [conn3x_package.mssql__server]
    repository {
      name   = "microsoft-prod"
      url    = "https://packages.microsoft.com/${local.repo[each.key].path}/prod"
      key    = file("${path.module}/files/microsoft.asc")
      suites = local.repo[each.key].suite == null ? null : [local.repo[each.key].suite]
    }
  }

  step "tools" {
    command {
      command = local.family[each.key] == "debian" ? "ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y mssql-tools18 unixodbc" : "ACCEPT_EULA=Y dnf install -y mssql-tools18 unixODBC"
      creates = "/opt/mssql-tools18/bin/sqlcmd"
    }
    depends_on = [conn3x_repository.mssql_tools__repo]
  }
}
