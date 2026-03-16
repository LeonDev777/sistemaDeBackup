-- Queries de análise dos logs de backup
--
-- Copie a que precisar e rode no psql ou no pgAdmin.
-- Todas assumem que o create_log_table.sql foi executado.


-- ============================================================
-- 1. Resumo dos últimos 7 dias
-- ============================================================
SELECT
    DATE(started_at)                    AS dia,
    db_name,
    COUNT(*) FILTER (WHERE status = 'SUCCESS')  AS ok,
    COUNT(*) FILTER (WHERE status = 'FAILED')   AS falhos,
    COUNT(*) FILTER (WHERE status = 'RESTORED') AS restores,
    ROUND(AVG(size_mb) FILTER (WHERE status = 'SUCCESS'), 0) AS tamanho_medio_mb,
    ROUND(AVG(duration_sec) FILTER (WHERE status = 'SUCCESS'), 0) AS duracao_media_seg
FROM backup_mgmt.backup_log
WHERE started_at > NOW() - INTERVAL '7 days'
GROUP BY dia, db_name
ORDER BY dia DESC, db_name;


-- ============================================================
-- 2. Último backup de cada banco (pra saber se está em dia)
-- ============================================================
SELECT
    db_name,
    MAX(started_at) FILTER (WHERE status = 'SUCCESS')  AS ultimo_backup_ok,
    MAX(started_at) FILTER (WHERE status = 'FAILED')   AS ultima_falha,
    -- quantas horas faz do último backup bem-sucedido
    ROUND(
        EXTRACT(EPOCH FROM (NOW() - MAX(started_at) FILTER (WHERE status = 'SUCCESS'))) / 3600
    , 1)                                                AS horas_desde_ultimo_backup,
    -- flag de alerta se faz mais de 25 horas sem backup
    CASE
        WHEN MAX(started_at) FILTER (WHERE status = 'SUCCESS') < NOW() - INTERVAL '25 hours'
        THEN '⚠ ATRASADO'
        ELSE 'ok'
    END                                                 AS situacao
FROM backup_mgmt.backup_log
GROUP BY db_name
ORDER BY horas_desde_ultimo_backup DESC NULLS FIRST;


-- ============================================================
-- 3. Crescimento do tamanho dos backups ao longo do tempo
-- ============================================================
SELECT
    DATE(started_at)    AS data,
    db_name,
    ROUND(size_mb, 0)   AS tamanho_mb,
    -- crescimento em relação ao dia anterior
    ROUND(
        size_mb - LAG(size_mb) OVER (PARTITION BY db_name ORDER BY started_at)
    , 0)                AS variacao_mb
FROM backup_mgmt.backup_log
WHERE status = 'SUCCESS'
  AND started_at > NOW() - INTERVAL '30 days'
ORDER BY db_name, data;


-- ============================================================
-- 4. Falhas recentes com detalhes
-- ============================================================
SELECT
    started_at,
    db_name,
    hostname,
    notes,
    backup_file
FROM backup_mgmt.backup_log
WHERE status = 'FAILED'
  AND started_at > NOW() - INTERVAL '30 days'
ORDER BY started_at DESC;


-- ============================================================
-- 5. Histórico de restores (auditoria)
-- ============================================================
SELECT
    started_at,
    db_name,
    backup_file,
    hostname,
    notes
FROM backup_mgmt.backup_log
WHERE status = 'RESTORED'
ORDER BY started_at DESC;


-- ============================================================
-- 6. Verifica se o backup de ontem rodou (útil em alertas)
--    Retorna 1 linha por banco que NÃO teve backup nas últimas 24h
-- ============================================================
SELECT
    DISTINCT b.db_name,
    'SEM BACKUP NAS ÚLTIMAS 24H'  AS alerta
FROM backup_mgmt.backup_log b
WHERE NOT EXISTS (
    SELECT 1
    FROM backup_mgmt.backup_log b2
    WHERE b2.db_name = b.db_name
      AND b2.status = 'SUCCESS'
      AND b2.started_at > NOW() - INTERVAL '24 hours'
)
ORDER BY b.db_name;
-- resultado vazio = tudo em dia
