# Common operations for the home dockerhost. Run from the repo root on the Pi.
# `make` or `make help` lists targets.

COMPOSE := docker compose
BACKUP_KEEP_DAYS ?= 30

.DEFAULT_GOAL := help
.PHONY: help up down restart pull update ps logs caddy-reload \
        mdns-install mdns-restart mdns-status backup-db backup-prune

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## Start / refresh the whole stack
	$(COMPOSE) up -d

down: ## Stop and remove the stack (and any orphaned containers)
	$(COMPOSE) down --remove-orphans

restart: ## Restart all services
	$(COMPOSE) restart

pull: ## Pull newer images
	$(COMPOSE) pull

update: pull up ## Pull newer images and apply them

ps: ## Show service status
	$(COMPOSE) ps

logs: ## Follow logs (all, or one service: make logs S=caddy)
	$(COMPOSE) logs -f $(S)

caddy-reload: ## Reload Caddy after editing the Caddyfile (no downtime)
	$(COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile

mdns-install: ## Install + enable the mDNS alias service (one-time, sudo)
	sudo cp mdns-aliases/mdns-aliases.service /etc/systemd/system/mdns-aliases.service
	sudo systemctl daemon-reload
	sudo systemctl enable --now mdns-aliases.service

mdns-restart: ## Restart the mDNS alias service (after editing mdns-aliases/aliases)
	sudo systemctl restart mdns-aliases.service

mdns-status: ## Show mDNS alias service status
	systemctl status mdns-aliases.service --no-pager

backup-db: ## Dump the recipes Postgres DB into backups/
	@mkdir -p backups
	$(COMPOSE) exec -T db_recipes pg_dumpall -U djangouser > backups/recipes-`date +%Y%m%d-%H%M%S`.sql
	@echo "Wrote backup to backups/"

backup-prune: ## Delete DB backups older than BACKUP_KEEP_DAYS (default 30)
	@find backups -name 'recipes-*.sql' -type f -mtime +$(BACKUP_KEEP_DAYS) -print -delete 2>/dev/null || true
	@echo "Pruned backups older than $(BACKUP_KEEP_DAYS) days"
