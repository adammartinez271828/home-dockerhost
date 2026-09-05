# Common operations for the home dockerhost. Run from the repo root on the Pi.
# Backup/restore runbook: docs/backup-restore.md
# `make` or `make help` lists targets.

COMPOSE := docker compose
BACKUP_KEEP_DAYS ?= 30
# Kinboard is a separate compose project driven by upstream's start.sh (kinboard/README.md).
KINBOARD_DIR := kinboard/upstream/webapp/docker

.DEFAULT_GOAL := help
.PHONY: help up down restart pull update ps logs caddy-reload \
        smokeping-targets beszel-key \
        mdns-install mdns-restart mdns-status \
        backup-db backup-cloud backup-list backup-prune backup-install backup-status \
        restore-test restore-test-clean dev-setup \
        kinboard-up kinboard-status kinboard-logs

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

caddy-reload: ## Reload Caddy after editing caddy/Caddyfile (no downtime)
	$(COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile

smokeping-targets: ## Apply tracked smokeping/Targets to the prober and restart it
	@test -d smokeping/config || { echo "smokeping/config not found - run 'make up' first so SmokePing creates it"; exit 1; }
	cp smokeping/Targets smokeping/config/Targets
	$(COMPOSE) restart smokeping
	@echo "Applied smokeping/Targets and restarted SmokePing"

beszel-key: ## Print the Beszel hub's public key (paste into env.d/beszel.env as KEY=)
	@$(COMPOSE) exec beszel cat /beszel_data/id_ed25519.pub

mdns-install: ## Install + enable the mDNS alias service (one-time, sudo)
	sed 's|^ExecStart=.*|ExecStart=$(CURDIR)/mdns-aliases/mdns-aliases.sh|' \
		mdns-aliases/mdns-aliases.service \
		| sudo tee /etc/systemd/system/mdns-aliases.service >/dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable --now mdns-aliases.service

mdns-restart: ## Restart the mDNS alias service (after editing mdns-aliases/aliases)
	sudo systemctl restart mdns-aliases.service

mdns-status: ## Show mDNS alias service status
	systemctl status mdns-aliases.service --no-pager

backup-db: ## Dump the recipes Postgres DB into backups/ (local only)
	@./scripts/db-backup.sh

backup-cloud: ## Dump + upload to the cloud remote (what the nightly timer runs)
	@./scripts/db-backup.sh --upload

backup-list: ## List the DB dumps held on the cloud remote
	@./scripts/db-restore.sh --list

backup-prune: ## Delete local DB backups older than BACKUP_KEEP_DAYS (default 30)
	@find backups -maxdepth 1 \( -name 'recipes-*.dump' -o -name 'recipes-*.sql' -o -name 'kinboard-*.dump' \) -type f -mtime +$(BACKUP_KEEP_DAYS) -print -delete 2>/dev/null || true
	@echo "Pruned local backups older than $(BACKUP_KEEP_DAYS) days"

backup-install: ## Install + enable the nightly cloud-backup systemd timer (one-time, sudo)
	sed -e 's|^User=.*|User=$(shell id -un)|' \
	    -e 's|^WorkingDirectory=.*|WorkingDirectory=$(CURDIR)|' \
	    -e 's|^ExecStart=.*|ExecStart=$(CURDIR)/scripts/db-backup.sh --upload|' \
	    cloud-backup/cloud-backup.service \
	    | sudo tee /etc/systemd/system/cloud-backup.service >/dev/null
	sudo cp cloud-backup/cloud-backup.timer /etc/systemd/system/cloud-backup.timer
	sudo systemctl daemon-reload
	sudo systemctl enable --now cloud-backup.timer
	systemctl list-timers cloud-backup.timer --no-pager

backup-status: ## Show the backup timer's next run and the last run's log
	@systemctl list-timers cloud-backup.timer --no-pager
	@journalctl -u cloud-backup.service -n 30 --no-pager

restore-test: ## Fetch the newest cloud dump and restore it into a throwaway DB container (F=file or N=name to pick one)
	@if [ -n "$(F)" ]; then ./scripts/db-restore.sh "$(F)"; else ./scripts/db-restore.sh --from-cloud $(N); fi

restore-test-clean: ## Remove the throwaway restore-test DB container
	docker rm -f con_db_restoretest

kinboard-up: ## Start / refresh the Kinboard stack (upstream start.sh up)
	@test -f $(KINBOARD_DIR)/.env || { echo "$(KINBOARD_DIR)/.env not found - see kinboard/README.md (git submodule update --init; setup.sh)"; exit 1; }
	cd $(KINBOARD_DIR) && ./start.sh up

kinboard-status: ## Show Kinboard container state
	cd $(KINBOARD_DIR) && ./start.sh status

kinboard-logs: ## Follow Kinboard logs (all, or one service: make kinboard-logs S=webapp)
	cd $(KINBOARD_DIR) && ./start.sh logs $(S)

dev-setup: ## Set up a dev clone: enable pre-commit hooks + check tooling (one-time)
	@./scripts/dev-setup.sh
