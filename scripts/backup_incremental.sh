#!/usr/bin/env bash
# ==============================================================
# backup_incremental.sh — backup incremental via pg_basebackup
#
# Usa pg_basebackup pra criar um backup base (com WAL archiving).
# Isso permite Point-in-Time Recovery (PITR): restaurar o banco
# pra qualquer momento no tempo, não só o horário do backup.
#
# Pré-requisitos no postgresql.conf:
#   wal_level = replica
#   archive_mode = on
#   archive_command = 'cp %p /var/backups/postgresql/wal_archive/%f'
#
# ATENÇÃO: esse script cria uma cópia do cluster inteiro (não só
# um banco). É mais pesado mas permite PITR. Use o backup.sh
# pra backups rápidos de bancos individuais.
#
# Uso:
#   ./backup_incremental.sh
#   ./backup_incremental.sh --check-wal    verifica configuração WAL
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

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*"
    mkdir -p "${LOG_DIR}"
    echo "[${ts}] $*" >> "${LOG_FILE}"
}

die() { log "ERROR $*"; exit 1; }

# verifica se o WAL archiving está configurado
_check_wal_config() {
    log "INFO  Verificando configuração WAL no servidor..."

    local wal_level archive_mode
    wal_level=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" \
        -U "${DB_USER}" -d "${DB_NAME}" -tAc "SHOW wal_level;" 2>/dev/null || echo "unknown")
    archive_mode=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" \
        -U "${DB_USER}" -d "${DB_NAME}" -tAc "SHOW archive_mode;" 2>/dev/null || echo "unknown")

    log "INFO  wal_level: ${wal_level}"
    log "INFO  archive_mode: ${archive_mode}"

    if [[ "${wal_level}" != "replica" && "${wal_level}" != "logical" ]]; then
        log "WARN  wal_level precisa ser 'replica' ou 'logical' para PITR."
        log "WARN  Adicione 'wal_level = replica' no postgresql.conf e reinicie o PostgreSQL."
        return 1
    fi

    if [[ "${archive_mode}" != "on" ]]; then
        log "WARN  archive_mode precisa estar 'on' para PITR."
        return 1
    fi

    log "INFO  Configuração WAL OK."
    return 0
}

# --check-wal: só verifica a configuração sem fazer backup
if [[ "${1:-}" == "--check-wal" ]]; then
    _check_wal_config
    exit $?
fi

# verifica pg_basebackup
if ! command -v pg_basebackup &> /dev/null; then
    die "pg_basebackup não encontrado. Instale o postgresql-client."
fi

# avisa mas não bloqueia se WAL não estiver configurado
_check_wal_config || log "WARN  Continuando sem PITR. O backup base será criado, mas não terá WAL archiving."

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BASE_BACKUP_DIR="${BACKUP_DIR}/basebackup_${TIMESTAMP}"

log "INFO  Iniciando pg_basebackup → ${BASE_BACKUP_DIR}"
log "INFO  Isso pode demorar alguns minutos dependendo do tamanho do cluster..."

START_TIME=$(date +%s)

PGPASSWORD="${DB_PASSWORD}" pg_basebackup \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --pgdata="${BASE_BACKUP_DIR}" \
    --format=tar \
    --gzip \
    --compress=6 \
    --checkpoint=fast \
    --wal-method=stream \
    --progress \
    --no-password \
    2>> "${LOG_FILE}" \
    || die "pg_basebackup falhou. Verifique ${LOG_FILE}."

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

# tamanho total do diretório gerado
TOTAL_SIZE_MB=$(du -sm "${BASE_BACKUP_DIR}" | cut -f1)

# grava um arquivo de metadados pra facilitar o restore
cat > "${BASE_BACKUP_DIR}/backup_info.txt" << EOF
backup_type=basebackup
timestamp=${TIMESTAMP}
db_host=${DB_HOST}
db_port=${DB_PORT}
elapsed_seconds=${ELAPSED}
size_mb=${TOTAL_SIZE_MB}
wal_method=stream
pg_version=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT version();" 2>/dev/null || echo "unknown")
EOF

log "INFO  pg_basebackup concluído."
log "INFO  Diretório : ${BASE_BACKUP_DIR}"
log "INFO  Tamanho   : ${TOTAL_SIZE_MB} MB"
log "INFO  Duração   : ${ELAPSED}s"
log "INFO  Para restaurar com PITR, veja docs/restore_guide.md"
