#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Punto de entrada de la interfaz grafica.

Se puede ejecutar de dos formas:
  - Como modulo:   python -m gui.main
  - Directamente:  python gui/main.py
  - Desde lanzar:  python lanzar.py --gui
"""

from __future__ import annotations

import os
import sys

# Permite ejecutar el archivo directamente (python gui/main.py) asegurando que
# la raiz del proyecto este en sys.path para los imports absolutos `gui.*`.
if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main() -> int:
    from PySide6.QtWidgets import QApplication

    from gui.backend import Backend
    from gui.mainwindow import MainWindow

    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName("Gestor de Bases de Datos")

    backend = Backend()
    if not backend.script_disponible():
        from PySide6.QtWidgets import QMessageBox

        destino = backend.script_ps1 if backend.windows else backend.script_sh
        QMessageBox.critical(None, "Error", f"No se encontro el script de gestion:\n{destino}")
        return 1

    ventana = MainWindow(backend)
    ventana.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
