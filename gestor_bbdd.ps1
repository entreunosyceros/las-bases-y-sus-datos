param(
    [Alias("h")]
    [switch]$Help,
    [switch]$Status,
    [string]$Start,
    [string]$Stop,
    [string]$Restart,
    [string]$Health,
    [switch]$Diagnose,
    [string]$Export,
    [switch]$Containers,
    [string]$ContainerStart,
    [string]$ContainerStop,
    [string]$ContainerRestart,
    [switch]$Json,
    [switch]$ComposeList,
    [string]$ComposeUp,
    [string]$ComposeDown,
    [switch]$Ports,
    [switch]$Detect,
    [switch]$HelpServices,
    [switch]$ResetPassword,
    [string]$OpenTerminal
)

# Configuración de servicios como máximo de bases de datos para prácticas de administración
$maxActivos = 2

# Puertos habituales de los motores de BD soportados.
# 1433 SQL Server, 3306 MySQL/MariaDB, 5432 PostgreSQL, 27017 MongoDB,
# 6379 Redis, 9200 Elasticsearch/OpenSearch, 9042 Cassandra/ScyllaDB,
# 5984 CouchDB, 8086 InfluxDB, 7474 Neo4j, 8123 ClickHouse,
# 26257 CockroachDB, 8529 ArangoDB, 11211 Memcached, 3050 Firebird,
# 28015 RethinkDB.
$puertosBD = @(1433,3306,5432,27017,6379,9200,9042,5984,8086,7474,8123,26257,8529,11211,3050,28015)

$script:healthTimeout = 3
$script:confExtraPaths = ""
$script:ignorarMotores = ""
$script:logEnabled = $false
$script:logFile = ""
$script:scriptDir = $PSScriptRoot
$script:modoCli = $false
$script:patronBdCont = 'mysql|maria|postgres|mongo|mssql|redis|elasticsearch|opensearch|cassandra|scylla|couchdb|influx|neo4j|clickhouse|cockroach|arango|memcached|firebird|rethinkdb'

function pause {
    if ($script:modoCli) { return }
    Read-Host "Pulsa ENTER para continuar"
}

# ---------------- Archivo de configuracion persistente ----------------

function Localizar-Config {
    if ($env:GESTOR_BD_CONF -and (Test-Path $env:GESTOR_BD_CONF)) { return $env:GESTOR_BD_CONF }
    $candidato = Join-Path $script:scriptDir "gestor_bbdd.conf"
    if (Test-Path $candidato) { return $candidato }
    $candidato = Join-Path $env:APPDATA "gestor_bbdd.conf"
    if (Test-Path $candidato) { return $candidato }
    return $null
}

function Aplicar-ConfigClave($clave, $valor) {
    switch ($clave) {
        'MAX_ACTIVOS'     { if ($valor -match '^\d+$') { $script:maxActivos = [int]$valor } }
        'EXTRA_PATHS'     { $script:confExtraPaths = $valor }
        'IGNORAR_MOTORES' { $script:ignorarMotores = $valor }
        'HEALTH_TIMEOUT'  { if ($valor -match '^\d+$') { $script:healthTimeout = [int]$valor } }
        'LOG_ENABLED'     { if ($valor -match '^(?i)(true|1|yes|si|sí)$') { $script:logEnabled = $true } }
        'LOG_FILE'        { $script:logFile = $valor }
    }
}

function Cargar-Config {
    $archivo = Localizar-Config
    if (-not $archivo) { return }
    foreach ($linea in Get-Content $archivo -ErrorAction SilentlyContinue) {
        if ($linea -match '^\s*#' -or $linea -notmatch '=') { continue }
        $partes = $linea -split '=', 2
        $clave = $partes[0].Trim()
        $valor = ($partes[1] -split '#', 2)[0].Trim()
        if ($clave) { Aplicar-ConfigClave $clave $valor }
    }
}

function Aplicar-EnvConfig {
    if ($env:GESTOR_BD_MAX_ACTIVOS -match '^\d+$') { $script:maxActivos = [int]$env:GESTOR_BD_MAX_ACTIVOS }
    if ($env:GESTOR_BD_HEALTH_TIMEOUT -match '^\d+$') { $script:healthTimeout = [int]$env:GESTOR_BD_HEALTH_TIMEOUT }
    if ($env:GESTOR_BD_IGNORAR_MOTORES) { $script:ignorarMotores = $env:GESTOR_BD_IGNORAR_MOTORES }
    if ($env:GESTOR_BD_LOG_ENABLED -match '^(?i)(true|1|yes|si|sí)$') { $script:logEnabled = $true }
    if ($env:GESTOR_BD_LOG_FILE) { $script:logFile = $env:GESTOR_BD_LOG_FILE }
}

function Motor-Ignorado($nombre) {
    if ([string]::IsNullOrWhiteSpace($script:ignorarMotores)) { return $false }
    $n = $nombre.ToLower()
    foreach ($m in ($script:ignorarMotores -split ',')) {
        $m = $m.Trim().ToLower()
        if ($m -and $n -like "*$m*") { return $true }
    }
    return $false
}

function Registrar-Log($mensaje) {
    if (-not $script:logEnabled -or [string]::IsNullOrWhiteSpace($script:logFile)) { return }
    $linea = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $mensaje"
    Add-Content -Path $script:logFile -Value $linea -ErrorAction SilentlyContinue
}

# ---------------- Comprobación de privilegios ----------------

# Comprueba si el script se esta ejecutando con privilegios de administrador.
# Devuelve $true si el usuario actual tiene el rol de administrador de Windows.
function EsAdministrador {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (EsAdministrador)) {
    Write-Host "AVISO!!: Este script necesita permisos de administrador para iniciar/detener servicios." -ForegroundColor Yellow
    Write-Host "Algunas funciones pueden no estar disponibles." -ForegroundColor Yellow
    Write-Host ""
    pause
}

Cargar-Config
Aplicar-EnvConfig

# ---------------- Funciones básicas ----------------

# Busca servicios de Windows registrados cuyo nombre coincida con motores de BD conocidos
# (MySQL, MariaDB, PostgreSQL, MongoDB, SQL Server, WAMP, XAMPP).
# Devuelve un array de objetos de servicio.
function DetectarServicios {
    $patron = "MSSQL|mysql|maria|postgres|mongo|redis|elasticsearch|opensearch|cassandra|scylla|couchdb|influx|neo4j|clickhouse|cockroach|arango|memcache|firebird|rethinkdb|wamp|xampp"
    $servicios = @(Get-Service | Where-Object {
        ($_.Name -match $patron -or $_.DisplayName -match $patron) -and -not (Motor-Ignorado $_.Name)
    })
    return ,$servicios
}

# Ejecuta mysqld --version para determinar si el binario es MySQL o MariaDB.
# En XAMPP, por ejemplo, el ejecutable se llama mysqld.exe pero es MariaDB.
# Recibe la ruta base del entorno. Devuelve "MariaDB" o "MySQL".
function IdentificarMotorMySQL($basePath) {
    $mysqld = Join-Path $basePath "mysql\bin\mysqld.exe"
    if (-not (Test-Path $mysqld)) { return "MySQL" }
    $version = & $mysqld --version 2>&1 | Out-String
    if ($version -match "MariaDB") { return "MariaDB" }
    return "MySQL"
}

# Busca procesos de BD activos o disponibles en entornos locales (XAMPP, WAMP, Laragon, MAMP, Bitnami, EasyPHP, Devilbox).
# Para cada entorno encontrado, detecta MySQL/MariaDB, PostgreSQL, MongoDB y Redis.
# Devuelve un array de objetos con nombre, estado, puerto, PID, RAM y scripts de inicio/parada.
function DetectarServidoresEntorno {
    $resultado = @()
    foreach ($nombre in @("XAMPP","WAMP","Laragon","MAMP","Bitnami","EasyPHP","Devilbox","AMPPS","UwAmp","WPN-XM","OpenServer")) {
        $basePath = BuscarEntornoEnUnidades $nombre
        if (-not $basePath) { continue }

        # MySQL/MariaDB: detectar motor real, el proceso siempre es mysqld
        $mysqlStart = Join-Path $basePath "mysql_start.bat"
        $mysqlStop  = Join-Path $basePath "mysql_stop.bat"
        $mysqldExe  = Join-Path $basePath "mysql\bin\mysqld.exe"

        if ((Test-Path $mysqldExe) -or (Test-Path $mysqlStart)) {
            $motorNombre = IdentificarMotorMySQL $basePath
            $startScript = if (Test-Path $mysqlStart) { $mysqlStart } else { $null }
            $stopScript  = if (Test-Path $mysqlStop)  { $mysqlStop }  else { $null }

            $proc = Get-Process -Name mysqld -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -and $_.Path -like "$basePath*" } |
                    Select-Object -First 1

            if ($proc) {
                $ram = [math]::Round($proc.WorkingSet/1MB,1)
                $resultado += [PSCustomObject]@{
                    Nombre      = "$motorNombre ($nombre)"
                    Tipo        = $nombre
                    Estado      = "Running"
                    Puerto      = 3306
                    RAM         = $ram
                    PID         = $proc.Id
                    BasePath    = $basePath
                    ProcName    = "mysqld"
                    StartScript = $startScript
                    StopScript  = $stopScript
                }
            }
            elseif ($startScript) {
                $resultado += [PSCustomObject]@{
                    Nombre      = "$motorNombre ($nombre)"
                    Tipo        = $nombre
                    Estado      = "Stopped"
                    Puerto      = 3306
                    RAM         = 0
                    PID         = 0
                    BasePath    = $basePath
                    ProcName    = "mysqld"
                    StartScript = $startScript
                    StopScript  = $stopScript
                }
            }
        }

        # PostgreSQL
        $pgProc = Get-Process -Name postgres -ErrorAction SilentlyContinue |
                  Where-Object { $_.Path -and $_.Path -like "$basePath*" } |
                  Select-Object -First 1
        if ($pgProc) {
            $ram = [math]::Round($pgProc.WorkingSet/1MB,1)
            $resultado += [PSCustomObject]@{
                Nombre = "PostgreSQL ($nombre)"; Tipo = $nombre; Estado = "Running"
                Puerto = 5432; RAM = $ram; PID = $pgProc.Id; BasePath = $basePath
                ProcName = "postgres"; StartScript = $null; StopScript = $null
            }
        }

        # MongoDB
        $mongoProc = Get-Process -Name mongod -ErrorAction SilentlyContinue |
                     Where-Object { $_.Path -and $_.Path -like "$basePath*" } |
                     Select-Object -First 1
        if ($mongoProc) {
            $ram = [math]::Round($mongoProc.WorkingSet/1MB,1)
            $resultado += [PSCustomObject]@{
                Nombre = "MongoDB ($nombre)"; Tipo = $nombre; Estado = "Running"
                Puerto = 27017; RAM = $ram; PID = $mongoProc.Id; BasePath = $basePath
                ProcName = "mongod"; StartScript = $null; StopScript = $null
            }
        }

        # Redis
        $redisExe = Join-Path $basePath "redis\redis-server.exe"
        if (-not (Test-Path $redisExe)) { $redisExe = Join-Path $basePath "bin\redis-server.exe" }
        if (-not (Test-Path $redisExe)) { $redisExe = Join-Path $basePath "redis\bin\redis-server.exe" }

        if (Test-Path $redisExe) {
            $redisProc = Get-Process -Name redis-server -ErrorAction SilentlyContinue |
                         Where-Object { $_.Path -and $_.Path -like "$basePath*" } |
                         Select-Object -First 1
            if ($redisProc) {
                $ram = [math]::Round($redisProc.WorkingSet/1MB,1)
                $resultado += [PSCustomObject]@{
                    Nombre = "Redis ($nombre)"; Tipo = $nombre; Estado = "Running"
                    Puerto = 6379; RAM = $ram; PID = $redisProc.Id; BasePath = $basePath
                    ProcName = "redis-server"; StartScript = $null; StopScript = $null
                }
            }
        }
    }
    return ,$resultado
}

# Busca archivos de configuracion de la BD dentro del entorno local.
# Segun el tipo de proceso (mysqld, postgres, mongod), busca en rutas habituales
# como my.ini, postgresql.conf o mongod.cfg. Devuelve un array con las rutas encontradas.
function BuscarConfigBD($basePath, $procName) {
    $configs = @()
    if ($procName -match "mysqld|mariadbd") {
        $candidatos = @(
            (Join-Path $basePath "mysql\bin\my.ini"),
            (Join-Path $basePath "mysql\my.ini"),
            (Join-Path $basePath "bin\mysql\my.ini"),
            (Join-Path $basePath "mysql\bin\my.cnf"),
            (Join-Path $basePath "bin\mariadb\my.ini")
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $configs += $c }
        }
    }
    elseif ($procName -match "postgres") {
        $candidatos = @(
            (Join-Path $basePath "pgsql\data\postgresql.conf"),
            (Join-Path $basePath "postgres\data\postgresql.conf"),
            (Join-Path $basePath "data\postgresql.conf")
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $configs += $c }
        }
    }
    elseif ($procName -match "mongod") {
        $candidatos = @(
            (Join-Path $basePath "MongoDB\Server\8.2\bin\mongod.cfg"),
            (Join-Path $basePath "MongoDB\Server\8.0\bin\mongod.cfg"),
            (Join-Path $basePath "MongoDB\Server\7.0\bin\mongod.cfg"),
            (Join-Path $basePath "MongoDB\Server\6.0\bin\mongod.cfg"),
            (Join-Path $basePath "bin\mongod.cfg"),
            (Join-Path $basePath "mongod.cfg")
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $configs += $c }
        }
    }
    elseif ($procName -match "redis-server") {
        $candidatos = @(
            (Join-Path $basePath "redis\redis.conf"),
            (Join-Path $basePath "redis\redis.windows.conf"),
            (Join-Path $basePath "redis\redis.windows-service.conf"),
            (Join-Path $basePath "bin\redis.conf"),
            (Join-Path $basePath "redis.conf"),
            "C:\ProgramData\Redis\redis.conf",
            "C:\Program Files\Redis\redis.conf"
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $configs += $c }
        }
    }
    elseif ($procName -match "java" -and $procName -match "elastic") {
        $candidatos = @(
            (Join-Path $basePath "config\elasticsearch.yml"),
            (Join-Path $basePath "elasticsearch\config\elasticsearch.yml"),
            "/etc/elasticsearch/elasticsearch.yml",
            "C:\ProgramData\Elastic\Elasticsearch\config\elasticsearch.yml"
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $configs += $c }
        }
    }
    elseif ($procName -match "couchdb") {
        $candidatos = @(
            (Join-Path $basePath "etc\local.ini"),
            (Join-Path $basePath "etc\default.ini"),
            "/etc/couchdb/local.ini",
            "C:\CouchDB\etc\local.ini"
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $configs += $c }
        }
    }
    elseif ($procName -match "influxd") {
        $candidatos = @(
            (Join-Path $basePath "influxdb.conf"),
            "C:\ProgramData\InfluxDB\influxdb.conf",
            "$env:USERPROFILE\.influxdbv2\configs"
        )
        foreach ($c in $candidatos) { if (Test-Path $c) { $configs += $c } }
    }
    elseif ($procName -match "neo4j") {
        $candidatos = @(
            (Join-Path $basePath "conf\neo4j.conf"),
            "C:\Program Files\Neo4j*\conf\neo4j.conf"
        )
        foreach ($c in $candidatos) {
            Get-ChildItem -Path $c -ErrorAction SilentlyContinue | ForEach-Object { $configs += $_.FullName }
        }
    }
    elseif ($procName -match "clickhouse") {
        $candidatos = @(
            (Join-Path $basePath "config.xml"),
            "C:\ProgramData\ClickHouse\config.xml"
        )
        foreach ($c in $candidatos) { if (Test-Path $c) { $configs += $c } }
    }
    elseif ($procName -match "arangod") {
        $candidatos = @(
            (Join-Path $basePath "etc\arangodb3\arangod.conf"),
            "C:\Program Files\ArangoDB*\etc\arangodb3\arangod.conf"
        )
        foreach ($c in $candidatos) {
            Get-ChildItem -Path $c -ErrorAction SilentlyContinue | ForEach-Object { $configs += $_.FullName }
        }
    }
    elseif ($procName -match "rethinkdb") {
        $candidatos = @(
            (Join-Path $basePath "rethinkdb.conf"),
            "C:\RethinkDB\rethinkdb.conf"
        )
        foreach ($c in $candidatos) { if (Test-Path $c) { $configs += $c } }
    }
    elseif ($procName -match "firebird") {
        $candidatos = @(
            (Join-Path $basePath "firebird.conf"),
            "C:\Program Files\Firebird\Firebird_*\firebird.conf"
        )
        foreach ($c in $candidatos) {
            Get-ChildItem -Path $c -ErrorAction SilentlyContinue | ForEach-Object { $configs += $_.FullName }
        }
    }
    return $configs
}

# Modifica el puerto en el archivo de configuracion de una BD.
# Usa expresiones regulares para reemplazar el valor del puerto segun el tipo de motor:
# - MySQL/MariaDB: port=XXXX en my.ini
# - PostgreSQL: port = XXXX en postgresql.conf
# - MongoDB: port: XXXX en mongod.cfg
function CambiarPuertoConfig($configPath, $procName, $nuevoPuerto) {
    $contenido = Get-Content $configPath -Raw
    if ($procName -match "mysqld|mariadbd") {
        # Reemplazar port=XXXX por port=$nuevoPuerto
        $contenido = $contenido -replace '(?m)^(\s*port\s*=\s*)\d+', "`${1}$nuevoPuerto"
    }
    elseif ($procName -match "postgres") {
        $contenido = $contenido -replace "(?m)^(\s*#?\s*port\s*=\s*)\d+", "`${1}$nuevoPuerto"
    }
    elseif ($procName -match "mongod") {
        $contenido = $contenido -replace '(?m)^(\s*port:\s*)\d+', "`${1}$nuevoPuerto"
    }
    elseif ($procName -match "redis-server") {
        $contenido = $contenido -replace '(?m)^(\s*port\s+)\d+', "`${1}$nuevoPuerto"
    }
    elseif ($procName -match "couchdb") {
        $contenido = $contenido -replace '(?m)^(\s*port\s*=\s*)\d+', "`${1}$nuevoPuerto"
    }
    Set-Content $configPath -Value $contenido -Encoding UTF8
}

# Inicia una BD de un entorno local (XAMPP, WAMP, etc.) usando su script de arranque.
# Si el puerto esta ocupado, ofrece al usuario cambiar el puerto automaticamente
# modificando el archivo de configuracion antes de iniciar.
function IniciarEntorno($entrada) {
    if (-not $entrada.StartScript -or -not (Test-Path $entrada.StartScript)) {
        Write-Host "No se encontro script de inicio para $($entrada.Nombre)" -ForegroundColor Red
        return
    }
    $puerto = $entrada.Puerto
    if ($puerto -gt 0 -and (PuertoOcupado $puerto)) {
        Write-Host "Puerto $puerto ya esta ocupado." -ForegroundColor Red
        Write-Host ""
        $configs = BuscarConfigBD $entrada.BasePath $entrada.ProcName
        if ($configs.Count -gt 0) {
            Write-Host "Se puede cambiar el puerto en la configuracion." -ForegroundColor Yellow
            $resp = Read-Host "Desea cambiar el puerto? (s/n)"
            if ($resp -eq "s") {
                $nuevoPuerto = Read-Host "Introduce el nuevo puerto"
                if ($nuevoPuerto -match '^\d+$' -and [int]$nuevoPuerto -ge 1024 -and [int]$nuevoPuerto -le 65535) {
                    if (PuertoOcupado ([int]$nuevoPuerto)) {
                        Write-Host "El puerto $nuevoPuerto tambien esta ocupado." -ForegroundColor Red
                        return
                    }
                    foreach ($cfg in $configs) {
                        CambiarPuertoConfig $cfg $entrada.ProcName ([int]$nuevoPuerto)
                        Write-Host "Puerto cambiado a $nuevoPuerto en $cfg" -ForegroundColor Green
                    }
                    Write-Host "Iniciando $($entrada.Nombre) en puerto $nuevoPuerto..." -ForegroundColor Yellow
                    Start-Process -FilePath $entrada.StartScript -WorkingDirectory $entrada.BasePath -WindowStyle Hidden
                    Start-Sleep 3
                    $proc = Get-Process -Name $entrada.ProcName -ErrorAction SilentlyContinue |
                            Where-Object { $_.Path -and $_.Path -like "$($entrada.BasePath)*" } |
                            Select-Object -First 1
                    if ($proc) {
                        Write-Host "$($entrada.Nombre) iniciado correctamente en puerto $nuevoPuerto (PID: $($proc.Id))" -ForegroundColor Green
                    } else {
                        Write-Host "No se pudo verificar el inicio de $($entrada.Nombre)." -ForegroundColor Red
                    }
                } else {
                    Write-Host "Puerto no valido. Debe estar entre 1024 y 65535." -ForegroundColor Red
                }
            }
        } else {
            Write-Host "No se encontro archivo de configuracion para cambiar el puerto." -ForegroundColor Yellow
        }
        return
    }
    Write-Host "Iniciando $($entrada.Nombre)..." -ForegroundColor Yellow
    Start-Process -FilePath $entrada.StartScript -WorkingDirectory $entrada.BasePath -WindowStyle Hidden
    Start-Sleep 3
    $proc = Get-Process -Name $entrada.ProcName -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -like "$($entrada.BasePath)*" } |
            Select-Object -First 1
    if ($proc) {
        Write-Host "$($entrada.Nombre) iniciado correctamente (PID: $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "No se pudo verificar el inicio de $($entrada.Nombre)." -ForegroundColor Red
    }
}

# Detiene una BD de un entorno local usando 3 metodos en cascada:
# 1. mysqladmin shutdown (para MySQL/MariaDB) o pg_ctl stop (para PostgreSQL)
# 2. Si falla, termina el proceso directamente con Stop-Process
# 3. Si nada funciona, muestra instrucciones para hacerlo manualmente
function DetenerEntorno($entrada) {
    Write-Host "Deteniendo $($entrada.Nombre)..." -ForegroundColor Yellow

    if ($entrada.PID -le 0) {
        Write-Host "No hay proceso activo de $($entrada.Nombre)." -ForegroundColor Red
        return
    }

    $detenido = $false

    # Metodo 1: mysqladmin shutdown (MySQL/MariaDB)
    if ($entrada.ProcName -match "mysqld|mariadbd") {
        $mysqladmin = Join-Path $entrada.BasePath "mysql\bin\mysqladmin.exe"
        if (Test-Path $mysqladmin) {
            Write-Host "  Enviando shutdown via mysqladmin..." -ForegroundColor Gray
            & $mysqladmin -u root shutdown 2>$null
            Start-Sleep 3
            $proc = Get-Process -Id $entrada.PID -ErrorAction SilentlyContinue
            if (-not $proc) { $detenido = $true }
        }
    }

    # Metodo 2: pg_ctl stop (PostgreSQL)
    if (-not $detenido -and $entrada.ProcName -match "postgres") {
        $pgctl = Get-ChildItem -Path $entrada.BasePath -Filter "pg_ctl.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pgctl) {
            $dataDir = Get-ChildItem -Path $entrada.BasePath -Filter "postgresql.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($dataDir) {
                Write-Host "  Enviando stop via pg_ctl..." -ForegroundColor Gray
                & $pgctl.FullName stop -D $dataDir.DirectoryName -m fast 2>$null
                Start-Sleep 3
                $proc = Get-Process -Id $entrada.PID -ErrorAction SilentlyContinue
                if (-not $proc) { $detenido = $true }
            }
        }
    }

    # Metodo 3: Terminar proceso directamente
    if (-not $detenido) {
        Write-Host "  Terminando proceso (PID: $($entrada.PID))..." -ForegroundColor Gray
        Stop-Process -Id $entrada.PID -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
        $proc = Get-Process -Id $entrada.PID -ErrorAction SilentlyContinue
        if (-not $proc) { $detenido = $true }
    }

    if ($detenido) {
        Write-Host "$($entrada.Nombre) detenido correctamente." -ForegroundColor Green
    } else {
        Write-Host "$($entrada.Nombre) no se pudo detener." -ForegroundColor Red
        Write-Host "Intenta cerrarlo desde el panel de control de $($entrada.Tipo) o con el administrador de tareas." -ForegroundColor Yellow
    }
}

# Reinicia una BD de entorno local deteniendo primero y luego iniciando.
function ReiniciarEntorno($entrada) {
    DetenerEntorno $entrada
    Start-Sleep 1
    IniciarEntorno $entrada
}

# Busca la carpeta de instalacion de un entorno (XAMPP, WAMP, Laragon, MAMP)
# recorriendo todas las unidades del sistema (C:, D:, E:, etc.) y Program Files.
# Devuelve la primera ruta encontrada o $null si no existe.
function BuscarEntornoEnUnidades($nombre) {
    $unidades = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root } | ForEach-Object { $_.Root })
    $carpetas = switch ($nombre) {
        "XAMPP"    { @("xampp") }
        "WAMP"     { @("wamp64","wamp") }
        "Laragon"  { @("laragon") }
        "MAMP"     { @("MAMP","mamp") }
        "Bitnami"  { @("Bitnami","bitnami") }
        "EasyPHP"  { @("EasyPHP","easyphp") }
        "Devilbox" { @("devilbox","Devilbox") }
        "AMPPS"    { @("Ampps","AMPPS","ampps") }
        "UwAmp"    { @("UwAmp","uwamp") }
        "WPN-XM"   { @("wpn-xm","WPN-XM") }
        "OpenServer" { @("OSPanel","openserver","ospanel") }
        default    { @() }
    }
    foreach ($u in $unidades) {
        foreach ($c in $carpetas) {
            $ruta = Join-Path $u $c
            if (Test-Path $ruta) { return $ruta }
        }
    }
    # Tambien buscar en Program Files y rutas de datos de aplicaciones
    $extras = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA)
    foreach ($pf in $extras) {
        if (-not $pf) { continue }
        foreach ($c in $carpetas) {
            $ruta = Join-Path $pf $c
            if (Test-Path $ruta) { return $ruta }
        }
    }
    # Distribuciones que se instalan en rutas de usuario concretas
    $rutasFijas = switch ($nombre) {
        "Local"     { @((Join-Path $env:LOCALAPPDATA "Local"), (Join-Path $env:APPDATA "Local")) }
        "DevKinsta" { @((Join-Path $env:USERPROFILE "DevKinsta"), (Join-Path $env:LOCALAPPDATA "DevKinsta")) }
        "Herd"      { @((Join-Path $env:LOCALAPPDATA "Herd"), (Join-Path $env:USERPROFILE ".config\herd")) }
        default     { @() }
    }
    foreach ($ruta in $rutasFijas) {
        if ($ruta -and (Test-Path $ruta)) { return $ruta }
    }
    # Rutas extra definidas por el usuario en la variable GESTOR_BD_EXTRA_PATHS
    foreach ($extra in (RutasExtraUsuario)) {
        if ((Test-Path $extra) -and ($extra.ToLower() -like "*$($nombre.ToLower())*")) {
            return $extra
        }
    }
    return $null
}

# Devuelve las rutas extra que el usuario haya definido en la variable de
# entorno GESTOR_BD_EXTRA_PATHS (separadas por ';').
function RutasExtraUsuario {
    $lista = @()
    if ($env:GESTOR_BD_EXTRA_PATHS) { $lista += ($env:GESTOR_BD_EXTRA_PATHS -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($script:confExtraPaths) { $lista += ($script:confExtraPaths -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return $lista
}

# Devuelve el puerto por defecto a partir del nombre del proceso.
function PuertoDeProceso($procName) {
    switch -Regex ($procName) {
        "mysqld|mariadbd" { return 3306 }
        "postgres"        { return 5432 }
        "mongod"          { return 27017 }
        "sqlservr"        { return 1433 }
        "redis-server"    { return 6379 }
        "couchdb"         { return 5984 }
        "influxd"         { return 8086 }
        "neo4j"           { return 7474 }
        "clickhouse"      { return 8123 }
        "cockroach"       { return 26257 }
        "arangod"         { return 8529 }
        "memcached"       { return 11211 }
        "fbserver|firebird" { return 3050 }
        "rethinkdb"       { return 28015 }
        default           { return 0 }
    }
}

# Muestra por pantalla los procesos de BD activos dentro de un entorno local.
# Filtra solo procesos de bases de datos que esten corriendo desde la ruta indicada.
function MostrarProcesosEntorno($basePath, $nombre) {
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path -like "$basePath*" -and $_.ProcessName -match "mysqld|mariadbd|postgres|mongod|sqlservr|redis-server|couchdb|influxd|neo4j|clickhouse|cockroach|arangod|memcached|fbserver|firebird|rethinkdb"
    }
    if ($procs) {
        foreach ($p in $procs) {
            $puerto = PuertoDeProceso $p.ProcessName
            $info = if ($puerto -gt 0) { " (puerto $puerto)" } else { "" }
            Write-Host "  -> $($p.ProcessName) EN EJECUCION$info - PID: $($p.Id)" -ForegroundColor Green
        }
    } else {
        Write-Host "  -> Ningun proceso de BD de $nombre en ejecucion" -ForegroundColor Gray
    }
}

# Detecta entornos de desarrollo local instalados (XAMPP, WAMP, Laragon, MAMP, Docker)
# en todas las unidades del sistema. Para cada uno muestra si esta instalado y que
# procesos de BD tiene activos. Tambien detecta contenedores Docker de BD.
function DetectarEntornosWeb {
    Write-Host ""
    Write-Host "DETECCION DE ENTORNOS LOCALES"
    Write-Host "-----------------------------"
    $encontrado = $false
    $rutasEntornos = @()

    # --- Stacks locales (XAMPP, WAMP, ...) detectados por carpeta ---
    foreach ($nombre in @("XAMPP","WAMP","Laragon","MAMP","Bitnami","EasyPHP","Devilbox","AMPPS","UwAmp","WPN-XM","OpenServer","Local","DevKinsta","Herd")) {
        $ruta = BuscarEntornoEnUnidades $nombre
        if ($ruta) {
            $encontrado = $true
            $rutasEntornos += $ruta
            Write-Host "$nombre detectado en $ruta" -ForegroundColor Yellow
            MostrarProcesosEntorno $ruta $nombre
        }
    }

    $patronBD = "mysql|maria|postgres|mongo|mssql|redis|elasticsearch|opensearch|cassandra|scylla|couchdb|influx|neo4j|clickhouse|cockroach|arango|memcached|firebird|rethinkdb"

    # --- Docker ---
    $docker = Get-Service -Name "docker" -ErrorAction SilentlyContinue
    if ($docker) {
        $encontrado = $true
        if ($docker.Status -eq "Running") {
            Write-Host "Docker instalado y EN EJECUCION" -ForegroundColor Green
            $dockerExe = Get-Command docker -ErrorAction SilentlyContinue
            if ($dockerExe) {
                $containers = docker ps --format "{{.Names}}  {{.Image}}  {{.Ports}}" 2>$null
                if ($containers) {
                    $dbContainers = $containers | Where-Object { $_ -match $patronBD }
                    if ($dbContainers) {
                        Write-Host "  Contenedores de BD activos:" -ForegroundColor Yellow
                        foreach ($c in $dbContainers) { Write-Host "  -> $c" -ForegroundColor Green }
                    }
                }
            }
        } else {
            Write-Host "Docker instalado pero DETENIDO" -ForegroundColor Red
        }
    }

    # --- Podman (alternativa a Docker) ---
    $podmanExe = Get-Command podman -ErrorAction SilentlyContinue
    if ($podmanExe) {
        $encontrado = $true
        $pcontainers = podman ps --format "{{.Names}}  {{.Image}}  {{.Ports}}" 2>$null
        if ($pcontainers) {
            $pdb = $pcontainers | Where-Object { $_ -match $patronBD }
            if ($pdb) {
                Write-Host "Podman detectado con contenedores de BD activos:" -ForegroundColor Green
                foreach ($c in $pdb) { Write-Host "  -> $c" -ForegroundColor Green }
            } else {
                Write-Host "Podman detectado (sin contenedores de BD activos)" -ForegroundColor Green
            }
        } else {
            Write-Host "Podman instalado" -ForegroundColor Green
        }
    }

    # --- Deteccion por procesos activos (aunque no se encuentre la carpeta) ---
    $procsDB = Get-Process -Name mysqld,mariadbd,postgres,mongod,sqlservr,redis-server,couchdb,influxd,neo4j,clickhouse,cockroach,arangod,memcached,fbserver,firebird,rethinkdb -ErrorAction SilentlyContinue
    $noMostrados = @()
    foreach ($p in $procsDB) {
        $path = $null
        try { $path = $p.Path } catch {}
        if (-not $path) { continue }
        $yaDetectado = $false
        foreach ($ruta in $rutasEntornos) {
            if ($ruta -and $path -like "$ruta*") { $yaDetectado = $true; break }
        }
        if (-not $yaDetectado) { $noMostrados += $p }
    }
    if ($noMostrados.Count -gt 0) {
        $encontrado = $true
        Write-Host ""
        Write-Host "OTROS PROCESOS DE BD DETECTADOS:" -ForegroundColor Yellow
        foreach ($p in $noMostrados) {
            $puerto = PuertoDeProceso $p.ProcessName
            $info = if ($puerto -gt 0) { " (puerto $puerto)" } else { "" }
            Write-Host "  -> $($p.ProcessName)$info - PID: $($p.Id) - $($p.Path)" -ForegroundColor Cyan
        }
    }

    if (-not $encontrado) {
        Write-Host "No se detecto ningun entorno local (XAMPP, WAMP, Laragon, MAMP, Docker, Podman, etc.)" -ForegroundColor Gray
    }
}

# Devuelve el puerto por defecto asociado a un servicio Windows de BD
# segun su nombre: MySQL/MariaDB=3306, PostgreSQL=5432, MongoDB=27017, SQL Server=1433.
function ObtenerPuerto($servicio){
    if($servicio.Name -match "mysql"){ return 3306 }
    if($servicio.Name -match "maria"){ return 3306 }
    if($servicio.Name -match "postgres"){ return 5432 }
    if($servicio.Name -match "mongo"){ return 27017 }
    if($servicio.Name -match "redis"){ return 6379 }
    if($servicio.Name -match "elasticsearch|opensearch"){ return 9200 }
    if($servicio.Name -match "cassandra|scylla"){ return 9042 }
    if($servicio.Name -match "couchdb"){ return 5984 }
    if($servicio.Name -match "influx"){ return 8086 }
    if($servicio.Name -match "neo4j"){ return 7474 }
    if($servicio.Name -match "clickhouse"){ return 8123 }
    if($servicio.Name -match "cockroach"){ return 26257 }
    if($servicio.Name -match "arango"){ return 8529 }
    if($servicio.Name -match "memcache"){ return 11211 }
    if($servicio.Name -match "firebird"){ return 3050 }
    if($servicio.Name -match "rethinkdb"){ return 28015 }
    if($servicio.Name -match "MSSQL"){ return 1433 }
    return 0
}

# Comprueba si un puerto TCP esta en uso (LISTENING) usando netstat.
# Devuelve $true si hay algun proceso escuchando en ese puerto.
function PuertoOcupado($puerto){
    $linea = netstat -ano | Select-String "LISTENING" | Select-String ":$puerto\s"
    if($linea){return $true} else {return $false}
}

# Calcula la memoria RAM (en MB) que esta usando un servicio Windows de BD.
# Obtiene el PID del servicio via WMI y consulta el WorkingSet del proceso.
function ObtenerRAM($servicio){
    $svcWmi = Get-CimInstance Win32_Service -Filter "Name='$($servicio.Name)'" -ErrorAction SilentlyContinue
    if ($svcWmi -and $svcWmi.ProcessId -gt 0) {
        $p = Get-Process -Id $svcWmi.ProcessId -ErrorAction SilentlyContinue
        if ($p) { return [math]::Round($p.WorkingSet/1MB,1) }
    }
    return 0
}

# ---------------- Diagnóstico y autocorrección ----------------

# Diagnostica por que un servicio de BD no puede iniciarse.
# Revisa si el puerto esta ocupado (y por que proceso), si hay RAM suficiente,
# y ofrece detener el proceso que bloquea el puerto.
function Diagnosticar($servicio){
    Write-Host ""
    Write-Host "DIAGNOSTICO DEL PROBLEMA" -ForegroundColor Yellow
    Write-Host "------------------------"
    $puerto = ObtenerPuerto $servicio

    if(PuertoOcupado $puerto){
        $linea = netstat -ano | Select-String "LISTENING" | Select-String ":$puerto\s" | Select-Object -First 1
        if($linea){
            $textoLinea = $linea.Line
            $pidProceso = ($textoLinea -split "\s+")[-1]
            $proceso = Get-Process -Id $pidProceso -ErrorAction SilentlyContinue
            if($proceso){
                Write-Host "Puerto $puerto ocupado por $($proceso.ProcessName)" -ForegroundColor Red
                $accion = Read-Host "¿Quieres detener este proceso para liberar el puerto? (s/n)"
                if($accion -eq "s"){
                    Stop-Process -Id $pidProceso -Force
                    Write-Host "Proceso detenido, intenta iniciarlo de nuevo." -ForegroundColor Green
                }
            } else {
                Write-Host "Puerto $puerto ocupado (PID $pidProceso)" -ForegroundColor Red
            }
        }
        return
    }

    $totalRAM = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024
    if($totalRAM -lt 500){Write-Host "RAM insuficiente para iniciar el servicio." -ForegroundColor Red; return}

    Write-Host "No se detecto ninguna causa con el método automatico." -ForegroundColor Yellow
    Write-Host "Revisa archivo de configuracion del servidor."
}

# ---------------- Comprobaciones de salud / conectividad ----------------
# Devuelve: OK | NORESP | NOCLI

function Test-SaludHttp($puerto) {
    $t = $script:healthTimeout
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/" -TimeoutSec $t -UseBasicParsing -ErrorAction Stop
        return 'OK'
    } catch {
        return 'NORESP'
    }
}

function Test-SaludTcp($puerto) {
    $t = $script:healthTimeout * 1000
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $puerto, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($t, $false)) {
            $client.Close()
            return 'NORESP'
        }
        $client.EndConnect($iar)
        $client.Close()
        return 'OK'
    } catch {
        return 'NORESP'
    }
}

# Ejecuta un cliente nativo con un timeout DURO: si no termina a tiempo,
# mata el proceso (evita que un servidor "congelado" cuelgue el menu aunque
# el puerto responda y la herramienta ignore su propio --connect-timeout).
# Devuelve un objeto con ExitCode, Salida y TimedOut.
function Invoke-SaludComando($exe, $argumentos, $timeoutSec) {
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    $res = [pscustomobject]@{ ExitCode = $null; Salida = ''; TimedOut = $false }
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argumentos -NoNewWindow -PassThru `
                -RedirectStandardOutput $out -RedirectStandardError $err -ErrorAction Stop
        if (-not $p.WaitForExit($timeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            try { $p.WaitForExit(1000) | Out-Null } catch {}
            $res.TimedOut = $true
            return $res
        }
        $res.ExitCode = $p.ExitCode
        $res.Salida = (Get-Content $out -Raw -ErrorAction SilentlyContinue)
    } catch {
        $res.TimedOut = $true
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
    return $res
}

function Test-SaludBD($nombre, $puerto) {
    $n = $nombre.ToLower()
    $t = $script:healthTimeout

    if ($n -match 'mysql|maria') {
        $exe = Get-Command mysqladmin.exe -ErrorAction SilentlyContinue
        if (-not $exe) { return 'NOCLI' }
        $r = Invoke-SaludComando $exe.Source @("--connect-timeout=$t", "-h", "127.0.0.1", "-P$puerto", "ping") $t
        if ($r.TimedOut) { return 'NORESP' }
        if ($r.ExitCode -eq 0) { return 'OK' } else { return 'NORESP' }
    }
    elseif ($n -match 'postgres') {
        $exe = Get-Command pg_isready.exe -ErrorAction SilentlyContinue
        if (-not $exe) { return 'NOCLI' }
        $r = Invoke-SaludComando $exe.Source @("-t", "$t", "-h", "127.0.0.1", "-p", "$puerto") $t
        if ($r.TimedOut) { return 'NORESP' }
        if ($r.ExitCode -eq 0) { return 'OK' } else { return 'NORESP' }
    }
    elseif ($n -match 'mongo') {
        $exe = Get-Command mongosh.exe -ErrorAction SilentlyContinue
        if (-not $exe) { return 'NOCLI' }
        $r = Invoke-SaludComando $exe.Source @("--quiet", "--host", "127.0.0.1", "--port", "$puerto", "--serverSelectionTimeoutMS", "$($t * 1000)", "--eval", "db.runCommand({ping:1})") $t
        if ($r.TimedOut) { return 'NORESP' }
        if ($r.ExitCode -eq 0) { return 'OK' } else { return 'NORESP' }
    }
    elseif ($n -match 'redis') {
        $exe = Get-Command redis-cli.exe -ErrorAction SilentlyContinue
        if (-not $exe) { return 'NOCLI' }
        $r = Invoke-SaludComando $exe.Source @("-t", "$t", "-p", "$puerto", "ping") $t
        if ($r.TimedOut) { return 'NORESP' }
        if ($r.Salida -match 'PONG') { return 'OK' } else { return 'NORESP' }
    }
    elseif ($n -match 'couchdb|elasticsearch|opensearch|influx|neo4j|rethink') {
        return (Test-SaludHttp $puerto)
    }
    elseif ($n -match 'clickhouse') {
        $exe = Get-Command clickhouse-client.exe -ErrorAction SilentlyContinue
        if ($exe) {
            $r = Invoke-SaludComando $exe.Source @("--connect_timeout", "$t", "--host", "127.0.0.1", "--port", "$puerto", "-q", "SELECT 1") $t
            if ($r.TimedOut) { return 'NORESP' }
            if ($r.ExitCode -eq 0) { return 'OK' } else { return 'NORESP' }
        }
        return (Test-SaludTcp $puerto)
    }
    elseif ($n -match 'cockroach') {
        $exe = Get-Command cockroach.exe -ErrorAction SilentlyContinue
        if ($exe) {
            $r = Invoke-SaludComando $exe.Source @("sql", "--insecure", "--host=127.0.0.1", "--port=$puerto", "-e", "SELECT 1") $t
            if ($r.TimedOut) { return 'NORESP' }
            if ($r.ExitCode -eq 0) { return 'OK' } else { return 'NORESP' }
        }
        return (Test-SaludTcp $puerto)
    }
    else {
        return (Test-SaludTcp $puerto)
    }
}

function Etiqueta-Salud($estado) {
    switch ($estado) {
        'OK'     { Write-Host 'salud: OK' -ForegroundColor Green }
        'NORESP' { Write-Host 'salud: sin respuesta' -ForegroundColor Yellow }
        'NOCLI'  { Write-Host 'salud: cliente no instalado' -ForegroundColor Gray }
        default  { Write-Host 'salud: desconocida' -ForegroundColor Gray }
    }
}

function Obtener-VersionMotor($nombre, $puerto) {
    $n = $nombre.ToLower()
    if ($n -match 'mysql|maria') {
        $exe = Buscar-Ejecutable 'mysql.exe'
        if ($exe) { return (& $exe --version 2>&1 | Select-Object -First 1) }
    }
    elseif ($n -match 'postgres') {
        $exe = Buscar-Ejecutable 'psql.exe'
        if ($exe) { return (& $exe --version 2>&1 | Select-Object -First 1) }
    }
    elseif ($n -match 'mongo') {
        $exe = Buscar-Ejecutable 'mongosh.exe'
        if ($exe) { return (& $exe --version 2>&1 | Select-Object -First 1) }
    }
    elseif ($n -match 'redis') {
        $exe = Buscar-Ejecutable 'redis-cli.exe'
        if ($exe) { return (& $exe --version 2>&1 | Select-Object -First 1) }
    }
    return $null
}

function Comprobar-SaludDetallada($nombre, $puerto, $servicio) {
    Clear-Host
    Write-Host "======================================"
    Write-Host "  COMPROBACION DE SALUD"
    Write-Host "======================================"
    Write-Host ""
    Write-Host "Servidor: $nombre" -ForegroundColor Cyan
    Write-Host "Puerto: $puerto" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Estado de conexion: " -NoNewline
    $estado = Test-SaludBD $nombre $puerto
    Etiqueta-Salud $estado
    $version = Obtener-VersionMotor $nombre $puerto
    if ($version) {
        Write-Host "Version: $version" -ForegroundColor Cyan
    }
    if ($servicio) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$servicio'" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Started) {
            Write-Host "Servicio Windows: $($svc.State)" -ForegroundColor Cyan
        }
    }
    Registrar-Log "health-check $nombre puerto=$puerto resultado=$estado"
    Write-Host ""
    pause
}

# Inicia un servicio Windows de BD usando Start-Service.
# Verifica que no se supere el maximo de servidores activos y que el puerto este libre.
# Si el puerto esta ocupado, muestra instrucciones especificas para cambiar el puerto
# segun el tipo de motor (MySQL, PostgreSQL, SQL Server, MongoDB).
function IniciarServidor($servicio,$activos){
    if($activos -ge $maxActivos){
        Write-Host ""
        Write-Host "Solo se permiten $maxActivos servidores activos." -ForegroundColor Red
        pause
        return
    }

    $puerto = ObtenerPuerto $servicio

    if(PuertoOcupado $puerto){
        Write-Host ""
        Write-Host "Puerto $puerto ocupado." -ForegroundColor Red
        Write-Host ""
        Write-Host "Para cambiar el puerto de un servicio Windows nativo, edita su archivo de configuracion:" -ForegroundColor Yellow
        if ($servicio.Name -match "mysql|maria") {
            Write-Host "  MySQL/MariaDB: Editar my.ini o my.cnf" -ForegroundColor Cyan
            Write-Host "  Buscar la linea 'port=3306' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\ProgramData\MySQL\MySQL Server X.X\my.ini" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "postgres") {
            Write-Host "  PostgreSQL: Editar postgresql.conf" -ForegroundColor Cyan
            Write-Host "  Buscar la linea 'port = 5432' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\Program Files\PostgreSQL\XX\data\postgresql.conf" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "elasticsearch") {
            Write-Host "  Elasticsearch: Editar elasticsearch.yml" -ForegroundColor Cyan
            Write-Host "  Buscar la linea 'http.port: 9200' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\ProgramData\Elastic\Elasticsearch\config\elasticsearch.yml" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "cassandra") {
            Write-Host "  Cassandra: Editar cassandra.yaml" -ForegroundColor Cyan
            Write-Host "  Buscar 'native_transport_port: 9042' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\Program Files\DataStax-Cassandra\conf\cassandra.yaml" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "MSSQL") {
            Write-Host "  SQL Server: Usar SQL Server Configuration Manager" -ForegroundColor Cyan
            Write-Host "  Protocolos de SQL Server -> TCP/IP -> Propiedades -> Direcciones IP" -ForegroundColor Cyan
            Write-Host "  Cambiar el campo 'Puerto TCP' en la seccion IPAll" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "mongo") {
            Write-Host "  MongoDB: Editar mongod.cfg" -ForegroundColor Cyan
            Write-Host "  Buscar 'port: 27017' bajo la seccion 'net:' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\Program Files\MongoDB\Server\X.X\bin\mongod.cfg" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "redis") {
            Write-Host "  Redis: Editar redis.conf o redis.windows.conf" -ForegroundColor Cyan
            Write-Host "  Buscar la linea 'port 6379' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\Program Files\Redis\redis.conf" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "couchdb") {
            Write-Host "  CouchDB: Editar local.ini" -ForegroundColor Cyan
            Write-Host "  Buscar la linea 'port = 5984' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\CouchDB\etc\local.ini" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "influx") {
            Write-Host "  InfluxDB: Editar influxdb.conf o config.toml" -ForegroundColor Cyan
            Write-Host "  Buscar 'http-bind-address' y cambiar el puerto 8086" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\ProgramData\InfluxDB\influxdb.conf" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "neo4j") {
            Write-Host "  Neo4j: Editar neo4j.conf" -ForegroundColor Cyan
            Write-Host "  Buscar 'server.http.listen_address=:7474' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\Program Files\Neo4j\conf\neo4j.conf" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "clickhouse") {
            Write-Host "  ClickHouse: Editar config.xml" -ForegroundColor Cyan
            Write-Host "  Buscar '<http_port>8123</http_port>' y cambiar el numero" -ForegroundColor Cyan
            Write-Host "  Ruta habitual: C:\ProgramData\ClickHouse\config.xml" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "cockroach") {
            Write-Host "  CockroachDB: el puerto se define al arrancar con --listen-addr=:26257" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "arango") {
            Write-Host "  ArangoDB: Editar arangod.conf" -ForegroundColor Cyan
            Write-Host "  Buscar 'endpoint = tcp://127.0.0.1:8529' y cambiar el numero" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "memcache") {
            Write-Host "  Memcached: cambiar el puerto en los argumentos del servicio (-p 11211)" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "firebird") {
            Write-Host "  Firebird: Editar firebird.conf" -ForegroundColor Cyan
            Write-Host "  Buscar 'RemoteServicePort = 3050' y cambiar el numero" -ForegroundColor Cyan
        }
        elseif ($servicio.Name -match "rethinkdb") {
            Write-Host "  RethinkDB: Editar rethinkdb.conf" -ForegroundColor Cyan
            Write-Host "  Buscar 'driver-port=28015' y cambiar el numero" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "Despues de cambiar el puerto, reinicia el servicio desde aqui." -ForegroundColor Yellow
        Diagnosticar $servicio
        pause
        return
    }

    try{
        Start-Service $servicio.Name -ErrorAction Stop
        Start-Sleep 2
        $estado=(Get-Service $servicio.Name).Status
        if($estado -ne "Running"){
            Write-Host "No se pudo iniciar el servidor." -ForegroundColor Red
            Registrar-Log "start servicio=$($servicio.Name) resultado=fallo"
            Diagnosticar $servicio
        }else{
            Write-Host "Servidor iniciado correctamente." -ForegroundColor Green
            Registrar-Log "start servicio=$($servicio.Name) resultado=ok"
        }
    }catch{
        Write-Host "Error al iniciar el servicio." -ForegroundColor Red
        Registrar-Log "start servicio=$($servicio.Name) resultado=error"
        Diagnosticar $servicio
    }
    pause
}

# ---------------- Modo práctica ----------------

# Inicia rapidamente un conjunto predefinido de servicios para practicas:
# Tipo 1 = MySQL + MongoDB, Tipo 2 = PostgreSQL.
# Util para preparar el entorno de clase con un solo comando.
function ModoPractica($tipo){
    switch($tipo){
		1 {
            Write-Host ""
            Write-Host "Iniciando entorno MySQL + MongoDB" -ForegroundColor Cyan
            # Intentamos iniciar usando comodines por si el nombre varía por la versión
            Start-Service "mysql*" -ErrorAction SilentlyContinue
            Start-Service "MongoDB*" -ErrorAction SilentlyContinue
        }
        2 {
            Write-Host ""
            Write-Host "Iniciando entorno PostgreSQL" -ForegroundColor Cyan
            Start-Service "postgresql*" -ErrorAction SilentlyContinue
        }
        3 {
            Write-Host ""
            Write-Host "Iniciando entorno MySQL + MongoDB + Redis" -ForegroundColor Cyan
            Start-Service "mysql*" -ErrorAction SilentlyContinue
            Start-Service "MongoDB*" -ErrorAction SilentlyContinue
            Start-Service "Redis*" -ErrorAction SilentlyContinue
        }
		Default {
            Write-Host "Opción no válida" -ForegroundColor Red
        }
    }
    pause
}

# ---------------- Ayuda ----------------

# Muestra instrucciones para configurar los servicios de BD en modo de inicio manual,
# tanto por interfaz grafica (services.msc) como por linea de comandos (sc config).
# Evita que los servidores arranquen automaticamente con Windows.
function AyudaServicios{
    Clear-Host
    Write-Host "CONFIGURAR SERVICIOS EN MODO MANUAL"
    Write-Host "-----------------------------------"
    Write-Host "Para evitar que los servidores se inicien automaticamente:"
    Write-Host ""
    Write-Host "Metodo grafico, pulsa tecla Windows + R:"
    Write-Host "1 Abrir services.msc"
    Write-Host "2 Buscar el servidor de base de datos"
    Write-Host "3 Cambiar 'Tipo de inicio' a MANUAL"
    Write-Host "-----------------------------------"
    Write-Host "Metodo comando administrador:"
    Write-Host ""
    Write-Host "sc config MySQL start= demand"
    Write-Host "sc config MongoDB start= demand"
    Write-Host "sc config postgresql-x64-15 start= demand"
    Write-Host "sc config MSSQLSERVER start= demand"
    Write-Host ""
    pause
}

# ---------------- Resetear password root ----------------

# Busca el ejecutable mysqld.exe en entornos locales (XAMPP, WAMP, Laragon, MAMP)
# y en el PATH del sistema. Devuelve un hashtable con la ruta del exe, la ruta base
# del entorno y el tipo, o $null si no se encuentra.
function BuscarMysqldExe {
    # Buscar en entornos locales
    foreach ($nombre in @("XAMPP","WAMP","Laragon","MAMP","Bitnami","EasyPHP","Devilbox","AMPPS","UwAmp","WPN-XM","OpenServer")) {
        $basePath = BuscarEntornoEnUnidades $nombre
        if ($basePath) {
            $exe = Join-Path $basePath "mysql\bin\mysqld.exe"
            if (Test-Path $exe) {
                return @{ Exe = $exe; BasePath = $basePath; Tipo = $nombre }
            }
        }
    }
    # Buscar en PATH
    $enPath = Get-Command mysqld.exe -ErrorAction SilentlyContinue
    if ($enPath) {
        return @{ Exe = $enPath.Source; BasePath = (Split-Path (Split-Path $enPath.Source)); Tipo = "Instalacion local" }
    }
    return $null
}

# Busca el cliente mysql.exe en entornos locales y en el PATH del sistema.
# Se usa para ejecutar comandos SQL durante el reseteo de password root.
# Devuelve la ruta completa del exe o $null si no se encuentra.
function BuscarMysqlExe {
    foreach ($nombre in @("XAMPP","WAMP","Laragon","MAMP","Bitnami","EasyPHP","Devilbox","AMPPS","UwAmp","WPN-XM","OpenServer")) {
        $basePath = BuscarEntornoEnUnidades $nombre
        if ($basePath) {
            $exe = Join-Path $basePath "mysql\bin\mysql.exe"
            if (Test-Path $exe) { return $exe }
        }
    }
    $enPath = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Source }
    return $null
}

# Resetea la contraseña root de MySQL/MariaDB en 4 pasos:
# 1. Detiene el servidor, 2. Lo inicia en modo skip-grant-tables,
# 3. Ejecuta ALTER USER para cambiar la contraseña,
# 4. Detiene el servidor inseguro para que se reinicie normalmente.
function ResetearPasswordRoot {
    Clear-Host
    Write-Host "======================================"
    Write-Host "  RESETEAR PASSWORD ROOT MySQL/MariaDB"
    Write-Host "======================================"
    Write-Host ""

    if (-not (EsAdministrador)) {
        Write-Host "Se necesitan permisos de administrador para esta operacion." -ForegroundColor Red
        pause
        return
    }

    $infoMysqld = BuscarMysqldExe
    if (-not $infoMysqld) {
        Write-Host "No se encontro mysqld.exe en el sistema." -ForegroundColor Red
        pause
        return
    }

    $mysqlExe = BuscarMysqlExe
    if (-not $mysqlExe) {
        Write-Host "No se encontro mysql.exe (cliente) en el sistema." -ForegroundColor Red
        pause
        return
    }

    $mysqldExe = $infoMysqld.Exe
    $basePath  = $infoMysqld.BasePath
    $tipo      = $infoMysqld.Tipo

    Write-Host "Motor encontrado: $tipo" -ForegroundColor Cyan
    Write-Host "mysqld: $mysqldExe" -ForegroundColor Gray
    Write-Host "mysql:  $mysqlExe" -ForegroundColor Gray
    Write-Host ""
    Write-Host "ATENCION: Este proceso detendra el servidor MySQL/MariaDB temporalmente." -ForegroundColor Yellow
    Write-Host ""
    $confirmar = Read-Host "Continuar? (s/n)"
    if ($confirmar -ne "s") { return }

    # Solicitar nueva password
    $nuevaPass = Read-Host "Introduce la nueva password para root"
    if ([string]::IsNullOrWhiteSpace($nuevaPass)) {
        Write-Host "La password no puede estar vacia." -ForegroundColor Red
        pause
        return
    }
    $confirmarPass = Read-Host "Repite la nueva password"
    if ($nuevaPass -ne $confirmarPass) {
        Write-Host "Las passwords no coinciden." -ForegroundColor Red
        pause
        return
    }

    Write-Host ""
    Write-Host "Paso 1: Deteniendo servidor MySQL/MariaDB..." -ForegroundColor Yellow

    # Detener el proceso mysqld actual
    $procMysql = Get-Process -Name mysqld -ErrorAction SilentlyContinue
    if ($procMysql) {
        # Intentar shutdown limpio
        $mysqladmin = Join-Path (Split-Path $mysqlExe) "mysqladmin.exe"
        if (Test-Path $mysqladmin) {
            & $mysqladmin -u root shutdown 2>$null
            Start-Sleep 3
        }
        # Si sigue vivo, forzar
        $procMysql = Get-Process -Name mysqld -ErrorAction SilentlyContinue
        if ($procMysql) {
            Stop-Process -Name mysqld -Force -ErrorAction SilentlyContinue
            Start-Sleep 2
        }
    }

    $procCheck = Get-Process -Name mysqld -ErrorAction SilentlyContinue
    if ($procCheck) {
        Write-Host "No se pudo detener MySQL/MariaDB." -ForegroundColor Red
        pause
        return
    }
    Write-Host "Servidor detenido." -ForegroundColor Green

    Write-Host "Paso 2: Iniciando en modo skip-grant-tables..." -ForegroundColor Yellow

    # Buscar my.ini para el datadir
    $myIni = Join-Path $basePath "mysql\bin\my.ini"
    $args_mysqld = @("--skip-grant-tables", "--skip-networking")
    if (Test-Path $myIni) {
        $args_mysqld = @("--defaults-file=$myIni", "--skip-grant-tables", "--skip-networking")
    }

    $procSkip = Start-Process -FilePath $mysqldExe -ArgumentList $args_mysqld -WindowStyle Hidden -PassThru
    Start-Sleep 4

    if ($procSkip.HasExited) {
        Write-Host "No se pudo iniciar mysqld en modo seguro." -ForegroundColor Red
        pause
        return
    }
    Write-Host "Servidor iniciado en modo seguro (PID: $($procSkip.Id))" -ForegroundColor Green

    Write-Host "Paso 3: Cambiando password de root..." -ForegroundColor Yellow

    # Detectar si es MariaDB o MySQL para usar la query correcta
    $version = & $mysqldExe --version 2>&1 | Out-String
    $esMariaDB = $version -match "MariaDB"

    # Escapar comillas simples en la password para evitar inyeccion SQL
    $passEscapada = $nuevaPass -replace "'", "''"

    if ($esMariaDB) {
        $sql = "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY '$passEscapada'; FLUSH PRIVILEGES;"
    } else {
        $sql = "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY '$passEscapada'; FLUSH PRIVILEGES;"
    }

    $resultadoSQL = echo $sql | & $mysqlExe -u root --port=0 --socket=mysql 2>&1 | Out-String

    # Metodo alternativo si el anterior falla
    if ($resultadoSQL -match "ERROR") {
        $sql2 = "FLUSH PRIVILEGES; SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$passEscapada'); FLUSH PRIVILEGES;"
        $resultadoSQL = echo $sql2 | & $mysqlExe -u root --port=0 --socket=mysql 2>&1 | Out-String
    }

    Write-Host "Paso 4: Deteniendo servidor en modo seguro..." -ForegroundColor Yellow
    Stop-Process -Id $procSkip.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep 2

    if ($resultadoSQL -match "ERROR") {
        Write-Host "Hubo un problema al cambiar la password:" -ForegroundColor Red
        Write-Host $resultadoSQL -ForegroundColor Red
        Write-Host ""
        Write-Host "Puedes intentar manualmente:" -ForegroundColor Yellow
        Write-Host "1. Abrir cmd como administrador" -ForegroundColor Cyan
        Write-Host "2. Ir a la carpeta bin de MySQL: cd $(Split-Path $mysqldExe)" -ForegroundColor Cyan
        Write-Host "3. mysqld --skip-grant-tables --skip-networking" -ForegroundColor Cyan
        Write-Host "4. En otra ventana: mysql -u root" -ForegroundColor Cyan
        Write-Host "5. FLUSH PRIVILEGES;" -ForegroundColor Cyan
        Write-Host "6. ALTER USER 'root'@'localhost' IDENTIFIED BY 'nuevapass';" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "Password de root cambiada correctamente." -ForegroundColor Green
        Write-Host "Ahora puedes iniciar el servidor normalmente desde el menu." -ForegroundColor Green
    }
    pause
}

# ---------------- Diagnóstico completo ----------------

# Realiza un diagnostico completo del equipo mostrando:
# - Servicios Windows de BD detectados y su estado
# - Servidores de BD encontrados en entornos locales
# - Puertos ocupados y posibles conflictos
# - Uso de memoria RAM por cada servidor activo
function DiagnosticoCompleto{
    Clear-Host
    Write-Host "======================================"
    Write-Host "  DIAGNOSTICO COMPLETO DEL EQUIPO"
    Write-Host "======================================"
    Write-Host ""

    $servicios = DetectarServicios
    $entornos  = DetectarServidoresEntorno

    Write-Host "SERVIDORES DE BASE DE DATOS"
    foreach($s in $servicios){
        $puerto = ObtenerPuerto $s
        $ram = ObtenerRAM $s
        if($s.Status -eq "Running"){
            $salud = Test-SaludBD $s.Name $puerto
            Write-Host "$($s.Name) ACTIVO  RAM:${ram}MB  PUERTO:$puerto  SALUD:$salud" -ForegroundColor Green
        }else{
            Write-Host "$($s.Name) DETENIDO  PUERTO:$puerto" -ForegroundColor Red
        }
    }
    foreach ($e in $entornos) {
        if ($e.Estado -eq "Running") {
            $salud = Test-SaludBD $e.Nombre $e.Puerto
            Write-Host "$($e.Nombre) ACTIVO  RAM:$($e.RAM)MB  PUERTO:$($e.Puerto)  SALUD:$salud" -ForegroundColor Cyan
        } else {
            Write-Host "$($e.Nombre) DETENIDO  PUERTO:$($e.Puerto)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "PUERTOS USADOS POR LAS BASES DE DATOS"
    $puertos = $puertosBD

    foreach($p in $puertos){
        $linea = netstat -ano | Select-String "LISTENING" | Select-String ":$p\s" | Select-Object -First 1
        if($linea){
            $textoLinea = $linea.Line
            $pidProceso = ($textoLinea -split "\s+")[-1]
            $proceso = Get-Process -Id $pidProceso -ErrorAction SilentlyContinue
            if($proceso){
                Write-Host "Puerto $p ocupado por $($proceso.ProcessName)" -ForegroundColor Yellow
            }else{
                Write-Host "Puerto $p ocupado (PID $pidProceso)" -ForegroundColor Yellow
            }
        }else{
            Write-Host "Puerto $p libre" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "USO DE MEMORIA POR LAS BASES DE DATOS"
    $total=0
    foreach($s in $servicios){$ram=ObtenerRAM $s;if($ram -gt 0){Write-Host "$($s.Name) usa ${ram}MB";$total+=$ram}}

    # Procesos de entornos locales (no registrados como servicios)
    foreach ($e in $entornos) {
        if ($e.Estado -eq "Running" -and $e.RAM -gt 0) {
            Write-Host "$($e.Nombre) usa $($e.RAM)MB" -ForegroundColor Cyan
            $total += $e.RAM
        }
    }
    Write-Host "RAM total usada por BBDD: $total MB"

    Write-Host ""
    Write-Host "DETECCION DE ENTORNOS QUE PUEDEN CAUSAR CONFLICTOS"
    DetectarEntornosWeb

    Write-Host ""
    Write-Host "RECOMENDACIONES"
    if($total -gt 2000){Write-Host "- Mucha RAM usada por las bases de datos. Detener alguno." -ForegroundColor Yellow}
    foreach($p in $puertos){if(PuertoOcupado $p){Write-Host "- Revisar conflicto en puerto $p" -ForegroundColor Yellow}}
    pause
}

# ---------------- Exportar diagnostico ----------------

function Generar-InformeDiagnostico {
    $servicios = DetectarServicios
    $entornos  = DetectarServidoresEntorno
    $total = 0
    $lineas = @()
    $lineas += "======================================"
    $lineas += "  INFORME DE DIAGNOSTICO - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lineas += "======================================"
    $lineas += ""
    $lineas += "SERVIDORES DE BASE DE DATOS"
    foreach ($s in $servicios) {
        $puerto = ObtenerPuerto $s
        $ram = ObtenerRAM $s
        if ($s.Status -eq "Running") {
            $salud = Test-SaludBD $s.Name $puerto
            $lineas += "$($s.Name) ACTIVO  RAM:${ram}MB  PUERTO:$puerto  SALUD:$salud"
            $total += $ram
        } else {
            $lineas += "$($s.Name) DETENIDO  PUERTO:$puerto"
        }
    }
    foreach ($e in $entornos) {
        if ($e.Estado -eq "Running") {
            $salud = Test-SaludBD $e.Nombre $e.Puerto
            $lineas += "$($e.Nombre) ACTIVO  RAM:$($e.RAM)MB  PUERTO:$($e.Puerto)  SALUD:$salud"
            $total += $e.RAM
        } else {
            $lineas += "$($e.Nombre) DETENIDO  PUERTO:$($e.Puerto)"
        }
    }
    $lineas += ""
    $lineas += "PUERTOS USADOS POR LAS BASES DE DATOS"
    foreach ($p in $puertosBD) {
        if (PuertoOcupado $p) { $lineas += "Puerto $p OCUPADO" }
        else { $lineas += "Puerto $p libre" }
    }
    $lineas += ""
    $lineas += "RAM total usada por BBDD: $total MB"
    $lineas += ""
    $lineas += "CONTENEDORES DE BD"
    $conts = Listar-ContenedoresBD
    if ($conts.Count -eq 0) { $lineas += "Ninguno detectado" }
    else {
        foreach ($c in $conts) {
            $lineas += "[$($c.Motor)] $($c.Nombre)  $($c.Imagen)  $($c.Estado)  $($c.Puertos)"
        }
    }
    $lineas += ""
    $lineas += "FIN DEL INFORME"
    return $lineas
}

function Exportar-Diagnostico($archivo) {
    if ([string]::IsNullOrWhiteSpace($archivo)) {
        $archivo = Read-Host "Ruta del archivo de salida"
    }
    if ([string]::IsNullOrWhiteSpace($archivo)) { return }
    try {
        Generar-InformeDiagnostico | Set-Content -Path $archivo -Encoding UTF8
        Write-Host "Diagnostico exportado a: $archivo" -ForegroundColor Green
        Registrar-Log "export-diagnostico archivo=$archivo resultado=ok"
    } catch {
        Write-Host "No se pudo escribir en: $archivo" -ForegroundColor Red
        Registrar-Log "export-diagnostico archivo=$archivo resultado=error"
    }
}

# ---------------- Gestion de contenedores Docker / Podman ----------------

function Listar-ContenedoresBD {
    $resultado = @()
    foreach ($motor in @('docker', 'podman')) {
        $exe = Get-Command $motor -ErrorAction SilentlyContinue
        if (-not $exe) { continue }
        $lista = & $motor ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' 2>$null
        foreach ($linea in $lista) {
            if ($linea -match $script:patronBdCont) {
                $partes = $linea -split '\|', 5
                if ($partes.Count -ge 5) {
                    $resultado += [PSCustomObject]@{
                        Motor   = $motor
                        Id      = $partes[0]
                        Nombre  = $partes[1]
                        Imagen  = $partes[2]
                        Puertos = $partes[3]
                        Estado  = $partes[4]
                    }
                }
            }
        }
    }
    return $resultado
}

function Invoke-AccionContenedor($motor, $accion, $nombre) {
    switch ($accion) {
        'start'   { & $motor start $nombre 2>$null; return $LASTEXITCODE -eq 0 }
        'stop'    { & $motor stop $nombre 2>$null; return $LASTEXITCODE -eq 0 }
        'restart' { & $motor restart $nombre 2>$null; return $LASTEXITCODE -eq 0 }
        default   { return $false }
    }
}

function Gestionar-Contenedores {
    Clear-Host
    Write-Host "======================================"
    Write-Host "  GESTION DE CONTENEDORES DE BD"
    Write-Host "======================================"
    Write-Host ""
    $conts = Listar-ContenedoresBD
    if ($conts.Count -eq 0) {
        Write-Host "No se detectaron contenedores de bases de datos." -ForegroundColor Yellow
        pause
        return
    }
    Write-Host "CONTENEDORES DETECTADOS:"
    for ($i = 0; $i -lt $conts.Count; $i++) {
        $c = $conts[$i]
        Write-Host "  [$($i+1)] [$($c.Motor)] $($c.Nombre)  ($($c.Imagen))  $($c.Estado)  $($c.Puertos)"
    }
    Write-Host ""
    Write-Host "1 Iniciar contenedor"
    Write-Host "2 Detener contenedor"
    Write-Host "3 Reiniciar contenedor"
    Write-Host "0 Volver"
    $acc = Read-Host "Accion"
    if ($acc -eq "0" -or [string]::IsNullOrWhiteSpace($acc)) { return }
    $num = Read-Host "Numero de contenedor"
    if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $conts.Count) {
        Write-Host "Numero no valido." -ForegroundColor Red
        pause
        return
    }
    $c = $conts[[int]$num - 1]
    $accionCmd = switch ($acc) {
        "1" { "start" }
        "2" { "stop" }
        "3" { "restart" }
        default { $null }
    }
    if (-not $accionCmd) {
        Write-Host "Accion no valida." -ForegroundColor Red
        pause
        return
    }
    if (Invoke-AccionContenedor $c.Motor $accionCmd $c.Nombre) {
        Write-Host "Contenedor $($c.Nombre) ($accionCmd) ejecutado correctamente." -ForegroundColor Green
        Registrar-Log "container $accionCmd motor=$($c.Motor) nombre=$($c.Nombre) resultado=ok"
    } else {
        Write-Host "Error al $accionCmd el contenedor $($c.Nombre)." -ForegroundColor Red
        Registrar-Log "container $accionCmd motor=$($c.Motor) nombre=$($c.Nombre) resultado=error"
    }
    pause
}

function Test-ComposeDisponible {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        docker compose version 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return [bool](Get-Command docker-compose -ErrorAction SilentlyContinue)
}

function Get-ProyectosCompose {
    $patron = $script:patronBdCont
    $archivos = @()

    # Acotamos la busqueda a carpetas de desarrollo habituales en lugar de
    # recorrer todo %USERPROFILE% (que incluye AppData con miles de archivos
    # y dispara el lag del menu en discos mecanicos o SSDs externos).
    $dirs = @(
        $script:scriptDir,
        (Join-Path $env:USERPROFILE 'Projects'),
        (Join-Path $env:USERPROFILE 'projects'),
        (Join-Path $env:USERPROFILE 'source\repos'),
        (Join-Path $env:USERPROFILE 'source'),
        (Join-Path $env:USERPROFILE 'dev'),
        (Join-Path $env:USERPROFILE 'git'),
        (Join-Path $env:USERPROFILE 'repos'),
        (Join-Path $env:USERPROFILE 'code'),
        (Join-Path $env:USERPROFILE 'Documents\GitHub'),
        'C:\opt', 'C:\srv', 'C:\projects', 'C:\dev', 'C:\docker'
    )
    # Rutas extra definidas por el usuario (GESTOR_BD_EXTRA_PATHS / conf).
    $dirs += (RutasExtraUsuario)

    # Profundidad limitada (-Depth 3): suficiente para <root>/<proyecto>/<sub>
    # sin penalizar la respuesta del menu interactivo.
    foreach ($dir in ($dirs | Where-Object { $_ } | Sort-Object -Unique)) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -Recurse -Depth 3 -File -Include docker-compose.yml,docker-compose.yaml,compose.yml,compose.yaml -ErrorAction SilentlyContinue | ForEach-Object {
            $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match $patron) { $archivos += $_.FullName }
        }
    }
    return @($archivos | Sort-Object -Unique)
}

function Invoke-ComposeEjecutar($accion, $ruta) {
    if (-not (Test-ComposeDisponible)) {
        Write-Host "Docker Compose no esta disponible en el sistema." -ForegroundColor Red
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ruta)) {
        Write-Host "Indica la ruta al archivo compose o al directorio del proyecto."
        return $false
    }
    $dir = $null
    $archivo = $null
    if (Test-Path $ruta -PathType Leaf) {
        $dir = Split-Path $ruta -Parent
        $archivo = Split-Path $ruta -Leaf
    } elseif (Test-Path $ruta -PathType Container) {
        $dir = $ruta
        if (Test-Path (Join-Path $dir "docker-compose.yml")) { $archivo = "docker-compose.yml" }
        elseif (Test-Path (Join-Path $dir "compose.yml")) { $archivo = "compose.yml" }
    } else {
        Write-Host "Ruta no valida: $ruta" -ForegroundColor Red
        return $false
    }
    $flags = if ($accion -eq "up") { "-d" } else { "" }
    Push-Location $dir
    try {
        docker compose version 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            if ($archivo) { docker compose -f $archivo $accion $flags }
            else { docker compose $accion $flags }
        } else {
            if ($archivo) { docker-compose -f $archivo $accion $flags }
            else { docker-compose $accion $flags }
        }
        if ($LASTEXITCODE -eq 0) {
            Registrar-Log "compose-$accion ruta=$dir resultado=ok"
            return $true
        }
    } finally { Pop-Location }
    Registrar-Log "compose-$accion ruta=$dir resultado=error"
    return $false
}

function Gestionar-Compose {
    Clear-Host
    Write-Host "======================================"
    Write-Host "  GESTION DOCKER COMPOSE (BD)"
    Write-Host "======================================"
    Write-Host ""
    if (-not (Test-ComposeDisponible)) {
        Write-Host "Docker Compose no esta instalado o no responde." -ForegroundColor Yellow
        pause
        return
    }
    $proyectos = Get-ProyectosCompose
    if ($proyectos.Count -eq 0) {
        Write-Host "No se detectaron proyectos Docker Compose con servicios de BD." -ForegroundColor Yellow
        pause
        return
    }
    Write-Host "PROYECTOS DETECTADOS:"
    for ($i = 0; $i -lt $proyectos.Count; $i++) {
        Write-Host "  [$($i+1)] $($proyectos[$i])"
    }
    Write-Host ""
    Write-Host "1 Levantar proyecto (docker compose up -d)"
    Write-Host "2 Detener proyecto (docker compose down)"
    Write-Host "0 Volver"
    $acc = Read-Host "Accion"
    if ($acc -eq "0" -or [string]::IsNullOrWhiteSpace($acc)) { return }
    $num = Read-Host "Numero de proyecto"
    if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $proyectos.Count) {
        Write-Host "Numero no valido." -ForegroundColor Red
        pause
        return
    }
    $ruta = $proyectos[[int]$num - 1]
    switch ($acc) {
        "1" {
            if (Invoke-ComposeEjecutar "up" $ruta) {
                Write-Host "Proyecto levantado: $ruta" -ForegroundColor Green
            } else {
                Write-Host "Error al levantar el proyecto." -ForegroundColor Red
            }
        }
        "2" {
            if (Invoke-ComposeEjecutar "down" $ruta) {
                Write-Host "Proyecto detenido: $ruta" -ForegroundColor Green
            } else {
                Write-Host "Error al detener el proyecto." -ForegroundColor Red
            }
        }
        default { Write-Host "Accion no valida." -ForegroundColor Red }
    }
    pause
}

# ---------------- Modo CLI ----------------

$script:resolverTipo = ""
$script:resolverNombre = ""
$script:resolverServicio = $null
$script:resolverEntorno = $null

function Get-ContarServidoresActivos {
    $n = 0
    foreach ($s in (DetectarServicios)) { if ($s.Status -eq "Running") { $n++ } }
    foreach ($e in (DetectarServidoresEntorno)) { if ($e.Estado -eq "Running") { $n++ } }
    return $n
}

function Resolve-ServidorBD($busqueda) {
    $b = $busqueda.ToLower()
    $script:resolverTipo = ""; $script:resolverNombre = ""
    $script:resolverServicio = $null; $script:resolverEntorno = $null
    foreach ($s in (DetectarServicios)) {
        if ($s.Name.ToLower() -like "*$b*") {
            $script:resolverTipo = "servicio"
            $script:resolverNombre = $s.Name
            $script:resolverServicio = $s
            return $true
        }
    }
    foreach ($e in (DetectarServidoresEntorno)) {
        if ($e.Nombre.ToLower() -like "*$b*" -or $e.Tipo.ToLower() -like "*$b*") {
            $script:resolverTipo = "entorno"
            $script:resolverNombre = $e.Nombre
            $script:resolverEntorno = $e
            return $true
        }
    }
    return $false
}

function Get-CliStatusJson {
    $servidores = @()
    foreach ($s in (DetectarServicios)) {
        $puerto = ObtenerPuerto $s
        $ram = ObtenerRAM $s
        $entry = [ordered]@{
            nombre = $s.Name
            tipo   = "servicio"
            estado = $s.Status
            puerto = [int]$puerto
            ram_mb = [int]$ram
        }
        if ($s.Status -eq "Running") { $entry.salud = Test-SaludBD $s.Name $puerto }
        $servidores += [pscustomobject]$entry
    }
    $entornos = @()
    foreach ($e in (DetectarServidoresEntorno)) {
        $entry = [ordered]@{
            nombre = $e.Nombre
            tipo   = $e.Tipo
            estado = $e.Estado
            puerto = [int]$e.Puerto
            ram_mb = [int]$e.RAM
        }
        if ($e.Estado -eq "Running") { $entry.salud = Test-SaludBD $e.Nombre $e.Puerto }
        $entornos += [pscustomobject]$entry
    }
    $contenedores = @()
    foreach ($c in (Listar-ContenedoresBD)) {
        $contenedores += [pscustomobject]@{
            motor   = $c.Motor
            id      = $c.Id
            nombre  = $c.Nombre
            imagen  = $c.Imagen
            puertos = $c.Puertos
            estado  = $c.Estado
        }
    }
    $data = [ordered]@{
        init_system       = "windows"
        servidores        = $servidores
        entornos          = $entornos
        contenedores      = $contenedores
        proyectos_compose = @(Get-ProyectosCompose)
    }
    return ($data | ConvertTo-Json -Depth 5 -Compress)
}

function Show-CliStatus {
    if ($Json) {
        Get-CliStatusJson | Write-Output
        return
    }
    Write-Host "ESTADO DE SERVIDORES DE BD"
    Write-Host "--------------------------"
    foreach ($s in (DetectarServicios)) {
        $puerto = ObtenerPuerto $s
        $ram = ObtenerRAM $s
        if ($s.Status -eq "Running") {
            $salud = Test-SaludBD $s.Name $puerto
            Write-Host "[SERVICIO] $($s.Name) ACTIVO  puerto=$puerto  RAM=${ram}MB  salud=$salud"
        } else {
            Write-Host "[SERVICIO] $($s.Name) DETENIDO  puerto=$puerto"
        }
    }
    foreach ($e in (DetectarServidoresEntorno)) {
        if ($e.Estado -eq "Running") {
            $salud = Test-SaludBD $e.Nombre $e.Puerto
            Write-Host "[$($e.Tipo)] $($e.Nombre) ACTIVO  puerto=$($e.Puerto)  RAM=$($e.RAM)MB  salud=$salud"
        } else {
            Write-Host "[$($e.Tipo)] $($e.Nombre) DETENIDO  puerto=$($e.Puerto)"
        }
    }
    Write-Host ""
    Write-Host "CONTENEDORES DE BD"
    foreach ($c in (Listar-ContenedoresBD)) {
        Write-Host "[$($c.Motor)] $($c.Nombre)  $($c.Estado)  $($c.Puertos)"
    }
}

function Invoke-CliAccionServidor($accion, $busqueda) {
    if ([string]::IsNullOrWhiteSpace($busqueda)) {
        Write-Host "Uso: -$accion <nombre>"
        return
    }
    if (-not (Resolve-ServidorBD $busqueda)) {
        Write-Host "No se encontro servidor: $busqueda"
        return
    }
    $activos = Get-ContarServidoresActivos
    switch ($accion) {
        "Start" {
            if ($script:resolverTipo -eq "servicio") {
                IniciarServidor $script:resolverServicio $activos
            } elseif ($script:resolverEntorno.Estado -eq "Running") {
                Write-Host "Ya activo: $($script:resolverNombre)"
            } elseif ($activos -ge $maxActivos) {
                Write-Host "Solo se permiten $maxActivos servidores activos."
            } else {
                IniciarEntorno $script:resolverEntorno
            }
        }
        "Stop" {
            if ($script:resolverTipo -eq "servicio") {
                Stop-Service $script:resolverServicio.Name -ErrorAction SilentlyContinue
                Write-Host "Base de datos $($script:resolverNombre) detenida."
                Registrar-Log "stop servicio=$($script:resolverNombre) resultado=ok"
            } else {
                DetenerEntorno $script:resolverEntorno
            }
        }
        "Restart" {
            if ($script:resolverTipo -eq "servicio") {
                Restart-Service $script:resolverServicio.Name -ErrorAction SilentlyContinue
                Write-Host "Base de datos $($script:resolverNombre) reiniciada."
                Registrar-Log "restart servicio=$($script:resolverNombre) resultado=ok"
            } else {
                ReiniciarEntorno $script:resolverEntorno
            }
        }
        "Health" {
            $puerto = if ($script:resolverTipo -eq "servicio") { ObtenerPuerto $script:resolverServicio } else { $script:resolverEntorno.Puerto }
            $estado = if ($script:resolverTipo -eq "servicio") { $script:resolverServicio.Status } else { $script:resolverEntorno.Estado }
            $salud = Test-SaludBD $script:resolverNombre $puerto
            if ($Json) {
                @{
                    nombre = $script:resolverNombre
                    estado = [string]$estado
                    puerto = [int]$puerto
                    salud  = $salud
                } | ConvertTo-Json -Compress | Write-Output
            } else {
                Write-Host "$($script:resolverNombre): estado=$estado puerto=$puerto salud=$salud"
            }
            Registrar-Log "cli-health nombre=$($script:resolverNombre) salud=$salud"
        }
    }
}

function Invoke-CliAccionContenedor($accion, $busqueda) {
    if ([string]::IsNullOrWhiteSpace($busqueda)) {
        Write-Host "Uso: -Container$accion <nombre>"
        return
    }
    $b = $busqueda.ToLower()
    foreach ($c in (Listar-ContenedoresBD)) {
        if ($c.Nombre.ToLower() -like "*$b*") {
            if (Invoke-AccionContenedor $c.Motor $accion.ToLower() $c.Nombre) {
                Write-Host "Contenedor $($c.Nombre) ($accion) OK"
                Registrar-Log "cli-container-$($accion.ToLower()) motor=$($c.Motor) nombre=$($c.Nombre) resultado=ok"
            } else {
                Write-Host "Error al $accion contenedor $($c.Nombre)"
            }
            return
        }
    }
    Write-Host "No se encontro contenedor: $busqueda"
}

function Show-CliHelp {
    @"
Uso: gestor_bbdd.ps1 [parametros]

Modo interactivo (por defecto):
  powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1

Modo CLI (no interactivo):
  -Status                  Muestra estado de servidores y contenedores
  -Start <nombre>          Inicia un servidor (coincidencia parcial)
  -Stop <nombre>           Detiene un servidor
  -Restart <nombre>        Reinicia un servidor
  -Health <nombre>          Comprueba salud/conectividad
  -Diagnose                Muestra diagnostico completo en pantalla
  -Export <archivo>        Exporta diagnostico a un archivo de texto
  -Containers              Lista contenedores Docker/Podman de BD
  -ContainerStart <nombre> Inicia contenedor por nombre
  -ContainerStop <nombre>   Detiene contenedor por nombre
  -ContainerRestart <nombre> Reinicia contenedor por nombre
  -ComposeList             Lista proyectos Docker Compose con servicios de BD
  -ComposeUp <ruta>        Levanta un proyecto compose (ruta al yml o directorio)
  -ComposeDown <ruta>      Detiene un proyecto compose
  -Ports                   Muestra los puertos en escucha
  -Detect                  Detecta entornos locales (XAMPP/WAMP/Docker/etc.)
  -HelpServices            Ayuda para configurar servicios en modo manual
  -ResetPassword           Resetea la contrasena root de MySQL/MariaDB (interactivo)
  -OpenTerminal <nombre>   Abre una terminal del cliente del servidor indicado
  -Json                    Salida en formato JSON (con -Status, -Diagnose, -Health, etc.)
  -Help                    Muestra esta ayuda

Ejemplos:
  powershell -File .\gestor_bbdd.ps1 -Status
  powershell -File .\gestor_bbdd.ps1 -Json -Status
  powershell -File .\gestor_bbdd.ps1 -Start mysql
  powershell -File .\gestor_bbdd.ps1 -ComposeUp C:\proyectos\mi-db\docker-compose.yml
  powershell -File .\gestor_bbdd.ps1 -Export C:\temp\diagnostico_bd.txt
"@ | Write-Host
}

function Invoke-CliMode {
    if ($Help) { Show-CliHelp; return }
    if ($Status) { Show-CliStatus; return }
    if ($Start) { Invoke-CliAccionServidor "Start" $Start; return }
    if ($Stop) { Invoke-CliAccionServidor "Stop" $Stop; return }
    if ($Restart) { Invoke-CliAccionServidor "Restart" $Restart; return }
    if ($Health) { Invoke-CliAccionServidor "Health" $Health; return }
    if ($Diagnose) {
        if ($Json) { Get-CliStatusJson | Write-Output; return }
        Generar-InformeDiagnostico | Write-Host
        return
    }
    if ($Export) { Exportar-Diagnostico $Export; return }
    if ($Containers) {
        if ($Json) {
            $conts = @(Listar-ContenedoresBD | ForEach-Object {
                [pscustomobject]@{
                    motor   = $_.Motor
                    id      = $_.Id
                    nombre  = $_.Nombre
                    imagen  = $_.Imagen
                    puertos = $_.Puertos
                    estado  = $_.Estado
                }
            })
            @{ contenedores = $conts } | ConvertTo-Json -Depth 4 -Compress | Write-Output
            return
        }
        Write-Host "CONTENEDORES DE BD"
        foreach ($c in (Listar-ContenedoresBD)) {
            Write-Host "[$($c.Motor)] $($c.Nombre)  $($c.Imagen)  $($c.Estado)  $($c.Puertos)"
        }
        return
    }
    if ($ContainerStart) { Invoke-CliAccionContenedor "Start" $ContainerStart; return }
    if ($ContainerStop) { Invoke-CliAccionContenedor "Stop" $ContainerStop; return }
    if ($ContainerRestart) { Invoke-CliAccionContenedor "Restart" $ContainerRestart; return }
    if ($ComposeList) {
        if ($Json) {
            @{ proyectos = @(Get-ProyectosCompose) } | ConvertTo-Json -Compress | Write-Output
        } else {
            Write-Host "PROYECTOS DOCKER COMPOSE (BD)"
            foreach ($p in (Get-ProyectosCompose)) { Write-Host "  $p" }
        }
        return
    }
    if ($ComposeUp) {
        if (Invoke-ComposeEjecutar "up" $ComposeUp) { Write-Host "Proyecto levantado." -ForegroundColor Green }
        else { Write-Host "Error al levantar el proyecto." -ForegroundColor Red }
        return
    }
    if ($ComposeDown) {
        if (Invoke-ComposeEjecutar "down" $ComposeDown) { Write-Host "Proyecto detenido." -ForegroundColor Green }
        else { Write-Host "Error al detener el proyecto." -ForegroundColor Red }
        return
    }
    if ($Ports) { netstat -ano | findstr LISTENING; return }
    if ($Detect) { DetectarEntornosWeb; return }
    if ($HelpServices) { AyudaServicios; return }
    if ($ResetPassword) { ResetearPasswordRoot; return }
    if ($OpenTerminal) {
        if (-not (Resolve-ServidorBD $OpenTerminal)) {
            Write-Host "No se encontro servidor: $OpenTerminal"
            return
        }
        AbrirTerminalDB ([pscustomobject]@{ Nombre = $script:resolverNombre })
        return
    }
    if ($Json) { Get-CliStatusJson | Write-Output; return }
}

# El "motor de búsqueda" que evitará que el programa falle si no encuentra la ruta.
function Buscar-Ejecutable($nombreArchivo) {
    # 1. Intentar buscar en el PATH del sistema (lo más rápido)
    $checkPath = Get-Command $nombreArchivo -ErrorAction SilentlyContinue
    if ($checkPath) { return $checkPath.Source }

    # 2. Definir raíces de búsqueda comunes
    $raices = @(
        "${env:ProgramFiles}", 
        "${env:ProgramFiles(x86)}", 
        "C:\xampp",
        "C:\wamp64", "C:\wamp",
        "C:\laragon",
        "C:\Bitnami",
        "C:\tools", # Si se usa Chocolatey
        "$env:LOCALAPPDATA",
        "$env:USERPROFILE\scoop\apps" # Si se usa Scoop
    )
    # Anadir rutas extra definidas por el usuario
    $raices += (RutasExtraUsuario)

    # 3. Buscar el archivo con una profundidad controlada para no tardar demasiado
    foreach ($raiz in $raices) {
        if (Test-Path $raiz) {
            # Buscamos el archivo. -Depth 4 es suficiente para llegar a los /bin de la mayoría de DBs
            $hallado = Get-ChildItem -Path $raiz -Filter $nombreArchivo -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hallado) { return $hallado.FullName }
        }
    }

    return $null
}

# Función para abrir la terminal de la base de datos encontrada
function AbrirTerminalDB($item) {
    $nombre = $item.Nombre.ToLower()
    $exe = $null
    $args = ""

    if ($nombre -like "*mysql*" -or $nombre -like "*maria*") {
        $exe = Buscar-Ejecutable "mysql.exe"
        $args = "-u root -p"
    } 
    elseif ($nombre -like "*mongo*") {
        # Buscamos primero el shell moderno
        $exe = Buscar-Ejecutable "mongosh.exe"
        
        if (-not $exe) {
            # Si no está, avisamos al usuario con la solución
            Write-Host "--- ERROR DE COMPONENTES ---" -ForegroundColor Red
            Write-Host "Se detectó el servidor MongoDB, pero falta el cliente 'mongosh.exe'." -ForegroundColor Yellow
            Write-Host "Debes descargarlo de: https://www.mongodb.com/try/download/shell" -ForegroundColor Cyan
            Write-Host "y colocarlo en la carpeta bin de MongoDB."
            return
        }
    } 
    elseif ($nombre -like "*postgres*") {
        $exe = Buscar-Ejecutable "psql.exe"
        $args = "-U postgres"
    }
    elseif ($nombre -like "*redis*") {
        $exe = Buscar-Ejecutable "redis-cli.exe"
        $args = ""
    }
    elseif ($nombre -like "*couchdb*" -or $nombre -like "*couch*") {
        Write-Host "CouchDB se administra via HTTP (Fauxton en http://localhost:5984/_utils)" -ForegroundColor Cyan
        Write-Host "Usa 'curl' desde una terminal para interactuar con la API REST." -ForegroundColor Yellow
        return
    }
    elseif ($nombre -like "*influx*") {
        $exe = Buscar-Ejecutable "influx.exe"
        if (-not $exe) {
            Write-Host "No se encontro el cliente 'influx.exe'. InfluxDB tambien se administra via HTTP en http://localhost:8086" -ForegroundColor Yellow
            return
        }
    }
    elseif ($nombre -like "*clickhouse*") {
        $exe = Buscar-Ejecutable "clickhouse-client.exe"
        if (-not $exe) { $exe = Buscar-Ejecutable "clickhouse.exe"; if ($exe) { $args = "client" } }
        if (-not $exe) {
            Write-Host "No se encontro 'clickhouse-client.exe'." -ForegroundColor Yellow
            return
        }
    }
    elseif ($nombre -like "*cockroach*") {
        $exe = Buscar-Ejecutable "cockroach.exe"
        $args = "sql --insecure"
    }
    elseif ($nombre -like "*arango*") {
        $exe = Buscar-Ejecutable "arangosh.exe"
        if (-not $exe) {
            Write-Host "No se encontro 'arangosh.exe'. ArangoDB tiene panel web en http://localhost:8529" -ForegroundColor Yellow
            return
        }
    }
    elseif ($nombre -like "*neo4j*") {
        $exe = Buscar-Ejecutable "cypher-shell.bat"
        if (-not $exe) { $exe = Buscar-Ejecutable "cypher-shell.exe" }
        if (-not $exe) {
            Write-Host "No se encontro 'cypher-shell'. Neo4j tiene panel web (Neo4j Browser) en http://localhost:7474" -ForegroundColor Yellow
            return
        }
        $args = "-u neo4j -p neo4j"
    }
    elseif ($nombre -like "*firebird*") {
        $exe = Buscar-Ejecutable "isql.exe"
        if (-not $exe) {
            Write-Host "No se encontro el cliente 'isql.exe' de Firebird." -ForegroundColor Yellow
            return
        }
    }
    elseif ($nombre -like "*rethink*") {
        Write-Host "RethinkDB se administra via panel web en http://localhost:8080" -ForegroundColor Cyan
        return
    }
    elseif ($nombre -like "*memcache*") {
        Write-Host "Memcached no tiene cliente propio. Usa 'telnet localhost 11211' (escribe 'stats' o 'quit')." -ForegroundColor Yellow
        return
    }

    if ($exe) {
        Write-Host "Lanzando terminal: $exe" -ForegroundColor Cyan
        Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", "& '$exe' $args"
    }
}
# ---------------- Menú principal ----------------

# Muestra el menu principal del programa con la lista unificada de servidores.
# Combina servicios Windows y procesos de entornos locales en una sola lista numerada.
# Muestra estado, puerto y RAM de cada servidor. Ofrece opciones del 0 al 9.
function MostrarMenu{
    Clear-Host
    Write-Host "======================================"
    Write-Host "   LAS BASES Y SUS DATOS"
    Write-Host "======================================"
    Write-Host ""
    $servicios = DetectarServicios
    $entornos  = DetectarServidoresEntorno
    $activos = 0

    # Lista unificada: cada elemento es un hashtable con Indice, Tipo, y datos
    $listaUnificada = @()

    # Agregar servicios Windows
    foreach ($s in $servicios) {
        $puerto = ObtenerPuerto $s
        $ram    = ObtenerRAM $s
        $listaUnificada += @{
            TipoGestion = "Servicio"
            Nombre      = $s.Name
            Estado      = $s.Status.ToString()
            Puerto      = $puerto
            RAM         = $ram
            Servicio    = $s
            Entorno     = $null
        }
        if ($s.Status -eq "Running") { $activos++ }
    }

    # Agregar entornos locales (evitando duplicados con servicios)
    foreach ($e in $entornos) {
        $duplicado = $false
        foreach ($s in $servicios) {
            if ($s.Status -eq "Running" -and $e.Estado -eq "Running") {
                $svcWmi = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue
                if ($svcWmi -and $svcWmi.ProcessId -eq $e.PID) { $duplicado = $true; break }
            }
        }
        if (-not $duplicado) {
            $listaUnificada += @{
                TipoGestion = $e.Tipo
                Nombre      = $e.Nombre
                Estado      = $e.Estado
                Puerto      = $e.Puerto
                RAM         = $e.RAM
                Servicio    = $null
                Entorno     = $e
            }
            if ($e.Estado -eq "Running") { $activos++ }
        }
    }

    if ($listaUnificada.Count -eq 0) {
        Write-Host "No se detectaron servidores de bases de datos." -ForegroundColor Yellow
    } else {
        Write-Host "SERVIDORES DETECTADOS:"
        Write-Host "----------------------"
        for ($i = 0; $i -lt $listaUnificada.Count; $i++) {
            $item = $listaUnificada[$i]
            $etiqueta = $item.Nombre
            $tipo = $item.TipoGestion
            if ($item.Estado -eq "Running") {
                $extra = "puerto $($item.Puerto), RAM: $($item.RAM)MB"
                if ($tipo -ne "Servicio") { $extra += ", $tipo" }
                $salud = Test-SaludBD $item.Nombre $item.Puerto
                switch ($salud) {
                    'OK'     { $extra += ", salud: OK" }
                    'NORESP' { $extra += ", salud: sin respuesta" }
                    'NOCLI'  { $extra += ", salud: sin cliente" }
                }
                Write-Host "  [$($i+1)] $etiqueta - ACTIVO ($extra)" -ForegroundColor Green
            } else {
                $extra = "puerto $($item.Puerto)"
                if ($tipo -ne "Servicio") { $extra += ", $tipo" }
                Write-Host "  [$($i+1)] $etiqueta - DETENIDO ($extra)" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Write-Host "Bases de datos activas: $activos / $maxActivos"
    Write-Host ""
    Write-Host "--- OPCIONES ---"
    Write-Host "1 Iniciar servidor"
    Write-Host "2 Detener servidor"
    Write-Host "3 Reiniciar servidor"
    Write-Host "4 Ver puertos abiertos"
    Write-Host "5 Modo practica"
    Write-Host "6 Detectar XAMPP/WAMP/Docker"
    Write-Host "7 Ayuda configurar servicios"
    Write-Host "8 Diagnostico completo del equipo"
    Write-Host "9 Resetear password root MySQL/MariaDB"
	Write-Host "10 Abrir TERMINAL de un servidor de DB"
    Write-Host "11 Comprobar salud / conectividad"
    Write-Host "12 Gestionar contenedores Docker/Podman"
    Write-Host "13 Exportar diagnostico a archivo"
    Write-Host "14 Gestionar proyectos Docker Compose"
    Write-Host "0 Salir"

    return @{ Lista = $listaUnificada; Activos = $activos }
}

# ---------------- Bucle principal ----------------

if ($Help -or $Status -or $Start -or $Stop -or $Restart -or $Health -or $Diagnose -or $Export -or $Containers -or $ContainerStart -or $ContainerStop -or $ContainerRestart -or $Json -or $ComposeList -or $ComposeUp -or $ComposeDown -or $Ports -or $Detect -or $HelpServices -or $ResetPassword -or $OpenTerminal) {
    $script:modoCli = $true
    Invoke-CliMode
    return
}

:menuLoop while($true){
    $resultado = MostrarMenu
    $lista = $resultado.Lista
    $activos = $resultado.Activos
    $op = Read-Host "Seleccione opcion"

    switch($op){
        "1"{
            if ($lista.Count -eq 0) { Write-Host "No hay bases de datos detectadas." -ForegroundColor Yellow; pause; continue }
            $n=Read-Host "Numero base de datos"
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $lista.Count) {
                $item = $lista[[int]$n-1]
                if ($item.Estado -eq "Running") {
                    Write-Host "$($item.Nombre) ya esta en ejecucion." -ForegroundColor Yellow
                } elseif ($item.TipoGestion -eq "Servicio") {
                    IniciarServidor $item.Servicio $activos
                } else {
                    if ($activos -ge $maxActivos) {
                        Write-Host "Solo se permiten $maxActivos servidores activos." -ForegroundColor Red
                    } else {
                        IniciarEntorno $item.Entorno
                    }
                }
            } else {
                Write-Host "Numero no valido." -ForegroundColor Red
            }
            pause
        }
        "2"{
            if ($lista.Count -eq 0) { Write-Host "No hay bases de datos detectadas." -ForegroundColor Yellow; pause; continue }
            $n=Read-Host "Numero base de datos"
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $lista.Count) {
                $item = $lista[[int]$n-1]
                if ($item.Estado -ne "Running") {
                    Write-Host "$($item.Nombre) ya esta detenido." -ForegroundColor Yellow
                } elseif ($item.TipoGestion -eq "Servicio") {
                    try {
                        Stop-Service $item.Servicio.Name -ErrorAction Stop
                        Write-Host "Base de datos $($item.Nombre) detenida." -ForegroundColor Green
                    } catch {
                        Write-Host "Error al detener $($item.Nombre): $_" -ForegroundColor Red
                    }
                } else {
                    DetenerEntorno $item.Entorno
                }
            } else {
                Write-Host "Numero no valido." -ForegroundColor Red
            }
            pause
        }
        "3"{
            if ($lista.Count -eq 0) { Write-Host "No hay bases de datos detectadas." -ForegroundColor Yellow; pause; continue }
            $n=Read-Host "Numero base de datos"
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $lista.Count) {
                $item = $lista[[int]$n-1]
                if ($item.TipoGestion -eq "Servicio") {
                    try {
                        Restart-Service $item.Servicio.Name -ErrorAction Stop
                        Write-Host "Base de datos $($item.Nombre) reiniciada." -ForegroundColor Green
                    } catch {
                        Write-Host "Error al reiniciar $($item.Nombre): $_" -ForegroundColor Red
                    }
                } else {
                    if ($item.Estado -eq "Running") {
                        ReiniciarEntorno $item.Entorno
                    } else {
                        Write-Host "$($item.Nombre) esta detenido. Usa la opcion 1 para iniciar." -ForegroundColor Yellow
                    }
                }
            } else {
                Write-Host "Numero no valido." -ForegroundColor Red
            }
            pause
        }
        "4"{netstat -ano | findstr LISTENING; pause}
        "5"{
            Write-Host "1 Entorno MySQL + MongoDB"
            Write-Host "2 Entorno PostgreSQL"
            Write-Host "3 Entorno MySQL + MongoDB + Redis"
            $t=Read-Host "Seleccion"
            ModoPractica $t
        }
        "6"{DetectarEntornosWeb; pause}
        "7"{AyudaServicios}
        "8"{DiagnosticoCompleto}
        "9"{ResetearPasswordRoot}
		"10"{
            if ($lista.Count -eq 0) { 
                Write-Host "No hay bases de datos detectadas." -ForegroundColor Yellow
                pause; continue 
            }
            $n = Read-Host "Indica el numero de la base de datos ACTIVA para intentar abrir su terminal"
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $lista.Count) {
                $item = $lista[[int]$n-1]
                if ($item.Estado -ne "Running") {
                    Write-Host "¡Error! La base de datos debe estar ACTIVA." -ForegroundColor Red
                } else {
                    AbrirTerminalDB $item
                }
            } else {
                Write-Host "Opción inválida." -ForegroundColor Red
            }
            pause
        }
        "11"{
            if ($lista.Count -eq 0) {
                Write-Host "No hay bases de datos detectadas." -ForegroundColor Yellow
                pause; continue
            }
            $n = Read-Host "Indica el numero del servidor a comprobar"
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $lista.Count) {
                $item = $lista[[int]$n-1]
                $svcName = $null
                if ($item.TipoGestion -eq "Servicio" -and $item.Servicio) { $svcName = $item.Servicio.Name }
                Comprobar-SaludDetallada $item.Nombre $item.Puerto $svcName
            } else {
                Write-Host "Opcion invalida." -ForegroundColor Red
                pause
            }
        }
        "12"{ Gestionar-Contenedores }
        "13"{ Exportar-Diagnostico ""; pause }
        "14"{ Gestionar-Compose }
        "0"{break menuLoop}
        default { Write-Host "Opcion no valida." -ForegroundColor Red; Start-Sleep 1 }
    }
}