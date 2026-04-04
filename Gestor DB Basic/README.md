# DB Master (Gestor Táctico de Bases de Datos)

**Arquitecto:** Daniel Betancourt
**Versión:** 3.0 (Edición "Extracción Multi-Nodo")
**Entorno:** Debian / Ubuntu / macOS (Bash Puro sin dependencias)

[![bash](https://img.shields.io/badge/bash-%234EAA25.svg?style=flat&logo=gnu-bash&logoColor=white)](#) [![docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)](#) [![postgresql](https://img.shields.io/badge/postgresql-%23316192.svg?style=flat&logo=postgresql&logoColor=white)](#)

---

## Descripción

**DB Master** es una herramienta TUI (Terminal User Interface) escrita en Bash puro diseñada para la administración, análisis y respaldo de bases de datos en servidores Headless. 

Sin necesidad de instalar interfaces gráficas pesadas (como phpMyAdmin o pgAdmin), el sistema escanea el servidor buscando motores SQL (Nativos o en Docker) y despliega un panel de control para crear bases de datos, gestionar usuarios y, lo más importante: **extraer respaldos y enrutarlos automáticamente a tu PC, una memoria USB física y un repositorio de GitHub.**

---

## Características Principales

* **Radar Omnisciente (3 Capas):** Detecta bases de datos instaladas de forma nativa (`apt`), atrapadas dentro de contenedores **Docker**, o mediante un ping de red TCP al puerto local.
* **Auto-Instalador:** Si no detecta el motor, permite instalarlo con un solo botón sin salir de la interfaz gráfica.
* **Docker Deep-Inspect:** Extrae automáticamente los usuarios y nombres de bases de datos configurados en las variables de entorno de los contenedores para garantizar el acceso (Auto-Login).
* **Asistente de Respaldos (Wizard):** Permite marcar múltiples bases de datos con la barra espaciadora y exportarlas en formato `.sql` simultáneamente a tu entorno local, USB y GitHub.

---

## Atajos de Teclado y Controles

El sistema está diseñado para operarse 100% con el teclado, dividido en módulos de acción:

### 1. Modo RADAR (Escáner Principal)

| Tecla / Atajo | Acción | Descripción |
| :--- | :--- | :--- |
| `[↑]` / `[↓]` | Navegar | Cambia la selección entre los motores SQL disponibles. |
| `[Enter]` | Acceder | Entra al panel de administración del motor seleccionado. |
| `[I]` | Instalar | Si el motor no está detectado, fuerza su instalación nativa. |
| `[Q]` | Salir | Cierra el Gestor DB y devuelve el control a la terminal. |

### 2. Modo SELECTOR (Múltiples Contenedores)
*Se activa automáticamente si hay más de un contenedor Docker corriendo el mismo motor SQL.*

| Tecla / Atajo | Acción | Descripción |
| :--- | :--- | :--- |
| `[↑]` / `[↓]` | Navegar | Se mueve entre los contenedores detectados. |
| `[Enter]` | Seleccionar | Fija el contenedor objetivo y entra a su panel de control. |
| `[Q]` | Volver | Regresa al Radar principal. |

### 3. Modo ADMIN CORE (Panel de Control)

| Tecla / Atajo | Acción | Descripción |
| :--- | :--- | :--- |
| `[↑]` / `[↓]` | Mover Cursor | Selecciona el protocolo a ejecutar. |
| `[Enter]` | Ejecutar | Lanza la acción seleccionada (Crear DB, Eliminar, Listar, etc.). |
| `[Enter]` *(En visor)* | Salir del Visor | Si estás viendo la salida de una tabla SQL, presiona Enter para cerrarla. |
| `[Q]` | Atrás | Regresa al menú anterior. |

### 4. Modo BACKUP WIZARD (Asistente de Extracción)

| Tecla / Atajo | Acción | Descripción |
| :--- | :--- | :--- |
| `[↑]` / `[↓]` | Mover Cursor | Sube o baja entre la lista de Bases de Datos o Nodos destino. |
| **`[Espacio]`** | **Marcar Casilla** | **Marca o desmarca la casilla `[x]` del elemento seleccionado.** |
| `[Enter]` | Confirmar | Avanza al siguiente paso o inicia la extracción. |
| `[Q]` | Cancelar | Aborta el respaldo y regresa al Panel de Control. |

---

## Configuración de Nodos de Respaldo

DB Master lee automáticamente el archivo secreto `.venv_nav` (creado por el **Navegador Táctico**). 
Para que el asistente de backups pueda enviar las bases de datos a tu USB o a GitHub, debes haber configurado esos destinos previamente desde el menú `[9] Git Master -> [INIT]` del Navegador.

---

## Registro del Creador

* **Web:** [www.danielbetancourt-trader.com](http://www.danielbetancourt-trader.com)
* **Instagram:** [@daniel.betancourt.trader](https://www.instagram.com/daniel.betancourt.trader)
* **Telegram:** [@D2S3B8C2](https://t.me/D2S3B8C2)

---
*Diseñado para la eficiencia operativa absoluta.*