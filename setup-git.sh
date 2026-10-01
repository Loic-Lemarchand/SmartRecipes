#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Loic-Lemarchand/SmartRecipes.git" # Collez ici l'URL du dépôt distant, puis relancez le script.
BRANCH="main"

if [[ -z "$REPO_URL" ]]; then
  echo "REPO_URL est vide : éditez setup-git.sh et renseignez l'URL du dépôt distant." >&2
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then echo "Git est requis." >&2; exit 2; fi
if [[ ! -d .git ]]; then git init -b "$BRANCH"; fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REPO_URL"
if [[ -n "$(git status --porcelain)" ]]; then git add -A && git commit -m "Initial Android and Wear OS project"; fi
git fetch origin "$BRANCH" 2>/dev/null || true
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git merge --allow-unrelated-histories --no-edit "origin/$BRANCH" || {
    if git status --porcelain | grep -Eq '^(UU|AA) README.md$'; then
      echo "Conflit README détecté : conservation du README local."
      git checkout --ours -- README.md
      git add README.md
      git commit --no-edit
    else
      echo "Fusion interrompue : résolvez les conflits, puis exécutez 'git add ... && git commit'." >&2
      exit 1
    fi
  }
fi
git branch -M "$BRANCH"
git push -u origin "$BRANCH"
echo "Dépôt initialisé et synchronisé avec $REPO_URL"
