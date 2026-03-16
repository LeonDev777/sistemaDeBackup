# Guia de Restauração

**Leia isso antes de precisar. Não na hora da emergência.**

Tem dois cenários principais cobertos aqui:
1. Restauração completa do banco (mais comum)
2. Point-in-Time Recovery — restaurar até um momento específico

---

## Cenário 1: Restauração completa

### Quando usar
- Banco corrompido
- Dados deletados acidentalmente
- Migração para novo servidor
- Criar cópia de produção em homologação

### Passo a passo

**1. Encontre o backup certo**

```bash
# lista os backups disponíveis
./restore/restore.sh --list
```

Saída exemplo:
```
  2025-03-15 02:00:12  847MB  meu_banco_20250315_020012.dump
  2025-03-14 02:00:08  845MB  meu_banco_20250314_020008.dump
  2025-03-13 02:00:11  842MB  meu_banco_20250313_020011.dump
```

**2. Verifique a integridade do arquivo**

```bash
./restore/restore.sh \
    --verify \
    --file /var/backups/postgresql/meu_banco/meu_banco_20250315_020012.dump
```

**3. Restaure em banco de teste primeiro**

Nunca restaure direto em produção sem testar antes. Cria um banco de homolog e testa:

```bash
./restore/restore.sh \
    --file /var/backups/postgresql/meu_banco/meu_banco_20250315_020012.dump \
    --target meu_banco_homolog
```

Verifique os dados:

```bash
psql -U postgres -d meu_banco_homolog -c "SELECT COUNT(*) FROM tabela_importante;"
psql -U postgres -d meu_banco_homolog -c "\dt"  # lista as tabelas
```

**4. Restaure em produção (se necessário)**

```bash
./restore/restore.sh \
    --file /var/backups/postgresql/meu_banco/meu_banco_20250315_020012.dump \
    --target meu_banco
```

O script vai pedir confirmação digitando o nome do banco.

---

## Cenário 2: Restaurar tabela específica (sem derrubar o banco inteiro)

Se só uma tabela foi deletada ou corrompida, você não precisa restaurar o banco inteiro.

```bash
# restaura só a tabela orders de um backup específico
PGPASSWORD=$DB_PASSWORD pg_restore \
    --host=localhost \
    --username=postgres \
    --dbname=meu_banco \
    --table=orders \
    --no-owner \
    --data-only \
    /var/backups/postgresql/meu_banco/meu_banco_20250315_020012.dump
```

**Atenção:** `--data-only` restaura só os dados, não a estrutura da tabela. Se a tabela foi droppada, remove o `--data-only`.

---

## Cenário 3: Point-in-Time Recovery (PITR)

Use quando precisar restaurar o banco para um momento exato: "quero o banco como estava às 14h32 de ontem".

Exige que o backup incremental + WAL archiving estejam configurados.

**Pré-requisito: listar os backups base disponíveis**

```bash
ls -la /var/backups/postgresql/ | grep basebackup
```

**Executa o PITR**

```bash
./restore/restore_point.sh \
    --base /var/backups/postgresql/basebackup_20250315_010000 \
    --target-time "2025-03-15 14:32:00" \
    --target-dir /var/lib/postgresql/restored_data
```

O script prepara o diretório. Depois:

```bash
# para o PostgreSQL
systemctl stop postgresql

# substitui o data dir (sempre mantém o original com .old por segurança)
mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main.bak
mv /var/lib/postgresql/restored_data /var/lib/postgresql/14/main
chown -R postgres:postgres /var/lib/postgresql/14/main

# inicia — vai entrar em modo recovery
systemctl start postgresql

# acompanha o recovery
tail -f /var/log/postgresql/postgresql-14-main.log
```

Quando aparecer `database system is ready to accept connections`, o recovery terminou.

---

## Comandos úteis pós-restore

```bash
# verifica quantas tabelas foram restauradas
psql -U postgres -d meu_banco -c "
SELECT schemaname, COUNT(*) AS tabelas
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
GROUP BY schemaname;"

# verifica se as sequences estão corretas (importante após restore de dados)
psql -U postgres -d meu_banco -c "
SELECT sequence_name, last_value
FROM information_schema.sequences s
JOIN pg_sequences ps ON ps.sequencename = s.sequence_name;"

# reindex se necessário (após restore muito grande)
# psql -U postgres -d meu_banco -c "REINDEX DATABASE meu_banco;"

# analyze pra atualizar estatísticas do planner
psql -U postgres -d meu_banco -c "ANALYZE VERBOSE;"
```

---

## Checklist pós-restore

Antes de apontar a aplicação pro banco restaurado:

- [ ] Verificou contagem de registros nas tabelas principais?
- [ ] Testou login de usuário?
- [ ] Rodou as queries mais comuns da aplicação?
- [ ] Verificou se as sequences estão corretas (evita conflito de ID)?
- [ ] Notificou a equipe sobre a janela de manutenção?
- [ ] Registrou o incidente e a causa raiz?

---

## Se o pg_restore der erro

Erros comuns e o que fazer:

**`role "app_user" does not exist`**
Normal quando restaurando num servidor diferente. Use `--no-owner --no-privileges` (já incluído no restore.sh).

**`ERROR: duplicate key value violates unique constraint`**
O banco destino já tem dados. Se for intencional, adicione `--clean` ao comando manual. O restore.sh já usa `--clean` por padrão.

**`pg_restore: error: could not execute query`**
Verifica o arquivo de log detalhado (`logs/restore.log`). Muitas vezes é só warning de extensão não instalada — não é bloqueante.

**O restore está demorando muito**
Normal pra bancos grandes. Aumenta o `--jobs` se tiver disco rápido (SSD):
```bash
./restore/restore.sh --file backup.dump --jobs 4
```
