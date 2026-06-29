#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Lanzador multiplataforma para el Gestor de Bases de Datos.

Detecta el sistema operativo sobre el que se ejecuta y lanza:
  - Windows : gestor_bbdd.bat
  - Linux   : gestor_bbdd.sh (solicitando permisos de root si es necesario)

Uso:
  python lanzar.py            # menu interactivo (script nativo)
  python lanzar.py --gui      # interfaz grafica (PySide6)
  python3 lanzar.py

En Linux tambien se puede ejecutar directamente si tiene permisos de ejecucion:
  ./lanzar.py
"""

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


def es_windows():
    """Devuelve True si el sistema operativo es Windows."""
    sistema = platform.system()
    return sistema == "Windows" or sistema.startswith("CYGWIN") or sistema.startswith("MINGW")


def es_linux():
    """Devuelve True si el sistema operativo es Linux."""
    return platform.system() == "Linux"


def ruta_script(base_dir, nombre):
    """Devuelve la ruta absoluta de un archivo dentro de la carpeta del proyecto."""
    return base_dir / nombre


def lanzar_windows(base_dir):
    """Ejecuta el lanzador de Windows (gestor_bbdd.bat)."""
    bat = ruta_script(base_dir, "gestor_bbdd.bat")
    if not bat.exists():
        print(f"[ERROR] No se encontro el lanzador de Windows: {bat}")
        sys.exit(1)

    print(f"[INFO] Sistema operativo detectado: Windows")
    print(f"[INFO] Ejecutando {bat.name} ...")

    # startfile abre el .bat con el programa predeterminado del sistema.
    try:
        os.startfile(str(bat))
    except AttributeError:
        # os.startfile no esta disponible en todas las variantes de Python/Windows
        subprocess.run([str(bat)], shell=True, check=False)


def lanzar_linux(base_dir):
    """Ejecuta el lanzador de Linux (gestor_bbdd.sh) solicitando root si es necesario."""
    sh = ruta_script(base_dir, "gestor_bbdd.sh")
    if not sh.exists():
        print(f"[ERROR] No se encontro el lanzador de Linux: {sh}")
        sys.exit(1)

    print(f"[INFO] Sistema operativo detectado: Linux")

    # Si ya somos root, ejecutamos directamente
    if os.geteuid() == 0:
        print(f"[INFO] Ejecutando {sh.name} ...")
        subprocess.run(["bash", str(sh)], check=False)
        return

    # Si no somos root, intentamos elevar privilegios
    print("[AVISO] Se necesitan permisos de root para gestionar servicios.")

    if shutil.which("sudo"):
        print(f"[INFO] Relanzando con sudo: sudo bash {sh.name}")
        subprocess.run(["sudo", "bash", str(sh)], check=False)
    elif shutil.which("pkexec"):
        print(f"[INFO] Relanzando con pkexec: pkexec bash {sh.name}")
        subprocess.run(["pkexec", "bash", str(sh)], check=False)
    else:
        print("[ERROR] No se encontro 'sudo' ni 'pkexec'.")
        print(f"[INFO] Ejecuta manualmente: sudo bash {sh}")
        sys.exit(1)


def lanzar_gui(base_dir):
    """Lanza la interfaz grafica (PySide6)."""
    sys.path.insert(0, str(base_dir))
    try:
        from gui.main import main as gui_main
    except ImportError as exc:
        print("[ERROR] No se pudo cargar la interfaz grafica.")
        if "PySide6" in str(exc):
            print("[INFO] Falta PySide6. Instalalo con:")
            print("       pip install -r requirements.txt")
            print("   o:  pip install PySide6")
        else:
            print(f"[ERROR] {exc}")
        sys.exit(1)

    print("[INFO] Iniciando interfaz grafica ...")
    sys.exit(gui_main())


def main():
    # Carpeta donde se encuentra este lanzador
    base_dir = Path(__file__).resolve().parent

    if "--gui" in sys.argv[1:] or "-g" in sys.argv[1:]:
        lanzar_gui(base_dir)
        return

    if es_windows():
        lanzar_windows(base_dir)
    elif es_linux():
        lanzar_linux(base_dir)
    else:
        print(f"[ERROR] Sistema operativo no soportado: {platform.system()}")
        print("[INFO] Este lanzador funciona en Windows y Linux.")
        sys.exit(1)


if __name__ == "__main__":
    main()
