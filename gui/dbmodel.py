#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Modelos de tabla para la GUI.

Los modelos solo consumen los datos ya normalizados por `Backend`; no conocen
los scripts ni el sistema operativo. Pintan un indicador de estado coloreado y
formatean puerto / RAM / salud para su lectura.
"""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import QAbstractTableModel, QModelIndex, Qt
from PySide6.QtGui import QColor

VERDE = QColor(46, 160, 67)
ROJO = QColor(207, 34, 46)
AMBAR = QColor(191, 135, 0)
GRIS = QColor(110, 118, 129)


class ServerTableModel(QAbstractTableModel):
    """Tabla de servidores de BD (servicios + entornos locales)."""

    COLUMNAS = ["Motor", "Estado", "Puerto", "RAM", "Salud", "Tipo"]

    def __init__(self, filas: list[dict] | None = None) -> None:
        super().__init__()
        self._filas: list[dict] = filas or []

    # -- API Qt --------------------------------------------------------
    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:  # noqa: N802
        return 0 if parent.isValid() else len(self._filas)

    def columnCount(self, parent: QModelIndex = QModelIndex()) -> int:  # noqa: N802
        return 0 if parent.isValid() else len(self.COLUMNAS)

    def headerData(self, section: int, orientation: Qt.Orientation, role: int = Qt.DisplayRole):  # noqa: N802
        if role == Qt.DisplayRole and orientation == Qt.Horizontal:
            return self.COLUMNAS[section]
        return None

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole) -> Any:
        if not index.isValid():
            return None
        fila = self._filas[index.row()]
        col = index.column()
        activo = fila.get("activo", False)

        if role == Qt.DisplayRole:
            if col == 0:
                return fila.get("nombre", "")
            if col == 1:
                return "\u25cf  Activo" if activo else "\u25cb  Detenido"
            if col == 2:
                puerto = fila.get("puerto", 0)
                return str(puerto) if puerto else "\u2014"
            if col == 3:
                ram = fila.get("ram_mb", 0)
                return f"{ram} MB" if (activo and ram) else "\u2014"
            if col == 4:
                return self._texto_salud(fila.get("salud", ""), activo)
            if col == 5:
                return fila.get("tipo", "")

        if role == Qt.ForegroundRole:
            if col == 1:
                return VERDE if activo else ROJO
            if col == 4:
                return self._color_salud(fila.get("salud", ""), activo)

        if role == Qt.TextAlignmentRole and col in (2, 3):
            return int(Qt.AlignRight | Qt.AlignVCenter)

        return None

    # -- Helpers -------------------------------------------------------
    @staticmethod
    def _texto_salud(salud: str, activo: bool) -> str:
        if not activo:
            return "\u2014"
        mapa = {"OK": "OK", "NORESP": "sin respuesta", "NOCLI": "sin cliente"}
        return mapa.get(salud, salud or "\u2014")

    @staticmethod
    def _color_salud(salud: str, activo: bool) -> QColor:
        if not activo:
            return GRIS
        return {"OK": VERDE, "NORESP": AMBAR, "NOCLI": GRIS}.get(salud, GRIS)

    def update(self, filas: list[dict]) -> None:
        self.beginResetModel()
        self._filas = filas or []
        self.endResetModel()

    def server_at(self, row: int) -> dict | None:
        if 0 <= row < len(self._filas):
            return self._filas[row]
        return None


class ContainerTableModel(QAbstractTableModel):
    """Tabla de contenedores Docker/Podman de BD."""

    COLUMNAS = ["Motor", "Nombre", "Imagen", "Estado", "Puertos"]
    CLAVES = ["motor", "nombre", "imagen", "estado", "puertos"]

    def __init__(self, filas: list[dict] | None = None) -> None:
        super().__init__()
        self._filas: list[dict] = filas or []

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:  # noqa: N802
        return 0 if parent.isValid() else len(self._filas)

    def columnCount(self, parent: QModelIndex = QModelIndex()) -> int:  # noqa: N802
        return 0 if parent.isValid() else len(self.COLUMNAS)

    def headerData(self, section: int, orientation: Qt.Orientation, role: int = Qt.DisplayRole):  # noqa: N802
        if role == Qt.DisplayRole and orientation == Qt.Horizontal:
            return self.COLUMNAS[section]
        return None

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole) -> Any:
        if not index.isValid():
            return None
        if role == Qt.DisplayRole:
            fila = self._filas[index.row()]
            return str(fila.get(self.CLAVES[index.column()], ""))
        if role == Qt.ForegroundRole and index.column() == 3:
            estado = str(self._filas[index.row()].get("estado", "")).lower()
            return VERDE if estado.startswith("up") else GRIS
        return None

    def update(self, filas: list[dict]) -> None:
        self.beginResetModel()
        self._filas = filas or []
        self.endResetModel()

    def container_at(self, row: int) -> dict | None:
        if 0 <= row < len(self._filas):
            return self._filas[row]
        return None
