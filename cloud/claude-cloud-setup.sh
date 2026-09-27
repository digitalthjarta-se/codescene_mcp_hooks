#!/bin/bash
# Setup script for a Claude Code cloud environment (claude.ai/code > environment > Setup script).
# Runs as root on Ubuntu before Claude starts. Must exit 0 and finish in about 5 minutes.
# Needs network access to downloads.codescene.io and devtools.codescene.io (see README).
curl -fsSL https://downloads.codescene.io/enterprise/cli/install-cs-tool.sh | sh -s -- -y || true
ln -sf "$HOME/.local/bin/cs" /usr/local/bin/cs || true
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq; } || true
cs version || true
