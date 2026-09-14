# Docker Engine on WSL 2 without Docker Desktop

PowerShell scripts to install and maintain Docker Engine inside Alpine Linux on WSL 2, without Docker Desktop.

All operations are performed through `bwd.ps1`. Internal scripts are located in `src/` and do not need to be invoked directly.

## Architecture

```text
Windows
├─ docker.exe / docker-compose.exe
├─ DOCKER_HOST=tcp://127.0.0.1:2376
├─ DOCKER_TLS_VERIFY=1
├─ DOCKER_CERT_PATH=<repo>\runtime\certs\client
└─ WSL 2
   └─ bare-docker
      ├─ Docker Engine managed by OpenRC
      ├─ Local TCP API protected with mutual TLS
      └─ /mnt/docker-data/docker
```

Windows provides the clients and Alpine runs the daemon. The API listens only on `127.0.0.1:2376` and requires a valid client certificate.

At startup, the manager detects an active Windows IPv4 address and configures host-gateway inside Docker Engine so containers can reach Windows-published services without relying on a hard-coded repository address.

The system and data are stored separately:

```text
runtime/
├─ bare-docker/
│  └─ ext4.vhdx
├─ data.vhdx
├─ certs/
│  └─ client/
├─ downloads/
├─ backups/
└─ logs/
```

- `bare-docker/ext4.vhdx` contains Alpine and installed packages.
- `data.vhdx` contains Docker images, containers, volumes, and metadata.
- `data.vhdx` is mounted before Docker starts. If it cannot be mounted, Docker does not start.
- `certs/client` contains the CA and certificate used by Windows clients.

The effective configuration is stored in `etc/config.json`, created from `etc/config.default.json`. Local configuration, VHDX files, certificates, downloads, backups, and logs are not versioned.

## Requirements

- Windows 11 with virtualization enabled.
- PowerShell run as administrator.
- Winget available to install the Windows Docker tools.
- Internet connection during installation and updates.

The installer can enable WSL and `VirtualMachinePlatform` when WSL is not yet operational. It requests a Windows restart only when a required change makes it necessary.

## Installation

From PowerShell as administrator:

```powershell
.\bwd.ps1 install
```

The first run asks where to create `data.vhdx`. Press Enter to accept:

```text
<repo>\runtime\data.vhdx
```

It can also be specified without a prompt:

```powershell
.\bwd.ps1 install -DataVhdxPath 'E:\Docker\data.vhdx' -NonInteractive
```

Installation:

1. verifies WSL 2 and updates its components;
2. installs `Docker.DockerCLI`, `Docker.DockerCompose`, and `Docker.docker-credential-wincred` through Winget when they are missing;
3. downloads and verifies the Alpine Mini Root Filesystem;
4. imports Alpine into `runtime\bare-docker`;
5. installs Docker Engine, Compose, OpenRC, and OpenSSL in Alpine;
6. configures Windows drives as `/c`, `/d`, etc. through `automount.root=/`;
7. enables `COMPOSE_CONVERT_WINDOWS_PATHS=1` to convert paths used by Compose;
8. creates and formats `data.vhdx` as ext4;
9. generates a CA and server and client certificates;
10. configures `DOCKER_HOST`, `DOCKER_TLS_VERIFY` and `DOCKER_CERT_PATH` for the Windows user;
11. registers the startup scheduled task;
12. validates the connection and runs `hello-world`.

Terminals opened before installation do not automatically receive the new environment variables. Open a new terminal before using the clients.

## Startup

```powershell
.\bwd.ps1 start
```

`start` mounts the data VHDX, starts Docker, and waits until both the daemon and the TLS connection from Windows are available. Installation registers `bwd.ps1 start -NonInteractive` as an elevated scheduled task at sign-in, with a default 30-second delay.

The log is stored at:

```text
runtime\logs\start.log
```

To stop Docker gracefully:

```powershell
.\bwd.ps1 stop
```

To immediately terminate the WSL distribution, interrupting in-progress operations:

```powershell
.\bwd.ps1 stop -Force
```

Restart performs a complete stop-and-start cycle. `-Force` applies to stopping:

```powershell
.\bwd.ps1 restart
.\bwd.ps1 restart -Force
```

## Automatic startup

To register or enable the scheduled task without starting Docker Engine:

```powershell
.\bwd.ps1 enable
```

`enable` reports whether the Engine is already running or remains stopped; enabling the task does not change its current state.

To disable automatic startup without stopping the Engine:

```powershell
.\bwd.ps1 disable
```

If Docker remains active, `disable` warns you. Use `stop` separately when you also want to stop it.

## Usage

From a new user terminal:

```powershell
docker info
docker run --rm hello-world
docker-compose.exe version
```

Relative bind mounts used by `docker-compose.exe` are converted from Windows paths to Alpine DrvFs mounts. For example:

```text
D:\projects\example\data → /d/projects/example/data
```

### Accessing the Windows host from a container

Docker Engine on Linux does not automatically add `host.docker.internal` to every container. Containers that need to access a service on the host must declare it using the standard `host-gateway` mechanism:

```yaml
services:
  application:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

They can then use the name without knowing the Windows address. For example:

```text
http://host.docker.internal:8096
```

`bwd.ps1 start` determines the address at each startup and generates the host-gateway-ips option in daemon.json inside bare-docker.

The Windows application must listen on a reachable address other than strict loopback, and Windows Firewall must allow the connection.

The Compose declaration is also compatible with Docker Engine on Linux and Docker Desktop on Windows or macOS; each platform resolves host-gateway to its own host.

`docker-credential-wincred.exe` lets Docker use Windows Credential Manager when `%USERPROFILE%\.docker\config.json` contains `"credsStore": "wincred"`.

## Tested third-party clients

The following external clients were tested with the mutual TLS connection configured by the installer. They are not part of the project and are not installed by these scripts:

| Cliente | Tipo | Resultado |
| --- | --- | --- |
| [LazyDocker](https://github.com/jesseduffield/lazydocker) | TUI | Compatible. |
| [Sidekick Docker for VS Code](https://marketplace.visualstudio.com/items?itemName=CesarAndresLopez.sidekick-docker-vscode) | GUI integrada en VS Code | Compatible. |

Both use the Docker interface configured through `DOCKER_HOST`, `DOCKER_TLS_VERIFY`, and `DOCKER_CERT_PATH`; neither requires a client installed inside Alpine.

## Update

```powershell
.\bwd.ps1 update
```

The update affects only Alpine and its Docker packages. Before modifying the distribution, it creates a backup in `runtime\backups`, unless specified otherwise:

```powershell
.\bwd.ps1 update -SkipBackup
```

It does not change the Alpine major branch, WSL, or Windows Winget packages.

## Uninstallation

```powershell
.\bwd.ps1 uninstall
```

The script removes the scheduled task, distribution, client certificates, and environment variables it manages. It does not uninstall Docker CLI, Compose, or Wincred from Windows.

If `data.vhdx` is found, the script asks whether to delete it; pressing Enter preserves it. To delete the data without a prompt:

```powershell
.\bwd.ps1 uninstall -DeleteDockerData
```

To also remove `etc/config.json`:

```powershell
.\bwd.ps1 uninstall -RemoveConfiguration
```

Deleting `data.vhdx` permanently destroys Docker images, containers, volumes, and metadata.

## WSL configuration

The distribution `/etc/wsl.conf` file configures `automount.root=/` to align DrvFs mounts with Docker Compose path conversion. The installer restarts only its distribution to apply the change.

Memory and swap belong to the global WSL 2 VM and are configured in `%USERPROFILE%\.wslconfig`, not in these scripts. The `WARNING: No swap limit support` message refers to per-container swap control and does not mean WSL lacks global swap.

As a reminder, after modifying `.wslconfig`, you must run `wsl --shutdown` to shut down the global WSL 2 VM and apply the new configuration at the next startup. This command stops all running distributions.

After shutting down WSL, this project Docker Engine must be started through `.\bwd.ps1 start`. Starting the distribution manually is not enough: this command attaches the data VHDX, verifies it is mounted correctly, and only then starts Docker. Without that mount, Docker cannot use its configured data-root.
