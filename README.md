# Docker Engine en WSL 2 sin Docker Desktop

Scripts de PowerShell para instalar y mantener Docker Engine dentro de Alpine Linux sobre WSL 2, sin Docker Desktop.

Todas las operaciones se realizan mediante `bwd.ps1`. Los scripts internos se encuentran en `src/` y no necesitan invocarse directamente.

## Arquitectura

```text
Windows
├─ docker.exe / docker-compose.exe
├─ DOCKER_HOST=tcp://127.0.0.1:2376
├─ DOCKER_TLS_VERIFY=1
├─ DOCKER_CERT_PATH=<repo>\runtime\certs\client
└─ WSL 2
   └─ bare-docker
      ├─ Docker Engine administrado con OpenRC
      ├─ API TCP local protegida con TLS mutuo
      └─ /mnt/docker-data/docker
```

Windows conserva los clientes y Alpine ejecuta el daemon. La API solamente escucha en `127.0.0.1:2376` y exige un certificado cliente válido.

El sistema y los datos se almacenan por separado:

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

- `bare-docker/ext4.vhdx` contiene Alpine y los paquetes instalados.
- `data.vhdx` contiene imágenes, contenedores, volúmenes y metadatos de Docker.
- `data.vhdx` se monta antes de iniciar Docker. Si no puede montarse, Docker no se inicia.
- `certs/client` contiene la CA y el certificado usados por los clientes de Windows.

La configuración efectiva se guarda en `etc/config.json`, creado a partir de `etc/config.default.json`. La configuración local, los VHDX, certificados, descargas, respaldos y logs no se versionan.

## Requisitos

- Windows 11 con virtualización habilitada.
- PowerShell ejecutado como administrador.
- Winget disponible para instalar las herramientas Docker de Windows.
- Conexión a Internet durante la instalación y las actualizaciones.

El instalador puede habilitar WSL y `VirtualMachinePlatform` cuando WSL todavía no está operativo. Solo solicita reiniciar Windows cuando una modificación necesaria lo requiere.

## Instalación

Desde PowerShell como administrador:

```powershell
.\bwd.ps1 install
```

La primera ejecución pregunta dónde crear `data.vhdx`. Enter acepta:

```text
<repo>\runtime\data.vhdx
```

También puede indicarse sin diálogo:

```powershell
.\bwd.ps1 install -DataVhdxPath 'E:\Docker\data.vhdx' -NonInteractive
```

La instalación:

1. verifica WSL 2 y actualiza sus componentes;
2. instala mediante Winget `Docker.DockerCLI`, `Docker.DockerCompose` y `Docker.docker-credential-wincred` si faltan;
3. descarga y verifica Alpine Mini Root Filesystem;
4. importa Alpine en `runtime\bare-docker`;
5. instala Docker Engine, Compose, OpenRC y OpenSSL en Alpine;
6. configura las unidades Windows como `/c`, `/d`, etc. mediante `automount.root=/`;
7. activa `COMPOSE_CONVERT_WINDOWS_PATHS=1` para convertir las rutas usadas por Compose;
8. crea y formatea `data.vhdx` como ext4;
9. genera una CA y certificados de servidor y cliente;
10. configura `DOCKER_HOST`, `DOCKER_TLS_VERIFY` y `DOCKER_CERT_PATH` para el usuario de Windows;
11. registra la tarea programada de inicio;
12. valida la conexión y ejecuta `hello-world`.

Las terminales abiertas antes de la instalación no reciben automáticamente las nuevas variables de entorno. Abra una terminal nueva antes de utilizar los clientes.

## Inicio

```powershell
.\bwd.ps1 start
```

`start` monta el VHDX de datos, inicia Docker y espera a que tanto el daemon como la conexión TLS desde Windows estén disponibles. La instalación registra `bwd.ps1 start -NonInteractive` como una tarea programada elevada al iniciar sesión, con un retraso predeterminado de 30 segundos.

El log se guarda en:

```text
runtime\logs\start.log
```

Para detener Docker ordenadamente:

```powershell
.\bwd.ps1 stop
```

Para terminar inmediatamente la distribución WSL, interrumpiendo las operaciones en curso:

```powershell
.\bwd.ps1 stop -Force
```

El reinicio realiza un ciclo completo de detención e inicio. `-Force` se aplica a la detención:

```powershell
.\bwd.ps1 restart
.\bwd.ps1 restart -Force
```

## Inicio automático

Para registrar o habilitar la tarea programada sin iniciar Docker Engine:

```powershell
.\bwd.ps1 enable
```

`enable` informa si el Engine ya está funcionando o si permanece detenido; habilitar la tarea no cambia su estado actual.

Para deshabilitar el inicio automático sin detener el Engine:

```powershell
.\bwd.ps1 disable
```

Si Docker continúa activo, `disable` lo advierte. Use `stop` por separado cuando también quiera detenerlo.

## Uso

Desde una terminal nueva del usuario:

```powershell
docker info
docker run --rm hello-world
docker-compose.exe version
```

Los bind mounts relativos usados por `docker-compose.exe` se convierten de rutas Windows a los montajes DrvFs de Alpine. Por ejemplo:

```text
D:\projects\example\data → /d/projects/example/data
```

`docker-credential-wincred.exe` permite que Docker use Windows Credential Manager cuando `%USERPROFILE%\.docker\config.json` contiene `"credsStore": "wincred"`.

También se verificó la compatibilidad de esta conexión con el cliente externo [LazyDocker](https://github.com/jesseduffield/lazydocker); LazyDocker no forma parte del proyecto ni es instalado por estos scripts.

## Actualización

```powershell
.\bwd.ps1 update
```

La actualización afecta solamente a Alpine y sus paquetes Docker. Antes de modificar la distribución crea un respaldo en `runtime\backups`, salvo que se indique:

```powershell
.\bwd.ps1 update -SkipBackup
```

No cambia la rama mayor de Alpine, WSL ni los paquetes Winget de Windows.

## Desinstalación

```powershell
.\bwd.ps1 uninstall
```

El script elimina la tarea programada, la distribución, los certificados cliente y las variables de entorno que administra. No desinstala Docker CLI, Compose ni Wincred de Windows.

Si encuentra `data.vhdx`, pregunta si debe eliminarlo; Enter lo conserva. Para eliminar los datos sin preguntar:

```powershell
.\bwd.ps1 uninstall -DeleteDockerData
```

Para eliminar también `etc/config.json`:

```powershell
.\bwd.ps1 uninstall -RemoveConfiguration
```

Eliminar `data.vhdx` destruye permanentemente imágenes, contenedores, volúmenes y metadatos de Docker.

## Configuración de WSL

El archivo `/etc/wsl.conf` de la distribución configura `automount.root=/` para alinear los montajes DrvFs con la conversión de rutas de Docker Compose. El instalador reinicia únicamente su distribución para aplicar el cambio.

La memoria y el swap pertenecen a la VM global de WSL 2 y se configuran en `%USERPROFILE%\.wslconfig`, no en estos scripts. El mensaje `WARNING: No swap limit support` se refiere al control de swap por contenedor y no implica que WSL carezca de swap global.

Como recordatorio, después de modificar `.wslconfig` es necesario ejecutar `wsl --shutdown` para apagar la VM global de WSL 2 y aplicar la nueva configuración en el siguiente inicio. Este comando detiene todas las distribuciones en ejecución.

Después de apagar WSL, el Docker Engine de este proyecto debe iniciarse mediante `.\bwd.ps1 start`. No basta con iniciar la distribución manualmente: este comando adjunta el VHDX de datos, verifica que esté montado correctamente y recién entonces inicia Docker. Sin ese montaje, Docker no puede usar su `data-root` configurado.
