[🏠 Documentación](README.md) › **Modo CLI**

# Modo CLI (no interactivo)

Ambos scripts admiten argumentos para usarlos desde terminal, scripts o tareas programadas sin abrir el menú.

## Linux

```bash
sudo bash gestor_bbdd.sh --help
sudo bash gestor_bbdd.sh --status
sudo bash gestor_bbdd.sh --start mysql
sudo bash gestor_bbdd.sh --stop postgresql
sudo bash gestor_bbdd.sh --health redis
sudo bash gestor_bbdd.sh --diagnose
sudo bash gestor_bbdd.sh --export /tmp/informe_bd.txt
sudo bash gestor_bbdd.sh --containers
sudo bash gestor_bbdd.sh --container-start mi-mysql
sudo bash gestor_bbdd.sh --json --status
sudo bash gestor_bbdd.sh --compose-list
sudo bash gestor_bbdd.sh --compose-up /ruta/al/proyecto/docker-compose.yml
sudo bash gestor_bbdd.sh --compose-down /ruta/al/proyecto
sudo bash gestor_bbdd.sh --ports
sudo bash gestor_bbdd.sh --detect
sudo bash gestor_bbdd.sh --help-services
sudo bash gestor_bbdd.sh --reset-password
sudo bash gestor_bbdd.sh --open-terminal mysql
```

Con `--json`, la salida es JSON válido (útil para scripts, CI o monitorización). Compatible con `--status`, `--diagnose`, `--health`, `--containers` y `--compose-list`.

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Help
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Status
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Start mysql
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Export C:\temp\informe_bd.txt
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -ContainerStop mi-postgres
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Json -Status
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -ComposeList
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -ComposeUp C:\proyectos\mi-db\docker-compose.yml
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Ports
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -Detect
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -HelpServices
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -ResetPassword
powershell -ExecutionPolicy Bypass -File .\gestor_bbdd.ps1 -OpenTerminal mysql
```

Con `-Json`, la salida es JSON válido (equivalente a `--json` en Linux).

Los nombres de servidor y contenedor admiten **coincidencia parcial** (p. ej. `mysql` coincide con el servicio `mysql`).

---

> La [interfaz gráfica](gui.md) reutiliza estos mismos comandos: su pestaña **Consola** permite ejecutar cualquiera de estas opciones y ver la salida en bruto.

---

[🏠 Índice](README.md) · [⬅ Anterior: Menú y funcionalidades](menu.md) · [Siguiente: Interfaz gráfica ➡](gui.md)
