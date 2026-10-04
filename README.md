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

## Design du logiciel 
Application de recettes. La principale fonctionnalité de l'application est de permettre à l'utilisateur de parser automatiquement et facilement une recette trouvee et de la stocker dans cette application sur le cloud. Les source possibles mais ne s'y limitent pas si tu as d'autres idés/proposition sont les suivante : Reseau sociaux via un partage - Image donc nécessité de passer par un ocr, je ne sais pas s'il y a des libs kotlins qui permettent cela. - via un texte copié collé. - via un lien d'une page web. DDans tout ces cas de figures une IA doit parser rapidement et efficacement les différent éléments de l'entrée pour produire une recette avec une image, des ingredients et des étapes pour la réalisation de la recette. L'applic doit permettre de créé des "Collection" de recettes, donc de crééer des catégories. De produire, à partir de recette sélectionnés, une liste de course avec tout les ingrédients adaptés.

L'application wear os doit permettre surtout de consulter les recettes et d'avoir au poignet les recettes que l'on a créé