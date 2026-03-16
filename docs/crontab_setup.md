# Agendamento de backups com cron

Como configurar os backups pra rodar automaticamente.

---

## Editar o crontab

```bash
# como usuário postgres (recomendado)
sudo -u postgres crontab -e

# ou como o usuário que roda os scripts
crontab -e
```

---

## Configurações sugeridas

Cole isso no crontab. Ajuste os caminhos conforme seu ambiente.

```cron
# ============================================================
# pg-backup-system — agendamento de backups
# ============================================================

# variáveis (nem todo cron herda as variáveis do shell)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# backup completo todo dia às 02:00
# redireciona stderr pro mesmo arquivo de log pra não perder nada
0 2 * * * /opt/pg-backup-system/scripts/backup.sh >> /var/log/pg-backup.log 2>&1

# limpeza de backups antigos toda segunda às 03:30
# roda depois do backup, nunca antes
30 3 * * 1 /opt/pg-backup-system/scripts/cleanup.sh >> /var/log/pg-backup.log 2>&1

# backup incremental (pg_basebackup) todo domingo às 01:00
# mais pesado, roda só uma vez por semana
0 1 * * 0 /opt/pg-backup-system/scripts/backup_incremental.sh >> /var/log/pg-backup-incremental.log 2>&1
```

---

## Múltiplos bancos

Se você tem mais de um banco pra fazer backup, cria entradas separadas passando `-d`:

```cron
# banco de produção às 02:00
0 2 * * * DB_NAME=producao /opt/pg-backup-system/scripts/backup.sh >> /var/log/pg-backup-prod.log 2>&1

# banco de analytics às 02:30 (evita concorrência)
30 2 * * * DB_NAME=analytics /opt/pg-backup-system/scripts/backup.sh >> /var/log/pg-backup-analytics.log 2>&1
```

---

## Evitando concorrência

Se o backup demorar mais que o intervalo entre execuções, duas instâncias podem rodar ao mesmo tempo e sobrecarregar o servidor. Use `flock` pra evitar isso:

```cron
0 2 * * * flock -n /tmp/pg-backup.lock /opt/pg-backup-system/scripts/backup.sh >> /var/log/pg-backup.log 2>&1
```

O `-n` faz o segundo processo sair imediatamente (não-bloqueante) se o lock já está ocupado.

---

## Verificando se o cron está rodando

```bash
# lista o crontab atual
crontab -l

# verifica se o crond está rodando
systemctl status cron    # Debian/Ubuntu
systemctl status crond   # RHEL/CentOS

# vê os últimos registros de execução do cron no syslog
grep CRON /var/log/syslog | tail -20
```

---

## Alternativa: systemd timer

Se preferir systemd ao cron (mais moderno, melhor integração com logs):

Crie `/etc/systemd/system/pg-backup.service`:

```ini
[Unit]
Description=PostgreSQL Backup
After=network.target postgresql.service

[Service]
Type=oneshot
User=postgres
WorkingDirectory=/opt/pg-backup-system
EnvironmentFile=/opt/pg-backup-system/.env
ExecStart=/opt/pg-backup-system/scripts/backup.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pg-backup
```

Crie `/etc/systemd/system/pg-backup.timer`:

```ini
[Unit]
Description=Roda pg-backup todo dia às 02:00
Requires=pg-backup.service

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Ativa e inicia:

```bash
systemctl daemon-reload
systemctl enable pg-backup.timer
systemctl start pg-backup.timer

# verifica
systemctl list-timers pg-backup.timer
journalctl -u pg-backup.service -f
```

A vantagem do systemd timer é que se o servidor estava desligado no horário agendado, ele roda quando ligar (por causa do `Persistent=true`).

---

## Verificando se o backup rodou

```bash
# verifica o log
tail -100 /var/log/pg-backup.log

# ou consulta no banco
psql -U postgres -d meu_banco -c "
SELECT started_at, status, size_mb, duration_sec
FROM backup_mgmt.backup_log
ORDER BY started_at DESC
LIMIT 10;"
```

---

## Alerta se o backup não rodar

Adiciona isso ao final do crontab pra receber e-mail se algo falhar silenciosamente:

```cron
# envia e-mail se não houver backup nas últimas 25 horas
0 3 * * * psql -U postgres -d meu_banco -tAc \
    "SELECT CASE WHEN COUNT(*) = 0 THEN 'ALERTA: sem backup nas últimas 25h' END \
     FROM backup_mgmt.backup_log \
     WHERE status='SUCCESS' AND started_at > NOW() - INTERVAL '25 hours'" \
    | grep -v '^$' | mail -s "[BACKUP] Verificação diária" seu@email.com 2>/dev/null
```
