#!/bin/bash
# Refuse a commit that adds anything shaped like a credential. Wired by:
#   git config core.hooksPath .githooks
set -u
patterns='sk-[A-Za-z0-9_-]{20,}|sk-proj-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|apiKey *= *"[^"]+"|Bearer [A-Za-z0-9._-]{20,}'
hits=$(git diff --cached -U0 --no-color -- . ':(exclude)scripts/precommit-secrets.sh' | grep -E '^\+' | grep -v '^+++' | grep -nE "$patterns" || true)
if [ -n "$hits" ]; then
  echo "precommit-secrets: refusing to commit something that looks like a key:" >&2
  echo "$hits" | cut -c1-160 >&2
  exit 1
fi
