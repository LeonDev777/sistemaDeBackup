SHELL := /bin/bash
SCRIPTS := scripts
RESTORE := restore

.PHONY: help setup backup restore-latest restore-list cleanup test-connection

help:
	@echo ""
	@echo "pg-backup-system — comandos disponíveis"
	@echo ""
	@echo "  make setup            cria a tabela de log no banco"
	@echo "  make backup           roda um backup agora"
	@echo "  make restore-list     lista backups disponíveis"
	@echo "  make restore-latest   restaura o backup mais recente"
	@echo "  make cleanup          remove backups antigos"
	@echo "  make cleanup-dry      simula a limpeza sem deletar"
	@echo "  make test-connection  verifica se o banco está acessível"
	@echo "  make chmod            dá permissão de execução nos scripts"
	@echo ""

chmod:
	chmod +x $(SCRIPTS)/*.sh $(RESTORE)/*.sh

setup: chmod
	@if [ ! -f .env ]; then echo "Erro: .env não encontrado. Copie .env.example."; exit 1; fi
	@source .env && psql -h $$DB_HOST -p $$DB_PORT -U $$DB_USER -d $$DB_NAME \
		-f sql/create_log_table.sql

backup: chmod
	$(SCRIPTS)/backup.sh

restore-list: chmod
	$(RESTORE)/restore.sh --list

restore-latest: chmod
	$(RESTORE)/restore.sh --latest

cleanup: chmod
	$(SCRIPTS)/cleanup.sh

cleanup-dry: chmod
	$(SCRIPTS)/cleanup.sh --dry-run

test-connection:
	@if [ ! -f .env ]; then echo "Erro: .env não encontrado."; exit 1; fi
	@source .env && PGPASSWORD=$$DB_PASSWORD psql \
		-h $$DB_HOST -p $$DB_PORT -U $$DB_USER -d $$DB_NAME \
		-c "SELECT version();" \
		&& echo "Conexão OK" || echo "Falha na conexão"
