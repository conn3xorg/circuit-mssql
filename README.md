# circuit-mssql

[![Conn3x grade](https://conn3x.org/circuits/mssql/grade.svg)](https://conn3x.org/circuits/mssql/grade)

A Conn3x circuit that installs Microsoft SQL Server 2025 on Linux from Microsoft's own repositories, runs `mssql-conf setup` for you without anyone typing answers into it, and keeps its settings where you put them. If someone changes the port or the memory limit by hand, the next plan shows it.

The `sa` password never lands in state. You pass it in at run time through an ephemeral variable, it reaches `mssql-conf` through the environment rather than a command line anyone can see in `ps`, and the plan only shows that it changed.

## Licensing, before anything else

SQL Server isn't open source, and this circuit doesn't decide anything about its licence for you.

- **Accepting Microsoft's licence terms is your decision.** `accept_eula` has no default. Read the [SQL Server licence terms](https://go.microsoft.com/fwlink/?LinkId=746388) and set it to `true` only if you agree; anything else stops the plan. With `install_tools` on, the same answer accepts the licence of the Microsoft ODBC Driver for SQL Server that `sqlcmd` needs.
- **The default edition is free, for non-production use only.** `edition = "Developer"` gets you Enterprise Developer edition: every feature, licensed for development and testing. For a small production database, `"Express"` is free too, within its caps on database size, memory and cores.
- **Standard and Enterprise need a licence you've bought.** The circuit will set up `"Standard"`, `"Enterprise"` or `"EnterpriseCore"` if you ask, but it can't check you're licensed for it. That part is between you and Microsoft.

## Usage

```hcl
variable "sa_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "mssql" {
  source = "github.com/conn3xorg/circuit-mssql?ref=v0.1.0"

  hosts                = { db = "192.168.1.40" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  # You've read https://go.microsoft.com/fwlink/?LinkId=746388 and agree.
  accept_eula = true
  edition     = "Express"
  sa_password = var.sa_password

  listen_address  = "0.0.0.0"
  memory_limit_mb = 4096
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_sa_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it.

SQL Server wants a strong `sa` password: 8 to 128 characters, from at least three of capitals, small letters, digits and symbols. The circuit checks that at plan time, so a weak one stops the plan instead of failing half-way through setup.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it.

```hcl
hosts = {
  for name, d in digitalocean_droplet.db : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container on an x86-64 Linux machine first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Checks the host: Ubuntu 22.04 or 24.04, or Enterprise Linux 9 or 10, on x86-64, with at least 2000 MB of memory, which `mssql-conf setup` won't go below. Anything else stops the plan with a message before the host is touched.
2. Adds Microsoft's SQL Server 2025 repository, `packages.microsoft.com/<distro>/<version>/mssql-server-2025`, checked against Microsoft's signing keys, which ship with the circuit in [files/microsoft.asc](files/microsoft.asc). It's the cumulative update repository, so a new install gets the newest CU.
3. Installs `mssql-server`.
4. Writes the `sa` password to `/etc/conn3x/mssql/sa_password` (root only, mode 0600).
5. Writes `tcp_port`, `listen_address`, `memory_limit_mb` and `settings` with `mssql-conf set`, with SQL Server stopped. `mssql-conf` refuses to set a port the running server holds, even the one it's already on.
6. On the first apply, runs `mssql-conf -n setup` with `ACCEPT_EULA`, `MSSQL_PID` and `MSSQL_SA_PASSWORD` in its environment, which creates the system databases and starts SQL Server. On later applies, when the password, the edition or a setting changed, it stops SQL Server, runs `mssql-conf -n set-sa-password` and `mssql-conf -n set-edition`, and starts it again. Either way it starts once per apply: stopping SQL Server while it's still starting up can hang for the unit's 30-minute timeout.
7. Keeps `mssql-server` running and enabled at boot.
8. With `install_tools` on, adds Microsoft's general repository, `.../prod`, and installs `mssql-tools18` with `ACCEPT_EULA=Y`, which brings `sqlcmd`, `bcp` and the ODBC driver.

By default SQL Server listens on `127.0.0.1:1433` only, so nothing outside the host can reach it until you set `listen_address`. SQL Server on Linux takes one IPv4 address there, or `0.0.0.0` for all of them.

To log in on the host, `sqlcmd` reads the password from `SQLCMDPASSWORD`, which keeps it off the command line too:

```sh
SQLCMDPASSWORD="$(cat /etc/conn3x/mssql/sa_password)" /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -C -Q 'SELECT @@VERSION'
```

`-C` trusts the self-signed certificate SQL Server makes for itself. Put your own certificate in place before you rely on encryption from other hosts.

### Where it runs, and where it doesn't

Microsoft publishes SQL Server 2025 for Ubuntu 22.04 and 24.04 and Red Hat Enterprise Linux 9 and 10, and nothing else. The circuit takes exactly those, with Rocky Linux and AlmaLinux 9 and 10 alongside RHEL, since they install the same packages. Rocky Linux was tested; AlmaLinux and RHEL itself weren't.

- **x86-64 only.** Microsoft builds SQL Server on Linux for x86-64 alone. Its Ubuntu repository lists arm64, but carries no packages for it. On an Apple-silicon Mac or an arm64 server, the plan stops on the architecture check.
- **Debian and Fedora.** Microsoft doesn't build SQL Server for either. Use Ubuntu or Rocky Linux.
- **Ubuntu 26.04.** Not in Microsoft's list or its repositories yet.
- **SUSE.** Microsoft dropped SLES with SQL Server 2025.
- **SQL Server 2022.** Microsoft builds it for Ubuntu 22.04 and Enterprise Linux 8 and 9, not 24.04 or 10, so this circuit sticks to 2025 rather than offering a version that only half its hosts can take.

### Signing keys

Microsoft signs these repositories with two keys, and [files/microsoft.asc](files/microsoft.asc) holds both. Ubuntu's repositories carry signatures from both, and apt wants every one of them checked. Enterprise Linux 10 packages are signed with the newer key and Enterprise Linux 9 ones with the older.

| Key | Fingerprint | Expires |
| --- | --- | --- |
| Microsoft (Release signing), published as `microsoft.asc` | `BC52 8686 B50D 79E3 39D3 721C EB3E 94AD BE12 29CF` | Never |
| Microsoft Corporation - General GPG Signer, published as `microsoft-2025.asc` | `AA86 F75E 427A 19DD 3334 6403 EE4D 7792 F748 182B` | Never |

Neither key has an expiry date. If Microsoft moves to a new one, the circuit needs a release with it, or installs start failing the signature check.

### What it doesn't cover

- **Upgrades.** The circuit installs `mssql-server` when it's missing. Later cumulative updates come in with your usual `apt upgrade` or `dnf upgrade`.
- **Logins, databases and permissions.** Only `sa` is set up. Create your own logins and databases in `sqlcmd`, and give your apps a login of their own rather than `sa`.
- **Removing a setting.** Taking a key out of `settings` leaves it in `mssql.conf`. Run `mssql-conf unset` on the host first.
- **TLS certificates, SQL Server Agent jobs, Always On availability groups, full-text search and backups.** None of these are set up. `settings = { "sqlagent.enabled" = "true" }` turns the agent on.
- **Firewall.** The circuit doesn't open port 1433. The [firewall circuit](https://github.com/conn3xorg/circuit-firewall) can.
- **An existing server.** On a host where SQL Server is already set up, the first apply sets `sa`'s password and the edition to yours, and restarts it.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `accept_eula` | bool | Required | Whether you accept the SQL Server licence terms, and the ODBC driver's when `install_tools` is on. Must be `true`. |
| `edition` | string | `"Developer"` | Edition, as `MSSQL_PID`: `Developer`, `EnterpriseDeveloper` or `StandardDeveloper` (free, non-production), `Express` (free, small production), `Evaluation` (180-day trial), or `Standard`, `Enterprise` or `EnterpriseCore` (need a licence). Changing it restarts SQL Server. |
| `sa_password` | string, ephemeral | Required | Password for `sa`: 8 to 128 characters from at least three of capitals, small letters, digits and symbols. Changing it restarts SQL Server. |
| `tcp_port` | number | `1433` | TCP port SQL Server listens on. Changing it restarts SQL Server. |
| `listen_address` | string | `"127.0.0.1"` | One IPv4 address to listen on, or `"0.0.0.0"` for all. Changing it restarts SQL Server. |
| `memory_limit_mb` | number | `null` | Physical memory SQL Server may use, in MB, 2048 or more. When null, 80% of the host's memory. Changing it restarts SQL Server. |
| `settings` | map(string) | `{}` | Other `mssql-conf` settings as `section.name`, such as `{ "sqlagent.enabled" = "true" }`. Changing them restarts SQL Server. |
| `install_tools` | bool | `true` | Install `sqlcmd` and `bcp` from `mssql-tools18`. |

## Outputs

| Name | Description |
| --- | --- |
| `port` | TCP port SQL Server listens on. |
| `sqlcmd` | Path of `sqlcmd` on each host, `/opt/mssql-tools18/bin/sqlcmd`, or null when `install_tools` is off. |

## Requirements

Requires Conn3x v0.6.9 or later, and on each host systemd, an x86-64 processor, at least 2 GB of memory and access to `packages.microsoft.com` and the distribution's package mirrors.

## Tested on

Ubuntu 24.04, Ubuntu 22.04, Rocky Linux 10 and Rocky Linux 9, on DigitalOcean droplets with 2 vCPUs and 4 GB, with SQL Server 2025 CU10 (17.0.5035.5). On each, the circuit installed and set up SQL Server listening on `127.0.0.1:1433` with a 2048 MB memory limit, the second plan had no changes, and `sa` logged in over TCP with `sqlcmd`, created a database and a table, wrote a row and read it back after a restart. On Ubuntu 24.04 and Rocky Linux 10, a second apply moved SQL Server from Developer to Express edition, to port 1533 on every address, and back to `127.0.0.1:1433` with a new `sa` password, and each change showed up on the server. All four came back after a reboot with SQL Server running, the row still there and the second plan clean. Both Rocky Linux droplets ran with SELinux enforcing, and their audit logs had no denials.

CI applies [examples/local](examples/local) to Ubuntu 24.04 and Rocky Linux 10 containers on GitHub's x86-64 runners, checks the second plan has no changes, then runs the same `sqlcmd` checks. Those containers can't run on an Apple-silicon Mac, so CI hadn't run when v0.1.0 was tagged; the droplet runs above are what this release rests on.

## License

MPL-2.0. See [LICENSE](LICENSE). SQL Server itself is proprietary Microsoft software under its own licence terms.
