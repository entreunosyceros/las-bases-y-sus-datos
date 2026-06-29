[🏠 Documentación](README.md) › **Referencia**

# Referencia

## Diferencias entre plataformas

| Característica | Windows | Linux |
|----------------|---------|-------|
| Gestión de servicios | `Get-Service`, `Start-Service`, `Stop-Service` | `systemctl` / `rc-service` / `/etc/init.d` |
| Detección de procesos | `Get-Process` | `ps`, `pgrep` |
| Puertos | `netstat -ano` | `ss -tlnp` / `netstat -tlnp` |
| Memoria RAM | `WorkingSet` de `Get-Process` | `/proc/<PID>/status` (`VmRSS`) |
| Elevación de privilegios | UAC (`RunAs`) | `sudo` / `pkexec` |
| Entornos locales | Unidades `C:`, `D:`, etc., `Program Files`, `%LOCALAPPDATA%` | `/opt`, `/srv`, `$HOME` |
| Clientes de BD | `mysql.exe`, `psql.exe`, `mongosh.exe`, `redis-cli.exe`, ... | `mysql`, `psql`, `mongosh`, `redis-cli`, ... |
| Contenedores | Docker, Podman | Docker, Podman, Docker Compose |
| Salida CLI JSON | `-Json` | `--json` |
| Rutas personalizadas | `GESTOR_BD_EXTRA_PATHS` (`;`) | `GESTOR_BD_EXTRA_PATHS` (`:`) + `/proc/<PID>/cmdline` |
| Configuración manual | `services.msc`, `sc config` | `systemctl` / `rc-update` / `chkconfig` |

---

## Casos de uso

- Preparar rápidamente un entorno de prácticas de administración de bases de datos.
- Detectar conflictos entre varias instalaciones locales de motores de BD.
- Ver qué servicios están activos y cuánta memoria consumen.
- Liberar puertos ocupados o identificar procesos conflictivos.
- Reiniciar bases de datos locales sin abrir varias herramientas de administración.
- Recuperar acceso root en MySQL o MariaDB cuando se ha olvidado la contraseña.

---

## Limitaciones y consideraciones

- El soporte para Linux está orientado a distribuciones que usan `systemd` (con soporte adicional para OpenRC y SysVinit).
- Algunas rutas y comprobaciones asumen estructuras típicas de XAMPP, WAMP, Laragon y MAMP.
- El reseteo de contraseña root está orientado a instalaciones locales de MySQL/MariaDB.
- Algunas operaciones dependen de que los ejecutables del motor estén en rutas esperadas o disponibles en el PATH.
- La detección de procesos asociados a puertos requiere privilegios suficientes.
- El lanzador multiplataforma requiere Python 3 instalado.

---

## Seguridad y recomendaciones

- Ejecuta la herramienta solo en equipos de laboratorio, desarrollo o uso autorizado.
- Revisa los cambios de puerto antes de aplicarlos en archivos de configuración.
- Usa la opción de reseteo de contraseña root con precaución, ya que detiene temporalmente el servidor.
- Mantén los servicios en modo manual si trabajas con varios motores para evitar conflictos al iniciar el sistema.
- En Linux, evita ejecutar el gestor como root de forma habitual; úsalo solo cuando necesites gestionar servicios.

---

## Posibles mejoras

- Empaquetar la GUI como ejecutable autónomo (PyInstaller) para distribución.
- Permitir cambio de puerto asistido también para los motores más recientes (InfluxDB, Neo4j, etc.).

---

[🏠 Índice](README.md) · [⬅ Anterior: Motores y entornos soportados](motores.md) · [README principal ➡](../README.md)
