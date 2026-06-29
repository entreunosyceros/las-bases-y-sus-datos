[🏠 Documentación](README.md) › **Motores y entornos soportados**

# Motores y entornos soportados

## Motores de bases de datos

| Motor | Puerto | Detección |
|-------|--------|-----------|
| MySQL / MariaDB | 3306 | servicio, proceso, configuración y cliente `mysql` |
| PostgreSQL | 5432 | servicio, proceso, configuración y cliente `psql` |
| MongoDB | 27017 | servicio, proceso, configuración y cliente `mongosh` |
| SQL Server | 1433 | servicio y puerto |
| Redis | 6379 | servicio, proceso, configuración y cliente `redis-cli` |
| Elasticsearch / OpenSearch | 9200 | servicio, configuración y puerto |
| Cassandra / ScyllaDB | 9042 | servicio, configuración y puerto |
| CouchDB | 5984 | servicio, proceso, configuración y acceso HTTP |
| InfluxDB | 8086 | servicio, configuración y cliente `influx` |
| Neo4j | 7474 | servicio, configuración y `cypher-shell` / Neo4j Browser |
| ClickHouse | 8123 | servicio, configuración y cliente `clickhouse-client` |
| CockroachDB | 26257 | servicio y cliente `cockroach sql` |
| ArangoDB | 8529 | servicio, configuración y cliente `arangosh` / panel web |
| Memcached | 11211 | servicio, configuración y acceso vía `nc`/`telnet` |
| Firebird | 3050 | servicio, configuración y cliente `isql` |
| RethinkDB | 28015 | servicio, configuración y panel web |

---

## Entornos y distribuciones locales

- **Bitnami** — stacks de BD en Windows (`C:\Bitnami`) y Linux (`/opt/bitnami`).
- **EasyPHP** — entorno de desarrollo PHP para Windows.
- **Devilbox** — entorno Docker para desarrollo web.
- **DDEV** — herramienta de desarrollo local (Linux).
- **AMPPS** — stack AMP multiplataforma.
- **Local** (Local by Flywheel / LocalWP) — entorno local para WordPress.
- **DevKinsta** — entorno local para WordPress de Kinsta.
- **Laravel Herd** — entorno PHP ligero.
- **ServBay / Lando** — entornos de desarrollo locales (detección).
- **UwAmp / WPN-XM / OpenServer** — stacks AMP para Windows.
- **Snap y Flatpak** — paquetes de bases de datos en Linux.
- **Docker y Podman** — detección de contenedores de BD activos.
- **Docker Compose** — detección de proyectos locales.

Además: XAMPP / LAMPP, WAMP, Laragon y MAMP.

---

## Novedades y evolución del proyecto

### Soporte para Linux

Script Bash (`gestor_bbdd.sh`) que replica las funcionalidades del de Windows adaptadas a Linux:

- Gestiona servicios con `systemctl` (también OpenRC/SysVinit, ver [Sistemas de init](sistemas-init.md)).
- Comprueba puertos con `ss` o `netstat`.
- Usa `ps`, `pgrep`, `pidof`, `kill` y `nohup` para trabajar con procesos.
- Lee `/proc/<PID>/status` para calcular el consumo de RAM.
- Detecta entornos locales en rutas típicas de Linux (`/opt/lampp`, `/opt/xampp`, etc.).
- Menú interactivo con colores y las mismas opciones que la versión Windows.

### Lanzador multiplataforma

`lanzar.py` detecta el sistema operativo y ejecuta el gestor correspondiente; en Linux eleva privilegios con `sudo` o `pkexec` si es necesario. Admite `--gui` para abrir la [interfaz gráfica](gui.md).

### Más motores y entornos

Ambos scripts se ampliaron para detectar todos los motores y entornos de las tablas anteriores.

### Otras mejoras

- Más versiones de MongoDB Server detectadas en archivos de configuración (6.0, 7.0, 8.0, 8.2).
- Detección de archivos de configuración para todos los motores soportados.
- Detección de configuraciones **personalizadas** vía `/proc/<PID>/cmdline` en Linux (ver [Configuración](configuracion.md)).
- Variable de entorno `GESTOR_BD_EXTRA_PATHS` para rutas de búsqueda adicionales.
- **Archivo de configuración persistente** `gestor_bbdd.conf`.
- **Comprobaciones de salud reales** (ver [Comprobaciones de salud](salud.md)).
- **Modo CLI** no interactivo con salida **JSON** (ver [Modo CLI](cli.md)).
- **Registro de actividad** configurable.
- **Gestión de contenedores** Docker/Podman y **Docker Compose** (ver [Contenedores y Compose](contenedores.md)).
- **Soporte SysVinit/OpenRC** además de systemd.
- **Interfaz gráfica** opcional (PySide6).
- **Exportación de diagnóstico** a archivo de texto.
- Cambio de puerto asistido para Redis y CouchDB, e instrucciones para los nuevos motores.
- Modo práctica que incluye MySQL + MongoDB + Redis.

---

## Función de cada archivo

### `gestor_bbdd.ps1`

Script principal de Windows. Detecta servicios (`Get-Service`), busca entornos locales en todas las unidades, inicia/detiene/reinicia servicios (`Start-Service`, `Stop-Service`, `Restart-Service`), diagnostica conflictos de puertos con `netstat`, resetea la contraseña root de MySQL/MariaDB, abre terminales de clientes y detecta contenedores Docker/Podman.

### `gestor_bbdd.bat`

Lanzador de Windows: comprueba permisos de administrador, se relanza con `RunAs` si hace falta y ejecuta `gestor_bbdd.ps1` con `-ExecutionPolicy Bypass`.

### `gestor_bbdd.sh`

Script principal de Linux, equivalente Bash de `gestor_bbdd.ps1`: detecta servicios del sistema de init, busca entornos locales, gestiona servicios, diagnostica puertos con `ss`/`netstat`, resetea contraseñas, abre terminales de clientes y detecta paquetes Snap/Flatpak, contenedores Docker/Podman y proyectos Docker Compose.

### `lanzar.py`

Lanzador multiplataforma. Detecta el SO con `platform.system()`: en Windows abre `gestor_bbdd.bat`; en Linux ejecuta `gestor_bbdd.sh` (elevando privilegios con `sudo`/`pkexec` si es necesario). Con `--gui` abre la interfaz gráfica.

### `gui/`

Interfaz gráfica en PySide6 (ver [Interfaz gráfica](gui.md)).

---

[🏠 Índice](README.md) · [⬅ Anterior: Sistemas de init](sistemas-init.md) · [Siguiente: Referencia ➡](referencia.md)
