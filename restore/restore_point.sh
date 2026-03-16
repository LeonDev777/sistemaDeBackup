#!/usr/bin/env bash
# ==============================================================
# restore_point.sh — Point-in-Time Recovery (PITR)
#
# Restaura o banco para um momento específico no tempo usando
# um backup base (pg_basebackup) + arquivos WAL.
#
# Exige que o backup_incremental.sh tenha sido usado e que
# o WAL archiving esteja configurado.
#
# Uso:
#   ./restore_point.sh \
#       --base /var/backups/postgresql/basebackup_20250315_020000 \
#       --target-time "2025-03-15 14:30:00" \
#       --target-dir /var/lib/postgresql/restored_data
#
# Esse script não inicializa o PostgreSQL. Ele prepara o
# diretório de dados. Você inicia o PostgreSQL manualmente depois.
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    source "${ROOT_DIR}/.env"
    set +a
fi

source "${ROOT_DIR}/config/backup.conf"

RESTORE_LOG="${LOG_DIR}/restore.log"

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*"
    mkdir -p "${LOG_DIR}"
    echo "[${ts}] $*" >> "${RESTORE_LOG}"
}

die() { log "ERROR $*"; exit 1; }

# --------------------------------------------------------------
# parse dos argumentos
# --------------------------------------------------------------

BASE_BACKUP_DIR=""
TARGET_TIME=""
TARGET_DIR=""
WAL_ARCHIVE_DIR="${BACKUP_DIR}/wal_archive"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)         BASE_BACKUP_DIR="$2"; shift 2 ;;
        --target-time)  TARGET_TIME="$2"; shift 2 ;;
        --target-dir)   TARGET_DIR="$2"; shift 2 ;;
        --wal-dir)      WAL_ARCHIVE_DIR="$2"; shift 2 ;;
        -h|--help)
            head -25 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Argumento desconhecido: $1" ;;
    esac
done

# --------------------------------------------------------------
# validações
# --------------------------------------------------------------

[[ -z "${BASE_BACKUP_DIR}" ]] && die "Informe --base /caminho/do/basebackup"
[[ -z "${TARGET_TIME}" ]]     && die "Informe --target-time 'YYYY-MM-DD HH:MM:SS'"
[[ -z "${TARGET_DIR}" ]]      && die "Informe --target-dir /caminho/de/destino"

[[ -d "${BASE_BACKUP_DIR}" ]] || die "Diretório de backup base não encontrado: ${BASE_BACKUP_DIR}"
[[ -d "${WAL_ARCHIVE_DIR}" ]] || die "Diretório WAL não encontrado: ${WAL_ARCHIVE_DIR}. Use --wal-dir."

if [[ -d "${TARGET_DIR}" ]] && [[ -n "$(ls -A "${TARGET_DIR}")" ]]; then
    die "Diretório de destino ${TARGET_DIR} não está vazio. Escolha outro ou limpe antes."
fi

log "INFO  Iniciando PITR → ${TARGET_DIR}"
log "INFO  Base backup : ${BASE_BACKUP_DIR}"
log "INFO  Target time : ${TARGET_TIME}"
log "INFO  WAL archive : ${WAL_ARCHIVE_DIR}"

# --------------------------------------------------------------
# extrai o backup base
# --------------------------------------------------------------

mkdir -p "${TARGET_DIR}"

log "INFO  Extraindo backup base..."

# o pg_basebackup com --format=tar gera base.tar.gz
if [[ -f "${BASE_BACKUP_DIR}/base.tar.gz" ]]; then
    tar -xzf "${BASE_BACKUP_DIR}/base.tar.gz" -C "${TARGET_DIR}"
else
    # formato directory: copia direto
    cp -a "${BASE_BACKUP_DIR}/." "${TARGET_DIR}/"
fi

# remove o pg_wal gerado pelo backup (vamos usar o do archive)
rm -rf "${TARGET_DIR}/pg_wal"/*

log "INFO  Backup base extraído."

# --------------------------------------------------------------
# cria o recovery.conf (PG 11 e anteriores) ou postgresql.auto.conf (PG 12+)
# --------------------------------------------------------------

# detecta a versão do PostgreSQL pra saber qual arquivo usar
PG_VERSION_FILE="${TARGET_DIR}/PG_VERSION"
if [[ -f "${PG_VERSION_FILE}" ]]; then
    PG_MAJOR_VERSION=$(cat "${PG_VERSION_FILE}")
else
    # se não conseguir detectar, assume PG 12+
    PG_MAJOR_VERSION=14
fi

log "INFO  PostgreSQL versão detectada: ${PG_MAJOR_VERSION}"

if [[ "${PG_MAJOR_VERSION}" -ge 12 ]]; then
    # PG 12+: usa postgresql.auto.conf + recovery.signal
    log "INFO  Configurando recovery para PG 12+ (recovery.signal)..."

    cat >> "${TARGET_DIR}/postgresql.auto.conf" << EOF

# --- Configuração PITR gerada por restore_point.sh em $(date) ---
restore_command = 'cp ${WAL_ARCHIVE_DIR}/%f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF

    # cria o arquivo signal que ativa o modo de recovery
    touch "${TARGET_DIR}/recovery.signal"

else
    # PG 11 e anteriores: usa recovery.conf
    log "INFO  Configurando recovery para PG <= 11 (recovery.conf)..."

    cat > "${TARGET_DIR}/recovery.conf" << EOF
# Configuração PITR gerada por restore_point.sh em $(date)
restore_command = 'cp ${WAL_ARCHIVE_DIR}/%f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF
fi

# ajusta permissões (PostgreSQL é exigente com isso)
chmod 700 "${TARGET_DIR}"

# --------------------------------------------------------------
# instruções finais
# --------------------------------------------------------------

log "INFO  Diretório preparado para PITR."

echo ""
echo "================================================================"
echo "  PITR preparado. Próximos passos:"
echo "================================================================"
echo ""
echo "  1. Certifique-se que o PostgreSQL está parado:"
echo "     systemctl stop postgresql"
echo ""
echo "  2. Aponte o data_directory para:"
echo "     ${TARGET_DIR}"
echo ""
echo "  3. Ou substitua o data dir atual (cuidado!):"
echo "     mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main.old"
echo "     mv ${TARGET_DIR} /var/lib/postgresql/14/main"
echo "     chown -R postgres:postgres /var/lib/postgresql/14/main"
echo ""
echo "  4. Inicie o PostgreSQL:"
echo "     systemctl start postgresql"
echo ""
echo "  5. O PostgreSQL vai entrar em modo de recovery e aplicar"
echo "     os WAL até '${TARGET_TIME}'."
echo ""
echo "  6. Acompanhe os logs:"
echo "     tail -f /var/log/postgresql/postgresql-*.log"
echo ""
echo "  Quando aparecer 'database system is ready to accept connections',"
echo "  o recovery terminou. Verifique os dados e remova o recovery.signal."
echo ""
