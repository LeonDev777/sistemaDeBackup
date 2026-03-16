#!/usr/bin/env bash
# ==============================================================
# cleanup.sh — remove backups antigos
#
# Respeita o RETENTION_DAYS e o MIN_BACKUPS_KEEP do backup.conf.
# Nunca apaga mais do que (total - MIN_BACKUPS_KEEP) arquivos,
# mesmo que todos sejam mais antigos que RETENTION_DAYS.
#
# Uso:
#   ./cleanup.sh              remove backups antigos
#   ./cleanup.sh --dry-run    só mostra o que seria removido
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

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    log "INFO  [DRY RUN] Nenhum arquivo será deletado."
fi

BACKUP_SUBDIR="${BACKUP_DIR}/${DB_NAME}"

if [[ ! -d "${BACKUP_SUBDIR}" ]]; then
    log "INFO  Diretório ${BACKUP_SUBDIR} não existe. Nada a limpar."
    exit 0
fi

# lista todos os dumps em ordem do mais antigo pro mais novo
mapfile -t ALL_BACKUPS < <(find "${BACKUP_SUBDIR}" -name "*.dump" -type f | sort)
TOTAL=${#ALL_BACKUPS[@]}

log "INFO  Total de backups encontrados: ${TOTAL}"
log "INFO  Retenção configurada: ${RETENTION_DAYS} dias, mínimo ${MIN_BACKUPS_KEEP} cópias"

if [[ "${TOTAL}" -le "${MIN_BACKUPS_KEEP}" ]]; then
    log "INFO  Apenas ${TOTAL} backup(s) encontrado(s). Nada a remover (mínimo: ${MIN_BACKUPS_KEEP})."
    exit 0
fi

DELETED=0
FREED_MB=0
CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -v "-${RETENTION_DAYS}d" '+%Y-%m-%d %H:%M:%S')  # fallback pro macOS

for backup in "${ALL_BACKUPS[@]}"; do
    # garante que sobram pelo menos MIN_BACKUPS_KEEP arquivos
    REMAINING=$(( TOTAL - DELETED ))
    if [[ "${REMAINING}" -le "${MIN_BACKUPS_KEEP}" ]]; then
        log "INFO  Limite mínimo atingido. Parando limpeza."
        break
    fi

    # data de modificação do arquivo
    FILE_DATE=$(stat -c '%y' "${backup}" 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "${backup}")

    if [[ "${FILE_DATE}" < "${CUTOFF_DATE}" ]]; then
        FILE_SIZE_MB=$(du -m "${backup}" | cut -f1)
        CHECKSUM_FILE="${backup}.sha256"

        if [[ "${DRY_RUN}" == true ]]; then
            log "INFO  [DRY RUN] Removeria: ${backup} (${FILE_SIZE_MB}MB, ${FILE_DATE})"
        else
            log "INFO  Removendo: ${backup} (${FILE_SIZE_MB}MB, ${FILE_DATE})"
            rm -f "${backup}"
            # remove o checksum junto
            [[ -f "${CHECKSUM_FILE}" ]] && rm -f "${CHECKSUM_FILE}"
            (( DELETED++ )) || true
            (( FREED_MB += FILE_SIZE_MB )) || true
        fi
    fi
done

if [[ "${DRY_RUN}" == false ]]; then
    log "INFO  Limpeza concluída: ${DELETED} arquivo(s) removido(s), ${FREED_MB}MB liberados."
else
    log "INFO  [DRY RUN] Simulação concluída. Nenhum arquivo foi removido."
fi
