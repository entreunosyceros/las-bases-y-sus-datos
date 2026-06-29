#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Backend agnostico del sistema operativo para la GUI.

Esta clase es la UNICA pieza que sabe si estamos en Windows o Linux. El resto
de la aplicacion (ventana, modelos, dialogos) trabaja contra esta interfaz y no
necesita conocer el sistema operativo ni los detalles de los scripts.

Funcionamiento:
  - Localiza `gestor_bbdd.sh` (Linux) o `gestor_bbdd.ps1` (Windows).
  - Ejecuta el script en modo CLI con `--json` y parsea la salida.
  - Las acciones que modifican el estado (start/stop/restart/compose/contenedores)
    se elevan con `pkexec` o `sudo` en Linux si el proceso no es root.

No importa PySide6 a proposito: asi puede probarse de forma aislada.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shlex
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

# Secuencias de escape ANSI (colores) que los scripts usan para la salida del
# menu; se eliminan al mostrar texto en la GUI.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# Flags que modifican el estado del sistema (se elevan en Linux sin root).
_FLAGS_MUTADORES = {
    "--start", "--stop", "--restart",
    "--container-start", "--container-stop", "--container-restart",
    "--compose-up", "--compose-down", "--reset-password",
    "-start", "-stop", "-restart",
    "-containerstart", "-containerstop", "-containerrestart",
    "-composeup", "-composedown", "-resetpassword",
}


class BackendError(Exception):
    """Error al invocar o interpretar la respuesta de los scripts."""


@dataclass
class CommandResult:
    """Resultado de una invocacion a los scripts."""

    ok: bool
    returncode: int
    stdout: str
    stderr: str
    data: Any = None

    @property
    def mensaje_error(self) -> str:
        """Texto de error mas util disponible (stderr o stdout)."""
        return (self.stderr or "").strip() or (self.stdout or "").strip()


def es_windows() -> bool:
    sistema = platform.system()
    return sistema == "Windows" or sistema.startswith("CYGWIN") or sistema.startswith("MINGW")


def es_linux() -> bool:
    return platform.system() == "Linux"


class Backend:
    """Fachada para los scripts de gestion de bases de datos."""

    def __init__(self, project_root: Optional[Path] = None, timeout: int = 90) -> None:
        self.root = Path(project_root) if project_root else Path(__file__).resolve().parent.parent
        self.script_sh = self.root / "gestor_bbdd.sh"
        self.script_ps1 = self.root / "gestor_bbdd.ps1"
        self.windows = es_windows()
        self.timeout = timeout

    # ------------------------------------------------------------------
    # Rutas auxiliares
    # ------------------------------------------------------------------
    @property
    def conf_path(self) -> Path:
        return self.root / "gestor_bbdd.conf"

    @property
    def conf_example_path(self) -> Path:
        return self.root / "gestor_bbdd.conf.example"

    def script_disponible(self) -> bool:
        return self.script_ps1.exists() if self.windows else self.script_sh.exists()

    def es_root(self) -> bool:
        if self.windows:
            return True  # la elevacion en Windows se gestiona al lanzar la app
        try:
            return os.geteuid() == 0
        except AttributeError:
            return False

    # ------------------------------------------------------------------
    # Construccion de comandos
    # ------------------------------------------------------------------
    def _base_cmd(self) -> list[str]:
        if self.windows:
            return [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(self.script_ps1),
            ]
        return ["bash", str(self.script_sh)]

    def _f(self, linux: list[str], win: list[str]) -> list[str]:
        """Devuelve los flags apropiados segun el sistema operativo."""
        return win if self.windows else linux

    def _maybe_elevate(self, cmd: list[str]) -> list[str]:
        """Antepone pkexec/sudo para acciones privilegiadas en Linux."""
        if self.windows or self.es_root():
            return cmd
        if shutil.which("pkexec"):
            return ["pkexec"] + cmd
        if shutil.which("sudo"):
            return ["sudo"] + cmd
        return cmd

    # ------------------------------------------------------------------
    # Ejecucion
    # ------------------------------------------------------------------
    def _run(self, args: list[str], elevate: bool = False) -> CommandResult:
        if not self.script_disponible():
            destino = self.script_ps1 if self.windows else self.script_sh
            raise BackendError(f"No se encontro el script: {destino}")

        cmd = self._base_cmd() + list(args)
        if elevate:
            cmd = self._maybe_elevate(cmd)

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise BackendError(
                f"Tiempo de espera agotado ({self.timeout}s) ejecutando: {' '.join(args)}"
            ) from exc
        except FileNotFoundError as exc:
            interprete = cmd[0]
            raise BackendError(
                f"No se encontro el interprete '{interprete}'. "
                "Asegurate de tener bash (Linux) o PowerShell (Windows)."
            ) from exc

        return CommandResult(
            ok=(proc.returncode == 0),
            returncode=proc.returncode,
            stdout=proc.stdout or "",
            stderr=proc.stderr or "",
        )

    def _run_json(self, args: list[str], elevate: bool = False) -> CommandResult:
        result = self._run(args, elevate=elevate)
        texto = (result.stdout or "").strip()
        if not texto:
            raise BackendError(result.mensaje_error or "El script no devolvio ninguna salida.")
        result.data = self._parse_json(texto)
        return result

    @staticmethod
    def _parse_json(texto: str) -> Any:
        try:
            return json.loads(texto)
        except json.JSONDecodeError:
            pass
        # Tolerancia: extraer el primer bloque JSON {...} o [...] de la salida.
        for apertura, cierre in (("{", "}"), ("[", "]")):
            inicio = texto.find(apertura)
            fin = texto.rfind(cierre)
            if inicio != -1 and fin != -1 and fin > inicio:
                try:
                    return json.loads(texto[inicio : fin + 1])
                except json.JSONDecodeError:
                    continue
        raise BackendError("La respuesta del script no es JSON valido:\n" + texto[:500])

    # ------------------------------------------------------------------
    # Operaciones de solo lectura (devuelven JSON)
    # ------------------------------------------------------------------
    def status(self) -> CommandResult:
        return self._run_json(self._f(["--json", "--status"], ["-Json", "-Status"]))

    def health(self, motor: str) -> CommandResult:
        return self._run_json(self._f(["--json", "--health", motor], ["-Json", "-Health", motor]))

    def containers(self) -> CommandResult:
        return self._run_json(self._f(["--json", "--containers"], ["-Json", "-Containers"]))

    def compose_list(self) -> CommandResult:
        return self._run_json(self._f(["--json", "--compose-list"], ["-Json", "-ComposeList"]))

    # ------------------------------------------------------------------
    # Acciones (modifican estado -> elevadas en Linux)
    # ------------------------------------------------------------------
    def start(self, motor: str) -> CommandResult:
        return self._run(self._f(["--start", motor], ["-Start", motor]), elevate=True)

    def stop(self, motor: str) -> CommandResult:
        return self._run(self._f(["--stop", motor], ["-Stop", motor]), elevate=True)

    def restart(self, motor: str) -> CommandResult:
        return self._run(self._f(["--restart", motor], ["-Restart", motor]), elevate=True)

    def container_action(self, accion: str, nombre: str) -> CommandResult:
        mapa = {
            "start": (["--container-start", nombre], ["-ContainerStart", nombre]),
            "stop": (["--container-stop", nombre], ["-ContainerStop", nombre]),
            "restart": (["--container-restart", nombre], ["-ContainerRestart", nombre]),
        }
        if accion not in mapa:
            raise BackendError(f"Accion de contenedor no valida: {accion}")
        linux, win = mapa[accion]
        return self._run(self._f(linux, win), elevate=True)

    def compose_up(self, ruta: str) -> CommandResult:
        return self._run(self._f(["--compose-up", ruta], ["-ComposeUp", ruta]), elevate=True)

    def compose_down(self, ruta: str) -> CommandResult:
        return self._run(self._f(["--compose-down", ruta], ["-ComposeDown", ruta]), elevate=True)

    def diagnose_text(self) -> CommandResult:
        return self._run_text(self._f(["--diagnose"], ["-Diagnose"]))

    def export(self, ruta: str) -> CommandResult:
        return self._run(self._f(["--export", ruta], ["-Export", ruta]))

    # ------------------------------------------------------------------
    # Opciones del menu expuestas como CLI (salida de texto)
    # ------------------------------------------------------------------
    @staticmethod
    def _strip_ansi(texto: str) -> str:
        return _ANSI_RE.sub("", texto or "")

    def _run_text(self, args: list[str], elevate: bool = False) -> CommandResult:
        """Como _run pero limpia codigos ANSI del stdout (salida legible)."""
        result = self._run(args, elevate=elevate)
        result.stdout = self._strip_ansi(result.stdout)
        result.stderr = self._strip_ansi(result.stderr)
        return result

    def ayuda(self) -> CommandResult:
        return self._run_text(self._f(["--help"], ["-Help"]))

    def ports(self) -> CommandResult:
        return self._run_text(self._f(["--ports"], ["-Ports"]))

    def detect(self) -> CommandResult:
        return self._run_text(self._f(["--detect"], ["-Detect"]))

    def help_services(self) -> CommandResult:
        return self._run_text(self._f(["--help-services"], ["-HelpServices"]))

    def open_terminal(self, nombre: str) -> CommandResult:
        return self._run(self._f(["--open-terminal", nombre], ["-OpenTerminal", nombre]))

    def run_raw(self, linea: str) -> CommandResult:
        """Ejecuta una linea de flags CLI arbitraria (pestana Consola)."""
        try:
            args = shlex.split(linea)
        except ValueError as exc:
            raise BackendError(f"Linea de comando no valida: {exc}") from exc
        if not args:
            raise BackendError("Escribe una opcion CLI (por ejemplo: --status).")
        elevate = any(a.lower() in _FLAGS_MUTADORES for a in args)
        return self._run_text(args, elevate=elevate)

    # ------------------------------------------------------------------
    # Acciones interactivas: se lanzan en una terminal del sistema
    # ------------------------------------------------------------------
    def _terminal_emulador(self) -> Optional[list[str]]:
        """Devuelve [terminal, flag_exec] para lanzar un comando en Linux."""
        candidatos = [
            ("x-terminal-emulator", "-e"),
            ("gnome-terminal", "--"),
            ("konsole", "-e"),
            ("xfce4-terminal", "-e"),
            ("mate-terminal", "-e"),
            ("terminator", "-e"),
            ("alacritty", "-e"),
            ("xterm", "-e"),
        ]
        for term, flag in candidatos:
            if shutil.which(term):
                return [term, flag]
        return None

    def launch_reset_password(self) -> None:
        """Abre una terminal del sistema con el reseteo de contrasena root.

        Es interactivo (pide la nueva contrasena) y requiere privilegios, por lo
        que debe ejecutarse en una terminal real, no capturado por la GUI.
        """
        if self.windows:
            ps_args = (
                "Start-Process powershell -Verb RunAs -ArgumentList "
                "'-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',"
                f"'{self.script_ps1}','-ResetPassword'"
            )
            subprocess.Popen(["powershell", "-NoProfile", "-Command", ps_args])
            return

        emulador = self._terminal_emulador()
        if emulador is None:
            raise BackendError(
                "No se encontro un emulador de terminal para lanzar el reseteo. "
                "Ejecuta manualmente: sudo bash gestor_bbdd.sh --reset-password"
            )
        prefijo = "sudo " if not self.es_root() and shutil.which("sudo") else ""
        inner = (
            f'{prefijo}bash "{self.script_sh}" --reset-password; '
            'echo; read -p "Pulsa ENTER para cerrar esta ventana..."'
        )
        term, flag = emulador
        try:
            subprocess.Popen([term, flag, "bash", "-c", inner])
        except OSError as exc:
            raise BackendError(f"No se pudo abrir la terminal: {exc}") from exc

    # ------------------------------------------------------------------
    # Helpers de alto nivel para la GUI
    # ------------------------------------------------------------------
    @staticmethod
    def _normalizar_fila(item: dict) -> dict:
        estado = str(item.get("estado", "")).lower()
        activo = estado in ("active", "running")
        puerto = item.get("puerto", 0) or 0
        ram = item.get("ram_mb", 0) or 0
        return {
            "nombre": item.get("nombre", ""),
            "tipo": item.get("tipo", ""),
            "activo": activo,
            "estado": item.get("estado", ""),
            "puerto": int(puerto) if str(puerto).isdigit() else puerto,
            "ram_mb": int(ram) if str(ram).isdigit() else ram,
            "salud": item.get("salud", ""),
        }

    def fetch_servers(self) -> tuple[list[dict], dict]:
        """Devuelve (filas_normalizadas, datos_crudos) para el modelo de tabla."""
        data = self.status().data or {}
        filas: list[dict] = []
        for grupo in ("servidores", "entornos"):
            for item in data.get(grupo, []) or []:
                filas.append(self._normalizar_fila(item))
        return filas, data

    def fetch_containers(self) -> list[dict]:
        data = self.containers().data or {}
        return list(data.get("contenedores", []) or [])

    def fetch_compose_projects(self) -> list[str]:
        data = self.compose_list().data or {}
        return list(data.get("proyectos", []) or [])

    # ------------------------------------------------------------------
    # Configuracion persistente y logs (lectura/escritura de archivos)
    # ------------------------------------------------------------------
    def localizar_config_activa(self) -> Optional[Path]:
        """Localiza el gestor_bbdd.conf REAL con el mismo orden que los scripts.

        Linux:   $GESTOR_BD_CONF -> <proyecto>/gestor_bbdd.conf -> ~/.config/gestor_bbdd.conf
        Windows: $GESTOR_BD_CONF -> <proyecto>/gestor_bbdd.conf -> %APPDATA%/gestor_bbdd.conf
        """
        env = os.environ.get("GESTOR_BD_CONF")
        if env and Path(env).is_file():
            return Path(env)
        if self.conf_path.is_file():
            return self.conf_path
        if self.windows:
            appdata = os.environ.get("APPDATA")
            if appdata:
                candidato = Path(appdata) / "gestor_bbdd.conf"
                if candidato.is_file():
                    return candidato
        else:
            xdg = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
            candidato = Path(xdg) / "gestor_bbdd.conf"
            if candidato.is_file():
                return candidato
        return None

    def config_origen(self) -> Optional[Path]:
        """Origen para el EDITOR: config activa real o, si no hay, la plantilla."""
        activa = self.localizar_config_activa()
        if activa is not None:
            return activa
        if self.conf_example_path.exists():
            return self.conf_example_path
        return None

    def read_config(self) -> str:
        origen = self.config_origen()
        if origen is None:
            return ""
        try:
            return origen.read_text(encoding="utf-8")
        except OSError as exc:
            raise BackendError(f"No se pudo leer la configuracion: {exc}") from exc

    def write_config(self, texto: str) -> None:
        try:
            self.conf_path.write_text(texto, encoding="utf-8")
        except OSError as exc:
            raise BackendError(f"No se pudo guardar la configuracion: {exc}") from exc

    def _texto_config_activa(self) -> str:
        """Texto de la config REAL (sin caer en la plantilla .example)."""
        activa = self.localizar_config_activa()
        if activa is None:
            return ""
        try:
            return activa.read_text(encoding="utf-8")
        except OSError:
            return ""

    def _config_valor(self, clave: str) -> Optional[str]:
        for linea in self._texto_config_activa().splitlines():
            linea = linea.strip()
            if not linea or linea.startswith("#"):
                continue
            if "=" in linea:
                k, _, v = linea.partition("=")
                if k.strip() == clave:
                    # Quita comentarios en linea y comillas alrededor del valor.
                    valor = v.split("#", 1)[0].strip().strip('"').strip("'")
                    return valor
        return None

    @staticmethod
    def _es_verdadero(valor: Optional[str]) -> bool:
        return (valor or "").strip().lower() in ("true", "1", "yes", "si", "sí")

    def log_enabled(self) -> bool:
        env = os.environ.get("GESTOR_BD_LOG_ENABLED")
        if env is not None:
            return self._es_verdadero(env)
        return self._es_verdadero(self._config_valor("LOG_ENABLED"))

    def log_file_path(self) -> Optional[Path]:
        env = os.environ.get("GESTOR_BD_LOG_FILE")
        if env:
            return Path(env)
        valor = self._config_valor("LOG_FILE")
        if not valor:
            return None
        return Path(valor)

    def read_log(self, max_lines: int = 500) -> str:
        ruta = self.log_file_path()
        if ruta is None:
            return ""
        if not ruta.exists():
            raise BackendError(f"El archivo de log no existe todavia: {ruta}")
        try:
            lineas = ruta.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            raise BackendError(f"No se pudo leer el log: {exc}") from exc
        return "\n".join(lineas[-max_lines:])


if __name__ == "__main__":
    # Smoke test sin GUI: imprime el estado en JSON legible.
    b = Backend()
    print(f"SO: {'Windows' if b.windows else 'Linux'} | root: {b.es_root()}")
    print(f"Script: {b.script_ps1 if b.windows else b.script_sh}")
    filas, datos = b.fetch_servers()
    print(f"init_system: {datos.get('init_system')}")
    for fila in filas:
        print(fila)
