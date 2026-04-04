#!/bin/bash
# ==============================================================
# DB MASTER (Gestor Táctico) - Fase 3: Asistente de Respaldos
# Arquitecto: Daniel Betancourt
# ==============================================================

# --- MEMORIA COMPARTIDA CON EL NAVEGADOR ---
CONFIG_FILE="$HOME/.venv_nav"
TARGET_DIR="$PWD" 
USB_PATH=""
GITHUB_TOKEN=""
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

# --- COLORES ANSI TÁCTICOS ---
VERDE="\e[1;32m"
ROJO="\e[1;31m"
AMARILLO="\e[1;33m"
CIAN="\e[1;36m"
BLANCO="\e[1;97m"
RESET="\e[0m"

# --- VARIABLES DE ESTADO ---
APP_MODE="RADAR"
SELECTED=0
DB_SELECTED=0
CONT_SELECTED=0
WIZARD_SEL=0
BACKUP_STEP=0

MYSQL_STATUS="NO DETECTADO"
MYSQL_VERSION=""
PG_STATUS="NO DETECTADO"
PG_VERSION=""
PG_CONTAINER=""
PG_ACTIVE_USER="postgres"
PG_ACTIVE_DB="template1"

declare -a DOCKER_PG_LIST
declare -a DB_EXECUTION_BUFFER
declare -a DB_LIST
declare -a DB_SELECTED_FLAG
declare -a DEST_LIST=("Nodo Local (PC)" "Bóveda Física (USB)" "Nube (GitHub)")
declare -a DEST_SELECTED_FLAG=(1 0 0)

DB_IO_STATE="STATUS"
DB_IO_PAGE=0
INPUT_BUFFER=""

# --- ESCÁNER OMNISCIENTE ---
escanear_servidor() {
    MYSQL_STATUS="NO DETECTADO"; PG_STATUS="NO DETECTADO"
    MYSQL_VERSION="N/A"; PG_VERSION="N/A"
    DOCKER_PG_LIST=()

    if command -v mysql &> /dev/null; then 
        MYSQL_STATUS="NATIVO"; MYSQL_VERSION=$(mysql -V | awk '{print $5}' | tr -d ',')
    elif sudo -n docker ps 2>/dev/null | grep -qiE 'mysql|mariadb'; then
        MYSQL_STATUS="DOCKER"; MYSQL_VERSION="Contenedor Activo"
    fi

    if command -v psql &> /dev/null; then 
        PG_STATUS="NATIVO"; PG_VERSION=$(psql -V | awk '{print $3}' | tr -d ',')
    elif sudo -n docker ps 2>/dev/null | grep -qi 'postgres'; then
        PG_STATUS="DOCKER"; PG_VERSION="Múltiples Contenedores"
        mapfile -t DOCKER_PG_LIST < <(sudo -n docker ps 2>/dev/null | grep -i 'postgres' | awk '{print $NF}')
    elif docker ps 2>/dev/null | grep -qi 'postgres'; then
        PG_STATUS="DOCKER"; PG_VERSION="Múltiples Contenedores"
        mapfile -t DOCKER_PG_LIST < <(docker ps 2>/dev/null | grep -i 'postgres' | awk '{print $NF}')
    fi
}

# --- AUTO-DETECCIÓN DE USUARIO Y DB ---
configurar_usuario_pg() {
    PG_ACTIVE_USER="postgres"
    PG_ACTIVE_DB="template1"
    if [ "$PG_STATUS" == "DOCKER" ] && [ -n "$PG_CONTAINER" ]; then
        local env_user=""; local env_db=""
        if docker ps &>/dev/null; then 
            env_user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" 2>/dev/null | grep -iE '^POSTGRES_USER=' | cut -d= -f2 | tr -d '\r')
            env_db=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" 2>/dev/null | grep -iE '^POSTGRES_DB=' | cut -d= -f2 | tr -d '\r')
        else 
            env_user=$(sudo docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" 2>/dev/null | grep -iE '^POSTGRES_USER=' | cut -d= -f2 | tr -d '\r')
            env_db=$(sudo docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" 2>/dev/null | grep -iE '^POSTGRES_DB=' | cut -d= -f2 | tr -d '\r')
        fi
        [ -n "$env_user" ] && PG_ACTIVE_USER="$env_user"
        [ -n "$env_db" ] && PG_ACTIVE_DB="$env_db"
    fi
}

# --- EXTRAER LISTA DE BASES DE DATOS ---
obtener_lista_dbs() {
    DB_LIST=()
    DB_SELECTED_FLAG=()
    local query="SELECT datname FROM pg_database WHERE datistemplate = false;"
    local temp_out="/tmp/.db_list"
    
    if [ "$PG_STATUS" == "DOCKER" ]; then
        if docker ps &>/dev/null; then docker exec -i "$PG_CONTAINER" psql -U "$PG_ACTIVE_USER" -d "$PG_ACTIVE_DB" -tAc "$query" > "$temp_out" 2>/dev/null
        else sudo docker exec -i "$PG_CONTAINER" psql -U "$PG_ACTIVE_USER" -d "$PG_ACTIVE_DB" -tAc "$query" > "$temp_out" 2>/dev/null; fi
    else
        sudo -u postgres psql -d template1 -tAc "$query" > "$temp_out" 2>/dev/null
    fi
    
    mapfile -t DB_LIST < "$temp_out"
    rm -f "$temp_out"
    for i in "${!DB_LIST[@]}"; do DB_SELECTED_FLAG[$i]=0; done
}

# --- PROTOCOLOS DE PANTALLA ---
entrar_pantalla_alterna() { echo -ne "\033[?1049h\033[?25l\033[2J\033[H"; }
salir_pantalla_alterna() { echo -ne "\033[?1049l\033[?25h\033[2J\033[H"; clear; }
salir_seguro() { salir_pantalla_alterna; exit 0; }
trap salir_seguro SIGINT SIGTERM
trap 'echo -ne "\033[2J\033[H"; dibujar_ui' WINCH

# ==============================================================
# MOTOR DE ENTRADA TÁCTICA 
# ==============================================================
pedir_dato_tui() {
    local prompt="$1"
    local COLS=$(tput cols)
    local LINES=$(tput lines)
    local CONTENT_HEIGHT=$(( LINES - 11 ))
    local row=$(( 5 + CONTENT_HEIGHT + 2 )) 
    echo -ne "\033[${row};1H${CIAN}│${RESET} ${AMARILLO}${prompt}${BLANCO}\033[K\033[${row};${COLS}H${CIAN}│${RESET}\033[${row};$(( 4 + ${#prompt} ))H"
    echo -ne "\033[?25h" 
    read -r INPUT_BUFFER
    echo -ne "\033[?25l" 
}

# ==============================================================
# MOTOR DE EJECUCIÓN SQL
# ==============================================================
ejecutar_sql_capture() {
    local query="$1"
    local temp_log="/tmp/.db_master_io_temp"
    DB_EXECUTION_BUFFER=()
    
    if [ "$APP_MODE" == "PG_ADMIN" ]; then
        if [ "$PG_STATUS" == "DOCKER" ]; then
            if docker ps &>/dev/null; then docker exec -i "$PG_CONTAINER" psql -U "$PG_ACTIVE_USER" -d "$PG_ACTIVE_DB" -c "$query" > "$temp_log" 2>&1
            else sudo docker exec -i "$PG_CONTAINER" psql -U "$PG_ACTIVE_USER" -d "$PG_ACTIVE_DB" -c "$query" > "$temp_log" 2>&1; fi
        else
            sudo -u postgres psql -d template1 -c "$query" > "$temp_log" 2>&1
        fi
    fi

    local COLS=$(tput cols)
    local L_W=$(( COLS / 2 - 2 ))
    local R_W=$(( COLS - L_W - 3 ))
    local MAX_W=$(( R_W - 3 ))
    
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        local out=""; local vis_len=0; local i=0
        local in_ansi=0; local last_ansi=""; local cur_ansi=""
        while [ $i -lt ${#raw_line} ]; do
            local c="${raw_line:$i:1}"
            if [[ "$c" == $'\e' ]]; then in_ansi=1; cur_ansi="$c"
            elif [ $in_ansi -eq 1 ]; then
                cur_ansi+="$c"
                if [[ "$c" == "m" || "$c" == "K" ]]; then in_ansi=0; [[ "$cur_ansi" == *"[0m" || "$cur_ansi" == *"[m" ]] && last_ansi="" || last_ansi="$cur_ansi"; fi
            fi
            out+="$c"
            if [ $in_ansi -eq 0 ] && [[ "$c" != $'\e' ]]; then
                ((vis_len++))
                if [ $vis_len -ge $MAX_W ]; then DB_EXECUTION_BUFFER+=("$out\e[0m"); out="  $last_ansi"; vis_len=2; fi
            fi
            ((i++))
        done
        [ -n "$out" ] && [ "$out" != "  $last_ansi" ] && DB_EXECUTION_BUFFER+=("$out\e[0m") || ([ ${#raw_line} -eq 0 ] && DB_EXECUTION_BUFFER+=(""))
    done < "$temp_log"
    rm -f "$temp_log"
    
    DB_EXECUTION_BUFFER+=("")
    DB_EXECUTION_BUFFER+=("${AMARILLO}>> Presiona [Enter] o flechas para volver. <<${RESET}")
    DB_IO_STATE="RESULT"
    DB_IO_PAGE=0
}

# ==============================================================
# MOTOR DE RENDERIZADO
# ==============================================================
dibujar_ui() {
    local COLS=$(tput cols)
    local LINES=$(tput lines)
    if [ "$COLS" -lt 85 ] || [ "$LINES" -lt 20 ]; then echo -ne "\033[H\033[J\033[1;31mVentana muy pequeña.\033[0m"; return; fi

    local L_W=$(( COLS / 2 - 2 ))
    local R_W=$(( COLS - L_W - 3 ))
    local MID=$(( L_W + 2 ))
    local CONTENT_HEIGHT=$(( LINES - 11 )) 
    local buffer="\033[H"

    buffer+="${CIAN}┌$(printf '─%.0s' $(seq 1 $((COLS-2))))┐${RESET}\n"
    buffer+="${CIAN}│${VERDE} NODO ACTIVO: $TARGET_DIR ${RESET}\033[K\033[2;${COLS}H${CIAN}│${RESET}\n"
    
    local c_str=" >> DB MASTER (RADAR) << "
    [ "$APP_MODE" == "PG_SELECTOR" ] && c_str=" >> SELECTOR DE CONTENEDORES POSTGRESQL << "
    [ "$APP_MODE" == "PG_ADMIN" ] && c_str=" >> POSTGRES ADMIN [ ID: $PG_CONTAINER | USR: $PG_ACTIVE_USER | DB: $PG_ACTIVE_DB ] << "
    [ "$APP_MODE" == "PG_BACKUP" ] && c_str=" >> ASISTENTE DE RESPALDO MULTI-NODO << "
    
    buffer+="${CIAN}│${AMARILLO}${c_str}${RESET}\033[K\033[3;${COLS}H${CIAN}│${RESET}\n"
    buffer+="${CIAN}├$(printf '─%.0s' $(seq 1 $L_W))┬$(printf '─%.0s' $(seq 1 $R_W))┤${RESET}\n"

    local LEFT_ITEMS=()
    local LEFT_COLORS=()
    local RIGHT_LINES=()
    local TOTAL_ITEMS=0
    local CUR_SEL=0

    # ==========================================================
    # LÓGICA DE MODOS
    # ==========================================================
    if [ "$APP_MODE" == "RADAR" ]; then
        LEFT_ITEMS=("[MYSQL] Servidor MySQL / MariaDB" "[POSTGRES] Servidor PostgreSQL" "[EXIT] Salir al sistema")
        LEFT_COLORS=("$CIAN" "$CIAN" "$ROJO")
        TOTAL_ITEMS=${#LEFT_ITEMS[@]}; CUR_SEL=$SELECTED

        RIGHT_LINES+=("                       ██████╗ ██████╗ ")
        RIGHT_LINES+=("                       ██╔══██╗██╔══██╗")
        RIGHT_LINES+=("                       ██║  ██║██████╔╝")
        RIGHT_LINES+=("                       ██║  ██║██╔══██╗")
        RIGHT_LINES+=("                       ██████╔╝██████╔╝")
        RIGHT_LINES+=("                       ╚═════╝ ╚═════╝ ")
        RIGHT_LINES+=("${CIAN}-------------------------------------------------------${RESET}")
        
        if [ "$SELECTED" -eq 0 ]; then
            RIGHT_LINES+=("${AMARILLO}>> ANÁLISIS DE NÚCLEO: MYSQL / MARIADB <<${RESET}")
            if [ "$MYSQL_STATUS" != "NO DETECTADO" ]; then
                RIGHT_LINES+=(" Estado: ${VERDE}[ INSTALADO - $MYSQL_STATUS ]${RESET}"); RIGHT_LINES+=(" Versión: $MYSQL_VERSION"); RIGHT_LINES+=("")
                RIGHT_LINES+=("${BLANCO}Motor listo. Presiona [Enter] para acceder (Fase 3).${RESET}")
            else
                RIGHT_LINES+=(" Estado: ${ROJO}[ NO DETECTADO ]${RESET}"); RIGHT_LINES+=("")
                RIGHT_LINES+=("Presiona ${VERDE}[ I ]${RESET} para iniciar instalación nativa.")
            fi
        elif [ "$SELECTED" -eq 1 ]; then
            RIGHT_LINES+=("${AMARILLO}>> ANÁLISIS DE NÚCLEO: POSTGRESQL <<${RESET}")
            if [ "$PG_STATUS" != "NO DETECTADO" ]; then
                RIGHT_LINES+=(" Estado: ${VERDE}[ INSTALADO - $PG_STATUS ]${RESET}"); RIGHT_LINES+=(" Versión: $PG_VERSION"); RIGHT_LINES+=("")
                RIGHT_LINES+=("${BLANCO}El motor está listo. Presiona [Enter] para acceder${RESET}")
            else
                RIGHT_LINES+=(" Estado: ${ROJO}[ NO DETECTADO ]${RESET}"); RIGHT_LINES+=("")
                RIGHT_LINES+=("Presiona ${VERDE}[ I ]${RESET} para iniciar instalación nativa.")
            fi
        elif [ "$SELECTED" -eq 2 ]; then RIGHT_LINES+=("${ROJO}>> DESCONEXIÓN <<${RESET}"); RIGHT_LINES+=("Cierra el DB Master."); fi

    elif [ "$APP_MODE" == "PG_SELECTOR" ]; then
        for cont in "${DOCKER_PG_LIST[@]}"; do LEFT_ITEMS+=("[DOCKER] $cont"); LEFT_COLORS+=("$AMARILLO"); done
        LEFT_ITEMS+=("[BACK] Volver al Radar"); LEFT_COLORS+=("$BLANCO")
        TOTAL_ITEMS=${#LEFT_ITEMS[@]}; CUR_SEL=$CONT_SELECTED

        RIGHT_LINES+=("${AMARILLO}>> MÚLTIPLES CONTENEDORES DETECTADOS <<${RESET}")
        RIGHT_LINES+=("${CIAN}-------------------------------------------------------${RESET}")
        RIGHT_LINES+=(" Selecciona el contenedor exacto que deseas administrar.")

    elif [ "$APP_MODE" == "PG_ADMIN" ]; then
        LEFT_ITEMS=("[DB] Listar Bases de Datos" "[DB] Crear Base de Datos" "[DB] Eliminar Base de Datos" "[USER] Listar Usuarios" "[USER] Crear Usuario" "[USER] Cambiar Password" "[SQL] Consola Libre (Query)" "[BACKUP] Asistente de Extracción" "[BACK] Volver al Selector/Radar")
        LEFT_COLORS=("$CIAN" "$VERDE" "$ROJO" "$CIAN" "$VERDE" "$AMARILLO" "$BLANCO" "$VERDE" "$BLANCO")
        TOTAL_ITEMS=${#LEFT_ITEMS[@]}; CUR_SEL=$DB_SELECTED

        if [ "$DB_IO_STATE" == "RESULT" ]; then
            RIGHT_LINES+=("${VERDE}== SALIDA DEL MOTOR ==${RESET}")
            for (( i=$DB_IO_PAGE; i<${#DB_EXECUTION_BUFFER[@]}; i++ )); do RIGHT_LINES+=(" ${DB_EXECUTION_BUFFER[$i]}"); if [ "${#RIGHT_LINES[@]}" -ge "$CONTENT_HEIGHT" ]; then break; fi; done
        else
            RIGHT_LINES+=("${AMARILLO}>> INSTRUCCIONES DE OPERACIÓN <<${RESET}"); RIGHT_LINES+=("${CIAN}-------------------------------------------------------${RESET}")
            case $CUR_SEL in
                0) RIGHT_LINES+=(" Imprime tabla con todas las bases de datos.") ;;
                1) RIGHT_LINES+=(" Te pedira un nombre y creara una BD limpia.") ;;
                2) RIGHT_LINES+=(" ${ROJO}PELIGRO:${RESET} Elimina una BD. Irreversible.") ;;
                3) RIGHT_LINES+=(" Imprime roles y usuarios existentes.") ;;
                4) RIGHT_LINES+=(" Crea un nuevo usuario.") ;;
                5) RIGHT_LINES+=(" Permite cambiar el password.") ;;
                6) RIGHT_LINES+=(" Prompt para escribir SQL crudo.") ;;
                7) RIGHT_LINES+=(" ${VERDE}[ASISTENTE ACTIVO]${RESET}"); RIGHT_LINES+=(" Abre el asistente visual para seleccionar multiples"); RIGHT_LINES+=(" bases de datos y enrutarlas a PC, USB o GitHub.") ;;
                8) RIGHT_LINES+=(" Desconecta el Admin Core.") ;;
            esac
        fi

    elif [ "$APP_MODE" == "PG_BACKUP" ]; then
        CUR_SEL=$WIZARD_SEL
        if [ "$BACKUP_STEP" -eq 0 ]; then
            for i in "${!DB_LIST[@]}"; do
                if [ "${DB_SELECTED_FLAG[$i]}" -eq 1 ]; then LEFT_ITEMS+=("[x] ${DB_LIST[$i]}"); LEFT_COLORS+=("$VERDE")
                else LEFT_ITEMS+=("[ ] ${DB_LIST[$i]}"); LEFT_COLORS+=("$CIAN"); fi
            done
            LEFT_ITEMS+=("[->] CONTINUAR (Paso 2)" "[X] CANCELAR")
            LEFT_COLORS+=("$AMARILLO" "$ROJO")
            TOTAL_ITEMS=${#LEFT_ITEMS[@]}

            RIGHT_LINES+=("${AMARILLO}>> PASO 1: SELECCIÓN DE OBJETIVOS <<${RESET}")
            RIGHT_LINES+=("${CIAN}-------------------------------------------------------${RESET}")
            RIGHT_LINES+=(" Muevete con las flechas y presiona la")
            RIGHT_LINES+=(" barra ${VERDE}[ESPACIO]${RESET} para marcar las bases de")
            RIGHT_LINES+=(" datos que deseas extraer del servidor.")
            RIGHT_LINES+=("")
            RIGHT_LINES+=(" Las bases seleccionadas se exportaran a")
            RIGHT_LINES+=(" archivos .sql puros.")
        
        elif [ "$BACKUP_STEP" -eq 1 ]; then
            for i in "${!DEST_LIST[@]}"; do
                local dest_name="${DEST_LIST[$i]}"
                if [ "$i" -eq 0 ]; then dest_name="$dest_name ($TARGET_DIR)"; fi
                if [ "$i" -eq 1 ]; then 
                    if [ -n "$USB_PATH" ]; then dest_name="$dest_name ($USB_PATH)"
                    else dest_name="$dest_name (No configurada en .venv_nav)"; fi
                fi
                if [ "$i" -eq 2 ]; then
                    if [ -z "$GITHUB_TOKEN" ]; then dest_name="$dest_name (Sin Token en .venv_nav)"; fi
                fi

                if [ "${DEST_SELECTED_FLAG[$i]}" -eq 1 ]; then LEFT_ITEMS+=("[x] $dest_name"); LEFT_COLORS+=("$VERDE")
                else LEFT_ITEMS+=("[ ] $dest_name"); LEFT_COLORS+=("$CIAN"); fi
            done
            LEFT_ITEMS+=("[->] INICIAR EXTRACCIÓN" "[X] CANCELAR")
            LEFT_COLORS+=("$AMARILLO" "$ROJO")
            TOTAL_ITEMS=${#LEFT_ITEMS[@]}

            RIGHT_LINES+=("${AMARILLO}>> PASO 2: ENRUTAMIENTO DE NODOS <<${RESET}")
            RIGHT_LINES+=("${CIAN}-------------------------------------------------------${RESET}")
            RIGHT_LINES+=(" Marca con ${VERDE}[ESPACIO]${RESET} hacia donde quieres")
            RIGHT_LINES+=(" enviar las bases de datos extraidas.")
            RIGHT_LINES+=("")
            RIGHT_LINES+=(" ${CIAN}[PC]:${RESET} Carpeta local de tu codigo.")
            RIGHT_LINES+=(" ${CIAN}[USB]:${RESET} Memoria fisica enlazada.")
            RIGHT_LINES+=(" ${CIAN}[GitHub]:${RESET} Sincroniza via Git Commit/Push.")
            RIGHT_LINES+=("")
            RIGHT_LINES+=(" (Rutas leidas de la Boveda .venv_nav)")
        fi
    fi

    # --- RENDERIZAR FILAS ---
    local offset=$(( CUR_SEL - CONTENT_HEIGHT / 2 ))
    [ "$offset" -lt 0 ] && offset=0
    [ "$offset" -gt $(( TOTAL_ITEMS - CONTENT_HEIGHT )) ] && [ "$TOTAL_ITEMS" -gt "$CONTENT_HEIGHT" ] && offset=$(( TOTAL_ITEMS - CONTENT_HEIGHT ))

    for (( i=0; i<CONTENT_HEIGHT; i++ )); do
        local row=$(( 5 + i ))
        local idx=$(( offset + i ))
        local l_text=""
        
        if [ "$idx" -lt "$TOTAL_ITEMS" ]; then
            local item="${LEFT_ITEMS[$idx]}"
            local m_color="${LEFT_COLORS[$idx]}"
            if [ "$idx" -eq "$CUR_SEL" ]; then l_text=" ${VERDE} ▶ [${RESET} ${m_color}${item}${RESET} ${VERDE}]${RESET}"
            else l_text="      ${m_color}${item}${RESET}"; fi
        fi

        local r_text=""
        if [ "$i" -lt "${#RIGHT_LINES[@]}" ]; then r_text="${RIGHT_LINES[$i]}"; fi
        buffer+="${CIAN}│${RESET}${l_text}\033[K\033[${row};${MID}H${CIAN}│${RESET}\e[?7l${r_text}\e[?7h\033[K\033[${row};${COLS}H${CIAN}│${RESET}\n"
    done

    # --- PIE DE PÁGINA ---
    local row=$(( 5 + CONTENT_HEIGHT ))
    buffer+="${CIAN}├$(printf '─%.0s' $(seq 1 $L_W))┴$(printf '─%.0s' $(seq 1 $R_W))┤${RESET}\n"
    row=$(( row + 1 ))
    
    local c1=""; local c2=""
    if [ "$APP_MODE" == "RADAR" ]; then 
        c1=" [↑/↓] Seleccionar Motor | [Enter] Acceder al Admin Core "; c2=" [I] Instalar Motor Faltante | [Q] Salir del DB Master ";
    elif [ "$APP_MODE" == "PG_SELECTOR" ]; then
        c1=" [↑/↓] Navegar Contenedores | [Enter] Acceder "; c2=" [Q] Volver al Radar ";
    elif [ "$APP_MODE" == "PG_ADMIN" ] && [ "$DB_IO_STATE" != "RESULT" ]; then
        c1=" [↑/↓] Seleccionar Protocolo | [Enter] Ejecutar Acción "; c2=" [Q] Volver ";
    elif [ "$APP_MODE" == "PG_BACKUP" ]; then
        c1=" [↑/↓] Navegar | [Espacio] Marcar/Desmarcar | [Enter] Confirmar "; c2=" [Q] Cancelar y Volver ";
    else
        c1=" [↑/↓] Scroll Visor | [Enter] Volver a Comandos "; c2=""; 
    fi
    
    buffer+="${CIAN}│${AMARILLO}${c1:0:$((COLS - 4))}${RESET}\033[K\033[${row};${COLS}H${CIAN}│${RESET}\n"
    row=$(( row + 1 ))
    buffer+="${CIAN}│${AMARILLO}${c2:0:$((COLS - 4))}${RESET}\033[K\033[${row};${COLS}H${CIAN}│${RESET}\n"
    row=$(( row + 1 ))
    buffer+="${CIAN}└$(printf '─%.0s' $(seq 1 $((COLS-2))))┘${RESET}"
    echo -ne "$buffer"
}

# ==============================================================
# BUCLE PRINCIPAL
# ==============================================================
entrar_pantalla_alterna
escanear_servidor

while true; do
    dibujar_ui
    IFS= read -rsn1 key  # <-- EL BLINDAJE ANTI-DEVORADOR DE ESPACIOS
    if [[ $key == $'\e' ]]; then read -rsn2 key2; key+="$key2"; fi

    if [ "$DB_IO_STATE" == "RESULT" ]; then
        case "$key" in
            $'\e[A') ((DB_IO_PAGE--)); [ $DB_IO_PAGE -lt 0 ] && DB_IO_PAGE=0 ;;
            $'\e[B') ((DB_IO_PAGE++)) ;;
            *) DB_IO_STATE="STATUS"; DB_EXECUTION_BUFFER=() ;;
        esac
        continue
    fi

    if [ "$APP_MODE" == "RADAR" ]; then
        case "$key" in
            $'\e[A') ((SELECTED--)); [ $SELECTED -lt 0 ] && SELECTED=2 ;;
            $'\e[B') ((SELECTED++)); [ $SELECTED -gt 2 ] && SELECTED=0 ;;
            "i"|"I") 
                if [ "$SELECTED" -eq 1 ] && [ "$PG_STATUS" == "NO DETECTADO" ]; then
                    salir_pantalla_alterna; sudo apt-get update && sudo apt-get install postgresql postgresql-contrib -y; read -p "Instalado. Enter para volver."; entrar_pantalla_alterna; escanear_servidor
                fi ;;
            "") 
                if [ "$SELECTED" -eq 2 ]; then salir_seguro; fi
                if [ "$SELECTED" -eq 1 ] && [ "$PG_STATUS" != "NO DETECTADO" ]; then 
                    if [ ${#DOCKER_PG_LIST[@]} -gt 1 ]; then APP_MODE="PG_SELECTOR"; CONT_SELECTED=0;
                    else 
                        [ ${#DOCKER_PG_LIST[@]} -eq 1 ] && PG_CONTAINER="${DOCKER_PG_LIST[0]}"
                        configurar_usuario_pg
                        APP_MODE="PG_ADMIN"; DB_SELECTED=0; 
                    fi
                fi
                ;;
            "q"|"Q") salir_seguro ;;
        esac

    elif [ "$APP_MODE" == "PG_SELECTOR" ]; then
        case "$key" in
            $'\e[A') ((CONT_SELECTED--)); [ $CONT_SELECTED -lt 0 ] && CONT_SELECTED=$((${#DOCKER_PG_LIST[@]})) ;;
            $'\e[B') ((CONT_SELECTED++)); [ $CONT_SELECTED -gt ${#DOCKER_PG_LIST[@]} ] && CONT_SELECTED=0 ;;
            "") 
                if [ "$CONT_SELECTED" -eq ${#DOCKER_PG_LIST[@]} ]; then APP_MODE="RADAR"
                else 
                    PG_CONTAINER="${DOCKER_PG_LIST[$CONT_SELECTED]}"
                    configurar_usuario_pg; APP_MODE="PG_ADMIN"; DB_SELECTED=0
                fi ;;
            "q"|"Q") APP_MODE="RADAR" ;;
        esac

    elif [ "$APP_MODE" == "PG_ADMIN" ]; then
        case "$key" in
            $'\e[A') ((DB_SELECTED--)); [ $DB_SELECTED -lt 0 ] && DB_SELECTED=8 ;;
            $'\e[B') ((DB_SELECTED++)); [ $DB_SELECTED -gt 8 ] && DB_SELECTED=0 ;;
            "") 
                case $DB_SELECTED in
                    0) ejecutar_sql_capture "\l" ;;
                    1) pedir_dato_tui "Nombre de BD a Crear: "; [ -n "$INPUT_BUFFER" ] && ejecutar_sql_capture "CREATE DATABASE \"$INPUT_BUFFER\";" ;;
                    2) pedir_dato_tui "CONFIRMAR nombre de BD a ELIMINAR: "; [ -n "$INPUT_BUFFER" ] && ejecutar_sql_capture "DROP DATABASE \"$INPUT_BUFFER\";" ;;
                    3) ejecutar_sql_capture "\du" ;;
                    4) pedir_dato_tui "Nuevo Usuario: "; usr="$INPUT_BUFFER"; pedir_dato_tui "Password: "; pwd="$INPUT_BUFFER"; [ -n "$usr" ] && ejecutar_sql_capture "CREATE USER \"$usr\" WITH PASSWORD '$pwd';" ;;
                    5) pedir_dato_tui "Usuario existente: "; usr="$INPUT_BUFFER"; pedir_dato_tui "Nuevo Password: "; pwd="$INPUT_BUFFER"; [ -n "$usr" ] && ejecutar_sql_capture "ALTER USER \"$usr\" WITH PASSWORD '$pwd';" ;;
                    6) pedir_dato_tui "SQL> "; [ -n "$INPUT_BUFFER" ] && ejecutar_sql_capture "$INPUT_BUFFER" ;;
                    7) obtener_lista_dbs; APP_MODE="PG_BACKUP"; BACKUP_STEP=0; WIZARD_SEL=0 ;;
                    8) if [ ${#DOCKER_PG_LIST[@]} -gt 1 ]; then APP_MODE="PG_SELECTOR"; else APP_MODE="RADAR"; fi ;;
                esac ;;
            "q"|"Q") if [ ${#DOCKER_PG_LIST[@]} -gt 1 ]; then APP_MODE="PG_SELECTOR"; else APP_MODE="RADAR"; fi ;;
        esac

    elif [ "$APP_MODE" == "PG_BACKUP" ]; then
        case "$key" in
            $'\e[A') ((WIZARD_SEL--)); [ $WIZARD_SEL -lt 0 ] && WIZARD_SEL=$((TOTAL_ITEMS - 1)) ;;
            $'\e[B') ((WIZARD_SEL++)); [ $WIZARD_SEL -ge $TOTAL_ITEMS ] && WIZARD_SEL=0 ;;
            " ") # Barra espaciadora para marcar/desmarcar
                if [ "$BACKUP_STEP" -eq 0 ] && [ "$WIZARD_SEL" -lt "${#DB_LIST[@]}" ]; then
                    DB_SELECTED_FLAG[$WIZARD_SEL]=$((1 - DB_SELECTED_FLAG[$WIZARD_SEL]))
                elif [ "$BACKUP_STEP" -eq 1 ] && [ "$WIZARD_SEL" -lt "${#DEST_LIST[@]}" ]; then
                    DEST_SELECTED_FLAG[$WIZARD_SEL]=$((1 - DEST_SELECTED_FLAG[$WIZARD_SEL]))
                fi ;;
            "") # Tecla Enter
                if [ "$BACKUP_STEP" -eq 0 ]; then
                    if [ "$WIZARD_SEL" -eq "${#DB_LIST[@]}" ]; then BACKUP_STEP=1; WIZARD_SEL=0; # CONTINUAR
                    elif [ "$WIZARD_SEL" -eq $((${#DB_LIST[@]} + 1)) ]; then APP_MODE="PG_ADMIN"; fi # CANCELAR
                elif [ "$BACKUP_STEP" -eq 1 ]; then
                    if [ "$WIZARD_SEL" -eq "${#DEST_LIST[@]}" ]; then # INICIAR EXTRACCIÓN
                        salir_pantalla_alterna
                        echo -e "${CIAN}======================================================${RESET}"
                        echo -e "${AMARILLO} INICIANDO EXTRACCIÓN Y ENRUTAMIENTO DE BASES DE DATOS${RESET}"
                        echo -e "${CIAN}======================================================${RESET}"
                        local date_str=$(date +%F_%H%M)
                        
                        for i in "${!DB_LIST[@]}"; do
                            if [ "${DB_SELECTED_FLAG[$i]}" -eq 1 ]; then
                                local db="${DB_LIST[$i]}"
                                local file="${TARGET_DIR}/${db}_backup_${date_str}.sql"
                                echo -e "${VERDE}[*] Extrayendo: $db -> Nodo Local...${RESET}"
                                
                                if [ "$PG_STATUS" == "DOCKER" ]; then
                                    if docker ps &>/dev/null; then docker exec -i "$PG_CONTAINER" pg_dump -U "$PG_ACTIVE_USER" "$db" > "$file" 2>/dev/null
                                    else sudo docker exec -i "$PG_CONTAINER" pg_dump -U "$PG_ACTIVE_USER" "$db" > "$file" 2>/dev/null; fi
                                else
                                    sudo -u postgres pg_dump "$db" > "$file" 2>/dev/null
                                fi
                                
                                if [ "${DEST_SELECTED_FLAG[1]}" -eq 1 ] && [ -n "$USB_PATH" ]; then
                                    echo -e "${AMARILLO}    -> Copiando a Bóveda USB ($USB_PATH)...${RESET}"
                                    cp "$file" "$USB_PATH/" 2>/dev/null
                                fi
                            fi
                        done
                        
                        if [ "${DEST_SELECTED_FLAG[2]}" -eq 1 ]; then
                            echo -e "${CIAN}[*] Sincronizando Bóveda con GitHub...${RESET}"
                            cd "$TARGET_DIR" 2>/dev/null && git add . && git commit -m "Auto-Backup DBs $date_str" && git push github main 2>/dev/null
                        fi
                        
                        echo -e "\n${VERDE}>> EXTRACCIÓN FINALIZADA. Presiona [Enter] para volver. <<${RESET}"
                        read
                        entrar_pantalla_alterna
                        APP_MODE="PG_ADMIN"
                    elif [ "$WIZARD_SEL" -eq $((${#DEST_LIST[@]} + 1)) ]; then APP_MODE="PG_ADMIN"; fi # CANCELAR
                fi ;;
            "q"|"Q") APP_MODE="PG_ADMIN" ;;
        esac
    fi
done
