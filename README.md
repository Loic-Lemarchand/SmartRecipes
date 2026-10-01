# Android + Wear OS Hello

Projet multi-module prêt à ouvrir dans Android Studio : une application téléphone/tablette (`app`) et une application Wear OS standalone (`wear`).

## Prérequis
- Android Studio dernière version stable.
- JDK 17 ou supérieur (Android Studio peut fournir son JDK embarqué).
- Dans SDK Manager : Android SDK Platform 36 et les outils nécessaires.
- Pour la montre : une image système Wear OS et un appareil virtuel Wear OS.

## Ouvrir et lancer
1. Ouvrir le dossier `android-wearos-hello` dans Android Studio et laisser la synchronisation Gradle se terminer.
2. Créer/sélectionner un émulateur téléphone dans **Device Manager**, puis choisir la configuration `app` et lancer.
3. Créer un **Wear OS Virtual Device** dans **Device Manager**, sélectionner la configuration `wear`, puis lancer.

Aucun SDK Android n'est requis sur la machine qui génère ce squelette ; la compilation et l'exécution se font dans Android Studio avec le SDK installé.

## Initialiser Git
Les scripts à la racine sont volontairement configurés par une variable en tête de fichier :

- Bash : éditer `REPO_URL` dans `setup-git.sh`, puis `bash setup-git.sh`.
- PowerShell : éditer `$REPO_URL` dans `setup-git.ps1`, puis `./setup-git.ps1`.

Ils sont réexécutables : ils traitent un dépôt distant vide ou déjà initialisé (par exemple avec un README), tentent une fusion propre et s'arrêtent avec des instructions explicites si un conflit reste à résoudre.
