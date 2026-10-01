@echo off
setlocal

rem ============================================================================
rem Configuration : remplacez la valeur ci-dessous par l'URL de votre dépôt Git.
rem ============================================================================
set "REPO_URL=https://github.com/Loic-Lemarchand/SmartRecipes.git"
set "BRANCH=main"
set "RC=0"

rem Vérification de l'URL avant toute opération Git.
if not defined REPO_URL (
    echo ERREUR : REPO_URL est vide. Editez setup-git.bat et renseignez l'URL du depot distant.
    set "RC=1"
    goto :END
)
if /i "%REPO_URL%"=="REMPLACEZ_PAR_URL_DU_DEPOT_GIT" (
    echo ERREUR : remplacez le placeholder REPO_URL par l'URL du depot distant.
    set "RC=1"
    goto :END
)

rem Vérification de la présence de Git dans le PATH.
where git >nul 2>&1
if errorlevel 1 (
    echo ERREUR : Git est requis mais n'a pas ete trouve dans le PATH.
    set "RC=1"
    goto :END
)

rem Le script travaille dans le dossier courant, comme le script PowerShell.
if not exist ".git\" (
    echo Initialisation du depot Git...
    git init -b "%BRANCH%"
    if errorlevel 1 (
        echo ERREUR : impossible d'initialiser le depot Git.
        set "RC=1"
        goto :END
    )
)

rem Ajouter origin uniquement s'il n'existe pas encore.
git remote get-url origin >nul 2>&1
if errorlevel 1 (
    git remote add origin "%REPO_URL%"
    if errorlevel 1 (
        echo ERREUR : impossible d'ajouter le remote origin.
        set "RC=1"
        goto :END
    )
)

rem Commit initial des modifications locales, s'il y en a.
git status --porcelain | findstr /r /c:"." >nul 2>&1
if not errorlevel 1 (
    git add -A
    if errorlevel 1 (
        echo ERREUR : impossible d'indexer les fichiers locaux.
        set "RC=1"
        goto :END
    )
    git commit -m "Initial Android and Wear OS project"
    if errorlevel 1 (
        echo ERREUR : impossible de creer le commit initial.
        set "RC=1"
        goto :END
    )
)

rem Recuperer la branche distante. Un echec est non bloquant, comme en PowerShell.
git fetch origin "%BRANCH%" >nul 2>&1
if errorlevel 1 (
    echo AVERTISSEMENT : impossible de recuperer origin/%BRANCH%. La suite continue.
    ver >nul
)

rem Fusionner uniquement si la branche distante existe localement apres le fetch.
git show-ref --verify --quiet "refs/remotes/origin/%BRANCH%"
if not errorlevel 1 (
    git merge --allow-unrelated-histories --no-edit "origin/%BRANCH%"
    if errorlevel 1 (
        rem En cas de conflit README.md UU ou AA, conserver la version locale.
        git status --porcelain | findstr /r /c:"^UU README.md$" /c:"^AA README.md$" >nul 2>&1
        if not errorlevel 1 (
            echo Conflit README detecte : conservation du README local.
            git checkout --ours -- README.md
            if errorlevel 1 (
                echo ERREUR : impossible de conserver le README local.
                set "RC=1"
                goto :END
            )
            git add README.md
            if errorlevel 1 (
                echo ERREUR : impossible d'indexer README.md.
                set "RC=1"
                goto :END
            )
            git commit --no-edit
            if errorlevel 1 (
                echo ERREUR : impossible de finaliser la fusion du README.
                set "RC=1"
                goto :END
            )
        ) else (
            echo ERREUR : fusion interrompue. Resolvez les conflits, puis executez :
            echo         git add ... ^&^& git commit
            set "RC=1"
            goto :END
        )
    )
)

git branch -M "%BRANCH%"
if errorlevel 1 (
    echo ERREUR : impossible de renommer la branche en %BRANCH%.
    set "RC=1"
    goto :END
)

git push -u origin "%BRANCH%"
if errorlevel 1 (
    echo ERREUR : echec de la publication vers origin/%BRANCH%.
    set "RC=1"
    goto :END
)

echo Depot initialise et synchronise avec %REPO_URL%

:END
echo.
if "%RC%"=="0" (
    echo Operation terminee avec succes.
) else (
    echo Operation terminee avec des erreurs.
)
pause
exit /b %RC%
