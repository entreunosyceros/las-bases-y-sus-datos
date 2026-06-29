#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dialogos auxiliares de la GUI."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QDesktopServices, QPixmap
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QLabel,
    QPlainTextEdit,
    QVBoxLayout,
)

URL_PROYECTO = "https://github.com/entreunosyceros/las-bases-y-sus-datos"


class LongTextDialog(QDialog):
    """Muestra texto largo (p. ej. un diagnostico) en un visor con scroll."""

    def __init__(self, titulo: str, texto: str, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle(titulo)
        self.resize(720, 520)

        layout = QVBoxLayout(self)
        visor = QPlainTextEdit()
        visor.setReadOnly(True)
        visor.setPlainText(texto)
        visor.setLineWrapMode(QPlainTextEdit.NoWrap)
        layout.addWidget(visor)

        botones = QDialogButtonBox(QDialogButtonBox.Close)
        botones.rejected.connect(self.reject)
        botones.accepted.connect(self.accept)
        layout.addWidget(botones)


class AboutDialog(QDialog):
    """Dialogo 'Acerca de'."""

    ANCHO_LOGO = 360

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Acerca de")
        self.setMinimumWidth(460)
        self.setMinimumHeight(520)

        layout = QVBoxLayout(self)

        # Logo (centrado y escalado a un tamano adecuado).
        logo = QLabel()
        logo.setAlignment(Qt.AlignCenter)
        ruta_logo = Path(__file__).resolve().parent / "img" / "logo.png"
        pixmap = QPixmap(str(ruta_logo))
        if not pixmap.isNull():
            pixmap = pixmap.scaledToWidth(self.ANCHO_LOGO, Qt.SmoothTransformation)
            logo.setPixmap(pixmap)
        layout.addWidget(logo)

        texto = (
            "<h3>Gestor de Bases de Datos</h3>"
            "<p>Interfaz grafica (PySide6) sobre los scripts "
            "<code>gestor_bbdd.sh</code> y <code>gestor_bbdd.ps1</code>.</p>"
            "<p>La GUI no gestiona servicios directamente: delega toda la logica "
            "en los scripts y consume su salida JSON.</p>"
            "<p>Autor: entreunosyceros.net &middot; Licencia MIT</p>"
        )
        etiqueta = QLabel(texto)
        etiqueta.setTextFormat(Qt.RichText)
        etiqueta.setWordWrap(True)
        etiqueta.setOpenExternalLinks(True)
        etiqueta.setAlignment(Qt.AlignCenter)
        layout.addWidget(etiqueta)

        layout.addStretch(1)

        botones = QDialogButtonBox(QDialogButtonBox.Ok)
        boton_github = botones.addButton("Ver en GitHub", QDialogButtonBox.ActionRole)
        boton_github.clicked.connect(self._abrir_github)
        botones.accepted.connect(self.accept)
        layout.addWidget(botones)

    @staticmethod
    def _abrir_github() -> None:
        QDesktopServices.openUrl(QUrl(URL_PROYECTO))
