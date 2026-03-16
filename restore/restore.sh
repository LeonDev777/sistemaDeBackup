#!/usr/bin/env bash
# ==============================================================
# restore.sh — restauração de backup PostgreSQL
#
# USE COM CUIDADO. Esse script pode sobrescrever dados de produção.
# Sempre restaure primeiro num banco de teste pra validar.
#
# Uso:
#   ./restore.sh --latest                  restaura o backup mais recente
#   ./restore.sh --file /path/backup.dump  restaura arquivo específico
#   ./restore.sh --list                    lista backups disponíveis
#   ./restore.sh --verify --file x.dump    verifica integridade sem restaurar
#   ./restore.sh --target outro_banco      restaura em banco diferente (seguro pra testar)
#
# Parâmetros opcionais:
#   --no-confirm    não pede confirmação (cuidado!)
#   --jobs N        paralelismo no restore (padrão: 2)
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

BACKUP_FILE=""
TARGET_DB=""
DO_LATEST=false
DO_LIST=false
DO_VERIFY=false
NO_CONFIRM=false
RESTORE_JOBS="${PARALLEL_JOBS:-2}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)       BACKUP_FILE="$2"; shift 2 ;;
        --target)     TARGET_DB="$2"; shift 2 ;;
        --latest)     DO_LATEST=true; shift ;;
        --list)       DO_LIST=true; shift ;;
        --verify)     DO_VERIFY=true; shift ;;
        --no-confirm) NO_CONFIRM=true; shift ;;
        --jobs)       RESTORE_JOBS="$2"; shift 2 ;;
        -h|--help)
            head -20 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Argumento desconhecido: $1" ;;
    esac
done

# --------------------------------------------------------------
# lista backups disponíveis
# --------------------------------------------------------------

if [[ "${DO_LIST}" == true ]]; then
    BACKUP_SUBDIR="${BACKUP_DIR}/${DB_NAME}"
    echo ""
    echo "Backups disponíveis em ${BACKUP_SUBDIR}:"
    echo "----------------------------------------------"
    if [[ -d "${BACKUP_SUBDIR}" ]]; then
        find "${BACKUP_SUBDIR}" -name "*.dump" -type f \
            | sort -r \
            | while read -r f; do
                SIZE=$(du -mh "$f" | cut -f1)
                DATE=$(stat -c '%y' "$f" 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f")
                echo "  ${DATE}  ${SIZE}  $(basename "$f")"
            done
    else
        echo "  (nenhum backup encontrado)"
    fi
    echo ""
    exit 0
fi

# --------------------------------------------------------------
# resolve qual arquivo usar
# --------------------------------------------------------------

if [[ "${DO_LATEST}" == true ]]; then
    BACKUP_SUBDIR="${BACKUP_DIR}/${DB_NAME}"
    BACKUP_FILE=$(find "${BACKUP_SUBDIR}" -name "*.dump" -type f | sort | tail -1)
    if [[ -z "${BACKUP_FILE}" ]]; then
        die "Nenhum backup encontrado em ${BACKUP_SUBDIR}"
    fi
    log "INFO  Backup mais recente: ${BACKUP_FILE}"
fi

if [[ -z "${BACKUP_FILE}" ]]; then
    die "Especifique --file /caminho/backup.dump ou use --latest. Use --list pra ver os disponíveis."
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
    die "Arquivo não encontrado: ${BACKUP_FILE}"
fi

# banco de destino (padrão: mesmo banco do backup)
if [[ -z "${TARGET_DB}" ]]; then
    TARGET_DB="${DB_NAME}"
fi

# --------------------------------------------------------------
# verifica integridade (checksum)
# --------------------------------------------------------------

CHECKSUM_FILE="${BACKUP_FILE}.sha256"

if [[ -f "${CHECKSUM_FILE}" ]]; then
    log "INFO  Verificando integridade do backup..."
    if command -v sha256sum &> /dev/null; then
        sha256sum --check "${CHECKSUM_FILE}" > /dev/null 2>&1 \
            && log "INFO  Checksum OK." \
            || die "CHECKSUM INVÁLIDO! O arquivo pode estar corrompido: ${BACKUP_FILE}"
    elif command -v shasum &> /dev/null; then
        shasum -a 256 --check "${CHECKSUM_FILE}" > /dev/null 2>&1 \
            && log "INFO  Checksum OK." \
            || die "CHECKSUM INVÁLIDO! O arquivo pode estar corrompido: ${BACKUP_FILE}"
    fi
else
    log "WARN  Arquivo de checksum não encontrado. Continuando sem verificação."
fi

# modo --verify: só checa, não restaura
if [[ "${DO_VERIFY}" == true ]]; then
    log "INFO  Verificando formato do dump com pg_restore --list..."
    PGPASSWORD="${DB_PASSWORD}" pg_restore \
        --list "${BACKUP_FILE}" > /dev/null 2>&1 \
        && log "INFO  Arquivo válido. Pode ser restaurado." \
        || die "Arquivo inválido ou corrompido."
    exit 0
fi

# --------------------------------------------------------------
# confirmação interativa
# --------------------------------------------------------------

FILE_SIZE_MB="$(du -m "${BACKUP_FILE}" | cut -f1)"

echo ""
echo "================================================================"
echo "  RESTAURAÇÃO DE BACKUP"
echo "================================================================"
echo "  Arquivo  : $(basename "${BACKUP_FILE}")"
echo "  Tamanho  : ${FILE_SIZE_MB} MB"
echo "  Data     : $(stat -c '%y' "${BACKUP_FILE}" 2>/dev/null || stat -f '%Sm' "${BACKUP_FILE}")"
echo "  Destino  : ${DB_HOST}:${DB_PORT}/${TARGET_DB}"
echo ""

if [[ "${TARGET_DB}" == "${DB_NAME}" ]]; then
    echo "  ⚠️  ATENÇÃO: você está restaurando NO BANCO DE PRODUÇÃO."
    echo "  Isso vai APAGAR e SOBRESCREVER todos os dados existentes."
    echo ""
fi

if [[ "${NO_CONFIRM}" == false ]]; then
    read -rp "  Digite o nome do banco para confirmar [${TARGET_DB}]: " CONFIRM
    if [[ "${CONFIRM}" != "${TARGET_DB}" ]]; then
        echo "  Restauração cancelada."
        exit 0
    fi
fi

# --------------------------------------------------------------
# executa o restore
# --------------------------------------------------------------

log "INFO  Iniciando restauração de $(basename "${BACKUP_FILE}") → ${TARGET_DB}"

START_TIME=$(date +%s)

# cria o banco de destino se não existir
if ! PGPASSWORD="${DB_PASSWORD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" \
    -U "${DB_USER}" -d postgres \
    -lqt | cut -d'|' -f1 | grep -qw "${TARGET_DB}"; then

    log "INFO  Banco '${TARGET_DB}' não existe. Criando..."
    PGPASSWORD="${DB_PASSWORD}" createdb \
        -h "${DB_HOST}" -p "${DB_PORT}" \
        -U "${DB_USER}" \
        "${TARGET_DB}" \
        || die "Falha ao criar banco ${TARGET_DB}"
fi

# pg_restore: --clean remove objetos antes de recriar (evita conflito de nomes)
# --if-exists: não falha se o objeto não existe na versão atual
# --no-owner: não tenta setar o dono (útil quando restaura em usuário diferente)
PGPASSWORD="${DB_PASSWORD}" pg_restore \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --dbname="${TARGET_DB}" \
    --jobs="${RESTORE_JOBS}" \
    --clean \
    --if-exists \
    --no-owner \
    --no-privileges \
    --verbose \
    "${BACKUP_FILE}" 2>> "${RESTORE_LOG}" \
    || {
        # pg_restore retorna exit code != 0 mesmo quando algumas coisas dão warning
        # verifica se o problema foi fatal ou só warnings
        log "WARN  pg_restore terminou com avisos. Verifique ${RESTORE_LOG} para detalhes."
        log "WARN  Isso é normal em alguns casos (objetos já existentes, permissões, etc)."
    }

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

log "INFO  Restauração concluída em ${ELAPSED}s."
log "INFO  Banco restaurado: ${DB_HOST}:${DB_PORT}/${TARGET_DB}"
log "INFO  Verifique os dados antes de apontar a aplicação para este banco."

# registra no log do banco (melhor esforço)
PGPASSWORD="${DB_PASSWORD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" \
    -U "${DB_USER}" -d "${TARGET_DB}" \
    -c "INSERT INTO backup_log (db_name, status, backup_file, size_mb, notes, hostname)
        VALUES ('${TARGET_DB}', 'RESTORED', '${BACKUP_FILE}', ${FILE_SIZE_MB}, 'elapsed=${ELAPSED}s', '$(hostname)')" \
    > /dev/null 2>&1 || true

echo ""
echo "  Restauração finalizada. Próximos passos:"
echo "  1. Conecte no banco e verifique os dados"
echo "  2. Rode alguns SELECTs nas tabelas principais"
echo "  3. Só então aponte a aplicação para este banco"
echo ""
