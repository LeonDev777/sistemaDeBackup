# pg-backup-system

Scripts de backup e restore para PostgreSQL. Desenvolvido pra uso em ambientes de produção onde você precisa de algo confiável, simples de manter e fácil de entender 
Nada de frameworks exóticos, nada de dependências desnecessárias. Shell script + pg_dump + cron. Funciona.

---

## O que tem aqui

```
pg-backup-system/
│
├── scripts/
│   ├── backup.sh           # backup completo (full dump)
│   ├── backup_incremental.sh # WAL archiving / incremental
│   └── cleanup.sh          # remove backups antigos
│
├── restore/
│   ├── restore.sh          # restauração completa
│   └── restore_point.sh    # restaura até um ponto no tempo (PITR)
│
├── config/
│   └── backup.conf         # configurações centralizadas
│
├── sql/
│   ├── create_log_table.sql # tabela de log de backups
│   └── backup_report.sql   # queries de análise dos logs
│
├── logs/                   # logs gerados (gitignored)
├── docs/
│   ├── crontab_setup.md    # como agendar os backups
│   └── restore_guide.md    # guia de restauração passo a passo
│
├── .env.example
└── README.md
```

---

## Pré-requisitos

- PostgreSQL 12+ (client tools: `pg_dump`, `pg_restore`, `psql`)
- Bash 4+
- Acesso ao servidor onde o banco roda (ou pg_hba.conf configurado pro seu IP)
- Espaço em disco. Bastante espaço em disco.

---

## Instalação rápida

```bash
git clone https://github.com/seu-usuario/pg-backup-system.git
cd pg-backup-system

# copia e preenche as configurações
cp .env.example .env
nano .env   # ou vim, ou o editor que preferir

# dá permissão de execução nos scripts
chmod +x scripts/*.sh restore/*.sh

# cria a tabela de log no banco
psql -U postgres -d seu_banco -f sql/create_log_table.sql

# testa o backup
./scripts/backup.sh
```

---

## Configuração

Edite o `.env` ou o `config/backup.conf`:

```bash
DB_HOST=localhost
DB_PORT=5432
DB_NAME=meu_banco
DB_USER=backup_user
DB_PASSWORD=senha_aqui

BACKUP_DIR=/var/backups/postgresql
RETENTION_DAYS=30
COMPRESS=true
```

**Importante:** nunca suba o `.env` com credenciais reais pro GitHub. O `.gitignore` já trata disso, mas vale o aviso.

---

## Uso

### Backup manual

```bash
# backup completo do banco
./scripts/backup.sh

# backup de um banco específico
./scripts/backup.sh -d outro_banco

# backup sem compressão (quando o disco é rápido e você quer restore mais rápido)
./scripts/backup.sh --no-compress
```

### Restore

```bash
# restaura o backup mais recente
./restore/restore.sh --latest

# restaura um backup específico
./restore/restore.sh --file /var/backups/postgresql/meu_banco_20250315_0200.dump

# restaura em outro banco (pra testar sem derrubar o prod)
./restore/restore.sh --file backup.dump --target banco_homolog
```

### Limpeza de backups antigos

```bash
# remove backups mais antigos que RETENTION_DAYS (definido no .env)
./scripts/cleanup.sh

# dry run - só mostra o que seria deletado, sem deletar nada
./scripts/cleanup.sh --dry-run
```

---

## Agendamento com cron

Veja o guia completo em `docs/crontab_setup.md`. Resumo:

```bash
crontab -e
```

```cron
# backup todo dia às 02:00
0 2 * * * /caminho/pg-backup-system/scripts/backup.sh >> /var/log/pg-backup.log 2>&1

# limpeza de backups antigos toda segunda às 03:00
0 3 * * 1 /caminho/pg-backup-system/scripts/cleanup.sh >> /var/log/pg-cleanup.log 2>&1
```

---

## Verificando os logs

```bash
# últimos backups realizados
tail -50 logs/backup.log

# ou consulta no banco
psql -U postgres -d meu_banco -f sql/backup_report.sql
```

---

## Estrutura dos backups gerados

```
/var/backups/postgresql/
├── meu_banco_20250315_0200.dump     # formato custom do pg_dump (comprimido)
├── meu_banco_20250315_0200.dump.sha256  # checksum pra verificar integridade
├── meu_banco_20250314_0200.dump
└── ...
```

O formato `.dump` (custom format do pg_dump) permite restore seletivo de tabelas e é mais eficiente que SQL puro. Pra ter o SQL legível junto, use a flag `--sql` no backup.sh.

---

## Usuário de backup recomendado

Não use o superusuário postgres pra backup em produção. Crie um usuário com permissões mínimas:

```sql
CREATE USER backup_user WITH PASSWORD 'senha_forte';
GRANT CONNECT ON DATABASE meu_banco TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
-- se usar pg_dump precisa de USAGE em todos os schemas também
GRANT USAGE ON SCHEMA public TO backup_user;
```

---

## Em caso de desastre

Calma. Vai em `docs/restore_guide.md`. Tem o passo a passo com os comandos exatos.

---

## Licença

MIT
