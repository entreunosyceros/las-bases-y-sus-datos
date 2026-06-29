#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Ventana principal de la GUI.

Organiza la aplicacion en pestanas (servidores, contenedores, compose,
diagnostico, configuracion y logs). Toda interaccion con el sistema pasa por el
`Backend` y se ejecuta de forma asincrona mediante `Worker` para no bloquear la
interfaz.
"""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import Qt, QThreadPool, QTimer
from PySide6.QtGui import QKeySequence, QTextCursor
from PySide6.QtWidgets import (
    QAbstractItemView,
    QFileDialog,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QTableView,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from gui.backend import Backend, CommandResult
from gui.dbmodel import ContainerTableModel, ServerTableModel
from gui.dialogs import AboutDialog, LongTextDialog
from gui.worker import Worker

INTERVALO_AUTORREFRESCO_MS = 12000


class MainWindow(QMainWindow):
    def __init__(self, backend: Backend | None = None) -> None:
        super().__init__()
        self.backend = backend or Backend()
        self.pool = QThreadPool.globalInstance()
        self._tareas_activas = 0
        self._workers: list[Worker] = []

        self.setWindowTitle("Gestor de Bases de Datos")
        self.resize(900, 600)

        self.tabs = QTabWidget()
        self.setCentralWidget(self.tabs)

        self._build_tab_servidores()
        self._build_tab_contenedores()
        self._build_tab_compose()
        self._build_tab_diagnostico()
        self._build_tab_herramientas()
        self._build_tab_consola()
        self._build_tab_config()
        self._build_tab_logs()
        self._build_menu()

        self.statusBar().showMessage("Listo.")
        self.init_label = QLabel("")
        self.statusBar().addPermanentWidget(self.init_label)

        if not self.backend.es_root() and not self.backend.windows:
            self.statusBar().showMessage(
                "Aviso: sin privilegios de root; las acciones pediran autenticacion (pkexec/sudo)."
            )

        self.timer = QTimer(self)
        self.timer.setInterval(INTERVALO_AUTORREFRESCO_MS)
        self.timer.timeout.connect(self._autorrefresco)
        self.timer.start()

        # Carga perezosa: contenedores y compose solo se consultan al abrir su
        # pestana por primera vez (evita invocar docker al arrancar).
        self._pestanas_cargadas: set[int] = set()
        self.tabs.currentChanged.connect(self._on_tab_changed)

        # Carga inicial de la pestana visible (Servidores).
        self.refresh_servers()

    # ==================================================================
    # Construccion de pestanas
    # ==================================================================
    def _build_tab_servidores(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        self.server_model = ServerTableModel()
        self.server_table = QTableView()
        self.server_table.setModel(self.server_model)
        self._config_tabla(self.server_table)
        layout.addWidget(self.server_table)

        botones = QHBoxLayout()
        self.btn_iniciar = QPushButton("Iniciar")
        self.btn_detener = QPushButton("Detener")
        self.btn_reiniciar = QPushButton("Reiniciar")
        self.btn_salud = QPushButton("Comprobar salud")
        self.btn_terminal = QPushButton("Abrir terminal")
        self.btn_refrescar = QPushButton("Actualizar")
        self.btn_iniciar.clicked.connect(lambda: self._accion_servidor("start"))
        self.btn_detener.clicked.connect(lambda: self._accion_servidor("stop"))
        self.btn_reiniciar.clicked.connect(lambda: self._accion_servidor("restart"))
        self.btn_salud.clicked.connect(self._comprobar_salud)
        self.btn_terminal.clicked.connect(self._abrir_terminal_servidor)
        self.btn_refrescar.clicked.connect(self.refresh_servers)
        for b in (self.btn_iniciar, self.btn_detener, self.btn_reiniciar, self.btn_salud, self.btn_terminal):
            botones.addWidget(b)
        botones.addStretch(1)
        botones.addWidget(self.btn_refrescar)
        layout.addLayout(botones)

        self._botones_servidor = [
            self.btn_iniciar,
            self.btn_detener,
            self.btn_reiniciar,
            self.btn_salud,
            self.btn_terminal,
            self.btn_refrescar,
        ]
        self.tabs.addTab(widget, "Servidores")

    def _build_tab_contenedores(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        self.cont_model = ContainerTableModel()
        self.cont_table = QTableView()
        self.cont_table.setModel(self.cont_model)
        self._config_tabla(self.cont_table)
        layout.addWidget(self.cont_table)

        botones = QHBoxLayout()
        self.btn_cont_iniciar = QPushButton("Iniciar")
        self.btn_cont_detener = QPushButton("Detener")
        self.btn_cont_reiniciar = QPushButton("Reiniciar")
        self.btn_cont_refrescar = QPushButton("Actualizar")
        self.btn_cont_iniciar.clicked.connect(lambda: self._accion_contenedor("start"))
        self.btn_cont_detener.clicked.connect(lambda: self._accion_contenedor("stop"))
        self.btn_cont_reiniciar.clicked.connect(lambda: self._accion_contenedor("restart"))
        self.btn_cont_refrescar.clicked.connect(self.refresh_containers)
        for b in (self.btn_cont_iniciar, self.btn_cont_detener, self.btn_cont_reiniciar):
            botones.addWidget(b)
        botones.addStretch(1)
        botones.addWidget(self.btn_cont_refrescar)
        layout.addLayout(botones)

        self._botones_contenedor = [
            self.btn_cont_iniciar,
            self.btn_cont_detener,
            self.btn_cont_reiniciar,
            self.btn_cont_refrescar,
        ]
        self.tabs.addTab(widget, "Contenedores")

    def _build_tab_compose(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        layout.addWidget(QLabel("Proyectos Docker Compose con servicios de BD:"))
        self.compose_list = QListWidget()
        layout.addWidget(self.compose_list)

        botones = QHBoxLayout()
        self.btn_compose_up = QPushButton("Levantar (up)")
        self.btn_compose_down = QPushButton("Detener (down)")
        self.btn_compose_refrescar = QPushButton("Actualizar")
        self.btn_compose_up.clicked.connect(lambda: self._accion_compose("up"))
        self.btn_compose_down.clicked.connect(lambda: self._accion_compose("down"))
        self.btn_compose_refrescar.clicked.connect(self.refresh_compose)
        botones.addWidget(self.btn_compose_up)
        botones.addWidget(self.btn_compose_down)
        botones.addStretch(1)
        botones.addWidget(self.btn_compose_refrescar)
        layout.addLayout(botones)

        self._botones_compose = [
            self.btn_compose_up,
            self.btn_compose_down,
            self.btn_compose_refrescar,
        ]
        self.tabs.addTab(widget, "Compose")

    def _build_tab_diagnostico(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        self.diag_text = QPlainTextEdit()
        self.diag_text.setReadOnly(True)
        self.diag_text.setLineWrapMode(QPlainTextEdit.NoWrap)
        layout.addWidget(self.diag_text)

        botones = QHBoxLayout()
        self.btn_diag_generar = QPushButton("Generar diagnostico")
        self.btn_diag_exportar = QPushButton("Exportar a archivo...")
        self.btn_diag_generar.clicked.connect(self._generar_diagnostico)
        self.btn_diag_exportar.clicked.connect(self._exportar_diagnostico)
        botones.addWidget(self.btn_diag_generar)
        botones.addWidget(self.btn_diag_exportar)
        botones.addStretch(1)
        layout.addLayout(botones)

        self._botones_diag = [self.btn_diag_generar, self.btn_diag_exportar]
        self.tabs.addTab(widget, "Diagnostico")

    def _build_tab_herramientas(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        fila = QHBoxLayout()
        self.btn_ports = QPushButton("Ver puertos abiertos")
        self.btn_detect = QPushButton("Detectar entornos")
        self.btn_helpsvc = QPushButton("Ayuda: configurar servicios")
        self.btn_resetpwd = QPushButton("Resetear contrasena root...")
        self.btn_ports.clicked.connect(self._ver_puertos)
        self.btn_detect.clicked.connect(self._detectar_entornos)
        self.btn_helpsvc.clicked.connect(self._ayuda_servicios)
        self.btn_resetpwd.clicked.connect(self._resetear_password)
        for b in (self.btn_ports, self.btn_detect, self.btn_helpsvc):
            fila.addWidget(b)
        fila.addStretch(1)
        fila.addWidget(self.btn_resetpwd)
        layout.addLayout(fila)

        self.herr_text = QPlainTextEdit()
        self.herr_text.setReadOnly(True)
        self.herr_text.setLineWrapMode(QPlainTextEdit.NoWrap)
        layout.addWidget(self.herr_text)

        self._botones_herramientas = [
            self.btn_ports,
            self.btn_detect,
            self.btn_helpsvc,
            self.btn_resetpwd,
        ]
        self.tabs.addTab(widget, "Herramientas")

    def _build_tab_consola(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        layout.addWidget(QLabel(
            "Ejecuta cualquier opcion CLI y observa la salida. Ejemplos: "
            "--status, --health mysql, --containers, --compose-list"
        ))

        self.consola_text = QPlainTextEdit()
        self.consola_text.setReadOnly(True)
        self.consola_text.setLineWrapMode(QPlainTextEdit.NoWrap)
        self.consola_text.setStyleSheet("font-family: monospace;")
        layout.addWidget(self.consola_text)

        entrada = QHBoxLayout()
        self.btn_ayuda = QPushButton("Ver ayuda (--help)")
        self.consola_input = QLineEdit()
        self.consola_input.setPlaceholderText("--status   (escribe los flags y pulsa Ejecutar o Enter)")
        self.btn_ejecutar = QPushButton("Ejecutar")
        self.btn_ayuda.clicked.connect(self._ver_ayuda)
        self.btn_ejecutar.clicked.connect(self._ejecutar_consola)
        self.consola_input.returnPressed.connect(self._ejecutar_consola)
        entrada.addWidget(self.btn_ayuda)
        entrada.addWidget(self.consola_input, 1)
        entrada.addWidget(self.btn_ejecutar)
        layout.addLayout(entrada)

        self._botones_consola = [self.btn_ayuda, self.btn_ejecutar]
        self.tabs.addTab(widget, "Consola")

    def _build_tab_config(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        self.config_origen_label = QLabel("")
        layout.addWidget(self.config_origen_label)

        self.config_text = QPlainTextEdit()
        self.config_text.setLineWrapMode(QPlainTextEdit.NoWrap)
        layout.addWidget(self.config_text)

        botones = QHBoxLayout()
        self.btn_config_recargar = QPushButton("Recargar")
        self.btn_config_guardar = QPushButton("Guardar en gestor_bbdd.conf")
        self.btn_config_recargar.clicked.connect(self.refresh_config)
        self.btn_config_guardar.clicked.connect(self._guardar_config)
        botones.addWidget(self.btn_config_recargar)
        botones.addStretch(1)
        botones.addWidget(self.btn_config_guardar)
        layout.addLayout(botones)

        self.tabs.addTab(widget, "Configuracion")
        self.refresh_config()

    def _build_tab_logs(self) -> None:
        widget = QWidget()
        layout = QVBoxLayout(widget)

        self.log_path_label = QLabel("")
        layout.addWidget(self.log_path_label)

        self.log_text = QPlainTextEdit()
        self.log_text.setReadOnly(True)
        self.log_text.setLineWrapMode(QPlainTextEdit.NoWrap)
        layout.addWidget(self.log_text)

        botones = QHBoxLayout()
        self.btn_log_recargar = QPushButton("Recargar log")
        self.btn_log_recargar.clicked.connect(self.refresh_logs)
        botones.addStretch(1)
        botones.addWidget(self.btn_log_recargar)
        layout.addLayout(botones)

        self.tabs.addTab(widget, "Logs")
        self.refresh_logs()

    def _build_menu(self) -> None:
        menu_archivo = self.menuBar().addMenu("&Archivo")
        accion_salir = menu_archivo.addAction("Salir")
        accion_salir.setShortcut(QKeySequence.Quit)
        accion_salir.triggered.connect(self.close)

        menu_ayuda = self.menuBar().addMenu("&Ayuda")
        accion_about = menu_ayuda.addAction("Acerca de")
        accion_about.triggered.connect(lambda: AboutDialog(self).exec())

    def _on_tab_changed(self, indice: int) -> None:
        texto = self.tabs.tabText(indice)
        # Logs se recarga SIEMPRE al abrir la pestana para reflejar la config
        # actual (p. ej. tras activar el registro en Configuracion).
        if texto == "Logs":
            self.refresh_logs()
            return
        if indice in self._pestanas_cargadas:
            return
        self._pestanas_cargadas.add(indice)
        if texto == "Contenedores":
            self.refresh_containers()
        elif texto == "Compose":
            self.refresh_compose()

    @staticmethod
    def _config_tabla(tabla: QTableView) -> None:
        tabla.setSelectionBehavior(QAbstractItemView.SelectRows)
        tabla.setSelectionMode(QAbstractItemView.SingleSelection)
        tabla.setEditTriggers(QAbstractItemView.NoEditTriggers)
        tabla.setAlternatingRowColors(True)
        tabla.verticalHeader().setVisible(False)
        tabla.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)

    # ==================================================================
    # Infraestructura asincrona
    # ==================================================================
    def _run_async(self, fn: Callable, on_ok: Callable, busy: str = "Trabajando...") -> None:
        self._set_busy(True, busy)
        worker = Worker(fn)
        worker.signals.finished.connect(
            lambda resultado, w=worker, cb=on_ok: self._on_worker_finished(w, resultado, cb),
            Qt.ConnectionType.QueuedConnection,
        )
        worker.signals.error.connect(
            lambda mensaje, w=worker: self._on_worker_error(w, mensaje),
            Qt.ConnectionType.QueuedConnection,
        )
        self._workers.append(worker)
        self.pool.start(worker)

    def _retirar_worker(self, worker: Worker) -> None:
        try:
            self._workers.remove(worker)
        except ValueError:
            pass

    def _on_worker_finished(self, worker: Worker, resultado: object, on_ok: Callable) -> None:
        self._retirar_worker(worker)
        self._set_busy(False)
        on_ok(resultado)

    def _on_worker_error(self, worker: Worker, mensaje: str) -> None:
        self._retirar_worker(worker)
        self._set_busy(False)
        self._error(mensaje)

    def _set_busy(self, busy: bool, mensaje: str = "") -> None:
        self._tareas_activas += 1 if busy else -1
        self._tareas_activas = max(self._tareas_activas, 0)
        ocupado = self._tareas_activas > 0
        for grupo in (
            getattr(self, "_botones_servidor", []),
            getattr(self, "_botones_contenedor", []),
            getattr(self, "_botones_compose", []),
            getattr(self, "_botones_diag", []),
            getattr(self, "_botones_herramientas", []),
            getattr(self, "_botones_consola", []),
        ):
            for boton in grupo:
                boton.setEnabled(not ocupado)
        if busy and mensaje:
            self.statusBar().showMessage(mensaje)
        elif not ocupado:
            self.statusBar().showMessage("Listo.")

    def _error(self, mensaje: str) -> None:
        QMessageBox.critical(self, "Error", mensaje or "Ocurrio un error desconocido.")

    def _info(self, mensaje: str) -> None:
        self.statusBar().showMessage(mensaje, 5000)

    # ==================================================================
    # Pestana Servidores
    # ==================================================================
    def _autorrefresco(self) -> None:
        if self._tareas_activas == 0:
            self.refresh_servers()

    def refresh_servers(self) -> None:
        self._run_async(self.backend.fetch_servers, self._on_servers, "Actualizando estado...")

    def _on_servers(self, resultado) -> None:
        filas, datos = resultado
        self.server_model.update(filas)
        self.init_label.setText(f"Init: {datos.get('init_system', '?')}")
        self._info(f"{len(filas)} servidor(es) detectado(s).")

    def _servidor_seleccionado(self) -> str | None:
        idx = self.server_table.currentIndex()
        if not idx.isValid():
            return None
        fila = self.server_model.server_at(idx.row())
        return fila.get("nombre") if fila else None

    def _accion_servidor(self, verbo: str) -> None:
        nombre = self._servidor_seleccionado()
        if not nombre:
            self._info("Selecciona un servidor en la tabla.")
            return
        fn = {"start": self.backend.start, "stop": self.backend.stop, "restart": self.backend.restart}[verbo]
        etiqueta = {"start": "Iniciando", "stop": "Deteniendo", "restart": "Reiniciando"}[verbo]
        self._run_async(lambda: fn(nombre), self._after_action, f"{etiqueta} {nombre}...")

    def _after_action(self, resultado: CommandResult) -> None:
        if not resultado.ok:
            self._error(resultado.mensaje_error or "La accion no se completo correctamente.")
        self.refresh_servers()

    def _comprobar_salud(self) -> None:
        nombre = self._servidor_seleccionado()
        if not nombre:
            self._info("Selecciona un servidor en la tabla.")
            return
        self._run_async(lambda: self.backend.health(nombre), self._on_salud, f"Comprobando salud de {nombre}...")

    def _on_salud(self, resultado: CommandResult) -> None:
        data = resultado.data or {}
        nombre = data.get("nombre", "?")
        salud = data.get("salud", "?")
        puerto = data.get("puerto", "?")
        QMessageBox.information(
            self,
            "Salud",
            f"Servidor: {nombre}\nPuerto: {puerto}\nSalud: {salud}",
        )

    def _abrir_terminal_servidor(self) -> None:
        nombre = self._servidor_seleccionado()
        if not nombre:
            self._info("Selecciona un servidor en la tabla.")
            return
        self._run_async(
            lambda: self.backend.open_terminal(nombre),
            self._after_open_terminal,
            f"Abriendo terminal de {nombre}...",
        )

    def _after_open_terminal(self, resultado: CommandResult) -> None:
        if resultado.ok:
            self._info("Terminal solicitada. Revisa tu escritorio.")
        else:
            self._error(resultado.mensaje_error or "No se pudo abrir la terminal del cliente.")

    # ==================================================================
    # Pestana Herramientas
    # ==================================================================
    def _ver_puertos(self) -> None:
        self._run_async(self.backend.ports, self._mostrar_herramienta, "Consultando puertos...")

    def _detectar_entornos(self) -> None:
        self._run_async(self.backend.detect, self._mostrar_herramienta, "Detectando entornos...")

    def _ayuda_servicios(self) -> None:
        self._run_async(self.backend.help_services, self._mostrar_herramienta, "Cargando ayuda...")

    def _mostrar_herramienta(self, resultado: CommandResult) -> None:
        texto = resultado.stdout.strip() or resultado.mensaje_error or "(sin salida)"
        # Por seguridad: elimina bytes nulos que podrian confundir a Qt.
        texto = texto.replace("\x00", "")
        self.herr_text.setPlainText(texto)

    def _resetear_password(self) -> None:
        respuesta = QMessageBox.warning(
            self,
            "Resetear contrasena root",
            "Esta operacion DETIENE temporalmente MySQL/MariaDB y abre una terminal "
            "del sistema para introducir la nueva contrasena (requiere privilegios).\n\n"
            "Deseas continuar?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if respuesta != QMessageBox.Yes:
            return
        try:
            self.backend.launch_reset_password()
        except Exception as exc:  # noqa: BLE001
            self._error(str(exc))
            return
        self._info("Se abrio una terminal para resetear la contrasena.")

    # ==================================================================
    # Pestana Consola
    # ==================================================================
    def _ver_ayuda(self) -> None:
        self._run_async(self.backend.ayuda, self._mostrar_consola, "Cargando ayuda...")

    def _ejecutar_consola(self) -> None:
        linea = self.consola_input.text().strip()
        if not linea:
            self._info("Escribe una opcion CLI (por ejemplo: --status).")
            return
        self.consola_text.appendPlainText(f"$ gestor_bbdd {linea}")
        self._run_async(lambda: self.backend.run_raw(linea), self._mostrar_consola, f"Ejecutando {linea}...")

    def _mostrar_consola(self, resultado: CommandResult) -> None:
        salida = resultado.stdout.rstrip()
        if salida:
            self.consola_text.appendPlainText(salida)
        err = resultado.stderr.strip()
        if err:
            self.consola_text.appendPlainText(f"[stderr] {err}")
        self.consola_text.appendPlainText("")
        self.consola_text.moveCursor(QTextCursor.End)

    # ==================================================================
    # Pestana Contenedores
    # ==================================================================
    def refresh_containers(self) -> None:
        self._run_async(self.backend.fetch_containers, self._on_containers, "Listando contenedores...")

    def _on_containers(self, filas: list[dict]) -> None:
        self.cont_model.update(filas)
        self._info(f"{len(filas)} contenedor(es) de BD detectado(s).")

    def _accion_contenedor(self, accion: str) -> None:
        idx = self.cont_table.currentIndex()
        if not idx.isValid():
            self._info("Selecciona un contenedor en la tabla.")
            return
        fila = self.cont_model.container_at(idx.row())
        if not fila:
            return
        nombre = fila.get("nombre", "")
        self._run_async(
            lambda: self.backend.container_action(accion, nombre),
            lambda r: self._after_container(r),
            f"{accion} {nombre}...",
        )

    def _after_container(self, resultado: CommandResult) -> None:
        if not resultado.ok:
            self._error(resultado.mensaje_error or "La accion sobre el contenedor fallo.")
        self.refresh_containers()

    # ==================================================================
    # Pestana Compose
    # ==================================================================
    def refresh_compose(self) -> None:
        self._run_async(self.backend.fetch_compose_projects, self._on_compose, "Buscando proyectos compose...")

    def _on_compose(self, proyectos: list[str]) -> None:
        self.compose_list.clear()
        self.compose_list.addItems(proyectos)
        self._info(f"{len(proyectos)} proyecto(s) compose detectado(s).")

    def _accion_compose(self, accion: str) -> None:
        item = self.compose_list.currentItem()
        if item is None:
            self._info("Selecciona un proyecto compose en la lista.")
            return
        ruta = item.text()
        fn = self.backend.compose_up if accion == "up" else self.backend.compose_down
        etiqueta = "Levantando" if accion == "up" else "Deteniendo"
        self._run_async(lambda: fn(ruta), self._after_compose, f"{etiqueta} {ruta}...")

    def _after_compose(self, resultado: CommandResult) -> None:
        if not resultado.ok:
            self._error(resultado.mensaje_error or "La operacion compose fallo.")
        else:
            self._info("Operacion compose completada.")
        self.refresh_compose()

    # ==================================================================
    # Pestana Diagnostico
    # ==================================================================
    def _generar_diagnostico(self) -> None:
        self._run_async(self.backend.diagnose_text, self._on_diagnostico, "Generando diagnostico...")

    def _on_diagnostico(self, resultado: CommandResult) -> None:
        self.diag_text.setPlainText(resultado.stdout or resultado.mensaje_error)

    def _exportar_diagnostico(self) -> None:
        ruta, _ = QFileDialog.getSaveFileName(
            self, "Exportar diagnostico", "diagnostico_bd.txt", "Texto (*.txt);;Todos (*.*)"
        )
        if not ruta:
            return
        self._run_async(lambda: self.backend.export(ruta), lambda r: self._after_export(r, ruta), "Exportando...")

    def _after_export(self, resultado: CommandResult, ruta: str) -> None:
        if resultado.ok:
            QMessageBox.information(self, "Exportar", f"Diagnostico exportado a:\n{ruta}")
        else:
            self._error(resultado.mensaje_error or "No se pudo exportar el diagnostico.")

    # ==================================================================
    # Pestana Configuracion
    # ==================================================================
    def refresh_config(self) -> None:
        try:
            texto = self.backend.read_config()
        except Exception as exc:  # noqa: BLE001
            self._error(str(exc))
            return
        origen = self.backend.config_origen()
        if origen is None:
            self.config_origen_label.setText("No se encontro gestor_bbdd.conf ni la plantilla .example.")
        elif origen == self.backend.conf_example_path:
            self.config_origen_label.setText(
                f"Mostrando plantilla: {origen.name} (al guardar se creara gestor_bbdd.conf)"
            )
        else:
            self.config_origen_label.setText(f"Editando: {origen}")
        self.config_text.setPlainText(texto)

    def _guardar_config(self) -> None:
        try:
            self.backend.write_config(self.config_text.toPlainText())
        except Exception as exc:  # noqa: BLE001
            self._error(str(exc))
            return
        self._info("Configuracion guardada en gestor_bbdd.conf.")
        self.refresh_config()

    # ==================================================================
    # Pestana Logs
    # ==================================================================
    def refresh_logs(self) -> None:
        habilitado = self.backend.log_enabled()
        ruta = self.backend.log_file_path()
        config_activa = self.backend.localizar_config_activa()

        partes = []
        if config_activa is None:
            partes.append("Sin gestor_bbdd.conf activo (se usa la plantilla .example)")
        partes.append(f"Registro: {'activado' if habilitado else 'DESACTIVADO'}")
        partes.append(f"Archivo: {ruta}" if ruta else "Archivo: no configurado")
        self.log_path_label.setText("   |   ".join(partes))

        if ruta is None:
            self.log_text.setPlainText(
                "No hay archivo de log configurado.\n\n"
                "Para activar el registro, abre la pestana Configuracion y define:\n"
                "    LOG_ENABLED=true\n"
                "    LOG_FILE=/ruta/al/archivo.log        (Windows: C:\\ruta\\archivo.log)\n\n"
                "Guarda los cambios y vuelve a esta pestana."
            )
            return

        try:
            contenido = self.backend.read_log()
        except Exception as exc:  # noqa: BLE001
            mensaje = str(exc)
            if not habilitado:
                mensaje += (
                    "\n\nAdemas, el registro esta DESACTIVADO (LOG_ENABLED=false), "
                    "por lo que no se escribiran nuevas entradas hasta activarlo."
                )
            self.log_text.setPlainText(mensaje)
            return

        if not contenido.strip():
            aviso = f"El archivo de log existe pero esta vacio:\n    {ruta}"
            if not habilitado:
                aviso += "\n\nEl registro esta DESACTIVADO (LOG_ENABLED=false)."
            self.log_text.setPlainText(aviso)
            return

        self.log_text.setPlainText(contenido)
        self.log_text.moveCursor(QTextCursor.End)
