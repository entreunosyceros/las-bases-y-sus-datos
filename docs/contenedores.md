[🏠 Documentación](README.md) › **Contenedores y Compose**

# Contenedores y Docker Compose

## Gestión de contenedores Docker/Podman

La **opción 12** del menú (o los parámetros CLI `--containers`, `--container-start`, etc.) permite:

- Listar contenedores de BD detectados por imagen o nombre.
- Iniciar, detener o reiniciar un contenedor por su nombre.

Funciona con **Docker** y **Podman**. Los contenedores se filtran automáticamente si su imagen o nombre contiene patrones de motores de BD conocidos (MySQL, PostgreSQL, MongoDB, Redis, etc.).

---

## Gestión de proyectos Docker Compose

La **opción 14** del menú (o los parámetros CLI `--compose-list`, `--compose-up`, `--compose-down`) permite:

- Detectar proyectos locales con `docker-compose.yml`, `compose.yml` o variantes `.yaml` que incluyan servicios de BD.
- Levantar un stack con `docker compose up -d`.
- Detener un stack con `docker compose down`.

La búsqueda se limita a directorios de desarrollo habituales (no recorre todo `$HOME` ni `%USERPROFILE%`, que incluiría `~/.cache`, `AppData`, etc. y ralentizaría el menú):

- **Linux**: el directorio del script, `~/projects`, `~/dev`, `~/git`, `~/repos`, `~/code`, `~/src`, `~/docker`, `~/workspace`, `/opt`, `/srv` y las rutas extra de `GESTOR_BD_EXTRA_PATHS`.
- **Windows**: el directorio del script, `%USERPROFILE%\Projects`, `source\repos`, `dev`, `git`, `repos`, `code`, `Documents\GitHub`, `C:\opt`, `C:\srv`, `C:\projects`, `C:\dev`, `C:\docker` y las rutas extra.

La profundidad de búsqueda está acotada (`maxdepth 3` / `-Depth 3`) para no penalizar la respuesta del menú interactivo en discos lentos.

Funciona con **Docker Compose V2** (`docker compose`) y el binario clásico `docker-compose`.

---

[🏠 Índice](README.md) · [⬅ Anterior: Comprobaciones de salud](salud.md) · [Siguiente: Sistemas de init ➡](sistemas-init.md)
