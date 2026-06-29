[🏠 Documentación](README.md) › **Instalación y ejecución**

# Instalación y ejecución

## Requisitos

### Windows

- Windows 10/11 o Windows Server.
- PowerShell disponible.
- Permisos de administrador para iniciar/detener servicios.

### Linux

- Distribución Linux con `systemd`, `OpenRC` o `SysVinit` (ver [Sistemas de init](sistemas-init.md)).
- Bash y herramientas estándar: `systemctl`/`rc-service`, `ss` o `netstat`, `ps`, `pgrep`, `kill`, `nohup`.
- Permisos de root para iniciar/detener servicios.

### Lanzador multiplataforma

- Python 3 instalado.

### Interfaz gráfica (opcional)

- Python 3 y **PySide6** (`pip install -r requirements.txt`).

### Motores/entornos compatibles (opcionales)

- MySQL o MariaDB, PostgreSQL, MongoDB, SQL Server
- Redis, Elasticsearch / OpenSearch, Cassandra / ScyllaDB
- CouchDB, InfluxDB, Neo4j, ClickHouse, CockroachDB, ArangoDB
- Memcached, Firebird, RethinkDB
- XAMPP / LAMPP, WAMP, Laragon, MAMP, Bitnami, EasyPHP, Devilbox, DDEV
- AMPPS, Local (LocalWP), DevKinsta, Laravel Herd, ServBay, Lando
- UwAmp, WPN-XM, OpenServer (Windows)
- Docker / Podman

Consulta el catálogo completo en [Motores y entornos soportados](motores.md).

---

## Ejecución

### Windows

La forma recomendada es hacer doble clic en `gestor_bbdd.bat` y ejecutarlo como administrador.

También puedes ejecutar directamente el script de PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1
```

### Linux

Primero dale permisos de ejecución al script:

```bash
chmod +x gestor_bbdd.sh
```

Después ejecútalo con permisos de root:

```bash
sudo ./gestor_bbdd.sh
```

O directamente con Bash:

```bash
sudo bash gestor_bbdd.sh
```

### Lanzador multiplataforma

Desde cualquiera de los dos sistemas operativos, si tienes Python 3 instalado:

```bash
python lanzar.py
# o
python3 lanzar.py
```

En Linux, si no eres root, el lanzador intentará elevar privilegios automáticamente con `sudo` o `pkexec`.

### Interfaz gráfica

```bash
pip install -r requirements.txt
python lanzar.py --gui
```

Más información en [Interfaz gráfica (GUI)](gui.md).

---

[🏠 Índice](README.md) · [⬅ README principal](../README.md) · [Siguiente: Configuración ➡](configuracion.md)
