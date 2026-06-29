#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Ejecucion asincrona de tareas del backend.

Las llamadas al backend invocan a `subprocess` y pueden tardar (especialmente
arrancar/parar servicios). Para que la ventana no se congele, cada operacion se
ejecuta en un hilo del `QThreadPool` y comunica el resultado mediante senales.

IMPORTANTE: el Worker NO debe auto-eliminarse (autoDelete=False). Si QThreadPool
destruye el QRunnable al terminar run() antes de que el event loop procese la
senal finished, la GUI puede crashear con SIGSEGV al actualizar widgets.
"""

from __future__ import annotations

from typing import Any, Callable

from PySide6.QtCore import QObject, QRunnable, Signal, Slot
from PySide6.QtWidgets import QApplication


class WorkerSignals(QObject):
    """Senales emitidas por un Worker."""

    finished = Signal(object)  # resultado de la funcion
    error = Signal(str)        # mensaje de error


class Worker(QRunnable):
    """Ejecuta `fn(*args, **kwargs)` en un hilo del pool."""

    def __init__(self, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> None:
        super().__init__()
        self.setAutoDelete(False)
        self.fn = fn
        self.args = args
        self.kwargs = kwargs
        self.signals = WorkerSignals()
        # Asegura que las senales se despachen al hilo principal de la GUI.
        app = QApplication.instance()
        if app is not None:
            self.signals.moveToThread(app.thread())

    @Slot()
    def run(self) -> None:
        try:
            resultado = self.fn(*self.args, **self.kwargs)
        except Exception as exc:  # noqa: BLE001 - cualquier error se reporta a la UI
            self.signals.error.emit(str(exc))
        else:
            self.signals.finished.emit(resultado)
