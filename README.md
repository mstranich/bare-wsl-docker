# Docker Engine en WSL 2 sin Docker Desktop

Scripts de PowerShell para instalar y mantener Docker Engine dentro de una distribución Alpine Linux en WSL 2, sin instalar Docker Desktop.

## Arquitectura

```text
Windows
├─ docker.exe / docker-compose.exe
├─ DOCKER_HOST=ssh://dockerd-wsl
└─ WSL 2
   └─ Alpine-Dockerd
      ├─ Docker Engine
      ├─ OpenSSH
      └─ /mnt/docker-data/docker
```

El sistema y los datos se almacenan por separado:

```text
runtime/
├─ dockerd/
│  └─ ext4.vhdx
└─ data.vhdx
```

- `ext4.vhdx` contiene Alpine y los paquetes instalados.
- `data.vhdx` contiene imágenes, contenedores, volúmenes y metadatos de Docker.
- `data.vhdx` se monta antes de iniciar Docker. Si no puede montarse, Docker no se inicia.

La configuración efectiva se guarda en `etc/config.json`, creado a partir de `etc/config.default.json`. El archivo efectivo, los VHDX, las descargas, los respaldos y los logs no se versionan.

## Requisitos

- Windows 11 con virtualización habilitada.
- PowerShell ejecutado como administrador.
- Winget disponible si faltan las herramientas Docker de Windows.
- Conexión a Internet durante la instalación y las actualizaciones.

El instalador puede habilitar WSL y `VirtualMachinePlatform` cuando WSL todavía no está operativo. Solo solicita reiniciar cuando una modificación necesaria lo requiere.

## Instalación

Desde PowerShell como administrador:

```powershell
Set-Location D:\wsl\dockerd
.\install.ps1
```

La primera ejecución pregunta dónde crear `data.vhdx`. Enter acepta:

```text
<repo>\runtime\data.vhdx
```

También puede indicarse sin diálogo:

```powershell
.\install.ps1 -DataVhdxPath 'E:\Docker\data.vhdx' -NonInteractive
```

La instalación:

1. verifica WSL 2 y OpenSSH Client;
2. instala mediante Winget `Docker.DockerCLI`, `Docker.DockerCompose` y `Docker.docker-credential-wincred` si faltan;
3. descarga y verifica Alpine Mini Root Filesystem;
4. importa Alpine en `runtime\dockerd`;
5. crea y formatea `data.vhdx` como ext4;
6. instala Docker Engine, Compose y OpenSSH en Alpine;
7. configura acceso SSH mediante una clave dedicada;
8. establece `DOCKER_HOST=ssh://dockerd-wsl` para el usuario de Windows;
9. registra la tarea programada de inicio;
10. valida la instalación ejecutando `hello-world`.

Las terminales abiertas antes de la instalación no reciben automáticamente el nuevo `DOCKER_HOST`. Abra una terminal nueva antes de utilizar `docker.exe`.

## Inicio

```powershell
.\start.ps1
```

`start.ps1` monta el VHDX de datos, inicia SSH y Docker, y valida la conexión desde Windows. La instalación registra este script como una tarea programada elevada, ejecutada al iniciar sesión con un retraso predeterminado de 30 segundos.

El log se guarda en:

```text
runtime\logs\start.log
```

## Uso

Desde una terminal nueva del usuario:

```powershell
docker info
docker run --rm hello-world
docker-compose.exe version
```

Los clientes de Windows se conectan mediante SSH. No se expone la API de Docker por TCP sin autenticación.

## Actualización

```powershell
.\update.ps1
```

La actualización afecta solamente a Alpine y sus paquetes Docker. Antes de modificar la distribución crea un respaldo en `runtime\backups`, salvo que se indique:

```powershell
.\update.ps1 -SkipBackup
```

No cambia la rama mayor de Alpine, WSL ni los paquetes Winget de Windows.

## Desinstalación

```powershell
.\uninstall.ps1
```

El script elimina la tarea programada, la distribución, las claves SSH administradas, su configuración y `DOCKER_HOST`. Si encuentra `data.vhdx`, pregunta si debe eliminarlo; Enter lo conserva.

Para eliminar los datos sin preguntar:

```powershell
.\uninstall.ps1 -DeleteDockerData
```

Para eliminar también `etc/config.json`:

```powershell
.\uninstall.ps1 -RemoveConfiguration
```

Eliminar `data.vhdx` destruye permanentemente imágenes, contenedores, volúmenes y metadatos de Docker.

## Configuración de WSL

La memoria y el swap pertenecen a la VM global de WSL 2 y se configuran en `%USERPROFILE%\.wslconfig`, no en estos scripts. El mensaje `WARNING: No swap limit support` se refiere al control de swap por contenedor y no implica que WSL carezca de swap global.

Los cambios en `.wslconfig` requieren detener todas las distribuciones mediante `wsl --shutdown` antes de volver a ejecutar `start.ps1`.
