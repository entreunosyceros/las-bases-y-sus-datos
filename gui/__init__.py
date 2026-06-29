"""Capa de interfaz grafica (PySide6) para el Gestor de Bases de Datos.

La GUI es un cliente "ligero": NO gestiona servicios, procesos ni puertos.
Toda la logica vive en los scripts `gestor_bbdd.sh` / `gestor_bbdd.ps1` y la
interfaz se limita a invocarlos y a consumir su salida JSON (ver `backend.py`).
"""

__all__ = ["backend", "worker", "dbmodel", "dialogs", "mainwindow"]
