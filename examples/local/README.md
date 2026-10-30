# Local example

Applies circuit-mssql to a throwaway Rocky Linux 10 container with systemd, setting up SQL Server 2025 Developer edition with a 2048 MB memory limit. You need Conn3x and Podman, on an x86-64 Linux machine with at least 4 GB of memory: SQL Server has no arm64 build, so this won't run on a Mac with Apple silicon.

[main.tf](main.tf) sets `accept_eula = true`. Read the [SQL Server licence terms](https://go.microsoft.com/fwlink/?LinkId=746388) before you run it; applying it accepts them.

```sh
export PODMAN="sudo podman"
./up.sh
export TF_VAR_sa_password='Pick-0ne-of-your-own'
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To log in as `sa` over TCP:

```sh
sudo podman exec -e SQLCMDPASSWORD="$TF_VAR_sa_password" circuit-mssql /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -C -Q 'SELECT @@VERSION'
```

`up.sh` listens on `127.0.0.1:2291`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as `ubuntu2404` from Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
