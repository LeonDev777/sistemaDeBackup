#!/usr/bin/env bash
# ==============================================================
# backup.sh — backup completo de banco PostgreSQL
#
# Uso:
#   ./backup.sh                    backup do banco definido no .env
#   ./backup.sh -d outro_banco     backup de banco específico
#   ./backup.sh --no-compress      sem compressão
#   ./backup.sh --sql              gera SQL legível além do .dump
#   ./backup.sh -h                 ajuda
#
# Requer: pg_dump, sha256sum (ou shasum no Mac)
# ==============================================================

set -euo pipefail
# set -x  # descomenta se precisar debugar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# carrega .env se existir
if [[ -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${ROOT_DIR}/.env"
    set +a
fi

# carrega configurações
# shellcheck disable=SC1091
source "${ROOT_DIR}/config/backup.conf"

# --------------------------------------------------------------
# funções auxiliares
# --------------------------------------------------------------

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[${ts}] [${level}] ${msg}"

    # grava no arquivo de log também
    mkdir -p "${LOG_DIR}"
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

die() {
    error "$@"
    # registra falha na tabela de log do banco (melhor esforço, não falha se o banco estiver fora)
    _log_to_db "FAILED" "0" "$*" || true
    _notify_failure "$*" || true
    exit 1
}

# notifica por e-mail se configurado
_notify_failure() {
    local msg="$1"
    if [[ -n "${ALERT_EMAIL:-}" ]]; then
        echo "Backup falhou em $(hostname) às $(date): ${msg}" \
            | mail -s "[ALERTA] Backup PostgreSQL falhou - ${DB_NAME}" "${ALERT_EMAIL}" 2>/dev/null || true
    fi

    if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
        curl -s -X POST "${SLACK_WEBHOOK}" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"❌ Backup PostgreSQL falhou em \`$(hostname)\`: ${msg}\"}" > /dev/null 2>&1 || true
    fi
}

# grava o resultado na tabela de log (se o banco estiver acessível)
_log_to_db() {
    local status="$1"
    local size_mb="$2"
    local notes="${3:-}"
    local backup_file="${4:-}"

    # não trava o script se isso falhar
    PGPASSWORD="${DB_PASSWORD}" psql \
        -h "${DB_HOST}" -p "${DB_PORT}" \
        -U "${DB_USER}" -d "${DB_NAME}" \
        -c "INSERT INTO backup_log (db_name, status, backup_file, size_mb, notes, hostname)
            VALUES ('${DB_NAME}', '${status}', '${backup_file}', ${size_mb}, '${notes}', '$(hostname)')" \
        > /dev/null 2>&1 || true
}

# verifica se os binários necessários estão disponíveis
_check_dependencies() {
    local missing=()
    for cmd in pg_dump psql; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Binários não encontrados: ${missing[*]}. Instale o postgresql-client."
    fi
}

# testa conectividade antes de começar (evita descobrir que o banco está fora depois de 10 min)
_check_connection() {
    info "Testando conexão com ${DB_HOST}:${DB_PORT}/${DB_NAME}..."
    if ! PGPASSWORD="${DB_PASSWORD}" psql \
        -h "${DB_HOST}" -p "${DB_PORT}" \
        -U "${DB_USER}" -d "${DB_NAME}" \
        -c "SELECT 1" > /dev/null 2>&1; then
        die "Não foi possível conectar no banco. Verifique as credenciais e se o banco está rodando."
    fi
    info "Conexão OK."
}

# monta os flags de exclusão do pg_dump
_build_exclude_flags() {
    local flags=""

    if [[ -n "${EXCLUDE_SCHEMAS:-}" ]]; then
        for schema in ${EXCLUDE_SCHEMAS}; do
            flags="${flags} --exclude-schema=${schema}"
        done
    fi

    if [[ -n "${EXCLUDE_TABLES:-}" ]]; then
        for table in ${EXCLUDE_TABLES}; do
            flags="${flags} --exclude-table=${table}"
        done
    fi

    echo "$flags"
}

# calcula tamanho do arquivo em MB
_file_size_mb() {
    local file="$1"
    if [[ -f "$file" ]]; then
        du -m "$file" | cut -f1
    else
        echo "0"
    fi
}

# --------------------------------------------------------------
# parse dos argumentos
# --------------------------------------------------------------

OVERRIDE_DB=""
NO_COMPRESS=false
DUMP_SQL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--database)
            OVERRIDE_DB="$2"
            shift 2
            ;;
        --no-compress)
            NO_COMPRESS=true
            shift
            ;;
        --sql)
            DUMP_SQL=true
            shift
            ;;
        -h|--help)
            head -15 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            die "Argumento desconhecido: $1"
            ;;
    esac
done

# sobrescreve o banco se passado via -d
if [[ -n "${OVERRIDE_DB}" ]]; then
    DB_NAME="${OVERRIDE_DB}"
fi

# --------------------------------------------------------------
# validações
# --------------------------------------------------------------

if [[ -z "${DB_NAME}" ]]; then
    die "DB_NAME não definido. Configure no .env ou passe -d nome_banco."
fi

_check_dependencies
_check_connection

# --------------------------------------------------------------
# prepara os caminhos
# --------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_SUBDIR="${BACKUP_DIR}/${DB_NAME}"
BACKUP_FILE="${BACKUP_SUBDIR}/${DB_NAME}_${TIMESTAMP}.dump"

mkdir -p "${BACKUP_SUBDIR}" || die "Não foi possível criar o diretório ${BACKUP_SUBDIR}"

# --------------------------------------------------------------
# executa o backup
# --------------------------------------------------------------

info "Iniciando backup de '${DB_NAME}' → ${BACKUP_FILE}"

START_TIME=$(date +%s)

COMPRESS_LEVEL=6
if [[ "${NO_COMPRESS}" == true ]]; then
    COMPRESS_LEVEL=0
fi

EXCLUDE_FLAGS="$(_build_exclude_flags)"

# o pg_dump com --format=custom já comprime internamente
# shellcheck disable=SC2086
PGPASSWORD="${DB_PASSWORD}" pg_dump \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --format="${DUMP_FORMAT}" \
    --compress="${COMPRESS_LEVEL}" \
    --jobs="${PARALLEL_JOBS}" \
    --no-password \
    --verbose \
    ${EXCLUDE_FLAGS} \
    "${DB_NAME}" \
    --file="${BACKUP_FILE}" 2>> "${LOG_FILE}" \
    || die "pg_dump falhou. Verifique ${LOG_FILE} para detalhes."

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

# verifica se o arquivo foi criado e não está vazio
if [[ ! -f "${BACKUP_FILE}" ]] || [[ ! -s "${BACKUP_FILE}" ]]; then
    die "Arquivo de backup não foi criado ou está vazio: ${BACKUP_FILE}"
fi

FILE_SIZE_MB="$(_file_size_mb "${BACKUP_FILE}")"

info "Backup concluído em ${ELAPSED}s. Tamanho: ${FILE_SIZE_MB}MB"

# --------------------------------------------------------------
# gera checksum
# --------------------------------------------------------------

if [[ "${VERIFY_CHECKSUM}" == "true" ]]; then
    CHECKSUM_FILE="${BACKUP_FILE}.sha256"
    if command -v sha256sum &> /dev/null; then
        sha256sum "${BACKUP_FILE}" > "${CHECKSUM_FILE}"
    elif command -v shasum &> /dev/null; then
        # macOS
        shasum -a 256 "${BACKUP_FILE}" > "${CHECKSUM_FILE}"
    else
        warn "sha256sum/shasum não encontrado, pulando geração de checksum."
    fi
    info "Checksum gravado em ${CHECKSUM_FILE}"
fi

# --------------------------------------------------------------
# backup em SQL legível (opcional, pra quem precisa inspecionar)
# --------------------------------------------------------------

if [[ "${DUMP_SQL}" == true ]]; then
    SQL_FILE="${BACKUP_FILE%.dump}.sql"
    info "Gerando dump SQL legível em ${SQL_FILE}..."
    PGPASSWORD="${DB_PASSWORD}" pg_dump \
        --host="${DB_HOST}" \
        --port="${DB_PORT}" \
        --username="${DB_USER}" \
        --format=plain \
        --no-password \
        ${EXCLUDE_FLAGS} \
        "${DB_NAME}" \
        > "${SQL_FILE}" 2>> "${LOG_FILE}" \
        || warn "Falha ao gerar SQL. O backup .dump principal foi concluído com sucesso."
fi

# --------------------------------------------------------------
# registra no banco
# --------------------------------------------------------------

_log_to_db "SUCCESS" "${FILE_SIZE_MB}" "elapsed=${ELAPSED}s compress=${COMPRESS_LEVEL}" "${BACKUP_FILE}"

info "=== Backup finalizado com sucesso ==="
info "  Arquivo : ${BACKUP_FILE}"
info "  Tamanho : ${FILE_SIZE_MB} MB"
info "  Duração : ${ELAPSED}s"
