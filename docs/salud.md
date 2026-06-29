[🏠 Documentación](README.md) › **Comprobaciones de salud**

# Comprobaciones de salud y conectividad

Además de comprobar si un puerto está en escucha, el gestor realiza **pruebas de conectividad** contra los motores activos:

| Motor | Método |
|-------|--------|
| MySQL/MariaDB | `mysqladmin ping` |
| PostgreSQL | `pg_isready` |
| MongoDB | `mongosh` con `db.runCommand({ping:1})` |
| Redis | `redis-cli ping` (espera `PONG`) |
| CouchDB, Elasticsearch, InfluxDB, Neo4j… | Petición HTTP a `http://127.0.0.1:<puerto>/` |
| Otros | Test TCP al puerto |

---

## Dónde se muestra la salud

- En el **menú principal**, junto a cada servidor activo (`salud: OK`, `sin respuesta`, `sin cliente`).
- En el **diagnóstico completo** (columna `SALUD`).
- En la **opción 11** del menú: comprobación detallada con versión del cliente y, en servicios systemd/Windows, tiempo activo.
- En la [interfaz gráfica](gui.md): columna **Salud** de la pestaña Servidores y botón **Comprobar salud**.

Si falta el cliente de un motor (p. ej. `pg_isready`), se indica `NOCLI` sin bloquear el resto de funciones.

---

## Timeouts

Las comprobaciones aplican un **timeout duro** según `HEALTH_TIMEOUT` (ver [Configuración](configuracion.md)): se pasa el timeout nativo a cada cliente (`mysqladmin --connect-timeout`, `pg_isready -t`, `mongosh --serverSelectionTimeoutMS`, `redis-cli -t`, etc.) y, además, el proceso se aborta a la fuerza si lo supera (`timeout -k 1` en Linux; `Process.Kill()` en Windows).

Así, un servidor "congelado" cuyo puerto sigue aceptando conexiones no deja colgado el menú.

---

[🏠 Índice](README.md) · [⬅ Anterior: Interfaz gráfica](gui.md) · [Siguiente: Contenedores y Compose ➡](contenedores.md)
