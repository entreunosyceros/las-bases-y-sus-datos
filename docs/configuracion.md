[🏠 Documentación](README.md) › **Configuración**

# Configuración

La herramienta intenta localizar automáticamente las instalaciones y los archivos de configuración en las rutas estándar de cada sistema. Además, ofrece tres mecanismos para afinar la detección y un registro de actividad opcional.

---

## Archivo de configuración persistente (`gestor_bbdd.conf`)

Copia `gestor_bbdd.conf.example` como `gestor_bbdd.conf` en una de estas ubicaciones:

| Prioridad | Linux | Windows |
|-----------|-------|---------|
| 1 (forzada) | Ruta en `GESTOR_BD_CONF` | Ruta en `GESTOR_BD_CONF` |
| 2 | Junto al script | Junto al script |
| 3 | `~/.config/gestor_bbdd.conf` | `%APPDATA%\gestor_bbdd.conf` |

**Claves soportadas:**

| Clave | Descripción | Por defecto |
|-------|-------------|-------------|
| `MAX_ACTIVOS` | Máximo de BD activas a la vez | `2` |
| `EXTRA_PATHS` | Rutas extra de búsqueda (`:` Linux, `;` Windows) | vacío |
| `TERMINAL` | Emulador de terminal preferido (Linux) | auto |
| `IGNORAR_MOTORES` | Motores a excluir, separados por coma | vacío |
| `HEALTH_TIMEOUT` | Segundos de espera en health checks | `3` |
| `LOG_ENABLED` | Activar registro (`true`/`false`) | `false` |
| `LOG_FILE` | Ruta del archivo de log | vacío |

**Precedencia:** valores por defecto del script → `gestor_bbdd.conf` → variables de entorno (`GESTOR_BD_MAX_ACTIVOS`, `GESTOR_BD_EXTRA_PATHS`, etc.).

---

## Rutas de búsqueda adicionales

Puedes indicar rutas extra donde buscar entornos y ejecutables mediante la variable de entorno `GESTOR_BD_EXTRA_PATHS`:

```bash
# Linux (rutas separadas por ':')
export GESTOR_BD_EXTRA_PATHS="/datos/mis-bd:/opt/stacks/mixampp"
sudo -E bash gestor_bbdd.sh
```

```powershell
# Windows (rutas separadas por ';')
$env:GESTOR_BD_EXTRA_PATHS = "D:\Servidores\mysql;E:\stacks\laragon"
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1
```

---

## Detección de configuración real en uso (Linux)

En Linux, cuando un motor está en ejecución, el script analiza la línea de comandos del proceso (`/proc/<PID>/cmdline`) para detectar el archivo de configuración que está usando realmente, aunque no esté en una ruta estándar. Reconoce, entre otros:

- `mysqld --defaults-file=/ruta/my.cnf`
- `postgres -D /ruta/datadir`
- `mongod --config /ruta/mongod.conf`
- `redis-server /ruta/redis.conf`

---

## Registro de actividad (logging)

Activa el log en `gestor_bbdd.conf`:

```ini
LOG_ENABLED=true
LOG_FILE=/var/log/gestor_bbdd.log
```

En Windows, una ruta típica sería `C:\Logs\gestor_bbdd.log`.

Se registran acciones como: inicio/parada/reinicio de servicios y entornos, comprobaciones de salud, exportación de diagnósticos y operaciones sobre contenedores Docker/Podman.

En la [interfaz gráfica](gui.md) la pestaña **Logs** muestra el final de este archivo si está configurado.

---

[🏠 Índice](README.md) · [⬅ Anterior: Instalación y ejecución](instalacion.md) · [Siguiente: Menú y funcionalidades ➡](menu.md)
