-- Tabela de log dos backups
--
-- Roda isso no banco que você quer monitorar.
-- Cria um schema separado pra não misturar com as tabelas da aplicação.
--
-- Uso:
--   psql -U postgres -d meu_banco -f sql/create_log_table.sql

CREATE SCHEMA IF NOT EXISTS backup_mgmt;

COMMENT ON SCHEMA backup_mgmt IS 'Schema do sistema de backup automatizado';


CREATE TABLE IF NOT EXISTS backup_mgmt.backup_log (
    id              BIGSERIAL PRIMARY KEY,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    db_name         TEXT NOT NULL,
    status          TEXT NOT NULL,     -- SUCCESS, FAILED, RESTORED
    backup_file     TEXT,              -- caminho completo do arquivo
    size_mb         NUMERIC(12, 2),
    duration_sec    INT,
    notes           TEXT,              -- qualquer info adicional
    hostname        TEXT DEFAULT current_setting('client_hostname', true),
    pg_version      TEXT DEFAULT current_setting('server_version')
);

COMMENT ON TABLE backup_mgmt.backup_log IS 'Histórico de execuções de backup e restore';

CREATE INDEX IF NOT EXISTS idx_backup_log_started_at
    ON backup_mgmt.backup_log (started_at DESC);

CREATE INDEX IF NOT EXISTS idx_backup_log_db_status
    ON backup_mgmt.backup_log (db_name, status);


-- cria uma view simplificada pra consulta rápida
CREATE OR REPLACE VIEW backup_mgmt.recent_backups AS
SELECT
    id,
    started_at,
    db_name,
    status,
    size_mb,
    duration_sec,
    notes,
    hostname,
    -- indica se foi o backup mais recente deste banco
    ROW_NUMBER() OVER (PARTITION BY db_name ORDER BY started_at DESC) AS recency_rank
FROM backup_mgmt.backup_log
ORDER BY started_at DESC;

COMMENT ON VIEW backup_mgmt.recent_backups IS
    'View simplificada dos backups. recency_rank=1 é o mais recente de cada banco.';


-- compat: a tabela antiga (sem schema) continua funcionando
-- se você já tinha uma tabela 'backup_log' no schema public
-- comente o bloco abaixo se não precisar dessa compatibilidade
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'backup_log'
    ) THEN
        -- cria uma view no schema public apontando pra tabela real
        EXECUTE $q$
            CREATE VIEW public.backup_log AS
            SELECT id, started_at AS captured_at, db_name, status,
                   backup_file, size_mb, notes, hostname
            FROM backup_mgmt.backup_log;
        $q$;
        RAISE NOTICE 'View pública backup_log criada.';
    END IF;
END
$$;

RAISE NOTICE 'Setup concluído. Tabela: backup_mgmt.backup_log';
