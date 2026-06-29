[🏠 Documentación](README.md) › **Interfaz gráfica (GUI)**

# Interfaz gráfica (GUI)

<img width="897" height="639" alt="GUI-las-bases-y-sus-datos" src="https://github.com/user-attachments/assets/14155335-88dd-4408-be1e-293dd72a6f32" />

La carpeta `gui/` contiene una interfaz gráfica opcional construida con **PySide6** (Qt 6, licencia LGPL). Es un **cliente ligero**: no gestiona servicios, procesos ni puertos por su cuenta, sino que **invoca a los scripts en modo CLI y consume su salida JSON**. Toda la lógica sigue viviendo en `gestor_bbdd.sh` / `gestor_bbdd.ps1`.

---

## Instalación y arranque

```bash
pip install -r requirements.txt      # instala PySide6
python lanzar.py --gui               # arranca la interfaz grafica
```

En Linux, el estado se consulta sin privilegios; las acciones que modifican servicios (iniciar/detener/reiniciar, contenedores, compose) se elevan automáticamente con `pkexec` o `sudo`. En Windows conviene arrancar la GUI como administrador para poder gestionar servicios.

---

## Arquitectura

La pieza central es la clase `Backend` (`gui/backend.py`), la **única** que conoce el sistema operativo:

```python
class Backend:
    def status(self): ...        # bash gestor_bbdd.sh --json --status  /  -Json -Status
    def start(self, motor): ...  # --start <motor>  /  -Start <motor>
    def stop(self, motor): ...
    def restart(self, motor): ...
```

El resto de la aplicación (ventana, modelos, diálogos) trabaja contra esta fachada y es totalmente transparente al SO. Si en el futuro cambia la implementación interna o se añade otra plataforma, la interfaz no necesita modificarse.

Cada operación se ejecuta en un hilo del `QThreadPool` (`gui/worker.py`), de modo que la ventana nunca se congela mientras un servicio arranca o se detiene.

### Archivos de la GUI

```text
gui/
├── __init__.py
├── backend.py     # Fachada agnóstica del SO: ejecuta los scripts y parsea JSON
├── worker.py      # Ejecución asíncrona (QThreadPool) para no bloquear la UI
├── dbmodel.py     # Modelos de tabla (servidores y contenedores)
├── dialogs.py     # Diálogos auxiliares (Acerca de, visor de texto)
├── mainwindow.py  # Ventana con pestañas
└── main.py        # Punto de entrada de la app Qt
```

---

## Pestañas

- **Servidores**: tabla con motor, estado (● activo / ○ detenido coloreado), puerto, RAM y salud; botones Iniciar / Detener / Reiniciar / Comprobar salud / Abrir terminal. Se autorrefresca cada pocos segundos.
- **Contenedores**: contenedores Docker/Podman de BD detectados, con acciones start/stop/restart.
- **Compose**: proyectos Docker Compose detectados, con `up` / `down`.
- **Diagnóstico**: genera el informe completo y permite exportarlo a archivo.
- **Herramientas**: ver puertos abiertos, detectar entornos locales, ayuda para configurar servicios en modo manual y reseteo de contraseña root (este último abre una terminal del sistema por ser interactivo y privilegiado).
- **Consola**: ejecuta cualquier opción CLI (`--status`, `--health mysql`, `--containers`, …) y muestra la salida en bruto; incluye un botón para ver la ayuda (`--help`).
- **Configuración**: editor de `gestor_bbdd.conf` (carga la plantilla `.example` si aún no existe).
- **Logs**: muestra el final del archivo de log si `LOG_FILE` está configurado.

Prácticamente todas las opciones disponibles desde la terminal están accesibles desde la GUI: las acciones del [modo CLI](cli.md) a través de las pestañas correspondientes, y las opciones que antes solo existían en el menú interactivo (puertos, detección de entornos, ayuda de servicios, reseteo de contraseña y apertura de terminal de cliente) mediante nuevos flags CLI (`--ports`, `--detect`, `--help-services`, `--reset-password`, `--open-terminal`).

La GUI rellena la tabla directamente desde el JSON, sin interpretar texto:

| Motor | Estado | Puerto | RAM | Salud |
|-------|--------|--------|-----|-------|
| MySQL | ● Activo | 3306 | 240 MB | OK |
| Redis | ○ Detenido | 6379 | — | — |

> Nota: los indicadores de estado usan caracteres Unicode y los iconos estándar de Qt, por lo que no se incluye un `resources.qrc` con imágenes binarias.

---

[🏠 Índice](README.md) · [⬅ Anterior: Modo CLI](cli.md) · [Siguiente: Comprobaciones de salud ➡](salud.md)
