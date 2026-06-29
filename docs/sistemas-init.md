[🏠 Documentación](README.md) › **Sistemas de init**

# Sistemas de init (Linux): systemd, SysVinit y OpenRC

En distribuciones sin systemd (Alpine con OpenRC, algunas instalaciones SysVinit), el script detecta automáticamente el sistema de init y usa el método de gestión apropiado:

| Init | Detección | Gestión de servicios |
|------|-----------|----------------------|
| **systemd** | `/run/systemd` o cgroup systemd | `systemctl start/stop/restart` |
| **OpenRC** | `rc-service` disponible | `rc-service <svc> start/stop/restart` |
| **SysVinit** | `/etc/init.d` con scripts | `/etc/init.d/<svc> start/stop/restart` |

El valor detectado aparece en los diagnósticos y en la salida JSON (`init_system`). La ayuda del menú (opción **7**) adapta las instrucciones según el init detectado.

El [modo práctica](menu.md#modo-práctica) también respeta el sistema de init detectado al arrancar los conjuntos predefinidos de servicios.

---

[🏠 Índice](README.md) · [⬅ Anterior: Contenedores y Compose](contenedores.md) · [Siguiente: Motores y entornos soportados ➡](motores.md)
