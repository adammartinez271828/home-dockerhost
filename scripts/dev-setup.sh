#!/usr/bin/env bash
# Dev-machine setup for working ON home-dockerhost from a clone that does NOT
# host the stack (a laptop, a Mac, etc.). For the Pi that runs the containers,
# use scripts/setup.sh instead.
#
# Enables the git pre-commit hook for this clone and checks that its tooling
# (shellcheck + the Docker Compose plugin) is present, printing an install hint
# per detected package manager for anything missing. Safe to re-run.
set -u

cd "$(git rev-parse --show-toplevel)" || exit 1

# enable the repo's pre-commit hook (shellcheck + docker compose config) here
git config core.hooksPath .githooks
echo "hook enabled (core.hooksPath=.githooks)"

# print the install command for $1/$2/$3/$4 = pacman/apt/dnf/brew package name
pkg_hint() {
	if   command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S $1"
	elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y $2"
	elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y $3"
	elif command -v brew    >/dev/null 2>&1; then echo "brew install $4"
	else echo "install it via your package manager"
	fi
}

# the linter for the shell scripts
if command -v shellcheck >/dev/null 2>&1; then
	echo "✓ shellcheck $(shellcheck --version | awk '/^version:/ {print $2}')"
else
	echo "✗ shellcheck missing — install with:"
	echo "    $(pkg_hint shellcheck shellcheck shellcheck shellcheck)"
fi

# docker compose v2 plugin: validates docker-compose.yml
if docker compose version >/dev/null 2>&1; then
	echo "✓ $(docker compose version | head -1)"
else
	echo "✗ docker compose missing — install with:"
	echo "    $(pkg_hint docker-compose docker-compose-plugin docker-compose-plugin docker-compose)"
fi
