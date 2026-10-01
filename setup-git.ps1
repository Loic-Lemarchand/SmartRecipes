$ErrorActionPreference = "Stop"

$REPO_URL = "https://github.com/Loic-Lemarchand/SmartRecipes.git"
$BRANCH = "main"

if ([string]::IsNullOrWhiteSpace($REPO_URL)) { throw "REPO_URL est vide : éditez setup-git.ps1 et renseignez l'URL du dépôt distant." }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git est requis." }
if (-not (Test-Path ".git")) { git init -b $BRANCH }
if (-not (git remote get-url origin 2>$null)) { git remote add origin $REPO_URL }
if ((git status --porcelain)) { git add -A; git commit -m "Initial Android and Wear OS project" }
git fetch origin $BRANCH 2>$null; if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
$remoteBranch = git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; if ($LASTEXITCODE -eq 0) {
  git merge --allow-unrelated-histories --no-edit "origin/$BRANCH"
  if ($LASTEXITCODE -ne 0) {
    $readmeConflict = git status --porcelain | Select-String '^(UU|AA) README.md$'
    if ($readmeConflict) {
      Write-Host "Conflit README détecté : conservation du README local."
      git checkout --ours -- README.md; git add README.md; git commit --no-edit
    } else { throw "Fusion interrompue : résolvez les conflits, puis exécutez 'git add ...; git commit'." }
  }
}
git branch -M $BRANCH
git push -u origin $BRANCH
Write-Host "Dépôt initialisé et synchronisé avec $REPO_URL"
