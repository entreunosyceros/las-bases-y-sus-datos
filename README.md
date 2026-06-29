# Las bases y sus datos
<p align="center">
<img width="455" height="412" alt="logo-gui" src="https://github.com/user-attachments/assets/56bcd84d-459e-49ad-962e-35cc150bf118" />
</p>

[![Licencia: MIT](https://img.shields.io/badge/Licencia-MIT-green.svg)](LICENSE)
![Plataformas](https://img.shields.io/badge/Plataformas-Windows%20%7C%20Linux-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)
![Python 3](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)
![GUI: PySide6](https://img.shields.io/badge/GUI-PySide6-41CD52?logo=qt&logoColor=white)
![Docker · Podman](https://img.shields.io/badge/Contenedores-Docker%20%C2%B7%20Podman-2496ED?logo=docker&logoColor=white)
[![Documentación](https://img.shields.io/badge/Documentaci%C3%B3n-docs%2F-informational)](docs/README.md)

Herramienta para **detectar, iniciar, detener, reiniciar y diagnosticar** servicios y entornos locales de bases de datos en **Windows y Linux**. Orientada a prácticas de administración de sistemas, unifica en un único menú la gestión de motores como MySQL, MariaDB, PostgreSQL, MongoDB, SQL Server, Redis y muchos más, mostrando su estado, puerto y consumo de memoria.

Fue creada originalmente para Windows a petición de Modesto; después se amplió con soporte para Linux, un lanzador multiplataforma, modo CLI/JSON y una interfaz gráfica opcional.

---

## Características destacadas

- **Multiplataforma**: scripts nativos para Windows (PowerShell) y Linux (Bash) con un lanzador común en Python.
- **Muchos motores**: MySQL/MariaDB, PostgreSQL, MongoDB, SQL Server, Redis, Elasticsearch/OpenSearch, Cassandra/ScyllaDB, CouchDB, InfluxDB, Neo4j, ClickHouse, CockroachDB, ArangoDB, Memcached, Firebird y RethinkDB.
- **Entornos locales**: XAMPP, WAMP, Laragon, MAMP, Bitnami, AMPPS, LocalWP, DevKinsta, Herd y más.
- **Contenedores**: Docker, Podman y Docker Compose.
- **Modo CLI** no interactivo con salida **JSON** para automatización.
- **Interfaz gráfica** opcional (PySide6) que reutiliza el modo CLI/JSON.
- **Comprobaciones de salud** reales, **logging**, **configuración persistente** y soporte **systemd / SysVinit / OpenRC**.

---

## Inicio rápido

### Windows

Haz doble clic en `gestor_bbdd.bat` (ejecutar como administrador) o:

```powershell
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1
```

### Linux

```bash
chmod +x gestor_bbdd.sh
sudo ./gestor_bbdd.sh
```

### Lanzador multiplataforma (Python 3)

```bash
python lanzar.py          # menú interactivo del script nativo
python lanzar.py --gui    # interfaz gráfica (requiere: pip install -r requirements.txt)
```

Más detalles en [Instalación y ejecución](docs/instalacion.md).

---

## Estructura del proyecto

```text
GESTION_BD/
├── gestor_bbdd.bat          # Lanzador Windows (pide permisos de administrador)
├── gestor_bbdd.ps1          # Gestor principal para Windows (PowerShell)
├── gestor_bbdd.sh           # Gestor principal para Linux (Bash)
├── gestor_bbdd.conf.example # Plantilla de configuración persistente
├── lanzar.py                # Lanzador multiplataforma (Python 3) + opción --gui
├── requirements.txt         # Dependencias de la GUI (PySide6)
├── gui/                     # Interfaz gráfica (PySide6) — cliente del modo CLI/JSON
├── docs/                    # Documentación detallada
└── README.md                # Este archivo
```

---

## Documentación

La documentación completa está en la carpeta [`docs/`](docs/README.md). Empieza por el índice o salta directamente a la sección que necesites:

| Sección | Contenido |
|---------|-----------|
| [Instalación y ejecución](docs/instalacion.md) | Requisitos por plataforma y formas de ejecutar la herramienta. |
| [Configuración](docs/configuracion.md) | Archivo `gestor_bbdd.conf`, rutas personalizadas y registro de actividad. |
| [Menú y funcionalidades](docs/menu.md) | Opciones del menú, modo práctica y qué detecta el script. |
| [Modo CLI](docs/cli.md) | Uso no interactivo desde terminal y salida JSON. |
| [Interfaz gráfica](docs/gui.md) | GUI en PySide6: instalación, arquitectura y pestañas. |
| [Comprobaciones de salud](docs/salud.md) | Pruebas de conectividad y *timeouts*. |
| [Contenedores y Compose](docs/contenedores.md) | Gestión de Docker, Podman y proyectos Docker Compose. |
| [Sistemas de init](docs/sistemas-init.md) | Soporte para systemd, SysVinit y OpenRC. |
| [Motores y entornos soportados](docs/motores.md) | Catálogo de motores/entornos y novedades del proyecto. |
| [Referencia](docs/referencia.md) | Diferencias entre plataformas, casos de uso, limitaciones y seguridad. |

---

## Autoría y licencia

Autor: entreunosyceros.net

Este proyecto se distribuye bajo la licencia **MIT**.
