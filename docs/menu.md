[🏠 Documentación](README.md) › **Menú y funcionalidades**

# Menú y funcionalidades

## Funcionalidades

- Detección automática de servicios de bases de datos registrados en Windows o Linux.
- Detección de entornos locales como XAMPP, WAMP, Laragon, MAMP, AMPPS, Local, DevKinsta, Herd y más.
- Identificación de procesos activos de los motores soportados dentro de instalaciones locales.
- Inicio, parada y reinicio de servidores desde un menú interactivo.
- Control del número máximo de bases de datos activas simultáneamente (2 por defecto).
- Diagnóstico de conflictos de puertos y consumo de memoria RAM.
- Detección de contenedores Docker y Podman con motores de bases de datos activos.
- Detección de rutas y archivos de configuración personalizados (ver [Configuración](configuracion.md)).
- Comprobaciones de salud y conectividad reales en servidores activos (ver [Comprobaciones de salud](salud.md)).
- **Modo CLI** no interactivo para automatización (ver [Modo CLI](cli.md)).
- **Registro de actividad** en archivo de log (inicios, paradas, health checks, contenedores).
- **Gestión de contenedores** Docker/Podman y proyectos Docker Compose (ver [Contenedores y Compose](contenedores.md)).
- **Exportación de diagnóstico** a archivo de texto.
- Ayuda para configurar servicios en modo manual.
- Reseteo guiado de la contraseña root de MySQL/MariaDB.
- Diagnóstico completo del equipo para detectar conflictos entre instalaciones locales.
- Apertura de terminales de clientes de base de datos (`mysql`, `psql`, `mongosh`, `redis-cli`, `influx`, `clickhouse-client`, `cockroach`, `arangosh`, `cypher-shell`, `isql`).

---

## Opciones del menú
<p align="center">
<img width="500" height="475" alt="CLI-las-bases-y-sus-datos" src="https://github.com/user-attachments/assets/7dca272c-aa50-4bf4-b9ec-74985b98e2c2" />
</p>

El menú principal ofrece estas acciones:

- `1`: Iniciar servidor
- `2`: Detener servidor
- `3`: Reiniciar servidor
- `4`: Ver puertos abiertos
- `5`: Modo práctica
- `6`: Detectar XAMPP, WAMP, Docker y otros entornos locales
- `7`: Ayuda para configurar servicios en modo manual
- `8`: Diagnóstico completo del equipo
- `9`: Resetear password root de MySQL/MariaDB
- `10`: Abrir terminal de un servidor de base de datos
- `11`: Comprobar salud / conectividad de un servidor
- `12`: Gestionar contenedores Docker/Podman
- `13`: Exportar diagnóstico a archivo
- `14`: Gestionar proyectos Docker Compose
- `0`: Salir

---

## Modo práctica

Incluye accesos rápidos pensados para clases o laboratorios:

- Entorno 1: MySQL + MongoDB
- Entorno 2: PostgreSQL
- Entorno 3: MySQL + MongoDB + Redis

En Windows estos atajos usan `Start-Service`. En Linux usan el sistema de init detectado (`systemctl`, `rc-service` o `/etc/init.d`).

---

## Qué detecta el script

El script busca:

- Servicios de Windows relacionados con `MSSQL`, `mysql`, `maria`, `postgres`, `mongo`, `redis`, `influx`, `neo4j`, `clickhouse`, `cockroach`, `arango`, `memcache`, `firebird`, `rethinkdb`, `wamp` y `xampp` (por nombre y por `DisplayName`).
- Servicios de Linux gestionados por **systemd**, **OpenRC** o **SysVinit**: `mysql`, `mariadb`, `postgresql`, `mongod`, `mssql-server`, `redis`, `elasticsearch`, `opensearch`, `cassandra`, `scylla-server`, `couchdb`, `influxdb`, `neo4j`, `clickhouse-server`, `cockroach`, `arangodb3`, `memcached`, `firebird` y `rethinkdb`.
- Procesos de bases de datos dentro de instalaciones locales conocidas.
- Puertos comunes de bases de datos:
  - `3306` para MySQL/MariaDB
  - `5432` para PostgreSQL
  - `27017` para MongoDB
  - `1433` para SQL Server
  - `6379` para Redis
  - `9200` para Elasticsearch/OpenSearch
  - `9042` para Cassandra/ScyllaDB
  - `5984` para CouchDB
  - `8086` para InfluxDB
  - `7474` para Neo4j
  - `8123` para ClickHouse
  - `26257` para CockroachDB
  - `8529` para ArangoDB
  - `11211` para Memcached
  - `3050` para Firebird
  - `28015` para RethinkDB

---

[🏠 Índice](README.md) · [⬅ Anterior: Configuración](configuracion.md) · [Siguiente: Modo CLI ➡](cli.md)
