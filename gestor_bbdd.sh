#!/usr/bin/env bash
# Gestor de Bases de Datos para Linux
# Detecta, inicia, detiene, reinicia y diagnostica servicios y entornos locales
# de bases de datos en distribuciones Linux (systemd, OpenRC, SysVinit).

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
MAX_ACTIVOS=2
HEALTH_TIMEOUT=3
CONF_EXTRA_PATHS=""
IGNORAR_MOTORES=""
LOG_ENABLED=false
LOG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODO_CLI=false
CLI_JSON=false
INIT_SYSTEM=""

# Patron para detectar contenedores de bases de datos
PATRON_BD_CONT='mysql|maria|postgres|mongo|mssql|redis|elasticsearch|opensearch|cassandra|scylla|couchdb|influx|neo4j|clickhouse|cockroach|arango|memcached|firebird|rethinkdb'

# Puertos habituales de los motores de BD soportados.
# 1433 SQL Server, 3306 MySQL/MariaDB, 5432 PostgreSQL, 27017 MongoDB,
# 6379 Redis, 9200 Elasticsearch/OpenSearch, 9042 Cassandra/ScyllaDB,
# 5984 CouchDB, 8086 InfluxDB, 7474 Neo4j, 8123 ClickHouse,
# 26257 CockroachDB, 8529 ArangoDB, 11211 Memcached, 3050 Firebird,
# 28015 RethinkDB.
PUERTOS_BD=(1433 3306 5432 27017 6379 9200 9042 5984 8086 7474 8123 26257 8529 11211 3050 28015)

# Colores
C_RST="\e[0m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_CYAN="\e[36m"
C_GRAY="\e[90m"

# ---------------------------------------------------------------------------
# Utilidades basicas
# ---------------------------------------------------------------------------

function pause() {
    [[ "$MODO_CLI" == true ]] && return 0
    read -rp "Pulsa ENTER para continuar..."
}

function limpiar_pantalla() {
    [[ "$MODO_CLI" == true ]] && return 0
    clear
}

function es_root() {
    [[ "$(id -u)" -eq 0 ]]
}

function comando_existe() {
    command -v "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Archivo de configuracion persistente (gestor_bbdd.conf)
# Precedencia: valores por defecto < archivo < variables de entorno
# ---------------------------------------------------------------------------

function localizar_config() {
    local candidato
    if [[ -n "${GESTOR_BD_CONF:-}" && -f "$GESTOR_BD_CONF" ]]; then
        echo "$GESTOR_BD_CONF"
        return 0
    fi
    candidato="${SCRIPT_DIR}/gestor_bbdd.conf"
    if [[ -f "$candidato" ]]; then
        echo "$candidato"
        return 0
    fi
    candidato="${XDG_CONFIG_HOME:-$HOME/.config}/gestor_bbdd.conf"
    if [[ -f "$candidato" ]]; then
        echo "$candidato"
        return 0
    fi
    return 1
}

function aplicar_config_clave() {
    local clave="$1" valor="$2"
    case "$clave" in
        MAX_ACTIVOS)
            [[ "$valor" =~ ^[0-9]+$ ]] && MAX_ACTIVOS="$valor"
            ;;
        EXTRA_PATHS)
            CONF_EXTRA_PATHS="$valor"
            ;;
        TERMINAL)
            [[ -z "${TERMINAL:-}" ]] && TERMINAL="$valor"
            ;;
        IGNORAR_MOTORES)
            IGNORAR_MOTORES="$valor"
            ;;
        HEALTH_TIMEOUT)
            [[ "$valor" =~ ^[0-9]+$ ]] && HEALTH_TIMEOUT="$valor"
            ;;
        LOG_ENABLED)
            case "${valor,,}" in true|1|yes|si|sí) LOG_ENABLED=true ;; esac
            ;;
        LOG_FILE)
            LOG_FILE="$valor"
            ;;
    esac
}

function cargar_config() {
    local archivo linea clave valor
    archivo=$(localizar_config) || return 0
    while IFS= read -r linea || [[ -n "$linea" ]]; do
        linea="${linea%%#*}"
        linea="$(echo "$linea" | xargs)"
        [[ -z "$linea" || "$linea" != *"="* ]] && continue
        clave="${linea%%=*}"
        valor="${linea#*=}"
        clave="$(echo "$clave" | xargs)"
        valor="$(echo "$valor" | xargs)"
        aplicar_config_clave "$clave" "$valor"
    done < "$archivo"
}

function aplicar_env_config() {
    [[ -n "${GESTOR_BD_MAX_ACTIVOS:-}" && "${GESTOR_BD_MAX_ACTIVOS}" =~ ^[0-9]+$ ]] && MAX_ACTIVOS="$GESTOR_BD_MAX_ACTIVOS"
    [[ -n "${GESTOR_BD_HEALTH_TIMEOUT:-}" && "${GESTOR_BD_HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && HEALTH_TIMEOUT="$GESTOR_BD_HEALTH_TIMEOUT"
    [[ -n "${GESTOR_BD_IGNORAR_MOTORES:-}" ]] && IGNORAR_MOTORES="$GESTOR_BD_IGNORAR_MOTORES"
    [[ -n "${TERMINAL:-}" ]] && : # ya definido por usuario o config
    case "${GESTOR_BD_LOG_ENABLED:-}" in true|1|yes|si|sí) LOG_ENABLED=true ;; esac
    [[ -n "${GESTOR_BD_LOG_FILE:-}" ]] && LOG_FILE="$GESTOR_BD_LOG_FILE"
}

function motor_ignorado() {
    local nombre="$1"
    local ignorados="${IGNORAR_MOTORES//,/ }"
    local m
    [[ -z "$ignorados" ]] && return 1
    for m in $ignorados; do
        m="$(echo "$m" | tr '[:upper:]' '[:lower:]' | xargs)"
        [[ -z "$m" ]] && continue
        if [[ "$(echo "$nombre" | tr '[:upper:]' '[:lower:]')" == *"$m"* ]]; then
            return 0
        fi
    done
    return 1
}

function registrar_log() {
    [[ "$LOG_ENABLED" != true || -z "$LOG_FILE" ]] && return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Sistema de init y gestion de servicios (systemd / OpenRC / SysVinit)
# ---------------------------------------------------------------------------

function detectar_init() {
    if comando_existe systemctl && [[ -d /run/systemd/system || -d /sys/fs/cgroup/systemd ]]; then
        INIT_SYSTEM="systemd"
    elif comando_existe rc-service; then
        INIT_SYSTEM="openrc"
    elif [[ -d /etc/init.d ]]; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="none"
    fi
}

function servicio_existe() {
    local nombre="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl cat "${nombre}.service" &>/dev/null ;;
        openrc|sysvinit) [[ -x "/etc/init.d/${nombre}" ]] ;;
        *) return 1 ;;
    esac
}

function servicio_estado() {
    local nombre="$1"
    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active "${nombre}.service" 2>/dev/null || echo "inactive"
            ;;
        openrc)
            if rc-service "$nombre" status 2>&1 | grep -qiE 'started|running'; then echo "active"; else echo "inactive"; fi
            ;;
        sysvinit)
            if service "$nombre" status 2>&1 | grep -qiE 'running|active'; then echo "active"; else echo "inactive"; fi
            ;;
        *) echo "inactive" ;;
    esac
}

function servicio_esta_activo() {
    local nombre="$1" estado
    estado=$(servicio_estado "$nombre")
    [[ "$estado" == "active" ]]
}

function estado_es_activo() {
    case "$1" in
        active|Active|running|Running|started|Started) return 0 ;;
    esac
    return 1
}

function iniciar_servicio_nativo() {
    local nombre="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl start "${nombre}.service" ;;
        openrc) rc-service "$nombre" start ;;
        sysvinit) service "$nombre" start ;;
        *) return 1 ;;
    esac
}

function detener_servicio_nativo() {
    local nombre="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "${nombre}.service" ;;
        openrc) rc-service "$nombre" stop ;;
        sysvinit) service "$nombre" stop ;;
        *) return 1 ;;
    esac
}

function reiniciar_servicio_nativo() {
    local nombre="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl restart "${nombre}.service" ;;
        openrc) rc-service "$nombre" restart ;;
        sysvinit) service "$nombre" restart ;;
        *) return 1 ;;
    esac
}

function nombre_init_amigable() {
    case "$INIT_SYSTEM" in
        systemd) echo "systemd" ;;
        openrc) echo "OpenRC" ;;
        sysvinit) echo "SysVinit" ;;
        *) echo "desconocido" ;;
    esac
}

# Devuelve una lista de servicios de BD conocidos, una linea por servicio:
# nombre|estado|puerto
function detectar_servicios() {
    [[ -z "$INIT_SYSTEM" ]] && detectar_init
    local servicios=(
        "mysql" "mariadb" "postgresql" "mongod" "mssql-server"
        "redis-server" "redis" "elasticsearch" "cassandra" "couchdb"
        "influxdb" "influxd" "neo4j" "clickhouse-server" "cockroach"
        "arangodb3" "arangodb" "memcached" "firebird" "firebird3.0"
        "rethinkdb" "scylla-server" "opensearch"
    )
    local nombre estado vistos=""
    for nombre in "${servicios[@]}"; do
        case " $vistos " in *" $nombre "*) continue ;; esac
        motor_ignorado "$nombre" && continue
        if servicio_existe "$nombre"; then
            estado=$(servicio_estado "$nombre")
            estado_es_activo "$estado" && estado="active" || estado="inactive"
            local puerto
            puerto=$(obtener_puerto "$nombre")
            echo "${nombre}|${estado}|${puerto}"
            vistos+=" $nombre"
        fi
    done
}

# ---------------------------------------------------------------------------
# Puertos
# ---------------------------------------------------------------------------

function obtener_puerto() {
    local nombre="$1"
    case "$nombre" in
        *mysql*|*maria*)      echo 3306 ;;
        *postgres*)           echo 5432 ;;
        *mongo*)              echo 27017 ;;
        *redis*)              echo 6379 ;;
        *elasticsearch*|*opensearch*) echo 9200 ;;
        *scylla*)             echo 9042 ;;
        *cassandra*)          echo 9042 ;;
        *couchdb*|*couch*)    echo 5984 ;;
        *influx*)             echo 8086 ;;
        *neo4j*)              echo 7474 ;;
        *clickhouse*)         echo 8123 ;;
        *cockroach*)          echo 26257 ;;
        *arango*)             echo 8529 ;;
        *memcache*)           echo 11211 ;;
        *firebird*)           echo 3050 ;;
        *rethink*)            echo 28015 ;;
        *mssql*|*sql*)        echo 1433 ;;
        *)                    echo 0 ;;
    esac
}

# Devuelve el puerto por defecto a partir del nombre del PROCESO (comm).
function puerto_de_proceso() {
    local comm="$1"
    case "$comm" in
        mysqld|mariadbd) echo 3306 ;;
        postgres)        echo 5432 ;;
        mongod)          echo 27017 ;;
        sqlservr)        echo 1433 ;;
        redis-server)    echo 6379 ;;
        couchdb|beam*)   echo 5984 ;;
        influxd)         echo 8086 ;;
        java)            echo 9200 ;;  # Elasticsearch/Cassandra/OpenSearch suelen correr sobre la JVM
        neo4j)           echo 7474 ;;
        clickhouse*)     echo 8123 ;;
        cockroach)       echo 26257 ;;
        arangod)         echo 8529 ;;
        memcached)       echo 11211 ;;
        fbserver|firebird*) echo 3050 ;;
        rethinkdb)       echo 28015 ;;
        *)               echo "?" ;;
    esac
}

# Comprueba si un puerto TCP esta en escucha. Devuelve 0 si esta ocupado.
function puerto_ocupado() {
    local puerto="$1"
    if comando_existe ss; then
        ss -tln 2>/dev/null | grep -qE ":${puerto}\b"
    elif comando_existe netstat; then
        netstat -tln 2>/dev/null | grep -qE ":${puerto}\b"
    else
        return 1
    fi
}

# Devuelve el PID que escucha en un puerto, o vacio si no hay.
function pid_del_puerto() {
    local puerto="$1"
    if comando_existe ss; then
        ss -tlnp 2>/dev/null | grep -E ":${puerto}\b" | sed -n 's/.*pid=\([0-9]*\).*/\1/p'
    elif comando_existe netstat; then
        netstat -tlnp 2>/dev/null | awk -v p=":${puerto}" '$0 ~ p {print $NF}' | sed 's|/.*||'
    fi
}

# ---------------------------------------------------------------------------
# RAM
# ---------------------------------------------------------------------------

# Recibe un nombre de servicio y devuelve el consumo aproximado en MB.
function obtener_ram() {
    local nombre="$1"
    local pid=0
    case "$INIT_SYSTEM" in
        systemd)
            pid=$(systemctl show "${nombre}.service" -p MainPID --value 2>/dev/null || echo 0)
            ;;
        *)
            pid=$(pgrep -x "$nombre" 2>/dev/null | head -n1 || true)
            [[ -z "$pid" ]] && pid=$(pidof "$nombre" 2>/dev/null | awk '{print $1}')
            ;;
    esac
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -d "/proc/${pid}" ]]; then
        local rss
        rss=$(awk '/VmRSS/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0)
        echo $((rss / 1024))
    else
        echo 0
    fi
}

# RAM de un proceso por PID
function obtener_ram_pid() {
    local pid="$1"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -d "/proc/${pid}" ]]; then
        local rss
        rss=$(awk '/VmRSS/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0)
        echo $((rss / 1024))
    else
        echo 0
    fi
}

# ---------------------------------------------------------------------------
# Deteccion de entornos locales (XAMPP/LAMPP principalmente)
# ---------------------------------------------------------------------------

# Rutas extra definidas por el usuario para afinar la deteccion.
# Se pueden indicar en la variable de entorno GESTOR_BD_EXTRA_PATHS
# separadas por ':' (formato PATH) o ';'.
function rutas_extra_usuario() {
    local lista="${GESTOR_BD_EXTRA_PATHS:-}"
    if [[ -n "$CONF_EXTRA_PATHS" ]]; then
        if [[ -n "$lista" ]]; then
            lista="${lista}:${CONF_EXTRA_PATHS}"
        else
            lista="$CONF_EXTRA_PATHS"
        fi
    fi
    [[ -z "$lista" ]] && return 0
    local r
    while IFS= read -r r; do
        [[ -n "$r" ]] && echo "$r"
    done < <(echo "$lista" | tr ':;' '\n')
}

# Busca rutas tipicas de entornos locales en Linux.
function buscar_entorno() {
    local nombre="$1"
    local candidatos=()
    case "$nombre" in
        "XAMPP"|"LAMPP")
            candidatos=("/opt/lampp" "/opt/xampp" "/srv/lampp" "$HOME/lampp")
            ;;
        "WAMP")
            candidatos=("/opt/wamp" "/opt/wamp64" "$HOME/wamp" "$HOME/wamp64")
            ;;
        "Laragon")
            candidatos=("/opt/laragon" "$HOME/laragon")
            ;;
        "MAMP")
            candidatos=("/opt/mamp" "/usr/local/mamp" "$HOME/mamp")
            ;;
        "Bitnami")
            candidatos=("/opt/bitnami" "/opt/Bitnami" "$HOME/bitnami")
            ;;
        "EasyPHP")
            candidatos=("/opt/easyphp" "/opt/EasyPHP" "$HOME/easyphp")
            ;;
        "Devilbox")
            candidatos=("/opt/devilbox" "$HOME/devilbox" "$HOME/Devilbox")
            ;;
        "DDEV")
            candidatos=("/usr/local/bin/ddev" "$HOME/.ddev")
            ;;
        "AMPPS")
            candidatos=("/usr/local/ampps" "/opt/ampps" "$HOME/ampps" "$HOME/Ampps")
            ;;
        "LocalWP")
            candidatos=("$HOME/.config/Local" "$HOME/.local/share/Local" "/opt/Local" "$HOME/Local Sites")
            ;;
        "DevKinsta")
            candidatos=("$HOME/DevKinsta" "$HOME/.config/DevKinsta" "/opt/DevKinsta")
            ;;
        "Herd")
            candidatos=("$HOME/.config/herd-lite" "$HOME/Library/Application Support/Herd" "$HOME/.herd" "/opt/herd")
            ;;
        "ServBay")
            candidatos=("/Applications/ServBay" "$HOME/ServBay" "/opt/servbay")
            ;;
        "Lando")
            candidatos=("$HOME/.lando" "/usr/local/bin/lando")
            ;;
    esac
    local ruta
    for ruta in "${candidatos[@]}"; do
        if [[ -d "$ruta" ]]; then
            echo "$ruta"
            return 0
        fi
    done
    # Comprobacion de rutas extra indicadas por el usuario que contengan el nombre
    local extra lname
    lname=$(echo "$nombre" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r extra; do
        [[ -z "$extra" ]] && continue
        if [[ -d "$extra" ]] && [[ "$(echo "$extra" | tr '[:upper:]' '[:lower:]')" == *"$lname"* ]]; then
            echo "$extra"
            return 0
        fi
    done < <(rutas_extra_usuario)
    return 1
}

# Identifica si el binario mysqld de un entorno es MariaDB o MySQL.
function identificar_motor_mysql() {
    local base="$1"
    local mysqld="${base}/bin/mysqld"
    if [[ ! -x "$mysqld" ]]; then
        mysqld="${base}/mysql/bin/mysqld"
    fi
    if [[ -x "$mysqld" ]]; then
        if "$mysqld" --version 2>/dev/null | grep -qi "MariaDB"; then
            echo "MariaDB"
            return
        fi
    fi
    echo "MySQL"
}

# Detecta servidores de BD dentro de entornos locales (XAMPP, etc.).
# Salida: nombre|tipo|estado|puerto|ram|pid|basePath|procName|startScript|stopScript
function detectar_servidores_entorno() {
    local entornos=("XAMPP" "WAMP" "Laragon" "MAMP" "Bitnami" "EasyPHP" "Devilbox" "AMPPS" "LocalWP" "DevKinsta")
    local nombre basePath motor procName startScript stopScript pid ram estado puerto
    for nombre in "${entornos[@]}"; do
        basePath=$(buscar_entorno "$nombre")
        [[ -z "$basePath" ]] && continue

        # MySQL/MariaDB en entornos locales
        procName="mysqld"
        startScript="${basePath}/lampp"
        if [[ ! -x "$startScript" ]]; then
            startScript="${basePath}/xampp"
        fi
        if [[ -x "${basePath}/manager-linux-x64.run" ]]; then
            startScript="${basePath}/manager-linux-x64.run"
        fi
        stopScript="$startScript"

        local mysqld="${basePath}/bin/mysqld"
        [[ ! -x "$mysqld" ]] && mysqld="${basePath}/mysql/bin/mysqld"

        if [[ -x "$mysqld" || -x "$startScript" ]]; then
            motor=$(identificar_motor_mysql "$basePath")
            pid=$(pgrep -f "$mysqld" 2>/dev/null | head -n1 || true)
            if [[ -n "$pid" ]]; then
                ram=$(obtener_ram_pid "$pid")
                estado="Running"
            else
                pid=0
                ram=0
                estado="Stopped"
            fi
            puerto=$(obtener_puerto "mysql")
            echo "${motor} (${nombre})|${nombre}|${estado}|${puerto}|${ram}|${pid}|${basePath}|${procName}|${startScript}|${stopScript}"
        fi

        # PostgreSQL
        local postgres="${basePath}/postgresql/bin/postgres"
        if [[ -x "$postgres" ]]; then
            pid=$(pgrep -f "$postgres" 2>/dev/null | head -n1 || true)
            if [[ -n "$pid" ]]; then
                ram=$(obtener_ram_pid "$pid")
                estado="Running"
            else
                pid=0; ram=0; estado="Stopped"
            fi
            echo "PostgreSQL (${nombre})|${nombre}|${estado}|5432|${ram}|${pid}|${basePath}|postgres||"
        fi

        # MongoDB
        local mongod="${basePath}/mongodb/bin/mongod"
        if [[ -x "$mongod" ]]; then
            pid=$(pgrep -f "$mongod" 2>/dev/null | head -n1 || true)
            if [[ -n "$pid" ]]; then
                ram=$(obtener_ram_pid "$pid")
                estado="Running"
            else
                pid=0; ram=0; estado="Stopped"
            fi
            echo "MongoDB (${nombre})|${nombre}|${estado}|27017|${ram}|${pid}|${basePath}|mongod||"
        fi

        # Redis
        local redis="${basePath}/bin/redis-server"
        [[ ! -x "$redis" ]] && redis="${basePath}/redis/bin/redis-server"
        [[ ! -x "$redis" ]] && redis="${basePath}/redis-server"
        if [[ -x "$redis" ]]; then
            pid=$(pgrep -f "$redis" 2>/dev/null | head -n1 || true)
            if [[ -n "$pid" ]]; then
                ram=$(obtener_ram_pid "$pid")
                estado="Running"
            else
                pid=0; ram=0; estado="Stopped"
            fi
            echo "Redis (${nombre})|${nombre}|${estado}|6379|${ram}|${pid}|${basePath}|redis-server||"
        fi
    done
}

# ---------------------------------------------------------------------------
# Configuracion de BD
# ---------------------------------------------------------------------------

# Intenta deducir el archivo de configuracion REAL a partir de la linea de
# comandos del proceso en ejecucion (lo mas fiable para configs personalizadas).
# Lee /proc/<PID>/cmdline buscando --defaults-file=, --config, -f, etc.
function config_desde_proceso() {
    local proc="$1"
    local pid cmd cfg
    pid=$(pgrep -x "$proc" 2>/dev/null | head -n1 || true)
    [[ -z "$pid" || ! -r "/proc/${pid}/cmdline" ]] && return 0

    # cmdline usa NUL como separador; lo convertimos a saltos de linea.
    cmd=$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null)

    case "$proc" in
        mysqld|mariadbd)
            cfg=$(echo "$cmd" | sed -n 's/^--defaults-file=//p' | head -n1)
            ;;
        postgres)
            # postgres -D <datadir>  => el config esta en <datadir>/postgresql.conf
            local datadir
            datadir=$(echo "$cmd" | grep -A1 -x '\-D' | tail -n1)
            [[ -n "$datadir" && -f "${datadir}/postgresql.conf" ]] && cfg="${datadir}/postgresql.conf"
            # tambien admite --config-file=
            [[ -z "$cfg" ]] && cfg=$(echo "$cmd" | sed -n 's/^--config-file=//p' | head -n1)
            ;;
        mongod)
            cfg=$(echo "$cmd" | grep -A1 -E -- '--config|-f' | tail -n1)
            ;;
        redis-server)
            # redis-server /ruta/redis.conf  (primer argumento que sea un .conf)
            cfg=$(echo "$cmd" | grep -E '\.conf$' | head -n1)
            ;;
    esac

    [[ -n "$cfg" && -f "$cfg" ]] && echo "$cfg"
}

function buscar_config_bd() {
    local base="$1"
    local proc="$2"
    local candidatos=()

    # 1) Config detectada a partir del proceso en ejecucion (prioritaria)
    local desdeProc
    desdeProc=$(config_desde_proceso "$proc")
    [[ -n "$desdeProc" ]] && echo "$desdeProc"

    if [[ "$proc" == "mysqld" || "$proc" == "mariadbd" ]]; then
        candidatos=(
            "${base}/etc/my.cnf"
            "${base}/etc/mysql/my.cnf"
            "${base}/mysql/bin/my.cnf"
            "${base}/mysql/my.cnf"
            "/etc/mysql/my.cnf"
            "/etc/mysql/mariadb.cnf"
            "/etc/mysql/mysql.conf.d/mysqld.cnf"
            "/etc/mysql/mariadb.conf.d/50-server.cnf"
            "/etc/my.cnf"
            "/etc/my.cnf.d/server.cnf"
            "$HOME/.my.cnf"
        )
    elif [[ "$proc" == "postgres" ]]; then
        candidatos=(
            "${base}/data/postgresql.conf"
            "${base}/pgsql/data/postgresql.conf"
            "/etc/postgresql/*/main/postgresql.conf"
            "/var/lib/pgsql/data/postgresql.conf"
            "/var/lib/pgsql/*/data/postgresql.conf"
            "/var/lib/postgresql/*/main/postgresql.conf"
        )
    elif [[ "$proc" == "mongod" ]]; then
        candidatos=(
            "${base}/etc/mongod.conf"
            "${base}/bin/mongod.conf"
            "${base}/mongodb.conf"
            "/etc/mongod.conf"
            "/etc/mongodb.conf"
        )
    elif [[ "$proc" == "redis-server" ]]; then
        candidatos=(
            "${base}/etc/redis.conf"
            "${base}/bin/redis.conf"
            "${base}/redis.conf"
            "/etc/redis/redis.conf"
            "/etc/redis.conf"
            "/etc/redis/redis.conf.d/*.conf"
        )
    elif [[ "$proc" == "couchdb" ]]; then
        candidatos=(
            "${base}/etc/local.ini"
            "${base}/etc/default.ini"
            "/etc/couchdb/local.ini"
            "/opt/couchdb/etc/local.ini"
        )
    elif [[ "$proc" == "influxd" ]]; then
        candidatos=(
            "${base}/etc/influxdb/influxdb.conf"
            "/etc/influxdb/influxdb.conf"
            "/etc/influxdb/config.toml"
            "$HOME/.influxdbv2/configs"
        )
    elif [[ "$proc" == "neo4j" ]]; then
        candidatos=(
            "${base}/conf/neo4j.conf"
            "/etc/neo4j/neo4j.conf"
            "/var/lib/neo4j/conf/neo4j.conf"
        )
    elif [[ "$proc" == "clickhouse-server" || "$proc" == "clickhouse" ]]; then
        candidatos=(
            "/etc/clickhouse-server/config.xml"
            "/etc/clickhouse-server/config.d/*.xml"
            "${base}/etc/config.xml"
        )
    elif [[ "$proc" == "cockroach" ]]; then
        candidatos=(
            "/etc/cockroach/cockroach.yaml"
            "${base}/cockroach.yaml"
        )
    elif [[ "$proc" == "arangod" ]]; then
        candidatos=(
            "/etc/arangodb3/arangod.conf"
            "${base}/etc/arangodb3/arangod.conf"
        )
    elif [[ "$proc" == "memcached" ]]; then
        candidatos=(
            "/etc/memcached.conf"
            "/etc/sysconfig/memcached"
            "/etc/default/memcached"
        )
    elif [[ "$proc" == "firebird" || "$proc" == "fbserver" ]]; then
        candidatos=(
            "/etc/firebird/*/firebird.conf"
            "/opt/firebird/firebird.conf"
            "${base}/firebird.conf"
        )
    elif [[ "$proc" == "rethinkdb" ]]; then
        candidatos=(
            "/etc/rethinkdb/instances.d/*.conf"
            "/etc/rethinkdb/default.conf"
            "${base}/rethinkdb.conf"
        )
    fi

    local c
    for c in "${candidatos[@]}"; do
        # Soporte para comodines
        for f in $c; do
            if [[ -f "$f" ]]; then
                echo "$f"
            fi
        done
    done
}

function cambiar_puerto_config() {
    local config="$1"
    local proc="$2"
    local nuevo="$3"

    if [[ ! -f "$config" ]]; then
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    case "$proc" in
        mysqld|mariadbd)
            sed -E "s/^([[:space:]]*port[[:space:]]*=[[:space:]]*)[0-9]+/\1${nuevo}/" "$config" > "$tmp"
            ;;
        postgres)
            sed -E "s/^([[:space:]]*#?[[:space:]]*port[[:space:]]*=[[:space:]]*)[0-9]+/\1${nuevo}/" "$config" > "$tmp"
            ;;
        mongod)
            sed -E "s/^([[:space:]]*port:[[:space:]]*)[0-9]+/\1${nuevo}/" "$config" > "$tmp"
            ;;
        redis-server)
            sed -E "s/^([[:space:]]*port[[:space:]]+)[0-9]+/\1${nuevo}/" "$config" > "$tmp"
            ;;
        couchdb)
            sed -E "s/^([[:space:]]*port[[:space:]]*=[[:space:]]*)[0-9]+/\1${nuevo}/" "$config" > "$tmp"
            ;;
        *)
            rm -f "$tmp"
            return 1
            ;;
    esac
    mv "$tmp" "$config"
}

# ---------------------------------------------------------------------------
# Iniciar / detener / reiniciar entornos locales
# ---------------------------------------------------------------------------

function iniciar_entorno() {
    local linea="$1"
    IFS='|' read -r nombre tipo estado puerto ram pid basePath procName startScript stopScript <<< "$linea"

    if [[ -z "$startScript" || ! -x "$startScript" ]]; then
        echo -e "${C_RED}No se encontro script de inicio para ${nombre}${C_RST}"
        return
    fi

    if [[ "$puerto" -gt 0 ]] && puerto_ocupado "$puerto"; then
        echo -e "${C_RED}Puerto ${puerto} ya esta ocupado.${C_RST}"
        local configs
        configs=$(buscar_config_bd "$basePath" "$procName")
        if [[ -n "$configs" ]]; then
            echo -e "${C_YELLOW}Se puede cambiar el puerto en la configuracion.${C_RST}"
            read -rp "Desea cambiar el puerto? (s/n): " resp
            if [[ "$resp" == "s" ]]; then
                read -rp "Introduce el nuevo puerto: " nuevoPuerto
                if [[ "$nuevoPuerto" =~ ^[0-9]+$ && "$nuevoPuerto" -ge 1024 && "$nuevoPuerto" -le 65535 ]]; then
                    if puerto_ocupado "$nuevoPuerto"; then
                        echo -e "${C_RED}El puerto ${nuevoPuerto} tambien esta ocupado.${C_RST}"
                        return
                    fi
                    local cfg
                    while IFS= read -r cfg; do
                        cambiar_puerto_config "$cfg" "$procName" "$nuevoPuerto"
                        echo -e "${C_GREEN}Puerto cambiado a ${nuevoPuerto} en ${cfg}${C_RST}"
                    done <<< "$configs"
                    echo -e "${C_YELLOW}Iniciando ${nombre} en puerto ${nuevoPuerto}...${C_RST}"
                    iniciar_script_entorno "$nombre" "$startScript" "$procName" "$basePath"
                else
                    echo -e "${C_RED}Puerto no valido. Debe estar entre 1024 y 65535.${C_RST}"
                fi
            fi
        else
            echo -e "${C_YELLOW}No se encontro archivo de configuracion para cambiar el puerto.${C_RST}"
        fi
        return
    fi

    echo -e "${C_YELLOW}Iniciando ${nombre}...${C_RST}"
    iniciar_script_entorno "$nombre" "$startScript" "$procName" "$basePath"
}

function iniciar_script_entorno() {
    local nombre="$1"
    local script="$2"
    local procName="$3"
    local basePath="$4"

    # Scripts estilo XAMPP/LAMPP
    if [[ "$script" == *"lampp" ]] || [[ "$script" == *"xampp" ]]; then
        "$script" startmysql &>/dev/null || "$script" start &>/dev/null
    else
        nohup "$script" &>/dev/null &
    fi

    sleep 3
    local nuevo_pid
    nuevo_pid=$(pgrep -f "${basePath}.*${procName}" 2>/dev/null | head -n1 || true)
    if [[ -n "$nuevo_pid" ]]; then
        echo -e "${C_GREEN}${nombre} iniciado correctamente (PID: ${nuevo_pid})${C_RST}"
        registrar_log "start entorno=${nombre} pid=${nuevo_pid} resultado=ok"
    else
        echo -e "${C_RED}No se pudo verificar el inicio.${C_RST}"
    fi
}

function detener_entorno() {
    local linea="$1"
    IFS='|' read -r nombre tipo estado puerto ram pid basePath procName startScript stopScript <<< "$linea"

    if [[ "$pid" -le 0 ]]; then
        echo -e "${C_RED}No hay proceso activo de ${nombre}.${C_RST}"
        return
    fi

    local detenido=false

    # Metodo 1: mysqladmin shutdown
    if [[ "$procName" == "mysqld" || "$procName" == "mariadbd" ]]; then
        local mysqladmin="${basePath}/bin/mysqladmin"
        [[ ! -x "$mysqladmin" ]] && mysqladmin="${basePath}/mysql/bin/mysqladmin"
        if [[ -x "$mysqladmin" ]]; then
            echo -e "${C_GRAY}  Enviando shutdown via mysqladmin...${C_RST}"
            "$mysqladmin" -u root shutdown 2>/dev/null || true
            sleep 3
            if ! kill -0 "$pid" 2>/dev/null; then
                detenido=true
            fi
        fi
    fi

    # Metodo 2: pg_ctl stop
    if [[ "$detenido" == false && "$procName" == "postgres" ]]; then
        local pgctl
        pgctl=$(find "$basePath" -name "pg_ctl" -type f -executable 2>/dev/null | head -n1)
        if [[ -n "$pgctl" ]]; then
            local dataDir
            dataDir=$(find "$basePath" -name "postgresql.conf" -type f 2>/dev/null | head -n1)
            if [[ -n "$dataDir" ]]; then
                dataDir=$(dirname "$dataDir")
                echo -e "${C_GRAY}  Enviando stop via pg_ctl...${C_RST}"
                "$pgctl" stop -D "$dataDir" -m fast 2>/dev/null || true
                sleep 3
                if ! kill -0 "$pid" 2>/dev/null; then
                    detenido=true
                fi
            fi
        fi
    fi

    # Metodo 3: terminar proceso
    if [[ "$detenido" == false ]]; then
        echo -e "${C_GRAY}  Terminando proceso (PID: ${pid})...${C_RST}"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            sleep 1
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            detenido=true
        fi
    fi

    if [[ "$detenido" == true ]]; then
        echo -e "${C_GREEN}${nombre} detenido correctamente.${C_RST}"
        registrar_log "stop entorno=${nombre} resultado=ok"
    else
        echo -e "${C_RED}${nombre} no se pudo detener.${C_RST}"
        echo -e "${C_YELLOW}Intenta cerrarlo manualmente con kill -9 ${pid}${C_RST}"
    fi
}

function reiniciar_entorno() {
    detener_entorno "$1"
    sleep 1
    iniciar_entorno "$1"
}

# ---------------------------------------------------------------------------
# Entornos web / Docker
# ---------------------------------------------------------------------------

function mostrar_procesos_entorno() {
    local base="$1"
    local nombre="$2"
    local p info
    local procesos
    procesos=$(ps -eo pid,comm,args 2>/dev/null | awk -v b="$base" '$0 ~ b && ($2 ~ /mysqld|mariadbd|postgres|mongod|sqlservr|redis-server|couchdb|influxd|neo4j|clickhouse|cockroach|arangod|memcached|fbserver|firebird|rethinkdb/) {print}')
    if [[ -n "$procesos" ]]; then
        while IFS= read -r p; do
            local pid_proc comm_proc
            pid_proc=$(echo "$p" | awk '{print $1}')
            comm_proc=$(echo "$p" | awk '{print $2}')
            info=" (puerto $(puerto_de_proceso "$comm_proc"))"
            echo -e "${C_GREEN}  -> ${comm_proc} EN EJECUCION${info} - PID: ${pid_proc}${C_RST}"
        done <<< "$procesos"
    else
        echo -e "${C_GRAY}  -> Ningun proceso de BD de ${nombre} en ejecucion${C_RST}"
    fi
}

function detectar_entornos_web() {
    echo ""
    echo -e "${C_YELLOW}DETECCION DE ENTORNOS LOCALES${C_RST}"
    echo "-----------------------------"
    local encontrado=false
    local nombre ruta

    for nombre in "XAMPP" "WAMP" "Laragon" "MAMP" "Bitnami" "EasyPHP" "Devilbox" "DDEV" "AMPPS" "LocalWP" "DevKinsta" "Herd" "ServBay" "Lando"; do
        ruta=$(buscar_entorno "$nombre")
        if [[ -n "$ruta" ]]; then
            encontrado=true
            echo -e "${C_YELLOW}${nombre} detectado en ${ruta}${C_RST}"
            mostrar_procesos_entorno "$ruta" "$nombre"
        fi
    done

    # Docker
    if comando_existe docker; then
        encontrado=true
        if systemctl is-active --quiet docker 2>/dev/null || pgrep -x dockerd &>/dev/null; then
            echo -e "${C_GREEN}Docker instalado y EN EJECUCION${C_RST}"
            local contenedores
            contenedores=$(docker ps --format "{{.Names}}  {{.Image}}  {{.Ports}}" 2>/dev/null || true)
            if [[ -n "$contenedores" ]]; then
                local dbContainers
                dbContainers=$(echo "$contenedores" | grep -Ei "mysql|maria|postgres|mongo|mssql|redis|elasticsearch|opensearch|cassandra|scylla|couchdb|influx|neo4j|clickhouse|cockroach|arango|memcached|firebird|rethinkdb" || true)
                if [[ -n "$dbContainers" ]]; then
                    echo -e "${C_YELLOW}  Contenedores de BD activos:${C_RST}"
                    echo "$dbContainers" | while read -r c; do
                        echo -e "${C_GREEN}  -> ${c}${C_RST}"
                    done
                fi
            fi
        else
            echo -e "${C_RED}Docker instalado pero DETENIDO${C_RST}"
        fi
    fi

    # Podman (alternativa a Docker, muy comun en Fedora/RHEL)
    if comando_existe podman; then
        encontrado=true
        local pcontenedores pdb
        pcontenedores=$(podman ps --format "{{.Names}}  {{.Image}}  {{.Ports}}" 2>/dev/null || true)
        if [[ -n "$pcontenedores" ]]; then
            pdb=$(echo "$pcontenedores" | grep -Ei "mysql|maria|postgres|mongo|mssql|redis|elasticsearch|opensearch|cassandra|scylla|couchdb|influx|neo4j|clickhouse|cockroach|arango|memcached|firebird|rethinkdb" || true)
            if [[ -n "$pdb" ]]; then
                echo -e "${C_GREEN}Podman detectado con contenedores de BD activos:${C_RST}"
                echo "$pdb" | while read -r c; do
                    echo -e "${C_GREEN}  -> ${c}${C_RST}"
                done
            else
                echo -e "${C_GREEN}Podman detectado (sin contenedores de BD activos)${C_RST}"
            fi
        else
            echo -e "${C_GREEN}Podman instalado${C_RST}"
        fi
    fi

    # Docker Compose (proyectos con docker-compose.yml)
    if comando_existe docker && comando_existe docker-compose 2>/dev/null; then
        local composeFiles
        composeFiles=$(find "$HOME" -maxdepth 3 -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null | head -n 10 || true)
        if [[ -n "$composeFiles" ]]; then
            echo ""
            echo -e "${C_YELLOW}Proyectos Docker Compose detectados:${C_RST}"
            echo "$composeFiles" | while read -r f; do
                echo -e "${C_GRAY}  -> ${f}${C_RST}"
            done
        fi
    fi

    # Snap packages de BD
    if comando_existe snap; then
        local snaps
        snaps=$(snap list 2>/dev/null | grep -Ei "mysql|maria|postgres|mongo|redis|influxdb|cockroach|arango|memcached|rethinkdb|couchdb|elasticsearch|opensearch" || true)
        if [[ -n "$snaps" ]]; then
            encontrado=true
            echo ""
            echo -e "${C_YELLOW}Paquetes Snap de BD detectados:${C_RST}"
            echo "$snaps" | while read -r s; do
                echo -e "${C_GREEN}  -> ${s}${C_RST}"
            done
        fi
    fi

    # Paquetes Flatpak de BD (poco habitual, pero posible)
    if comando_existe flatpak; then
        local flat
        flat=$(flatpak list --app 2>/dev/null | grep -Ei "mysql|maria|postgres|mongo|redis|influx" || true)
        if [[ -n "$flat" ]]; then
            encontrado=true
            echo ""
            echo -e "${C_YELLOW}Aplicaciones Flatpak de BD detectadas:${C_RST}"
            echo "$flat" | while read -r f; do
                echo -e "${C_GREEN}  -> ${f}${C_RST}"
            done
        fi
    fi

    # Otros procesos de BD no asociados a entornos detectados
    local procsDB
    procsDB=$(ps -eo pid,comm,args 2>/dev/null | awk '$2 ~ /mysqld|mariadbd|postgres|mongod|sqlservr|redis-server|couchdb|influxd|neo4j|clickhouse|cockroach|arangod|memcached|fbserver|firebird|rethinkdb/ {print $1"|"$2"|"$3}')
    if [[ -n "$procsDB" ]]; then
        encontrado=true
        echo ""
        echo -e "${C_YELLOW}OTROS PROCESOS DE BD DETECTADOS:${C_RST}"
        while IFS='|' read -r p comm arg; do
            local info=" (puerto $(puerto_de_proceso "$comm"))"
            echo -e "${C_CYAN}  -> ${comm}${info} - PID: ${p} - ${arg}${C_RST}"
        done <<< "$procsDB"
    fi

    if [[ "$encontrado" == false ]]; then
        echo -e "${C_GRAY}No se detecto ningun entorno local (XAMPP, WAMP, Laragon, MAMP, Docker, Podman, etc.)${C_RST}"
    fi
}

# ---------------------------------------------------------------------------
# Gestion de servicios systemd
# ---------------------------------------------------------------------------

function iniciar_servidor() {
    local nombre="$1"
    local activos="$2"

    if [[ "$activos" -ge "$MAX_ACTIVOS" ]]; then
        echo ""
        echo -e "${C_RED}Solo se permiten ${MAX_ACTIVOS} servidores activos.${C_RST}"
        pause
        return
    fi

    local puerto
    puerto=$(obtener_puerto "$nombre")
    if puerto_ocupado "$puerto"; then
        echo ""
        echo -e "${C_RED}Puerto ${puerto} ocupado.${C_RST}"
        echo ""
        echo -e "${C_YELLOW}Para cambiar el puerto de un servicio nativo, edita su archivo de configuracion:${C_RST}"
        if [[ "$nombre" == *"mysql"* || "$nombre" == *"maria"* ]]; then
            echo -e "${C_CYAN}  MySQL/MariaDB: Editar /etc/mysql/my.cnf o /etc/my.cnf${C_RST}"
            echo -e "${C_CYAN}  Buscar la linea 'port=3306' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"postgres"* ]]; then
            echo -e "${C_CYAN}  PostgreSQL: Editar /etc/postgresql/XX/main/postgresql.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar la linea 'port = 5432' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"mongo"* ]]; then
            echo -e "${C_CYAN}  MongoDB: Editar /etc/mongod.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar 'port: 27017' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"mssql"* ]]; then
            echo -e "${C_CYAN}  SQL Server: editar /var/opt/mssql/mssql.conf con mssql-conf${C_RST}"
        elif [[ "$nombre" == *"redis"* ]]; then
            echo -e "${C_CYAN}  Redis: Editar /etc/redis/redis.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar la linea 'port 6379' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"elasticsearch"* ]]; then
            echo -e "${C_CYAN}  Elasticsearch: Editar /etc/elasticsearch/elasticsearch.yml${C_RST}"
            echo -e "${C_CYAN}  Buscar la linea 'http.port: 9200' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"cassandra"* ]]; then
            echo -e "${C_CYAN}  Cassandra: Editar /etc/cassandra/cassandra.yaml${C_RST}"
            echo -e "${C_CYAN}  Buscar 'native_transport_port: 9042' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"couchdb"* ]]; then
            echo -e "${C_CYAN}  CouchDB: Editar /etc/couchdb/local.ini${C_RST}"
            echo -e "${C_CYAN}  Buscar 'port = 5984' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"influx"* ]]; then
            echo -e "${C_CYAN}  InfluxDB: Editar /etc/influxdb/influxdb.conf (o config.toml)${C_RST}"
            echo -e "${C_CYAN}  Buscar 'bind-address' / 'http-bind-address' y cambiar el puerto 8086${C_RST}"
        elif [[ "$nombre" == *"neo4j"* ]]; then
            echo -e "${C_CYAN}  Neo4j: Editar /etc/neo4j/neo4j.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar 'server.http.listen_address=:7474' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"clickhouse"* ]]; then
            echo -e "${C_CYAN}  ClickHouse: Editar /etc/clickhouse-server/config.xml${C_RST}"
            echo -e "${C_CYAN}  Buscar '<http_port>8123</http_port>' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"cockroach"* ]]; then
            echo -e "${C_CYAN}  CockroachDB: el puerto se define al arrancar con --listen-addr=:26257${C_RST}"
        elif [[ "$nombre" == *"arango"* ]]; then
            echo -e "${C_CYAN}  ArangoDB: Editar /etc/arangodb3/arangod.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar 'endpoint = tcp://127.0.0.1:8529' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"memcache"* ]]; then
            echo -e "${C_CYAN}  Memcached: Editar /etc/memcached.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar la linea '-p 11211' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"firebird"* ]]; then
            echo -e "${C_CYAN}  Firebird: Editar /etc/firebird/*/firebird.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar 'RemoteServicePort = 3050' y cambiar el numero${C_RST}"
        elif [[ "$nombre" == *"rethink"* ]]; then
            echo -e "${C_CYAN}  RethinkDB: Editar /etc/rethinkdb/instances.d/*.conf${C_RST}"
            echo -e "${C_CYAN}  Buscar 'driver-port=28015' y cambiar el numero${C_RST}"
        fi
        echo ""
        diagnosticar "$nombre"
        pause
        return
    fi

    if iniciar_servicio_nativo "$nombre"; then
        sleep 2
        if servicio_esta_activo "$nombre"; then
            echo -e "${C_GREEN}Servidor iniciado correctamente.${C_RST}"
            registrar_log "start servicio=${nombre} init=${INIT_SYSTEM} resultado=ok"
        else
            echo -e "${C_RED}No se pudo iniciar el servidor.${C_RST}"
            registrar_log "start servicio=${nombre} init=${INIT_SYSTEM} resultado=fallo"
            diagnosticar "$nombre"
        fi
    else
        echo -e "${C_RED}Error al iniciar el servicio.${C_RST}"
        registrar_log "start servicio=${nombre} init=${INIT_SYSTEM} resultado=error"
        diagnosticar "$nombre"
    fi
    pause
}

function detener_servidor() {
    local nombre="$1"
    if detener_servicio_nativo "$nombre"; then
        echo -e "${C_GREEN}Base de datos ${nombre} detenida.${C_RST}"
        registrar_log "stop servicio=${nombre} init=${INIT_SYSTEM} resultado=ok"
    else
        echo -e "${C_RED}Error al detener ${nombre}.${C_RST}"
        registrar_log "stop servicio=${nombre} init=${INIT_SYSTEM} resultado=error"
    fi
}

function reiniciar_servidor() {
    local nombre="$1"
    if reiniciar_servicio_nativo "$nombre"; then
        echo -e "${C_GREEN}Base de datos ${nombre} reiniciada.${C_RST}"
        registrar_log "restart servicio=${nombre} init=${INIT_SYSTEM} resultado=ok"
    else
        echo -e "${C_RED}Error al reiniciar ${nombre}.${C_RST}"
        registrar_log "restart servicio=${nombre} init=${INIT_SYSTEM} resultado=error"
    fi
}

function diagnosticar() {
    local nombre="$1"
    echo ""
    echo -e "${C_YELLOW}DIAGNOSTICO DEL PROBLEMA${C_RST}"
    echo "------------------------"
    local puerto
    puerto=$(obtener_puerto "$nombre")

    if puerto_ocupado "$puerto"; then
        local pid_proc
        pid_proc=$(pid_del_puerto "$puerto")
        if [[ -n "$pid_proc" ]]; then
            local proc
            proc=$(ps -p "$pid_proc" -o comm= 2>/dev/null || echo "desconocido")
            echo -e "${C_RED}Puerto ${puerto} ocupado por ${proc}${C_RST}"
            read -rp "Quieres detener este proceso para liberar el puerto? (s/n): " accion
            if [[ "$accion" == "s" ]]; then
                kill -9 "$pid_proc" 2>/dev/null || true
                echo -e "${C_GREEN}Proceso detenido, intenta iniciarlo de nuevo.${C_RST}"
            fi
        else
            echo -e "${C_RED}Puerto ${puerto} ocupado${C_RST}"
        fi
        return
    fi

    local ram_libre
    ram_libre=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 9999)
    if [[ "$ram_libre" -lt 500 ]]; then
        echo -e "${C_RED}RAM insuficiente para iniciar el servicio.${C_RST}"
        return
    fi

    echo -e "${C_YELLOW}No se detecto ninguna causa con el metodo automatico.${C_RST}"
    echo "Revisa el archivo de configuracion del servidor o el log con: journalctl -u ${nombre}.service"
}

# ---------------------------------------------------------------------------
# Comprobaciones de salud / conectividad
# Devuelve: OK | NORESP | NOCLI
# ---------------------------------------------------------------------------

function salud_tcp() {
    local puerto="$1" t="${2:-$HEALTH_TIMEOUT}"
    if timeout -k 1 "$t" bash -c "exec 3<>/dev/tcp/127.0.0.1/${puerto}" 2>/dev/null; then
        echo OK
    else
        echo NORESP
    fi
}

function salud_http() {
    local puerto="$1" t="${2:-$HEALTH_TIMEOUT}" url="http://127.0.0.1:${puerto}/"
    if comando_existe curl; then
        curl -fsS --max-time "$t" "$url" &>/dev/null && echo OK && return
    elif comando_existe wget; then
        wget -q --timeout="$t" -O /dev/null "$url" &>/dev/null && echo OK && return
    else
        salud_tcp "$puerto" "$t"
        return
    fi
    echo NORESP
}

function comprobar_salud() {
    local nombre="$1" puerto="$2"
    local t="${HEALTH_TIMEOUT:-3}"
    local n
    n=$(echo "$nombre" | tr '[:upper:]' '[:lower:]')

    case "$n" in
        *mysql*|*maria*)
            if ! comando_existe mysqladmin; then echo NOCLI; return; fi
            timeout -k 1 "$t" mysqladmin --connect-timeout="$t" -h 127.0.0.1 -P"$puerto" ping &>/dev/null && echo OK || echo NORESP
            ;;
        *postgres*)
            if ! comando_existe pg_isready; then echo NOCLI; return; fi
            timeout -k 1 "$t" pg_isready -t "$t" -h 127.0.0.1 -p "$puerto" &>/dev/null && echo OK || echo NORESP
            ;;
        *mongo*)
            if ! comando_existe mongosh; then echo NOCLI; return; fi
            timeout -k 1 "$t" mongosh --quiet --host 127.0.0.1 --port "$puerto" --serverSelectionTimeoutMS "$((t * 1000))" --eval "db.runCommand({ping:1})" &>/dev/null && echo OK || echo NORESP
            ;;
        *redis*)
            if ! comando_existe redis-cli; then echo NOCLI; return; fi
            [[ "$(timeout -k 1 "$t" redis-cli -t "$t" -p "$puerto" ping 2>/dev/null)" == "PONG" ]] && echo OK || echo NORESP
            ;;
        *couchdb*|*elasticsearch*|*opensearch*|*influx*|*neo4j*|*rethink*)
            salud_http "$puerto" "$t"
            ;;
        *clickhouse*)
            if comando_existe clickhouse-client; then
                timeout -k 1 "$t" clickhouse-client --connect_timeout "$t" --host 127.0.0.1 --port "$puerto" -q "SELECT 1" &>/dev/null && echo OK || echo NORESP
            else
                salud_tcp "$puerto" "$t"
            fi
            ;;
        *cockroach*)
            if comando_existe cockroach; then
                timeout -k 1 "$t" cockroach sql --insecure --host=127.0.0.1 --port="$puerto" -e "SELECT 1" &>/dev/null && echo OK || echo NORESP
            else
                salud_tcp "$puerto" "$t"
            fi
            ;;
        *memcache*)
            if comando_existe nc; then
                printf "stats\r\nquit\r\n" | timeout -k 1 "$t" nc -w "$t" 127.0.0.1 "$puerto" 2>/dev/null | grep -q "STAT" && echo OK || echo NORESP
            else
                salud_tcp "$puerto" "$t"
            fi
            ;;
        *)
            salud_tcp "$puerto" "$t"
            ;;
    esac
}

function etiqueta_salud() {
    local estado="$1"
    case "$estado" in
        OK)      echo -e "${C_GREEN}salud: OK${C_RST}" ;;
        NORESP)  echo -e "${C_YELLOW}salud: sin respuesta${C_RST}" ;;
        NOCLI)   echo -e "${C_GRAY}salud: cliente no instalado${C_RST}" ;;
        *)       echo -e "${C_GRAY}salud: desconocida${C_RST}" ;;
    esac
}

function obtener_version_motor() {
    local nombre="$1" puerto="$2"
    local n exe out
    n=$(echo "$nombre" | tr '[:upper:]' '[:lower:]')
    case "$n" in
        *mysql*|*maria*)
            exe=$(buscar_ejecutable "mysql" 2>/dev/null || true)
            [[ -n "$exe" ]] && "$exe" --version 2>/dev/null | head -n1
            ;;
        *postgres*)
            exe=$(buscar_ejecutable "psql" 2>/dev/null || true)
            [[ -n "$exe" ]] && "$exe" --version 2>/dev/null | head -n1
            ;;
        *mongo*)
            exe=$(buscar_ejecutable "mongosh" 2>/dev/null || true)
            [[ -n "$exe" ]] && "$exe" --version 2>/dev/null | head -n1
            ;;
        *redis*)
            exe=$(buscar_ejecutable "redis-cli" 2>/dev/null || true)
            [[ -n "$exe" ]] && "$exe" --version 2>/dev/null | head -n1
            ;;
        *couchdb*|*elasticsearch*|*influx*|*neo4j*)
            if comando_existe curl; then
                out=$(curl -fsS --max-time "$HEALTH_TIMEOUT" "http://127.0.0.1:${puerto}/" 2>/dev/null | head -c 120 || true)
                [[ -n "$out" ]] && echo "$out"
            fi
            ;;
        *)
            echo "No disponible"
            ;;
    esac
}

function comprobar_salud_detallada() {
    local nombre="$1" puerto="$2" servicio="${3:-}"
    local estado_salud version uptime_sec
    limpiar_pantalla
    echo "======================================"
    echo "  COMPROBACION DE SALUD"
    echo "======================================"
    echo ""
    echo -e "${C_CYAN}Servidor: ${nombre}${C_RST}"
    echo -e "${C_GRAY}Puerto: ${puerto}${C_RST}"
    echo ""
    echo -n "Estado de conexion: "
    estado_salud=$(comprobar_salud "$nombre" "$puerto")
    etiqueta_salud "$estado_salud"
    echo ""
    version=$(obtener_version_motor "$nombre" "$puerto")
    if [[ -n "$version" ]]; then
        echo -e "${C_CYAN}Version / respuesta:${C_RST} ${version}"
    fi
    if [[ -n "$servicio" && "$INIT_SYSTEM" == "systemd" ]]; then
        uptime_sec=$(systemctl show "${servicio}.service" -p ActiveEnterTimestamp --value 2>/dev/null || true)
        [[ -n "$uptime_sec" && "$uptime_sec" != "n/a" ]] && echo -e "${C_CYAN}Activo desde:${C_RST} ${uptime_sec}"
    fi
    registrar_log "health-check ${nombre} puerto=${puerto} resultado=${estado_salud}"
    echo ""
    pause
}

# ---------------------------------------------------------------------------
# Modo practica
# ---------------------------------------------------------------------------

function modo_practica() {
    local tipo="$1" s
    case "$tipo" in
        1)
            echo ""
            echo -e "${C_CYAN}Iniciando entorno MySQL + MongoDB${C_RST}"
            for s in mysql mariadb mongod; do servicio_existe "$s" && iniciar_servicio_nativo "$s" 2>/dev/null || true; done
            ;;
        2)
            echo ""
            echo -e "${C_CYAN}Iniciando entorno PostgreSQL${C_RST}"
            servicio_existe postgresql && iniciar_servicio_nativo postgresql 2>/dev/null || true
            ;;
        3)
            echo ""
            echo -e "${C_CYAN}Iniciando entorno MySQL + MongoDB + Redis${C_RST}"
            for s in mysql mariadb mongod redis-server redis; do servicio_existe "$s" && iniciar_servicio_nativo "$s" 2>/dev/null || true; done
            ;;
        *)
            echo -e "${C_RED}Opcion no valida${C_RST}"
            ;;
    esac
    pause
}

# ---------------------------------------------------------------------------
# Ayuda servicios
# ---------------------------------------------------------------------------

function ayuda_servicios() {
    limpiar_pantalla
    echo "CONFIGURAR SERVICIOS EN MODO MANUAL"
    echo "-----------------------------------"
    echo "Para evitar que los servidores se inicien automaticamente:"
    echo ""
    case "$INIT_SYSTEM" in
        openrc)
            echo "Metodo con OpenRC:"
            echo "  sudo rc-update del mysql default"
            echo "  sudo rc-update del mongod default"
            echo "  sudo rc-update add <servicio> default   # para habilitar"
            ;;
        sysvinit)
            echo "Metodo con SysVinit (Debian/Ubuntu):"
            echo "  sudo update-rc.d mysql disable"
            echo "  sudo update-rc.d mongod disable"
            echo "  sudo update-rc.d <servicio> enable    # para habilitar"
            ;;
        *)
            echo "Metodo con systemctl:"
            echo "  sudo systemctl disable mysql"
            echo "  sudo systemctl disable mongod"
            echo "  sudo systemctl disable postgresql"
            echo "  sudo systemctl disable mssql-server"
            echo ""
            echo "Para volver a habilitarlos:"
            echo "  sudo systemctl enable <servicio>"
            ;;
    esac
    echo ""
    pause
}

# ---------------------------------------------------------------------------
# Resetear password root MySQL/MariaDB
# ---------------------------------------------------------------------------

function buscar_mysqld() {
    local base
    base=$(buscar_entorno "XAMPP")
    if [[ -n "$base" && -x "${base}/bin/mysqld" ]]; then
        echo "${base}/bin/mysqld|${base}|XAMPP"
        return
    fi
    if comando_existe mysqld; then
        local exe
        exe=$(command -v mysqld)
        local dir
        dir=$(dirname "$(dirname "$exe")")
        echo "${exe}|${dir}|Instalacion local"
        return
    fi
}

function buscar_mysql() {
    local base
    base=$(buscar_entorno "XAMPP")
    if [[ -n "$base" && -x "${base}/bin/mysql" ]]; then
        echo "${base}/bin/mysql"
        return
    fi
    if comando_existe mysql; then
        command -v mysql
    fi
}

function resetear_password_root() {
    limpiar_pantalla
    echo "======================================"
    echo "  RESETEAR PASSWORD ROOT MySQL/MariaDB"
    echo "======================================"
    echo ""

    if ! es_root; then
        echo -e "${C_RED}Se necesitan permisos de root/administrador para esta operacion.${C_RST}"
        pause
        return
    fi

    local info
    info=$(buscar_mysqld)
    if [[ -z "$info" ]]; then
        echo -e "${C_RED}No se encontro mysqld en el sistema.${C_RST}"
        pause
        return
    fi

    local mysqldExe basePath tipo
    IFS='|' read -r mysqldExe basePath tipo <<< "$info"

    local mysqlExe
    mysqlExe=$(buscar_mysql)
    if [[ -z "$mysqlExe" ]]; then
        echo -e "${C_RED}No se encontro mysql (cliente) en el sistema.${C_RST}"
        pause
        return
    fi

    echo -e "${C_CYAN}Motor encontrado: ${tipo}${C_RST}"
    echo -e "${C_GRAY}mysqld: ${mysqldExe}${C_RST}"
    echo -e "${C_GRAY}mysql:  ${mysqlExe}${C_RST}"
    echo ""
    echo -e "${C_YELLOW}ATENCION: Este proceso detendra el servidor MySQL/MariaDB temporalmente.${C_RST}"
    echo ""
    read -rp "Continuar? (s/n): " confirmar
    if [[ "$confirmar" != "s" ]]; then
        return
    fi

    local pass1 pass2
    read -rsp "Introduce la nueva password para root: " pass1
    echo ""
    read -rsp "Repite la nueva password: " pass2
    echo ""
    if [[ -z "$pass1" || "$pass1" != "$pass2" ]]; then
        echo -e "${C_RED}Las passwords no coinciden o estan vacias.${C_RST}"
        pause
        return
    fi

    echo ""
    echo -e "${C_YELLOW}Paso 1: Deteniendo servidor MySQL/MariaDB...${C_RST}"
    systemctl stop mysql mariadb 2>/dev/null || true
    detener_servicio_nativo mysql 2>/dev/null || true
    detener_servicio_nativo mariadb 2>/dev/null || true
    local pid
    pid=$(pgrep -x mysqld 2>/dev/null | head -n1 || true)
    if [[ -n "$pid" ]]; then
        local mysqladmin
        mysqladmin=$(dirname "$mysqlExe")/mysqladmin
        if [[ -x "$mysqladmin" ]]; then
            "$mysqladmin" -u root shutdown 2>/dev/null || true
            sleep 3
        fi
        pid=$(pgrep -x mysqld 2>/dev/null | head -n1 || true)
        if [[ -n "$pid" ]]; then
            kill -9 "$pid" 2>/dev/null || true
            sleep 2
        fi
    fi

    if pgrep -x mysqld &>/dev/null; then
        echo -e "${C_RED}No se pudo detener MySQL/MariaDB.${C_RST}"
        pause
        return
    fi
    echo -e "${C_GREEN}Servidor detenido.${C_RST}"

    echo -e "${C_YELLOW}Paso 2: Iniciando en modo skip-grant-tables...${C_RST}"
    local myIni
    myIni="${basePath}/etc/my.cnf"
    [[ ! -f "$myIni" ]] && myIni="${basePath}/mysql/bin/my.cnf"
    [[ ! -f "$myIni" ]] && myIni="/etc/mysql/my.cnf"

    local args=("--skip-grant-tables" "--skip-networking")
    [[ -f "$myIni" ]] && args=("--defaults-file=${myIni}" "--skip-grant-tables" "--skip-networking")

    nohup "$mysqldExe" "${args[@]}" &>/tmp/mysqld_skip.log &
    sleep 4

    if ! pgrep -f "skip-grant-tables" &>/dev/null; then
        echo -e "${C_RED}No se pudo iniciar mysqld en modo seguro.${C_RST}"
        pause
        return
    fi
    local skip_pid
    skip_pid=$(pgrep -f "skip-grant-tables" | head -n1)
    echo -e "${C_GREEN}Servidor iniciado en modo seguro (PID: ${skip_pid})${C_RST}"

    echo -e "${C_YELLOW}Paso 3: Cambiando password de root...${C_RST}"
    local passEscapada
    passEscapada=${pass1//\'/\'\'}
    local sql="FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY '${passEscapada}'; FLUSH PRIVILEGES;"

    local resultadoSQL
    resultadoSQL=$(echo "$sql" | "$mysqlExe" -u root --protocol=socket 2>&1 || true)

    if echo "$resultadoSQL" | grep -qi "ERROR"; then
        local sql2="FLUSH PRIVILEGES; SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${passEscapada}'); FLUSH PRIVILEGES;"
        resultadoSQL=$(echo "$sql2" | "$mysqlExe" -u root --protocol=socket 2>&1 || true)
    fi

    echo -e "${C_YELLOW}Paso 4: Deteniendo servidor en modo seguro...${C_RST}"
    kill -9 "$skip_pid" 2>/dev/null || true
    sleep 2

    if echo "$resultadoSQL" | grep -qi "ERROR"; then
        echo -e "${C_RED}Hubo un problema al cambiar la password:${C_RST}"
        echo "$resultadoSQL" | sed "s/^/${C_RED}/;s/$/${C_RST}/"
    else
        echo ""
        echo -e "${C_GREEN}Password de root cambiada correctamente.${C_RST}"
        echo -e "${C_GREEN}Ahora puedes iniciar el servidor normalmente desde el menu.${C_RST}"
    fi
    pause
}

# ---------------------------------------------------------------------------
# Terminal de base de datos
# ---------------------------------------------------------------------------

function buscar_ejecutable() {
    local archivo="$1"
    if comando_existe "$archivo"; then
        command -v "$archivo"
        return
    fi
    local raices=(
        "/usr/bin" "/usr/local/bin" "/snap/bin"
        "/opt/lampp/bin" "/opt/mongodb/bin" "/opt/lampp/redis/bin"
        "/opt/bitnami/mysql/bin" "/opt/bitnami/postgresql/bin"
        "/opt/bitnami/redis/bin" "/opt/bitnami/mongodb/bin"
        "/opt/influxdb" "/opt/neo4j/bin" "/var/lib/neo4j/bin"
        "/opt/cockroach" "/opt/firebird/bin" "/opt/ampps/mysql/bin"
    )
    # Anadir rutas extra del usuario (sus subdirectorios bin tambien)
    local extra
    while IFS= read -r extra; do
        [[ -n "$extra" ]] && raices+=("$extra" "${extra}/bin")
    done < <(rutas_extra_usuario)
    local r
    for r in "${raices[@]}"; do
        if [[ -x "${r}/${archivo}" ]]; then
            echo "${r}/${archivo}"
            return
        fi
    done
}

function abrir_terminal_db() {
    local nombre="$1"
    local exe args term
    nombre=$(echo "$nombre" | tr '[:upper:]' '[:lower:]')

    term="${TERMINAL:-}"
    if [[ -z "$term" ]]; then
        for c in gnome-terminal konsole xfce4-terminal mate-terminal terminator alacritty xterm; do
            if comando_existe "$c"; then
                term="$c"
                break
            fi
        done
    fi

    if [[ -z "$term" ]]; then
        echo -e "${C_RED}No se encontro un emulador de terminal instalado.${C_RST}"
        return
    fi

    if [[ "$nombre" == *"mysql"* || "$nombre" == *"maria"* ]]; then
        exe=$(buscar_ejecutable "mysql")
        args="-u root -p"
        if [[ -n "$exe" ]]; then
            echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
            nohup "$term" -e "${exe} ${args}" &>/dev/null &
        fi
    elif [[ "$nombre" == *"mongo"* ]]; then
        exe=$(buscar_ejecutable "mongosh")
        if [[ -z "$exe" ]]; then
            echo -e "${C_RED}--- ERROR DE COMPONENTES ---${C_RST}"
            echo -e "${C_YELLOW}Se detecto el servidor MongoDB, pero falta el cliente 'mongosh'.${C_RST}"
            echo -e "${C_CYAN}Instalalo con el gestor de paquetes de tu distribucion.${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "$exe" &>/dev/null &
    elif [[ "$nombre" == *"postgres"* ]]; then
        exe=$(buscar_ejecutable "psql")
        args="-U postgres"
        if [[ -n "$exe" ]]; then
            echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
            nohup "$term" -e "${exe} ${args}" &>/dev/null &
        fi
    elif [[ "$nombre" == *"redis"* ]]; then
        exe=$(buscar_ejecutable "redis-cli")
        if [[ -z "$exe" ]]; then
            echo -e "${C_RED}--- ERROR DE COMPONENTES ---${C_RST}"
            echo -e "${C_YELLOW}Se detecto el servidor Redis, pero falta el cliente 'redis-cli'.${C_RST}"
            echo -e "${C_CYAN}Instalalo con: sudo apt install redis-tools${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "$exe" &>/dev/null &
    elif [[ "$nombre" == *"couchdb"* || "$nombre" == *"couch"* ]]; then
        echo -e "${C_CYAN}CouchDB se administra via HTTP (Fauxton en http://localhost:5984/_utils)${C_RST}"
        echo -e "${C_YELLOW}Usa 'curl' desde una terminal para interactuar con la API REST.${C_RST}"
        return
    elif [[ "$nombre" == *"influx"* ]]; then
        exe=$(buscar_ejecutable "influx")
        if [[ -z "$exe" ]]; then
            echo -e "${C_YELLOW}No se encontro el cliente 'influx'. InfluxDB tambien se administra via HTTP en http://localhost:8086${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "$exe" &>/dev/null &
    elif [[ "$nombre" == *"clickhouse"* ]]; then
        exe=$(buscar_ejecutable "clickhouse-client")
        if [[ -z "$exe" ]]; then
            echo -e "${C_YELLOW}No se encontro 'clickhouse-client'. Prueba: clickhouse client${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "$exe" &>/dev/null &
    elif [[ "$nombre" == *"cockroach"* ]]; then
        exe=$(buscar_ejecutable "cockroach")
        if [[ -n "$exe" ]]; then
            echo -e "${C_CYAN}Lanzando terminal: ${exe} sql --insecure${C_RST}"
            nohup "$term" -e "${exe} sql --insecure" &>/dev/null &
        fi
    elif [[ "$nombre" == *"arango"* ]]; then
        exe=$(buscar_ejecutable "arangosh")
        if [[ -z "$exe" ]]; then
            echo -e "${C_YELLOW}No se encontro 'arangosh'. ArangoDB tambien tiene panel web en http://localhost:8529${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "$exe" &>/dev/null &
    elif [[ "$nombre" == *"neo4j"* ]]; then
        exe=$(buscar_ejecutable "cypher-shell")
        if [[ -z "$exe" ]]; then
            echo -e "${C_YELLOW}No se encontro 'cypher-shell'. Neo4j tiene panel web (Neo4j Browser) en http://localhost:7474${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "${exe} -u neo4j -p neo4j" &>/dev/null &
    elif [[ "$nombre" == *"rethink"* ]]; then
        echo -e "${C_CYAN}RethinkDB se administra via panel web en http://localhost:8080${C_RST}"
        return
    elif [[ "$nombre" == *"memcache"* ]]; then
        if comando_existe nc; then
            echo -e "${C_CYAN}Conectando a Memcached con 'nc localhost 11211' (escribe 'stats' o 'quit')${C_RST}"
            nohup "$term" -e "nc localhost 11211" &>/dev/null &
        else
            echo -e "${C_YELLOW}Memcached no tiene cliente propio. Usa 'telnet localhost 11211' o 'nc localhost 11211'.${C_RST}"
        fi
        return
    elif [[ "$nombre" == *"firebird"* ]]; then
        exe=$(buscar_ejecutable "isql-fb")
        [[ -z "$exe" ]] && exe=$(buscar_ejecutable "isql")
        if [[ -z "$exe" ]]; then
            echo -e "${C_YELLOW}No se encontro el cliente 'isql-fb' de Firebird.${C_RST}"
            return
        fi
        echo -e "${C_CYAN}Lanzando terminal: ${exe}${C_RST}"
        nohup "$term" -e "$exe" &>/dev/null &
    fi
}

# ---------------------------------------------------------------------------
# Diagnostico completo
# ---------------------------------------------------------------------------

function diagnostico_completo() {
    limpiar_pantalla
    echo "======================================"
    echo "  DIAGNOSTICO COMPLETO DEL EQUIPO"
    echo "======================================"
    echo ""

    local servicios entornos
    servicios=$(detectar_servicios)
    entornos=$(detectar_servidores_entorno)

    echo "SERVIDORES DE BASE DE DATOS"
    local total=0
    local nombre estado puerto ram salud
    while IFS='|' read -r nombre estado puerto; do
        [[ -z "$nombre" ]] && continue
        ram=$(obtener_ram "$nombre")
        if [[ "$estado" == "active" ]]; then
            salud=$(comprobar_salud "$nombre" "$puerto")
            echo -e "${C_GREEN}${nombre} ACTIVO  RAM:${ram}MB  PUERTO:${puerto}  SALUD:${salud}${C_RST}"
            total=$((total + ram))
        else
            echo -e "${C_RED}${nombre} DETENIDO  PUERTO:${puerto}${C_RST}"
        fi
    done <<< "$servicios"

    local eNombre eTipo eEstado ePuerto eRam ePid
    while IFS='|' read -r eNombre eTipo eEstado ePuerto eRam ePid _; do
        [[ -z "$eNombre" ]] && continue
        if [[ "$eEstado" == "Running" ]]; then
            salud=$(comprobar_salud "$eNombre" "$ePuerto")
            echo -e "${C_CYAN}${eNombre} ACTIVO  RAM:${eRam}MB  PUERTO:${ePuerto}  SALUD:${salud}${C_RST}"
            total=$((total + eRam))
        else
            echo -e "${C_RED}${eNombre} DETENIDO  PUERTO:${ePuerto}${C_RST}"
        fi
    done <<< "$entornos"

    echo ""
    echo "PUERTOS USADOS POR LAS BASES DE DATOS"
    local p pid_p proc_p
    for p in "${PUERTOS_BD[@]}"; do
        if puerto_ocupado "$p"; then
            pid_p=$(pid_del_puerto "$p")
            proc_p=$(ps -p "$pid_p" -o comm= 2>/dev/null || echo "desconocido")
            echo -e "${C_YELLOW}Puerto ${p} ocupado por ${proc_p}${C_RST}"
        else
            echo -e "${C_GREEN}Puerto ${p} libre${C_RST}"
        fi
    done

    echo ""
    echo "USO DE MEMORIA POR LAS BASES DE DATOS"
    while IFS='|' read -r nombre estado _; do
        ram=$(obtener_ram "$nombre")
        if [[ "$ram" -gt 0 ]]; then
            echo "${nombre} usa ${ram}MB"
        fi
    done <<< "$servicios"
    while IFS='|' read -r eNombre _ eEstado _ eRam _; do
        if [[ "$eEstado" == "Running" && "$eRam" -gt 0 ]]; then
            echo -e "${C_CYAN}${eNombre} usa ${eRam}MB${C_RST}"
        fi
    done <<< "$entornos"
    echo "RAM total usada por BBDD: ${total} MB"

    echo ""
    echo "DETECCION DE ENTORNOS QUE PUEDEN CAUSAR CONFLICTOS"
    detectar_entornos_web

    echo ""
    echo "RECOMENDACIONES"
    if [[ "$total" -gt 2000 ]]; then
        echo -e "${C_YELLOW}- Mucha RAM usada por las bases de datos. Detener alguno.${C_RST}"
    fi
    for p in "${PUERTOS_BD[@]}"; do
        if puerto_ocupado "$p"; then
            echo -e "${C_YELLOW}- Revisar conflicto en puerto ${p}${C_RST}"
        fi
    done
    pause
}

# ---------------------------------------------------------------------------
# Exportar diagnostico a archivo
# ---------------------------------------------------------------------------

function generar_informe_diagnostico() {
    local servicios entornos total=0 nombre estado puerto ram salud p
    servicios=$(detectar_servicios)
    entornos=$(detectar_servidores_entorno)

    echo "======================================"
    echo "  INFORME DE DIAGNOSTICO - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================"
    echo ""
    echo "SERVIDORES DE BASE DE DATOS"
    while IFS='|' read -r nombre estado puerto; do
        [[ -z "$nombre" ]] && continue
        ram=$(obtener_ram "$nombre")
        if [[ "$estado" == "active" ]]; then
            salud=$(comprobar_salud "$nombre" "$puerto")
            echo "${nombre} ACTIVO  RAM:${ram}MB  PUERTO:${puerto}  SALUD:${salud}"
            total=$((total + ram))
        else
            echo "${nombre} DETENIDO  PUERTO:${puerto}"
        fi
    done <<< "$servicios"
    while IFS='|' read -r eNombre eTipo eEstado ePuerto eRam ePid _; do
        [[ -z "$eNombre" ]] && continue
        if [[ "$eEstado" == "Running" ]]; then
            salud=$(comprobar_salud "$eNombre" "$ePuerto")
            echo "${eNombre} ACTIVO  RAM:${eRam}MB  PUERTO:${ePuerto}  SALUD:${salud}"
            total=$((total + eRam))
        else
            echo "${eNombre} DETENIDO  PUERTO:${ePuerto}"
        fi
    done <<< "$entornos"
    echo ""
    echo "PUERTOS USADOS POR LAS BASES DE DATOS"
    for p in "${PUERTOS_BD[@]}"; do
        if puerto_ocupado "$p"; then
            echo "Puerto ${p} OCUPADO"
        else
            echo "Puerto ${p} libre"
        fi
    done
    echo ""
    echo "RAM total usada por BBDD: ${total} MB"
    echo ""
    echo "CONTENEDORES DE BD"
    listar_contenedores_bd || echo "Ninguno detectado"
    echo ""
    echo "FIN DEL INFORME"
}

function exportar_diagnostico() {
    local archivo="${1:-}"
    if [[ -z "$archivo" ]]; then
        read -rp "Ruta del archivo de salida: " archivo
    fi
    [[ -z "$archivo" ]] && return 1
    if generar_informe_diagnostico > "$archivo" 2>/dev/null; then
        if [[ "$MODO_CLI" == true ]]; then
            echo "Diagnostico exportado a: ${archivo}"
        else
            echo -e "${C_GREEN}Diagnostico exportado a: ${archivo}${C_RST}"
        fi
        registrar_log "export-diagnostico archivo=${archivo} resultado=ok"
    else
        if [[ "$MODO_CLI" == true ]]; then
            echo "No se pudo escribir en: ${archivo}"
        else
            echo -e "${C_RED}No se pudo escribir en: ${archivo}${C_RST}"
        fi
        registrar_log "export-diagnostico archivo=${archivo} resultado=error"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Gestion de contenedores Docker / Podman
# ---------------------------------------------------------------------------

function listar_contenedores_bd() {
    local motor id nombre imagen puertos estado linea
    for motor in docker podman; do
        comando_existe "$motor" || continue
        while IFS='|' read -r id nombre imagen puertos estado; do
            [[ -z "$id" ]] && continue
            linea="${nombre} ${imagen}"
            if echo "$linea" | grep -Eiq "$PATRON_BD_CONT"; then
                echo "${motor}|${id}|${nombre}|${imagen}|${puertos}|${estado}"
            fi
        done < <("${motor}" ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' 2>/dev/null || true)
    done
}

function accion_contenedor() {
    local motor="$1" accion="$2" nombre="$3"
    case "$accion" in
        start)  "$motor" start "$nombre" 2>/dev/null ;;
        stop)   "$motor" stop "$nombre" 2>/dev/null ;;
        restart) "$motor" restart "$nombre" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

function gestionar_contenedores() {
    limpiar_pantalla
    echo "======================================"
    echo "  GESTION DE CONTENEDORES DE BD"
    echo "======================================"
    echo ""

    mapfile -t CONT_LISTA < <(listar_contenedores_bd)
    if [[ ${#CONT_LISTA[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}No se detectaron contenedores de bases de datos.${C_RST}"
        echo "Asegurate de que Docker o Podman este instalado y en ejecucion."
        pause
        return
    fi

    local i partes motor id nombre imagen puertos estado
    echo "CONTENEDORES DETECTADOS:"
    for ((i = 0; i < ${#CONT_LISTA[@]}; i++)); do
        IFS='|' read -r motor id nombre imagen puertos estado <<< "${CONT_LISTA[$i]}"
        echo "  [$((i + 1))] [${motor}] ${nombre}  (${imagen})  ${estado}  ${puertos}"
    done
    echo ""
    echo "1 Iniciar contenedor"
    echo "2 Detener contenedor"
    echo "3 Reiniciar contenedor"
    echo "0 Volver"
    echo ""
    read -rp "Accion: " acc
    [[ "$acc" == "0" || -z "$acc" ]] && return

    read -rp "Numero de contenedor: " num
    if [[ ! "$num" =~ ^[0-9]+$ || "$num" -lt 1 || "$num" -gt ${#CONT_LISTA[@]} ]]; then
        echo -e "${C_RED}Numero no valido.${C_RST}"
        pause
        return
    fi

    IFS='|' read -r motor id nombre imagen puertos estado <<< "${CONT_LISTA[$((num - 1))]}"
    local accion_cmd=""
    case "$acc" in
        1) accion_cmd="start" ;;
        2) accion_cmd="stop" ;;
        3) accion_cmd="restart" ;;
        *) echo -e "${C_RED}Accion no valida.${C_RST}"; pause; return ;;
    esac

    if accion_contenedor "$motor" "$accion_cmd" "$nombre"; then
        echo -e "${C_GREEN}Contenedor ${nombre} (${accion_cmd}) ejecutado correctamente.${C_RST}"
        registrar_log "container ${accion_cmd} motor=${motor} nombre=${nombre} resultado=ok"
    else
        echo -e "${C_RED}Error al ${accion_cmd} el contenedor ${nombre}.${C_RST}"
        registrar_log "container ${accion_cmd} motor=${motor} nombre=${nombre} resultado=error"
    fi
    pause
}

# ---------------------------------------------------------------------------
# Docker Compose (proyectos con servicios de BD)
# ---------------------------------------------------------------------------

function compose_disponible() {
    comando_existe docker && docker compose version &>/dev/null && return 0
    comando_existe docker-compose && return 0
    return 1
}

function listar_proyectos_compose() {
    local dir f extra
    # Acotamos a directorios de desarrollo habituales en lugar de recorrer todo
    # $HOME (evita escanear ~/.cache, ~/.config, etc. y penalizar la respuesta).
    local -a dirs=(
        "$SCRIPT_DIR"
        "$HOME/projects" "$HOME/Projects" "$HOME/dev" "$HOME/git"
        "$HOME/repos" "$HOME/code" "$HOME/src" "$HOME/docker" "$HOME/workspace"
        "/opt" "/srv"
    )
    while IFS= read -r extra; do
        [[ -n "$extra" ]] && dirs+=("$extra")
    done < <(rutas_extra_usuario)

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            if grep -Eiq "$PATRON_BD_CONT" "$f" 2>/dev/null; then
                echo "$f"
            fi
        done < <(find "$dir" -maxdepth 3 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null)
    done | sort -u
}

function compose_ejecutar() {
    local accion="$1" ruta="$2" dir archivo
    if ! compose_disponible; then
        echo -e "${C_RED}Docker Compose no esta disponible en el sistema.${C_RST}"
        return 1
    fi
    if [[ -f "$ruta" ]]; then
        dir=$(dirname "$ruta")
        archivo=$(basename "$ruta")
    elif [[ -d "$ruta" ]]; then
        dir="$ruta"
        archivo=""
        [[ -f "${dir}/docker-compose.yml" ]] && archivo="docker-compose.yml"
        [[ -z "$archivo" && -f "${dir}/compose.yml" ]] && archivo="compose.yml"
    else
        echo -e "${C_RED}Ruta no valida: ${ruta}${C_RST}"
        return 1
    fi
    local flags=""
    [[ "$accion" == "up" ]] && flags="-d"
    if docker compose version &>/dev/null; then
        if [[ -n "$archivo" ]]; then
            (cd "$dir" && docker compose -f "$archivo" "$accion" $flags) || return 1
        else
            (cd "$dir" && docker compose "$accion" $flags) || return 1
        fi
    else
        if [[ -n "$archivo" ]]; then
            (cd "$dir" && docker-compose -f "$archivo" "$accion" $flags) || return 1
        else
            (cd "$dir" && docker-compose "$accion" $flags) || return 1
        fi
    fi
    registrar_log "compose-${accion} ruta=${dir} resultado=ok"
    return 0
}

function gestionar_compose() {
    limpiar_pantalla
    echo "======================================"
    echo "  GESTION DOCKER COMPOSE (BD)"
    echo "======================================"
    echo ""

    if ! compose_disponible; then
        echo -e "${C_YELLOW}Docker Compose no esta instalado o no responde.${C_RST}"
        pause
        return
    fi

    mapfile -t COMPOSE_LISTA < <(listar_proyectos_compose)
    if [[ ${#COMPOSE_LISTA[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}No se detectaron proyectos Docker Compose con servicios de BD.${C_RST}"
        pause
        return
    fi

    local i f
    echo "PROYECTOS DETECTADOS:"
    for ((i = 0; i < ${#COMPOSE_LISTA[@]}; i++)); do
        f="${COMPOSE_LISTA[$i]}"
        echo "  [$((i + 1))] ${f}"
    done
    echo ""
    echo "1 Levantar proyecto (docker compose up -d)"
    echo "2 Detener proyecto (docker compose down)"
    echo "0 Volver"
    echo ""
    read -rp "Accion: " acc
    [[ "$acc" == "0" || -z "$acc" ]] && return

    read -rp "Numero de proyecto: " num
    if [[ ! "$num" =~ ^[0-9]+$ || "$num" -lt 1 || "$num" -gt ${#COMPOSE_LISTA[@]} ]]; then
        echo -e "${C_RED}Numero no valido.${C_RST}"
        pause
        return
    fi

    f="${COMPOSE_LISTA[$((num - 1))]}"
    case "$acc" in
        1)
            if compose_ejecutar up "$f"; then
                echo -e "${C_GREEN}Proyecto levantado: ${f}${C_RST}"
            else
                echo -e "${C_RED}Error al levantar el proyecto.${C_RST}"
                registrar_log "compose-up ruta=${f} resultado=error"
            fi
            ;;
        2)
            if compose_ejecutar down "$f"; then
                echo -e "${C_GREEN}Proyecto detenido: ${f}${C_RST}"
            else
                echo -e "${C_RED}Error al detener el proyecto.${C_RST}"
                registrar_log "compose-down ruta=${f} resultado=error"
            fi
            ;;
        *) echo -e "${C_RED}Accion no valida.${C_RST}" ;;
    esac
    pause
}

# ---------------------------------------------------------------------------
# Salida JSON (modo CLI)
# ---------------------------------------------------------------------------

function json_str() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    printf '"%s"' "$s"
}

function cli_status_json() {
    local servicios entornos nombre estado puerto ram salud first=true
    servicios=$(detectar_servicios)
    entornos=$(detectar_servidores_entorno)
    echo "{"
    echo -n "  \"init_system\": "; json_str "$INIT_SYSTEM"; echo ","
    echo "  \"servidores\": ["
    while IFS='|' read -r nombre estado puerto; do
        [[ -z "$nombre" ]] && continue
        ram=$(obtener_ram "$nombre")
        salud=""
        [[ "$estado" == "active" ]] && salud=$(comprobar_salud "$nombre" "$puerto")
        [[ "$first" == true ]] || echo ","
        first=false
        echo -n "    {\"nombre\":$(json_str "$nombre"),\"tipo\":\"servicio\",\"estado\":$(json_str "$estado"),\"puerto\":${puerto},\"ram_mb\":${ram}"
        [[ -n "$salud" ]] && echo -n ",\"salud\":$(json_str "$salud")"
        echo -n "}"
    done <<< "$servicios"
    echo ""
    first=true
    echo "  ],"
    echo "  \"entornos\": ["
    while IFS='|' read -r eNombre eTipo eEstado ePuerto eRam _; do
        [[ -z "$eNombre" ]] && continue
        salud=""
        [[ "$eEstado" == "Running" ]] && salud=$(comprobar_salud "$eNombre" "$ePuerto")
        [[ "$first" == true ]] || echo ","
        first=false
        echo -n "    {\"nombre\":$(json_str "$eNombre"),\"tipo\":$(json_str "$eTipo"),\"estado\":$(json_str "$eEstado"),\"puerto\":${ePuerto},\"ram_mb\":${eRam}"
        [[ -n "$salud" ]] && echo -n ",\"salud\":$(json_str "$salud")"
        echo -n "}"
    done <<< "$entornos"
    echo ""
    first=true
    echo "  ],"
    echo "  \"contenedores\": ["
    while IFS='|' read -r motor id nombre imagen puertos estado; do
        [[ -z "$motor" ]] && continue
        [[ "$first" == true ]] || echo ","
        first=false
        echo "    {\"motor\":$(json_str "$motor"),\"id\":$(json_str "$id"),\"nombre\":$(json_str "$nombre"),\"imagen\":$(json_str "$imagen"),\"puertos\":$(json_str "$puertos"),\"estado\":$(json_str "$estado")}"
    done < <(listar_contenedores_bd)
    echo ""
    echo "  ],"
    echo -n "  \"proyectos_compose\": ["
    first=true
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$first" == true ]] || echo -n ","
        first=false
        echo -n "$(json_str "$f")"
    done < <(listar_proyectos_compose)
    echo ""
    echo "  ]"
    echo "}"
}

# ---------------------------------------------------------------------------
# Modo CLI (no interactivo)
# ---------------------------------------------------------------------------

RESOLVER_TIPO=""
RESOLVER_NOMBRE=""
RESOLVER_SERVICIO=""
RESOLVER_ENTORNO=""

function contar_servidores_activos() {
    local n=0 servicios entornos nombre estado
    servicios=$(detectar_servicios)
    while IFS='|' read -r nombre estado _; do
        [[ -z "$nombre" ]] && continue
        [[ "$estado" == "active" ]] && n=$((n + 1))
    done <<< "$servicios"
    entornos=$(detectar_servidores_entorno)
    while IFS='|' read -r _ _ estado _; do
        [[ "$estado" == "Running" ]] && n=$((n + 1))
    done <<< "$entornos"
    echo "$n"
}

function resolver_servidor() {
    local busqueda="$1" b nombre estado puerto entornos
    b=$(echo "$busqueda" | tr '[:upper:]' '[:lower:]')
    RESOLVER_TIPO=""; RESOLVER_NOMBRE=""; RESOLVER_SERVICIO=""; RESOLVER_ENTORNO=""

    local servicios
    servicios=$(detectar_servicios)
    while IFS='|' read -r nombre estado puerto; do
        [[ -z "$nombre" ]] && continue
        if [[ "$(echo "$nombre" | tr '[:upper:]' '[:lower:]')" == *"$b"* ]]; then
            RESOLVER_TIPO="servicio"
            RESOLVER_NOMBRE="$nombre"
            RESOLVER_SERVICIO="$nombre"
            return 0
        fi
    done <<< "$servicios"

    entornos=$(detectar_servidores_entorno)
    while IFS='|' read -r eNombre eTipo eEstado ePuerto eRam ePid eBase eProc eStart eStop; do
        [[ -z "$eNombre" ]] && continue
        if [[ "$(echo "$eNombre" | tr '[:upper:]' '[:lower:]')" == *"$b"* ]] \
            || [[ "$(echo "$eTipo" | tr '[:upper:]' '[:lower:]')" == *"$b"* ]]; then
            RESOLVER_TIPO="entorno"
            RESOLVER_NOMBRE="$eNombre"
            RESOLVER_ENTORNO="${eNombre}|${eTipo}|${eEstado}|${ePuerto}|${eRam}|${ePid}|${eBase}|${eProc}|${eStart}|${eStop}"
            return 0
        fi
    done <<< "$entornos"
    return 1
}

function cli_status() {
    [[ "$CLI_JSON" == true ]] && { cli_status_json; return 0; }
    local servicios entornos nombre estado puerto ram salud
    servicios=$(detectar_servicios)
    entornos=$(detectar_servidores_entorno)
    echo "ESTADO DE SERVIDORES DE BD"
    echo "--------------------------"
    while IFS='|' read -r nombre estado puerto; do
        [[ -z "$nombre" ]] && continue
        ram=$(obtener_ram "$nombre")
        if [[ "$estado" == "active" ]]; then
            salud=$(comprobar_salud "$nombre" "$puerto")
            echo "[SERVICIO] ${nombre} ACTIVO  puerto=${puerto}  RAM=${ram}MB  salud=${salud}"
        else
            echo "[SERVICIO] ${nombre} DETENIDO  puerto=${puerto}"
        fi
    done <<< "$servicios"
    while IFS='|' read -r eNombre eTipo eEstado ePuerto eRam _; do
        [[ -z "$eNombre" ]] && continue
        if [[ "$eEstado" == "Running" ]]; then
            salud=$(comprobar_salud "$eNombre" "$ePuerto")
            echo "[${eTipo}] ${eNombre} ACTIVO  puerto=${ePuerto}  RAM=${eRam}MB  salud=${salud}"
        else
            echo "[${eTipo}] ${eNombre} DETENIDO  puerto=${ePuerto}"
        fi
    done <<< "$entornos"
    echo ""
    echo "CONTENEDORES DE BD"
    listar_contenedores_bd | while IFS='|' read -r motor id nombre imagen puertos estado; do
        echo "[${motor}] ${nombre}  ${estado}  ${puertos}"
    done
}

function cli_ejecutar_accion() {
    local accion="$1" busqueda="$2" activos
    [[ -z "$busqueda" ]] && { echo "Uso: --${accion} <nombre>"; return 1; }
    resolver_servidor "$busqueda" || { echo "No se encontro servidor: ${busqueda}"; return 1; }
    activos=$(contar_servidores_activos)

    case "$accion" in
        start)
            if [[ "$RESOLVER_TIPO" == "servicio" ]]; then
                iniciar_servidor "$RESOLVER_SERVICIO" "$activos"
            else
                IFS='|' read -r _ _ estado _ <<< "$RESOLVER_ENTORNO"
                if [[ "$estado" == "Running" ]]; then
                    echo "Ya activo: ${RESOLVER_NOMBRE}"
                elif [[ "$activos" -ge "$MAX_ACTIVOS" ]]; then
                    echo "Solo se permiten ${MAX_ACTIVOS} servidores activos."
                    return 1
                else
                    iniciar_entorno "$RESOLVER_ENTORNO"
                fi
            fi
            ;;
        stop)
            if [[ "$RESOLVER_TIPO" == "servicio" ]]; then
                detener_servidor "$RESOLVER_SERVICIO"
            else
                detener_entorno "$RESOLVER_ENTORNO"
            fi
            ;;
        restart)
            if [[ "$RESOLVER_TIPO" == "servicio" ]]; then
                reiniciar_servidor "$RESOLVER_SERVICIO"
            else
                reiniciar_entorno "$RESOLVER_ENTORNO"
            fi
            ;;
        health)
            local puerto estado salud
            if [[ "$RESOLVER_TIPO" == "servicio" ]]; then
                puerto=$(obtener_puerto "$RESOLVER_SERVICIO")
                estado=$(servicio_estado "$RESOLVER_SERVICIO")
            else
                IFS='|' read -r _ _ estado puerto _ <<< "$RESOLVER_ENTORNO"
            fi
            salud=$(comprobar_salud "$RESOLVER_NOMBRE" "$puerto")
            if [[ "$CLI_JSON" == true ]]; then
                echo "{\"nombre\":$(json_str "$RESOLVER_NOMBRE"),\"estado\":$(json_str "$estado"),\"puerto\":${puerto},\"salud\":$(json_str "$salud")}"
            else
                echo "${RESOLVER_NOMBRE}: estado=${estado} puerto=${puerto} salud=${salud}"
            fi
            registrar_log "cli-health nombre=${RESOLVER_NOMBRE} salud=${salud}"
            ;;
    esac
}

function mostrar_ayuda_cli() {
    cat <<EOF
Uso: gestor_bbdd.sh [opciones]

Modo interactivo (por defecto):
  sudo bash gestor_bbdd.sh

Modo CLI (no interactivo):
  --status                  Muestra estado de servidores y contenedores
  --start <nombre>          Inicia un servidor (coincidencia parcial)
  --stop <nombre>           Detiene un servidor
  --restart <nombre>        Reinicia un servidor
  --health <nombre>         Comprueba salud/conectividad
  --diagnose                Muestra diagnostico completo en pantalla
  --export <archivo>        Exporta diagnostico a un archivo de texto
  --containers              Lista contenedores Docker/Podman de BD
  --container-start <nombre>   Inicia contenedor por nombre
  --container-stop <nombre>    Detiene contenedor por nombre
  --container-restart <nombre> Reinicia contenedor por nombre
  --compose-list            Lista proyectos Docker Compose con servicios de BD
  --compose-up <ruta>       Levanta un proyecto compose (ruta al yml o directorio)
  --compose-down <ruta>     Detiene un proyecto compose
  --ports                   Muestra los puertos en escucha
  --detect                  Detecta entornos locales (XAMPP/WAMP/Docker/etc.)
  --help-services           Ayuda para configurar servicios en modo manual
  --reset-password [motor]  Resetea la contrasena root de MySQL/MariaDB (interactivo)
  --open-terminal <nombre>  Abre una terminal del cliente del servidor indicado
  --json                    Salida en formato JSON (con --status, --diagnose, --health, etc.)
  -h, --help                Muestra esta ayuda

Ejemplos:
  sudo bash gestor_bbdd.sh --status
  sudo bash gestor_bbdd.sh --json --status
  sudo bash gestor_bbdd.sh --start mysql
  sudo bash gestor_bbdd.sh --compose-up /opt/mi-proyecto/docker-compose.yml
  sudo bash gestor_bbdd.sh --export /tmp/diagnostico_bd.txt
EOF
}

function cli_accion_contenedor() {
    local accion="$1" busqueda="$2" linea motor nombre
    [[ -z "$busqueda" ]] && { echo "Uso: --container-${accion} <nombre>"; return 1; }
    local b encontrado=false
    b=$(echo "$busqueda" | tr '[:upper:]' '[:lower:]')
    while IFS='|' read -r motor id nombre imagen puertos estado; do
        [[ -z "$motor" ]] && continue
        if [[ "$(echo "$nombre" | tr '[:upper:]' '[:lower:]')" == *"$b"* ]]; then
            encontrado=true
            if accion_contenedor "$motor" "$accion" "$nombre"; then
                echo "Contenedor ${nombre} (${accion}) OK"
                registrar_log "cli-container-${accion} motor=${motor} nombre=${nombre} resultado=ok"
                return 0
            fi
            echo "Error al ${accion} contenedor ${nombre}"
            registrar_log "cli-container-${accion} motor=${motor} nombre=${nombre} resultado=error"
            return 1
        fi
    done < <(listar_contenedores_bd)
    [[ "$encontrado" == false ]] && echo "No se encontro contenedor: ${busqueda}"
    return 1
}

function cli_compose_list() {
    local first=true f
    if [[ "$CLI_JSON" == true ]]; then
        echo -n '{"proyectos":['
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ "$first" == true ]] || echo -n ","
            first=false
            echo -n "$(json_str "$f")"
        done < <(listar_proyectos_compose)
        echo "]}"
        return 0
    fi
    echo "PROYECTOS DOCKER COMPOSE (BD)"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "  ${f}"
    done < <(listar_proyectos_compose)
}

function procesar_cli() {
    local args=() arg
    for arg in "$@"; do
        case "$arg" in
            --json) CLI_JSON=true ;;
            *) args+=("$arg") ;;
        esac
    done
    case "${args[0]:-}" in
        -h|--help) mostrar_ayuda_cli; return 0 ;;
        --status) cli_status; return 0 ;;
        --start) cli_ejecutar_accion start "${args[1]:-}"; return $? ;;
        --stop) cli_ejecutar_accion stop "${args[1]:-}"; return $? ;;
        --restart) cli_ejecutar_accion restart "${args[1]:-}"; return $? ;;
        --health) cli_ejecutar_accion health "${args[1]:-}"; return $? ;;
        --diagnose)
            [[ "$CLI_JSON" == true ]] && { cli_status_json; return 0; }
            generar_informe_diagnostico
            return 0
            ;;
        --export) exportar_diagnostico "${args[1]:-}"; return $? ;;
        --containers)
            if [[ "$CLI_JSON" == true ]]; then
                echo -n '{"contenedores":['
                local first=true
                while IFS='|' read -r motor id nombre imagen puertos estado; do
                    [[ -z "$motor" ]] && continue
                    [[ "$first" == true ]] || echo ","
                    first=false
                    echo -n "{\"motor\":$(json_str "$motor"),\"id\":$(json_str "$id"),\"nombre\":$(json_str "$nombre"),\"imagen\":$(json_str "$imagen"),\"puertos\":$(json_str "$puertos"),\"estado\":$(json_str "$estado")}"
                done < <(listar_contenedores_bd)
                echo "]}"
            else
                echo "CONTENEDORES DE BD"
                while IFS='|' read -r motor id nombre imagen puertos estado; do
                    [[ -z "$motor" ]] && continue
                    echo "[${motor}] ${nombre}  ${imagen}  ${estado}  ${puertos}"
                done < <(listar_contenedores_bd)
            fi
            return 0
            ;;
        --container-start) cli_accion_contenedor start "${args[1]:-}"; return $? ;;
        --container-stop) cli_accion_contenedor stop "${args[1]:-}"; return $? ;;
        --container-restart) cli_accion_contenedor restart "${args[1]:-}"; return $? ;;
        --compose-list) cli_compose_list; return 0 ;;
        --compose-up)
            [[ -z "${args[1]:-}" ]] && { echo "Uso: --compose-up <ruta>"; return 1; }
            compose_ejecutar up "${args[1]}"; return $?
            ;;
        --compose-down)
            [[ -z "${args[1]:-}" ]] && { echo "Uso: --compose-down <ruta>"; return 1; }
            compose_ejecutar down "${args[1]}"; return $?
            ;;
        --ports) ver_puertos_abiertos; return 0 ;;
        --detect) detectar_entornos_web; return 0 ;;
        --help-services) ayuda_servicios; return 0 ;;
        --reset-password) resetear_password_root; return $? ;;
        --open-terminal)
            [[ -z "${args[1]:-}" ]] && { echo "Uso: --open-terminal <nombre>"; return 1; }
            abrir_terminal_db "${args[1]}"; return 0
            ;;
        *)
            echo "Opcion desconocida: ${args[0]:-}"
            mostrar_ayuda_cli
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Menu principal
# ---------------------------------------------------------------------------

# Variables globales para mantener la lista unificada entre opciones
declare -a LISTA_TIPO
declare -a LISTA_NOMBRE
declare -a LISTA_ESTADO
declare -a LISTA_PUERTO
declare -a LISTA_RAM
declare -a LISTA_SERVICIO
declare -a LISTA_ENTORNO

function mostrar_menu() {
    limpiar_pantalla
    echo "======================================"
    echo "   LAS BASES Y SUS DATOS"
    echo "======================================"
    echo ""

    LISTA_TIPO=()
    LISTA_NOMBRE=()
    LISTA_ESTADO=()
    LISTA_PUERTO=()
    LISTA_RAM=()
    LISTA_SERVICIO=()
    LISTA_ENTORNO=()

    local servicios entornos activos=0
    servicios=$(detectar_servicios)
    entornos=$(detectar_servidores_entorno)

    # Agregar servicios systemd
    local nombre estado puerto ram
    while IFS='|' read -r nombre estado puerto; do
        [[ -z "$nombre" ]] && continue
        LISTA_TIPO+=("Servicio")
        LISTA_NOMBRE+=("$nombre")
        LISTA_ESTADO+=("$estado")
        LISTA_PUERTO+=("$puerto")
        LISTA_RAM+=("$(obtener_ram "$nombre")")
        LISTA_SERVICIO+=("$nombre")
        LISTA_ENTORNO+=("")
        if [[ "$estado" == "active" ]]; then
            activos=$((activos + 1))
        fi
    done <<< "$servicios"

    # Agregar entornos locales
    local eNombre eTipo eEstado ePuerto eRam ePid eBase eProc eStart eStop linea
    while IFS='|' read -r eNombre eTipo eEstado ePuerto eRam ePid eBase eProc eStart eStop; do
        [[ -z "$eNombre" ]] && continue
        LISTA_TIPO+=("$eTipo")
        LISTA_NOMBRE+=("$eNombre")
        LISTA_ESTADO+=("$eEstado")
        LISTA_PUERTO+=("$ePuerto")
        LISTA_RAM+=("$eRam")
        LISTA_SERVICIO+=("")
        LISTA_ENTORNO+=("${eNombre}|${eTipo}|${eEstado}|${ePuerto}|${eRam}|${ePid}|${eBase}|${eProc}|${eStart}|${eStop}")
        if [[ "$eEstado" == "Running" ]]; then
            activos=$((activos + 1))
        fi
    done <<< "$entornos"

    local total=${#LISTA_NOMBRE[@]}
    if [[ "$total" -eq 0 ]]; then
        echo -e "${C_YELLOW}No se detectaron servidores de bases de datos.${C_RST}"
    else
        echo "SERVIDORES DETECTADOS:"
        echo "----------------------"
        local i etiqueta tipo extra salud
        for ((i = 0; i < total; i++)); do
            etiqueta="${LISTA_NOMBRE[$i]}"
            tipo="${LISTA_TIPO[$i]}"
            if [[ "${LISTA_ESTADO[$i]}" == "active" || "${LISTA_ESTADO[$i]}" == "Running" ]]; then
                extra="puerto ${LISTA_PUERTO[$i]}, RAM: ${LISTA_RAM[$i]}MB"
                [[ "$tipo" != "Servicio" ]] && extra+=", ${tipo}"
                salud=$(comprobar_salud "${LISTA_NOMBRE[$i]}" "${LISTA_PUERTO[$i]}")
                case "$salud" in
                    OK) extra+=", salud: OK" ;;
                    NORESP) extra+=", salud: sin respuesta" ;;
                    NOCLI) extra+=", salud: sin cliente" ;;
                esac
                echo -e "${C_GREEN}  [$((i + 1))] ${etiqueta} - ACTIVO (${extra})${C_RST}"
            else
                extra="puerto ${LISTA_PUERTO[$i]}"
                [[ "$tipo" != "Servicio" ]] && extra+=", ${tipo}"
                echo -e "${C_RED}  [$((i + 1))] ${etiqueta} - DETENIDO (${extra})${C_RST}"
            fi
        done
    fi

    echo ""
    echo "Bases de datos activas: ${activos} / ${MAX_ACTIVOS}"
    echo ""
    echo "--- OPCIONES ---"
    echo "1 Iniciar servidor"
    echo "2 Detener servidor"
    echo "3 Reiniciar servidor"
    echo "4 Ver puertos abiertos"
    echo "5 Modo practica"
    echo "6 Detectar XAMPP/WAMP/Docker"
    echo "7 Ayuda configurar servicios"
    echo "8 Diagnostico completo del equipo"
    echo "9 Resetear password root MySQL/MariaDB"
    echo "10 Abrir TERMINAL de un servidor de DB"
    echo "11 Comprobar salud / conectividad"
    echo "12 Gestionar contenedores Docker/Podman"
    echo "13 Exportar diagnostico a archivo"
    echo "14 Gestionar proyectos Docker Compose"
    echo "0 Salir"

    ACTIVOS_MENU=$activos
}

# ---------------------------------------------------------------------------
# Ver puertos abiertos
# ---------------------------------------------------------------------------

function ver_puertos_abiertos() {
    if comando_existe ss; then
        ss -tlnp
    elif comando_existe netstat; then
        netstat -tlnp
    else
        echo -e "${C_RED}No se encontro ss ni netstat en el sistema.${C_RST}"
    fi
    pause
}

# ---------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------

function main() {
    cargar_config
    aplicar_env_config
    detectar_init

    if [[ $# -gt 0 ]]; then
        MODO_CLI=true
        procesar_cli "$@"
        exit $?
    fi

    if ! es_root; then
        echo -e "${C_YELLOW}AVISO!!: Este script necesita permisos de root/administrador para iniciar/detener servicios.${C_RST}"
        echo -e "${C_YELLOW}Algunas funciones pueden no estar disponibles.${C_RST}"
        echo ""
        pause
    fi

    while true; do
        local activos
        mostrar_menu
        activos=$ACTIVOS_MENU
        local total=${#LISTA_NOMBRE[@]}
        read -rp "Seleccione opcion: " op || break

        case "$op" in
            1)
                if [[ "$total" -eq 0 ]]; then
                    echo -e "${C_YELLOW}No hay bases de datos detectadas.${C_RST}"
                    pause
                    continue
                fi
                read -rp "Numero base de datos: " n
                if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$total" ]]; then
                    local idx=$((n - 1))
                    if [[ "${LISTA_ESTADO[$idx]}" == "active" || "${LISTA_ESTADO[$idx]}" == "Running" ]]; then
                        echo -e "${C_YELLOW}${LISTA_NOMBRE[$idx]} ya esta en ejecucion.${C_RST}"
                    elif [[ "${LISTA_TIPO[$idx]}" == "Servicio" ]]; then
                        iniciar_servidor "${LISTA_SERVICIO[$idx]}" "$activos"
                    else
                        if [[ "$activos" -ge "$MAX_ACTIVOS" ]]; then
                            echo -e "${C_RED}Solo se permiten ${MAX_ACTIVOS} servidores activos.${C_RST}"
                        else
                            iniciar_entorno "${LISTA_ENTORNO[$idx]}"
                        fi
                    fi
                else
                    echo -e "${C_RED}Numero no valido.${C_RST}"
                fi
                pause
                ;;
            2)
                if [[ "$total" -eq 0 ]]; then
                    echo -e "${C_YELLOW}No hay bases de datos detectadas.${C_RST}"
                    pause
                    continue
                fi
                read -rp "Numero base de datos: " n
                if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$total" ]]; then
                    local idx=$((n - 1))
                    if [[ "${LISTA_ESTADO[$idx]}" != "active" && "${LISTA_ESTADO[$idx]}" != "Running" ]]; then
                        echo -e "${C_YELLOW}${LISTA_NOMBRE[$idx]} ya esta detenido.${C_RST}"
                    elif [[ "${LISTA_TIPO[$idx]}" == "Servicio" ]]; then
                        detener_servidor "${LISTA_SERVICIO[$idx]}"
                    else
                        detener_entorno "${LISTA_ENTORNO[$idx]}"
                    fi
                else
                    echo -e "${C_RED}Numero no valido.${C_RST}"
                fi
                pause
                ;;
            3)
                if [[ "$total" -eq 0 ]]; then
                    echo -e "${C_YELLOW}No hay bases de datos detectadas.${C_RST}"
                    pause
                    continue
                fi
                read -rp "Numero base de datos: " n
                if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$total" ]]; then
                    local idx=$((n - 1))
                    if [[ "${LISTA_TIPO[$idx]}" == "Servicio" ]]; then
                        reiniciar_servidor "${LISTA_SERVICIO[$idx]}"
                    else
                        if [[ "${LISTA_ESTADO[$idx]}" == "Running" ]]; then
                            reiniciar_entorno "${LISTA_ENTORNO[$idx]}"
                        else
                            echo -e "${C_YELLOW}${LISTA_NOMBRE[$idx]} esta detenido. Usa la opcion 1 para iniciar.${C_RST}"
                        fi
                    fi
                else
                    echo -e "${C_RED}Numero no valido.${C_RST}"
                fi
                pause
                ;;
            4)
                ver_puertos_abiertos
                ;;
            5)
                echo "1 Entorno MySQL + MongoDB"
                echo "2 Entorno PostgreSQL"
                echo "3 Entorno MySQL + MongoDB + Redis"
                read -rp "Seleccion: " t
                modo_practica "$t"
                ;;
            6)
                detectar_entornos_web
                pause
                ;;
            7)
                ayuda_servicios
                ;;
            8)
                diagnostico_completo
                ;;
            9)
                resetear_password_root
                ;;
            10)
                if [[ "$total" -eq 0 ]]; then
                    echo -e "${C_YELLOW}No hay bases de datos detectadas.${C_RST}"
                    pause
                    continue
                fi
                read -rp "Indica el numero de la base de datos ACTIVA para intentar abrir su terminal: " n
                if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$total" ]]; then
                    local idx=$((n - 1))
                    if [[ "${LISTA_ESTADO[$idx]}" != "active" && "${LISTA_ESTADO[$idx]}" != "Running" ]]; then
                        echo -e "${C_RED}Error! La base de datos debe estar ACTIVA.${C_RST}"
                    else
                        abrir_terminal_db "${LISTA_NOMBRE[$idx]}"
                    fi
                else
                    echo -e "${C_RED}Opcion invalida.${C_RST}"
                fi
                pause
                ;;
            11)
                if [[ "$total" -eq 0 ]]; then
                    echo -e "${C_YELLOW}No hay bases de datos detectadas.${C_RST}"
                    pause
                    continue
                fi
                read -rp "Indica el numero del servidor a comprobar: " n
                if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$total" ]]; then
                    local idx=$((n - 1))
                    comprobar_salud_detallada "${LISTA_NOMBRE[$idx]}" "${LISTA_PUERTO[$idx]}" "${LISTA_SERVICIO[$idx]}"
                else
                    echo -e "${C_RED}Opcion invalida.${C_RST}"
                    pause
                fi
                ;;
            12)
                gestionar_contenedores
                ;;
            13)
                exportar_diagnostico ""
                pause
                ;;
            14)
                gestionar_compose
                ;;
            0)
                break
                ;;
            *)
                echo -e "${C_RED}Opcion no valida.${C_RST}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
