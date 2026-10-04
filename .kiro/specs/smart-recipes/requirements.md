# Document d'exigences : SmartRecipes (Android + Wear OS) — V1

## Introduction

SmartRecipes est une application Android (téléphone) et Wear OS (montre) qui centralise les recettes personnelles d'un utilisateur dans le cloud (Supabase). Sa fonction centrale est l'import d'une recette depuis n'importe quelle source (réseau social, page web, image, texte), structurée automatiquement par une IA (Google Gemini Flash, appelée uniquement depuis une Edge Function) en recette propre : titre, image, ingrédients, étapes.

La V1 est une bibliothèque strictement PRIVÉE, avec un coût d'infrastructure de 0 €. La montre sert à consulter les recettes et à cuisiner au poignet ; elle est en lecture seule, sauf pour les états personnels. Le schéma de données et l'architecture V1 préparent une V2 communautaire sans migration destructive, sans rien en exposer.

Source de vérité : `SDD.md` (cahier des charges). En cas de divergence, le SDD prime. Chaque exigence référence les identifiants du SDD (EX-xx, sections §1 à §9). La section §10 du SDD (instructions de travail : requirements → design → tasks, validation utilisateur avant de continuer, ordre de découpage des tâches, chaque tâche compilée et testée) régit le processus et non le produit ; elle n'est donc pas traduite en exigences.

## Glossary

- **Système** : l'ensemble SmartRecipes (app téléphone `app`, app montre `wear`, module `shared`, backend Supabase et Edge Functions).
- **Téléphone** : l'application Android `app`.
- **Montre** : l'application Wear OS `wear`.
- **Cloud** : le projet Supabase (PostgreSQL, Auth, Storage, Edge Functions, Realtime), source de vérité unique.
- **Cache local** : la base Room de chaque appareil.
- **File d'écritures** : la file persistante des écritures locales en attente d'envoi (Room + WorkManager).
- **Données métier** : recettes, ingrédients, étapes, collections, listes de courses, articles, états personnels, profil, préférences.
- **États personnels** : favori, « réalisée », articles cochés de la liste de courses, progression en cours de cuisson (dont l'état « recette en cours »).
- **Code de session appareil** : code à usage unique, valable 60 s, généré par l'Edge Function `create-device-session`.
- **Data Layer** : Wearable Data Layer API (MessageClient, CapabilityClient).
- **Remote Activity** : ouverture d'une activité ou d'une URL sur le téléphone depuis la montre (RemoteActivityHelper).
- **Soft delete** : suppression logique via la colonne `deleted_at`.
- **LWW** : last-write-wins sur la colonne `updated_at`.
- **Dernier sync** : horodatage de la dernière synchronisation incrémentale réussie, stocké par appareil et par table.
- **Import** : traitement d'une entrée (texte, URL, image(s), partage) jusqu'à l'écran de validation.

## Hypothèses (à valider en revue de conception)

- H1 : la valeur du quota quotidien d'imports IA par utilisateur n'est pas fixée par le SDD ; elle est configurable côté serveur et appliquée par l'Edge Function `parse-recipe`.
- H2 : les seuils de « titre très proche » (EX-08) et de « modifications substantielles » (§8) ne sont pas chiffrés par le SDD ; ils seront définis dans design.md.
- H3 : la fréquence de la synchronisation périodique et les limites de fréquence de `create-device-session` ne sont pas chiffrées ; elles seront définies dans design.md, dans le respect des quotas gratuits.
- H4 : « recette proposée en moins de 10 s » (§4, §7) s'entend hors temps de saisie utilisateur, pour une entrée texte ou URL, réseau normal, mesurée de la soumission à l'affichage de l'écran de validation.
- H5 : sur la montre, les écritures d'états personnels effectuées hors ligne suivent le même mécanisme que le téléphone (file d'écritures + LWW).
- H6 : la déconnexion sur le téléphone efface aussi la session et le cache Room du téléphone (protection de la vie privée ; non explicitement exigé par le SDD).
- H7 : la relance automatique en cas de code expiré (EX-70) est bornée à un nombre maximal de tentatives, défini dans design.md, pour éviter une boucle infinie.
- H8 : l'export RGPD (EX-63) contient toutes les données en JSON ; les images y sont référencées par leur chemin Storage et une URL signée, et non incluses en binaire.
- H9 : les minuteurs du téléphone (EX-45) et de la montre (EX-75) sont locaux à l'appareil qui les lance ; ils ne sont pas synchronisés entre appareils.

## Requirements

_Domaine 1 — Synchronisation et hors ligne_

### Requirement 1: Cloud comme source de vérité unique
Traçabilité : §2.1, EX-71, §7 (Hors ligne)

**User Story:** En tant qu'utilisateur, je veux que mes recettes, collections et listes de courses soient stockées dans le cloud, afin de les retrouver identiques sur mon téléphone et ma montre.

#### Acceptance Criteria
1. THE SYSTEM SHALL utiliser Supabase comme source de vérité unique pour toutes les données métier.
2. WHEN le téléphone écrit une donnée métier, THE SYSTEM SHALL l'envoyer directement du téléphone vers Supabase.
3. WHEN la montre écrit un état personnel, THE SYSTEM SHALL l'envoyer directement de la montre vers Supabase.
4. WHEN le téléphone ou la montre a besoin de données métier absentes du cache local, THE SYSTEM SHALL les lire directement depuis Supabase depuis cet appareil.
5. THE SYSTEM SHALL ne faire transiter aucune donnée métier entre le téléphone et la montre via la Data Layer.
6. THE SYSTEM SHALL maintenir sur le téléphone un cache local Room des données synchronisées.
7. THE SYSTEM SHALL maintenir sur la montre un cache local Room des données synchronisées.
8. WHILE le téléphone est hors ligne, THE SYSTEM SHALL permettre la consultation complète (liste, fiche, mode cuisine, liste de courses) des recettes déjà synchronisées.
9. WHILE la montre est hors ligne, THE SYSTEM SHALL permettre la consultation complète (liste, fiche compacte, mode cuisine, liste de courses) des recettes déjà synchronisées.

### Requirement 2: Écritures hors ligne
Traçabilité : §2.1, §7 (Fiabilité), H5

**User Story:** En tant qu'utilisateur, je veux pouvoir modifier mes recettes et cocher mes états sans réseau, afin de ne pas être bloqué en cuisine ou en magasin.

#### Acceptance Criteria
1. WHEN une écriture est effectuée sur le téléphone sans réseau, THE SYSTEM SHALL l'appliquer immédiatement au cache local.
2. WHEN une écriture est effectuée sur le téléphone sans réseau, THE SYSTEM SHALL l'enregistrer dans la file d'écritures persistante.
3. WHEN un état personnel est modifié sur la montre sans réseau, THE SYSTEM SHALL l'appliquer immédiatement au cache local de la montre et l'enregistrer dans la file d'écritures de la montre.
4. WHEN le réseau redevient disponible, THE SYSTEM SHALL envoyer les écritures en attente au cloud via WorkManager.
5. THE SYSTEM SHALL envoyer les écritures en attente dans leur ordre de création.
6. IF l'envoi d'une écriture échoue pour une erreur réseau ou serveur transitoire, THEN THE SYSTEM SHALL conserver l'écriture dans la file et la réessayer ultérieurement avec un délai croissant.
7. IF l'envoi d'une écriture est rejeté définitivement par le serveur (erreur de validation ou d'autorisation), THEN THE SYSTEM SHALL retirer l'écriture de la file, restaurer la version cloud dans le cache local et signaler l'erreur dans l'indicateur de synchronisation.
8. WHILE des écritures sont en attente, THE SYSTEM SHALL les conserver après fermeture de l'application.
9. WHILE des écritures sont en attente, THE SYSTEM SHALL les conserver après redémarrage de l'appareil.

### Requirement 3: Résolution des conflits (last-write-wins)
Traçabilité : §2.1, §7 (Tests)

**User Story:** En tant qu'utilisateur multi-appareils, je veux que les conflits de modification soient résolus de façon déterministe, afin de ne jamais obtenir de données incohérentes.

#### Acceptance Criteria
1. THE SYSTEM SHALL maintenir une colonne `updated_at` sur chaque table synchronisée.
2. WHEN un enregistrement synchronisé est modifié, THE SYSTEM SHALL mettre à jour sa colonne `updated_at`.
3. WHEN deux versions d'un même enregistrement entrent en conflit, THE SYSTEM SHALL conserver la version dont `updated_at` est le plus récent.
4. WHEN une écriture locale en attente est plus ancienne que la version cloud, THE SYSTEM SHALL appliquer la version cloud au cache local.
5. WHEN une écriture locale en attente est plus ancienne que la version cloud, THE SYSTEM SHALL abandonner l'écriture locale obsolète sans l'envoyer.
6. WHEN deux versions ont exactement le même `updated_at`, THE SYSTEM SHALL appliquer une règle de départage déterministe identique sur tous les appareils.
7. THE SYSTEM SHALL couvrir le moteur de synchronisation par des tests unitaires.
8. THE SYSTEM SHALL couvrir la résolution de conflits LWW par des tests unitaires (version locale plus récente, version cloud plus récente, égalité).

### Requirement 4: Mises à jour rapides et synchronisation incrémentale
Traçabilité : §2.1, §7 (Fiabilité), EX-65

**User Story:** En tant qu'utilisateur, je veux voir rapidement sur un appareil les changements faits sur l'autre, afin de passer de l'un à l'autre sans friction.

#### Acceptance Criteria
1. WHILE l'application est au premier plan et en ligne, THE SYSTEM SHALL s'abonner à Supabase Realtime pour les données de l'utilisateur connecté.
2. WHEN une modification est reçue via Realtime, THE SYSTEM SHALL mettre à jour le cache local.
3. WHEN l'application passe en arrière-plan, THE SYSTEM SHALL se désabonner de Supabase Realtime.
4. WHEN l'application s'ouvre, THE SYSTEM SHALL effectuer une synchronisation incrémentale des enregistrements dont `updated_at` est postérieur au dernier sync.
5. THE SYSTEM SHALL planifier une synchronisation incrémentale périodique via WorkManager, exécutée y compris lorsque l'application est fermée.
6. WHEN une synchronisation incrémentale réussit, THE SYSTEM SHALL enregistrer la nouvelle date de dernier sync.
7. IF une synchronisation incrémentale échoue, THEN THE SYSTEM SHALL conserver la date de dernier sync précédente.
8. THE SYSTEM SHALL configurer la synchronisation périodique de sorte qu'elle sollicite le projet Supabase assez souvent pour éviter sa mise en pause sur l'offre gratuite.

### Requirement 5: Suppressions logiques (soft delete)
Traçabilité : §2.1, §8

**User Story:** En tant qu'utilisateur, je veux qu'une suppression faite sur un appareil disparaisse aussi sur l'autre, afin de garder une bibliothèque cohérente.

#### Acceptance Criteria
1. WHEN l'utilisateur supprime un enregistrement synchronisé, THE SYSTEM SHALL renseigner `deleted_at` au lieu de supprimer physiquement la ligne.
2. WHEN l'utilisateur supprime un enregistrement synchronisé, THE SYSTEM SHALL mettre à jour `updated_at` du même enregistrement.
3. WHEN une synchronisation reçoit un enregistrement dont `deleted_at` est renseigné, THE SYSTEM SHALL le retirer de l'affichage de l'appareil.
4. WHEN une synchronisation reçoit un enregistrement dont `deleted_at` est renseigné, THE SYSTEM SHALL le retirer du cache local de l'appareil.
5. THE SYSTEM SHALL exclure les enregistrements soft-deleted de toutes les listes, recherches, filtres et compteurs.

### Requirement 6: État de synchronisation
Traçabilité : EX-65

**User Story:** En tant qu'utilisateur, je veux savoir si mes données sont à jour et pouvoir forcer une synchronisation, afin d'avoir confiance dans ce que j'affiche.

#### Acceptance Criteria
1. THE SYSTEM SHALL afficher sur le téléphone un indicateur d'état de synchronisation parmi : à jour, en cours, écritures en attente, hors ligne, erreur.
2. WHILE des écritures sont en attente, THE SYSTEM SHALL afficher leur nombre dans l'indicateur.
3. WHEN l'utilisateur déclenche « Synchroniser maintenant », THE SYSTEM SHALL envoyer les écritures en attente, puis effectuer une synchronisation incrémentale.
4. IF la synchronisation échoue, THEN THE SYSTEM SHALL afficher un message d'erreur clair indiquant la cause (réseau, session expirée, quota, serveur).
5. IF la synchronisation échoue, THEN THE SYSTEM SHALL conserver intactes les données locales et les écritures en attente.

_Domaine 2 — Authentification de la montre via le téléphone_

### Requirement 7: Rôle limité de la Data Layer et absence de formulaire sur la montre
Traçabilité : §2.2, §3, EX-70

**User Story:** En tant qu'utilisateur, je veux connecter ma montre sans rien saisir sur son petit écran, afin d'être opérationnel en quelques secondes.

#### Acceptance Criteria
1. THE SYSTEM SHALL utiliser la Data Layer uniquement pour les messages `/auth/request`, `/auth/token`, `/auth/logout` et pour la détection de capacité (CapabilityClient).
2. THE SYSTEM SHALL ne proposer aucun formulaire ni champ de saisie de connexion sur la montre.
3. WHILE la montre n'est pas connectée, THE SYSTEM SHALL afficher sur la montre « Ouvrez SmartRecipes sur votre téléphone ».
4. WHILE la montre n'est pas connectée, THE SYSTEM SHALL afficher sur la montre un bouton « Ouvrir sur le téléphone » qui ouvre l'app téléphone via Remote Activity.
5. WHEN la montre non connectée démarre, THE SYSTEM SHALL envoyer une demande de connexion au téléphone via MessageClient sur le chemin `/auth/request`.
6. WHEN l'utilisateur relance la connexion depuis l'écran d'attente de la montre, THE SYSTEM SHALL envoyer une nouvelle demande `/auth/request`.

### Requirement 8: Génération du code de session appareil
Traçabilité : §2.2, §7 (Sécurité)

**User Story:** En tant qu'utilisateur, je veux que la connexion de ma montre soit sécurisée, afin que personne ne puisse usurper ma session.

#### Acceptance Criteria
1. WHEN le téléphone reçoit `/auth/request` et que l'utilisateur y est connecté, THE SYSTEM SHALL appeler l'Edge Function `create-device-session` avec le JWT de l'utilisateur.
2. IF l'appel à `create-device-session` ne contient pas de JWT valide, THEN THE SYSTEM SHALL refuser la requête (HTTP 401) sans générer de code.
3. IF la fréquence d'appels à `create-device-session` dépasse la limite définie pour un utilisateur, THEN THE SYSTEM SHALL refuser la requête (HTTP 429) sans générer de code.
4. WHEN la requête est valide, THE SYSTEM SHALL générer via l'API admin Supabase un code à usage unique lié à l'utilisateur du JWT.
5. THE SYSTEM SHALL limiter la validité de chaque code de session appareil à 60 secondes après sa génération.
6. IF un code de session appareil déjà utilisé est présenté, THEN THE SYSTEM SHALL le rejeter.
7. IF un code de session appareil est présenté plus de 60 secondes après sa génération, THEN THE SYSTEM SHALL le rejeter.
8. THE SYSTEM SHALL ne jamais écrire le code de session appareil dans les logs de l'Edge Function.
9. THE SYSTEM SHALL ne jamais écrire le code de session appareil dans les logs Android (téléphone et montre).
10. WHEN un code est généré, THE SYSTEM SHALL le transmettre à la montre demandeuse via MessageClient sur le chemin `/auth/token`.

### Requirement 9: Session propre à la montre
Traçabilité : §2.2, §7 (Sécurité)

**User Story:** En tant qu'utilisateur, je veux que ma montre ait sa propre session, afin que mes deux appareils restent connectés indépendamment.

#### Acceptance Criteria
1. WHEN la montre reçoit un code sur `/auth/token`, THE SYSTEM SHALL l'échanger contre une session Supabase propre à la montre (verifyOtp).
2. THE SYSTEM SHALL stocker la session de la montre chiffrée avec une clé protégée par l'Android Keystore.
3. THE SYSTEM SHALL ne jamais transmettre l'access token du téléphone à la montre.
4. THE SYSTEM SHALL ne jamais transmettre le refresh token du téléphone à la montre.
5. WHILE la montre est connectée, THE SYSTEM SHALL lui permettre d'accéder au cloud via Wi-Fi ou LTE sans que le téléphone soit joignable.
6. WHILE la montre est connectée, THE SYSTEM SHALL renouveler la session de la montre depuis la montre elle-même.
7. WHEN le téléphone renouvelle sa propre session, THE SYSTEM SHALL laisser la session de la montre valide.
8. WHEN la montre se connecte avec succès, THE SYSTEM SHALL enregistrer l'appareil dans la table `device_sessions`.
9. IF le renouvellement de la session de la montre échoue définitivement (session révoquée ou expirée), THEN THE SYSTEM SHALL effacer la session et le cache Room de la montre et revenir à l'écran d'attente de connexion.

### Requirement 10: Connexion automatique et cas d'erreur
Traçabilité : §2.2, EX-64, EX-70, H7

**User Story:** En tant qu'utilisateur, je veux que ma montre se connecte toute seule quand je me connecte sur mon téléphone, et être guidé si quelque chose bloque.

#### Acceptance Criteria
1. WHEN l'utilisateur se connecte sur le téléphone et qu'une montre appairée possède l'app installée (détectée via CapabilityClient), THE SYSTEM SHALL générer un code de session et l'envoyer à cette montre sans action de l'utilisateur.
2. IF le téléphone reçoit `/auth/request` alors que l'utilisateur n'y est pas connecté, THEN THE SYSTEM SHALL répondre à la montre que l'utilisateur n'est pas connecté.
3. WHEN la montre reçoit la réponse « utilisateur non connecté », THE SYSTEM SHALL afficher sur la montre « Connectez-vous d'abord sur votre téléphone ».
4. IF aucun téléphone appairé n'est joignable, THEN THE SYSTEM SHALL afficher sur la montre un message indiquant que le téléphone est absent ou hors de portée.
5. IF le téléphone est joignable mais que l'app SmartRecipes n'y est pas installée, THEN THE SYSTEM SHALL l'indiquer sur la montre.
6. IF l'app SmartRecipes n'est pas installée sur le téléphone, THEN THE SYSTEM SHALL proposer sur la montre l'ouverture de la fiche Play Store sur le téléphone via Remote Activity.
7. IF le code de session est expiré ou rejeté lors de l'échange, THEN THE SYSTEM SHALL envoyer automatiquement une nouvelle demande `/auth/request`.
8. IF le nombre maximal de relances automatiques est atteint, THEN THE SYSTEM SHALL cesser les relances et afficher sur la montre un message d'erreur avec un bouton « Réessayer ».
9. IF aucune réponse du téléphone n'est reçue dans le délai défini, THEN THE SYSTEM SHALL afficher sur la montre un message d'expiration avec un bouton « Réessayer ».

### Requirement 11: Déconnexion et appareils connectés
Traçabilité : §2.2, EX-64, H6

**User Story:** En tant qu'utilisateur, je veux pouvoir déconnecter ma montre depuis le téléphone ou depuis la montre, afin de garder le contrôle de mes données.

#### Acceptance Criteria
1. WHEN l'utilisateur se déconnecte sur le téléphone, THE SYSTEM SHALL envoyer `/auth/logout` à la montre via MessageClient.
2. WHEN l'utilisateur se déconnecte sur le téléphone, THE SYSTEM SHALL effacer la session et le cache Room du téléphone.
3. WHEN la montre reçoit `/auth/logout`, THE SYSTEM SHALL effacer la session de la montre.
4. WHEN la montre reçoit `/auth/logout`, THE SYSTEM SHALL effacer le cache Room de la montre.
5. WHEN l'utilisateur se déconnecte depuis la montre, THE SYSTEM SHALL effacer la session et le cache Room de la montre.
6. WHEN l'utilisateur se déconnecte depuis la montre, THE SYSTEM SHALL laisser le téléphone connecté.
7. THE SYSTEM SHALL proposer sur le téléphone un écran « Appareils connectés » listant les montres actives issues de `device_sessions`.
8. WHEN l'utilisateur appuie sur « Déconnecter » pour une montre dans cet écran, THE SYSTEM SHALL révoquer côté serveur la session de cette montre.
9. WHEN l'utilisateur appuie sur « Déconnecter » pour une montre joignable, THE SYSTEM SHALL lui envoyer `/auth/logout`.
10. WHEN une montre est déconnectée depuis cet écran, THE SYSTEM SHALL marquer l'entrée correspondante de `device_sessions` comme révoquée.

### Requirement 12: Prérequis applicationId et signature
Traçabilité : §2.2

**User Story:** En tant que développeur, je veux que les deux apps partagent identifiant et signature, afin que la Data Layer fonctionne.

#### Acceptance Criteria
1. THE SYSTEM SHALL utiliser le même applicationId pour les modules `app` et `wear`.
2. THE SYSTEM SHALL signer `app` et `wear` avec la même clé de signature pour chaque type de build (debug et release).
3. THE SYSTEM SHALL documenter ce prérequis dans le README du projet.

_Domaine 3 — Pipeline d'import et parsing IA_

### Requirement 13: Sources d'import
Traçabilité : EX-01, EX-02, EX-03, EX-04, EX-05, EX-06, §4 (étape 1)

**User Story:** En tant qu'utilisateur, je veux importer une recette depuis n'importe quelle source, afin de tout centraliser sans recopier.

#### Acceptance Criteria
1. WHEN l'utilisateur partage vers SmartRecipes un texte (Intent ACTION_SEND, type text/plain) depuis une autre app, THE SYSTEM SHALL démarrer un import texte ou URL selon le contenu. (EX-01)
2. WHEN le texte partagé contient une URL, THE SYSTEM SHALL démarrer un import URL avec cette URL. (EX-01)
3. WHEN l'utilisateur partage vers SmartRecipes une image (ACTION_SEND) ou plusieurs images (ACTION_SEND_MULTIPLE), THE SYSTEM SHALL démarrer un import image avec toutes les images reçues. (EX-01)
4. THE SYSTEM SHALL accepter les partages provenant de n'importe quelle app (dont Instagram, TikTok, Facebook, Pinterest, YouTube, navigateurs, galerie). (EX-01)
5. WHEN l'utilisateur colle un lien de page web, THE SYSTEM SHALL démarrer un import URL. (EX-02)
6. IF le texte collé comme lien n'est pas une URL http(s) valide, THEN THE SYSTEM SHALL afficher un message d'erreur et ne pas démarrer l'import. (EX-02)
7. WHEN l'utilisateur colle un texte libre, THE SYSTEM SHALL démarrer un import texte. (EX-03)
8. WHEN l'utilisateur sélectionne une ou plusieurs images dans la galerie, THE SYSTEM SHALL les traiter comme une seule recette. (EX-04)
9. WHEN l'utilisateur ouvre l'appareil photo intégré, THE SYSTEM SHALL afficher un aperçu avec un cadre de cadrage. (EX-05)
10. WHEN l'utilisateur prend une photo avec l'appareil photo intégré, THE SYSTEM SHALL permettre d'ajouter d'autres photos à la même recette avant de lancer l'import. (EX-04, EX-05)
11. IF l'utilisateur refuse la permission caméra, THEN THE SYSTEM SHALL afficher un message explicatif et proposer l'import depuis la galerie. (EX-05)
12. WHEN l'application passe au premier plan et que le presse-papiers contient un lien, THE SYSTEM SHALL proposer « Importer le lien copié ? ». (EX-06)
13. IF le lien du presse-papiers a déjà été proposé à l'utilisateur, THEN THE SYSTEM SHALL ne pas le proposer à nouveau. (EX-06)

### Requirement 14: Pré-traitement des entrées
Traçabilité : §4 (étape 2)

**User Story:** En tant qu'utilisateur, je veux que l'app tire le meilleur de chaque source, afin d'obtenir une recette fiable et rapide.

#### Acceptance Criteria
1. WHEN l'entrée est une URL, THE SYSTEM SHALL télécharger la page depuis une Edge Function et non depuis l'appareil.
2. WHEN la page contient des données structurées schema.org/Recipe en JSON-LD, THE SYSTEM SHALL les extraire en priorité.
3. WHEN la page ne contient pas de JSON-LD Recipe mais contient des microdata schema.org/Recipe, THE SYSTEM SHALL extraire ces microdata.
4. IF la page ne contient aucune donnée structurée Recipe, THEN THE SYSTEM SHALL envoyer à l'IA le texte principal nettoyé de la page (sans navigation, publicités ni scripts).
5. WHEN l'entrée est une ou plusieurs images, THE SYSTEM SHALL effectuer l'OCR sur l'appareil avec ML Kit Text Recognition v2.
6. WHEN l'OCR est terminé, THE SYSTEM SHALL envoyer le texte reconnu à l'IA, accompagné optionnellement de l'image.
7. IF l'OCR ne reconnaît aucun texte, THEN THE SYSTEM SHALL en informer l'utilisateur et proposer une nouvelle image ou la création manuelle.
8. WHEN l'entrée est un lien de réseau social, THE SYSTEM SHALL récupérer la légende ou la description via les balises Open Graph.
9. WHEN l'entrée est un lien de réseau social, THE SYSTEM SHALL récupérer la miniature via la balise Open Graph image.
10. IF le contenu d'un réseau social est inaccessible ou ne contient pas de recette exploitable, THEN THE SYSTEM SHALL proposer à l'utilisateur d'importer une capture d'écran traitée par OCR.

### Requirement 15: Parsing IA par l'Edge Function `parse-recipe`
Traçabilité : §4 (étape 3), §3 (IA), §7 (Sécurité)

**User Story:** En tant qu'utilisateur, je veux qu'une IA structure automatiquement ma recette, afin de ne rien avoir à saisir.

#### Acceptance Criteria
1. THE SYSTEM SHALL appeler Google Gemini (modèle Flash) uniquement depuis l'Edge Function `parse-recipe`.
2. THE SYSTEM SHALL ne jamais inclure la clé API Gemini dans l'application téléphone ni montre.
3. THE SYSTEM SHALL stocker la clé API Gemini uniquement dans les secrets des Edge Functions.
4. WHEN `parse-recipe` appelle Gemini, THE SYSTEM SHALL imposer une sortie JSON contrainte par un schéma strict.
5. THE SYSTEM SHALL produire les champs : title, description, servings, prep_time, cook_time, total_time, difficulty, ingredients[{quantity, unit, name, note, group}], steps[{order, text, timer_seconds?}], tags, cuisine, diet_flags, image_url, source_url, source_name, language, confidence.
6. IF la réponse de Gemini ne respecte pas le schéma, THEN THE SYSTEM SHALL la rejeter et la traiter comme une erreur d'import.
7. IF la réponse de Gemini ne contient ni titre ni au moins un ingrédient ou une étape, THEN THE SYSTEM SHALL la traiter comme une erreur « aucune recette détectée ».
8. IF l'appel à `parse-recipe` ne présente pas de JWT utilisateur valide, THEN THE SYSTEM SHALL refuser la requête (HTTP 401).
9. WHEN des données structurées schema.org/Recipe complètes ont été extraites, THE SYSTEM SHALL les mapper vers le même schéma de sortie.

### Requirement 16: Normalisation
Traçabilité : §4 (étape 4), §7 (Tests)

**User Story:** En tant qu'utilisateur, je veux des quantités et unités homogènes, afin de pouvoir ajuster les portions et générer des listes de courses.

#### Acceptance Criteria
1. WHEN une recette est parsée, THE SYSTEM SHALL convertir les unités dans le système de la préférence utilisateur, métrique par défaut.
2. WHEN une quantité est exprimée en fraction (ex. « ½ », « 1 1/2 »), THE SYSTEM SHALL la convertir en valeur numérique.
3. WHEN une quantité est exprimée en toutes lettres (ex. « une », « deux »), THE SYSTEM SHALL la convertir en valeur numérique.
4. IF une quantité n'est pas quantifiable (ex. « une pincée », « selon le goût »), THEN THE SYSTEM SHALL laisser la quantité vide et conserver le texte dans `note` ou `unit`.
5. THE SYSTEM SHALL conserver le regroupement des ingrédients (champ `group`).
6. WHEN une étape mentionne une durée, THE SYSTEM SHALL renseigner `timer_seconds` avec cette durée en secondes.
7. WHEN une étape mentionne une plage de durée (ex. « 10 à 15 minutes »), THE SYSTEM SHALL renseigner `timer_seconds` avec la borne haute.
8. THE SYSTEM SHALL couvrir la normalisation des quantités, des unités et la détection des minuteurs par des tests unitaires.

### Requirement 17: Écran de validation obligatoire
Traçabilité : §4 (étape 5)

**User Story:** En tant qu'utilisateur, je veux relire et corriger la recette avant de l'enregistrer, afin de garantir sa justesse.

#### Acceptance Criteria
1. WHEN le parsing aboutit, THE SYSTEM SHALL afficher un écran de validation présentant tous les champs de la recette en édition.
2. THE SYSTEM SHALL n'enregistrer aucune recette importée sans validation explicite de l'utilisateur sur cet écran.
3. WHEN l'utilisateur valide, THE SYSTEM SHALL enregistrer la recette avec `origin = IMPORTED`.
4. WHEN l'utilisateur valide, THE SYSTEM SHALL enregistrer la recette avec `visibility = PRIVATE`.
5. IF le titre est vide au moment de la validation, THEN THE SYSTEM SHALL bloquer l'enregistrement et signaler le champ en erreur.
6. WHEN l'utilisateur abandonne l'écran de validation, THE SYSTEM SHALL demander confirmation avant de perdre le résultat de l'import.

### Requirement 18: Image de la recette
Traçabilité : §4 (étape 6), §3 (Images), §7 (Sécurité)

**User Story:** En tant qu'utilisateur, je veux que chaque recette ait une image, afin de la reconnaître d'un coup d'œil.

#### Acceptance Criteria
1. WHEN la source fournit une image, THE SYSTEM SHALL l'utiliser comme image de la recette.
2. IF la source ne fournit pas d'image et que l'import contient une photo, THEN THE SYSTEM SHALL utiliser cette photo.
3. IF ni la source ni l'import ne fournissent d'image, THEN THE SYSTEM SHALL proposer à l'utilisateur de prendre une photo.
4. IF l'utilisateur refuse de prendre une photo, THEN THE SYSTEM SHALL utiliser un visuel par défaut.
5. WHEN une image est envoyée au cloud, THE SYSTEM SHALL la convertir au préalable en WebP.
6. WHEN une image est envoyée au cloud, THE SYSTEM SHALL la redimensionner au préalable pour que son plus grand côté ne dépasse pas 1600 px.
7. THE SYSTEM SHALL stocker les images dans un bucket Supabase Storage privé.
8. THE SYSTEM SHALL accéder aux images uniquement par URLs signées à durée limitée.
9. THE SYSTEM SHALL afficher les images avec Coil.

### Requirement 19: Erreurs, quota et performance de l'import
Traçabilité : §4 (Objectif, Erreurs, Limitation), §7 (Performance, Fiabilité)

**User Story:** En tant qu'utilisateur, je veux un import rapide et, en cas d'échec, une solution de repli, afin de ne jamais perdre ma recette.

#### Acceptance Criteria
1. WHEN l'entrée est un texte ou une URL, THE SYSTEM SHALL afficher l'écran de validation en moins de 10 secondes.
2. IF l'import échoue, THEN THE SYSTEM SHALL afficher un message indiquant la cause parmi : réseau, source inaccessible, aucune recette détectée, réponse IA invalide, quota atteint.
3. IF l'import échoue, THEN THE SYSTEM SHALL proposer de réessayer.
4. IF l'import échoue, THEN THE SYSTEM SHALL proposer la création manuelle pré-remplie avec le texte brut disponible.
5. THE SYSTEM SHALL appliquer dans `parse-recipe` un quota d'imports IA par utilisateur et par jour.
6. IF l'utilisateur a atteint son quota quotidien, THEN THE SYSTEM SHALL refuser l'appel IA (HTTP 429) sans appeler Gemini.
7. WHEN l'appel IA est refusé pour quota atteint, THE SYSTEM SHALL en informer l'utilisateur et proposer la création manuelle.
8. WHEN un import est refusé pour quota, THE SYSTEM SHALL ne pas décompter cet import du quota.

### Requirement 20: Création manuelle, doublons, source et file d'imports
Traçabilité : EX-07, EX-08, EX-09, EX-10

**User Story:** En tant qu'utilisateur, je veux créer des recettes à la main, éviter les doublons, garder la source et lancer plusieurs imports à la fois.

#### Acceptance Criteria
1. THE SYSTEM SHALL permettre la création manuelle d'une recette avec tous ses champs. (EX-07)
2. WHEN une recette est créée manuellement, THE SYSTEM SHALL l'enregistrer avec `origin = CREATED`. (EX-07)
3. WHEN une recette en cours d'import a la même URL source qu'une recette existante non supprimée, THE SYSTEM SHALL avertir l'utilisateur d'un doublon potentiel. (EX-08)
4. WHEN une recette en cours d'import a un titre très proche d'une recette existante non supprimée, THE SYSTEM SHALL avertir l'utilisateur d'un doublon potentiel. (EX-08)
5. WHEN un doublon potentiel est signalé, THE SYSTEM SHALL laisser l'utilisateur choisir entre continuer l'import et ouvrir la recette existante. (EX-08)
6. THE SYSTEM SHALL conserver l'URL source et le nom du site ou du créateur de chaque recette importée. (EX-09)
7. WHEN une recette possède une URL source, THE SYSTEM SHALL afficher sur la fiche un lien ouvrant cette source. (EX-09)
8. THE SYSTEM SHALL permettre de lancer plusieurs imports traités en arrière-plan dans une file. (EX-10)
9. WHEN un import en arrière-plan réussit, THE SYSTEM SHALL afficher une notification menant à l'écran de validation. (EX-10)
10. WHEN un import en arrière-plan échoue, THE SYSTEM SHALL afficher une notification menant au message d'erreur et aux options de repli. (EX-10)
11. IF la permission de notification est refusée, THEN THE SYSTEM SHALL afficher l'état des imports dans l'application. (EX-10)

_Domaine 4 — Bibliothèque_

### Requirement 21: Affichage et recherche
Traçabilité : EX-20, EX-21, EX-26, §8 (Index full-text)

**User Story:** En tant qu'utilisateur, je veux parcourir et rechercher mes recettes, afin de trouver rapidement quoi cuisiner.

#### Acceptance Criteria
1. THE SYSTEM SHALL afficher les recettes en liste ou en grille, au choix de l'utilisateur. (EX-20)
2. THE SYSTEM SHALL afficher pour chaque recette son image, son titre, son temps total et ses tags. (EX-20)
3. WHEN l'utilisateur saisit une recherche, THE SYSTEM SHALL rechercher en plein texte dans le titre, les noms d'ingrédients et les tags. (EX-21)
4. WHEN l'utilisateur saisit une recherche, THE SYSTEM SHALL afficher d'abord les résultats issus du cache local. (EX-21)
5. WHILE l'appareil est en ligne, THE SYSTEM SHALL compléter les résultats par une recherche cloud via l'index full-text. (EX-21)
6. WHILE l'appareil est hors ligne, THE SYSTEM SHALL effectuer la recherche uniquement sur le cache local. (EX-21)
7. THE SYSTEM SHALL afficher les tags générés par l'IA sur la fiche recette. (EX-26)
8. THE SYSTEM SHALL permettre à l'utilisateur d'ajouter, modifier et supprimer les tags d'une recette. (EX-26)

### Requirement 22: Filtres et tris
Traçabilité : EX-22, EX-23

**User Story:** En tant qu'utilisateur, je veux filtrer et trier ma bibliothèque, afin de cibler une recette adaptée à mon envie et à mon temps.

#### Acceptance Criteria
1. THE SYSTEM SHALL proposer les filtres : collection, tags, temps total, difficulté, régime (végétarien, sans gluten…), favoris, déjà réalisée, jamais réalisée. (EX-22)
2. WHEN plusieurs filtres sont actifs, THE SYSTEM SHALL n'afficher que les recettes satisfaisant tous les filtres. (EX-22)
3. THE SYSTEM SHALL proposer les tris : récentes, alphabétique, plus réalisées, temps. (EX-23)
4. WHEN l'utilisateur modifie un filtre ou un tri, THE SYSTEM SHALL mettre à jour la liste depuis le cache local sans attente réseau.

### Requirement 23: « Mon frigo »
Traçabilité : EX-24

**User Story:** En tant qu'utilisateur, je veux saisir ce que j'ai dans mon frigo, afin de voir ce que je peux cuisiner.

#### Acceptance Criteria
1. WHEN l'utilisateur saisit une liste d'ingrédients disponibles, THE SYSTEM SHALL afficher les recettes de sa bibliothèque contenant au moins un de ces ingrédients.
2. THE SYSTEM SHALL trier ces recettes par nombre d'ingrédients manquants croissant.
3. THE SYSTEM SHALL afficher pour chaque recette le nombre d'ingrédients manquants.
4. THE SYSTEM SHALL limiter « Mon frigo » à la bibliothèque personnelle de l'utilisateur en V1.

### Requirement 24: Favoris, historique et notes personnelles
Traçabilité : EX-25, §8 (`user_recipe_state`)

**User Story:** En tant qu'utilisateur, je veux marquer mes favoris, garder l'historique et noter mes recettes, afin de me souvenir de ce qui m'a plu.

#### Acceptance Criteria
1. THE SYSTEM SHALL permettre de marquer et de démarquer une recette comme favorite.
2. WHEN l'utilisateur marque une recette « réalisée », THE SYSTEM SHALL enregistrer la date de réalisation.
3. WHEN l'utilisateur marque une recette « réalisée », THE SYSTEM SHALL incrémenter `cooked_count` de la recette.
4. THE SYSTEM SHALL afficher sur la fiche l'historique « réalisée le… ».
5. THE SYSTEM SHALL permettre une note personnelle privée entière de 1 à 5.
6. IF la note saisie n'est pas un entier entre 1 et 5, THEN THE SYSTEM SHALL la refuser.
7. THE SYSTEM SHALL permettre des notes libres sur chaque recette.
8. THE SYSTEM SHALL stocker ces états dans `user_recipe_state`.
9. THE SYSTEM SHALL rendre ces états accessibles uniquement à leur propriétaire.

_Domaine 5 — Collections_

### Requirement 25: Gestion des collections
Traçabilité : EX-30, EX-31, EX-32, EX-33

**User Story:** En tant qu'utilisateur, je veux organiser mes recettes en collections, afin de les ranger à ma façon.

#### Acceptance Criteria
1. THE SYSTEM SHALL permettre de créer une collection avec un nom, un emoji ou une couleur, et une image de couverture optionnelle. (EX-30)
2. IF le nom de la collection est vide, THEN THE SYSTEM SHALL refuser la création. (EX-30)
3. THE SYSTEM SHALL permettre de renommer une collection. (EX-30)
4. THE SYSTEM SHALL permettre de supprimer une collection (soft delete) après confirmation. (EX-30)
5. THE SYSTEM SHALL permettre de réordonner les collections, et conserver cet ordre après synchronisation. (EX-30)
6. THE SYSTEM SHALL permettre qu'une recette appartienne à plusieurs collections. (EX-31)
7. WHEN une collection est supprimée, THE SYSTEM SHALL conserver les recettes qu'elle contenait. (EX-30, EX-31)
8. WHEN l'utilisateur effectue un appui long sur une recette, THE SYSTEM SHALL proposer l'ajout à une ou plusieurs collections. (EX-32)
9. WHEN l'utilisateur sélectionne plusieurs recettes, THE SYSTEM SHALL proposer leur ajout groupé à une ou plusieurs collections. (EX-32)
10. WHERE l'utilisateur active les collections intelligentes, THE SYSTEM SHALL proposer des collections définies par des filtres (ex. « Rapides < 30 min »). (EX-33)
11. WHERE une collection intelligente existe, THE SYSTEM SHALL recalculer son contenu automatiquement à chaque modification de la bibliothèque. (EX-33)

_Domaine 6 — Fiche recette et mode cuisine_

### Requirement 26: Fiche recette, portions, unités et édition
Traçabilité : EX-40, EX-41, EX-42, EX-43, EX-09

**User Story:** En tant qu'utilisateur, je veux consulter une fiche complète et l'adapter, afin de cuisiner pour le bon nombre de personnes.

#### Acceptance Criteria
1. THE SYSTEM SHALL afficher sur la fiche : image, temps, portions, difficulté, tags, ingrédients, étapes, source et notes. (EX-40)
2. WHEN l'utilisateur modifie le nombre de portions, THE SYSTEM SHALL recalculer proportionnellement toutes les quantités affichées. (EX-41)
3. WHEN l'utilisateur modifie le nombre de portions, THE SYSTEM SHALL laisser inchangées les quantités enregistrées de la recette. (EX-41)
4. IF le nombre de portions demandé est inférieur à 1, THEN THE SYSTEM SHALL le refuser. (EX-41)
5. WHEN l'utilisateur bascule entre métrique et impérial, THE SYSTEM SHALL convertir les unités affichées. (EX-42)
6. THE SYSTEM SHALL permettre l'édition de tous les champs de la recette (titre, description, infos, image, ingrédients, étapes, tags, source). (EX-43)
7. WHEN l'utilisateur enregistre une modification, THE SYSTEM SHALL mettre à jour `updated_at` et synchroniser la recette. (EX-43, §2.1)

### Requirement 27: Mode cuisine téléphone
Traçabilité : EX-44, EX-45, EX-46, H9

**User Story:** En tant qu'utilisateur aux mains occupées, je veux un mode cuisine lisible avec minuteurs, afin de suivre la recette sans erreur.

#### Acceptance Criteria
1. WHEN l'utilisateur entre en mode cuisine, THE SYSTEM SHALL afficher une seule étape par écran en texte grand. (EX-44)
2. WHILE une étape est affichée en mode cuisine, THE SYSTEM SHALL mettre en évidence les ingrédients cités dans l'étape. (EX-44)
3. WHILE le mode cuisine est actif, THE SYSTEM SHALL maintenir l'écran allumé. (EX-44)
4. WHEN une étape contient un minuteur détecté, THE SYSTEM SHALL permettre de le lancer en un seul geste. (EX-45)
5. THE SYSTEM SHALL permettre plusieurs minuteurs simultanés. (EX-45)
6. WHILE un minuteur est en cours, THE SYSTEM SHALL l'exécuter dans un service de premier plan avec une notification affichant le temps restant. (EX-45)
7. WHEN un minuteur arrive à échéance, THE SYSTEM SHALL émettre une notification et une alarme sonore, y compris si l'app est en arrière-plan. (EX-45)
8. THE SYSTEM SHALL proposer des cases à cocher pour les ingrédients préparés. (EX-46)
9. WHEN l'utilisateur change d'étape, THE SYSTEM SHALL enregistrer l'étape courante dans `user_recipe_state`.

### Requirement 28: Envoi en mode cuisine sur la montre et partage externe
Traçabilité : EX-47, EX-48, §2.1

**User Story:** En tant qu'utilisateur, je veux basculer la recette sur ma montre ou la partager, afin de cuisiner au poignet ou d'en faire profiter un proche.

#### Acceptance Criteria
1. WHEN l'utilisateur choisit « Envoyer en mode cuisine sur la montre », THE SYSTEM SHALL écrire dans le cloud l'état « recette en cours » (recette, étape courante, portions). (EX-47)
2. THE SYSTEM SHALL n'utiliser aucun transfert direct téléphone → montre pour l'envoi en mode cuisine. (EX-47)
3. WHEN l'utilisateur partage une recette en texte, THE SYSTEM SHALL générer un texte formaté et l'envoyer via le partage Android. (EX-48)
4. WHEN l'utilisateur partage une recette en PDF, THE SYSTEM SHALL générer un PDF et l'envoyer via le partage Android. (EX-48)
5. THE SYSTEM SHALL ne proposer aucune fonction communautaire dans le partage. (EX-48)

_Domaine 7 — Liste de courses_

### Requirement 29: Génération et fusion
Traçabilité : EX-50, EX-51, EX-52, §7 (Tests)

**User Story:** En tant qu'utilisateur, je veux générer automatiquement ma liste de courses à partir de recettes, afin de gagner du temps en magasin.

#### Acceptance Criteria
1. WHEN l'utilisateur sélectionne une ou plusieurs recettes avec leur nombre de portions, THE SYSTEM SHALL générer une liste de courses avec les quantités ajustées aux portions. (EX-50)
2. WHEN plusieurs entrées concernent le même ingrédient avec des unités compatibles, THE SYSTEM SHALL les fusionner en une ligne en additionnant les quantités après conversion (ex. « 200 g + 0,5 kg farine » → « 700 g farine »). (EX-51)
3. IF les unités d'un même ingrédient sont incompatibles, THEN THE SYSTEM SHALL conserver des lignes distinctes. (EX-51)
4. THE SYSTEM SHALL classer les articles par rayon (fruits et légumes, crèmerie, épicerie…) via l'IA ou un dictionnaire local. (EX-52)
5. IF le rayon d'un article ne peut pas être déterminé, THEN THE SYSTEM SHALL le classer dans un rayon « Autres ». (EX-52)
6. THE SYSTEM SHALL couvrir la fusion de la liste de courses par des tests unitaires.

### Requirement 30: Gestion des articles et des listes
Traçabilité : EX-53, EX-54, EX-55, EX-56, EX-77

**User Story:** En tant qu'utilisateur, je veux gérer librement mes listes et cocher mes achats depuis le téléphone ou la montre.

#### Acceptance Criteria
1. THE SYSTEM SHALL permettre l'ajout manuel d'articles. (EX-53)
2. THE SYSTEM SHALL permettre l'édition d'articles. (EX-53)
3. THE SYSTEM SHALL permettre la suppression d'articles (soft delete). (EX-53)
4. WHEN l'utilisateur coche ou décoche un article, THE SYSTEM SHALL enregistrer l'état dans le cloud. (EX-54)
5. WHEN un article est coché sur un appareil, THE SYSTEM SHALL refléter l'état sur l'autre appareil à sa prochaine synchronisation. (EX-54)
6. THE SYSTEM SHALL permettre de marquer un produit « déjà dans le placard ». (EX-55)
7. WHEN un produit est marqué « déjà dans le placard », THE SYSTEM SHALL l'exclure des listes générées. (EX-55)
8. THE SYSTEM SHALL permettre plusieurs listes de courses simultanées. (EX-56)
9. WHEN l'utilisateur partage une liste, THE SYSTEM SHALL l'exporter en texte via le partage Android. (EX-56)

_Domaine 8 — Compte et RGPD_

### Requirement 31: Inscription, connexion et profil
Traçabilité : EX-60, EX-61, §3 (Authentification téléphone)

**User Story:** En tant qu'utilisateur, je veux créer un compte simplement, afin de retrouver mes recettes partout.

#### Acceptance Criteria
1. THE SYSTEM SHALL permettre l'inscription et la connexion sur le téléphone via Google (Credential Manager). (EX-60)
2. THE SYSTEM SHALL permettre l'inscription et la connexion sur le téléphone via e-mail et mot de passe. (EX-60)
3. IF l'adresse e-mail saisie n'a pas un format valide, THEN THE SYSTEM SHALL bloquer l'envoi et signaler le champ en erreur.
4. IF les identifiants sont invalides, THEN THE SYSTEM SHALL afficher un message d'erreur sans révéler si le compte existe.
5. WHEN un compte est créé, THE SYSTEM SHALL créer la ligne correspondante dans `profiles`. (EX-61)
6. THE SYSTEM SHALL permettre de modifier le pseudo et l'avatar du profil. (EX-61)

### Requirement 32: Préférences
Traçabilité : EX-62

**User Story:** En tant qu'utilisateur, je veux régler mes préférences, afin que l'app s'adapte à mes habitudes.

#### Acceptance Criteria
1. THE SYSTEM SHALL permettre de définir le système d'unités (métrique ou impérial).
2. THE SYSTEM SHALL permettre de définir la langue.
3. THE SYSTEM SHALL permettre de définir le nombre de portions par défaut.
4. THE SYSTEM SHALL permettre de définir les régimes alimentaires de l'utilisateur.
5. WHEN une préférence est modifiée, THE SYSTEM SHALL l'appliquer à l'affichage.
6. WHEN une préférence est modifiée, THE SYSTEM SHALL l'appliquer aux imports suivants.

### Requirement 33: RGPD
Traçabilité : EX-63

**User Story:** En tant qu'utilisateur, je veux contrôler mes données personnelles, afin d'exercer mes droits RGPD.

#### Acceptance Criteria
1. WHEN l'utilisateur demande l'export de ses données, THE SYSTEM SHALL produire un fichier JSON contenant toutes ses données métier (H8).
2. THE SYSTEM SHALL demander une confirmation explicite avant toute suppression de compte.
3. WHEN l'utilisateur confirme la suppression de son compte, THE SYSTEM SHALL supprimer définitivement le compte et toutes ses données dans le cloud.
4. WHEN l'utilisateur confirme la suppression de son compte, THE SYSTEM SHALL supprimer toutes ses images du Storage.
5. WHEN le compte est supprimé, THE SYSTEM SHALL déconnecter tous ses appareils, montre comprise.
6. WHEN le compte est supprimé, THE SYSTEM SHALL effacer le cache Room du téléphone.
7. THE SYSTEM SHALL donner accès depuis l'app à une politique de confidentialité.
8. THE SYSTEM SHALL mentionner dans la politique de confidentialité le traitement IA par Google Gemini.

Note : la gestion des appareils connectés (EX-64) est couverte par les Requirements 10 et 11 ; l'état de synchronisation (EX-65) par le Requirement 6.

_Domaine 9 — Wear OS_

### Requirement 34: Accès aux recettes et navigation
Traçabilité : EX-70, EX-71, EX-72, §2.1

**User Story:** En tant qu'utilisateur, je veux consulter mes recettes au poignet, même sans téléphone.

#### Acceptance Criteria
1. THE SYSTEM SHALL connecter la montre uniquement via le téléphone, selon le flux des Requirements 7 à 11. (EX-70)
2. THE SYSTEM SHALL charger les recettes de la montre directement depuis Supabase. (EX-71)
3. THE SYSTEM SHALL mettre en cache Room sur la montre les recettes chargées. (EX-71)
4. THE SYSTEM SHALL proposer sur la montre la navigation par favoris, récentes et collections. (EX-72)
5. THE SYSTEM SHALL proposer sur la montre une recherche par saisie vocale. (EX-72)
6. THE SYSTEM SHALL afficher les résultats de recherche de la montre sous forme de liste. (EX-72)
7. THE SYSTEM SHALL n'autoriser sur la montre que l'écriture des états personnels. (§2.1)
8. IF une écriture autre qu'un état personnel est tentée depuis la montre, THEN THE SYSTEM SHALL la refuser. (§2.1)

### Requirement 35: Fiche compacte et mode cuisine montre
Traçabilité : EX-73, EX-74, EX-75, EX-76, H9

**User Story:** En tant qu'utilisateur en cuisine, je veux suivre la recette sur ma montre, afin de garder les mains libres.

#### Acceptance Criteria
1. THE SYSTEM SHALL afficher sur la montre une fiche compacte : temps, portions, ingrédients. (EX-73)
2. THE SYSTEM SHALL permettre de cocher les ingrédients sur la fiche compacte. (EX-73)
3. WHEN l'utilisateur entre en mode cuisine sur la montre, THE SYSTEM SHALL afficher une étape par écran. (EX-74)
4. WHILE le mode cuisine est actif sur la montre, THE SYSTEM SHALL permettre de changer d'étape par swipe. (EX-74)
5. WHILE le mode cuisine est actif sur la montre, THE SYSTEM SHALL permettre de changer d'étape par la couronne rotative. (EX-74)
6. WHILE le mode cuisine est actif sur la montre, THE SYSTEM SHALL garder l'écran allumé. (EX-74)
7. WHEN la montre passe en mode ambiant pendant le mode cuisine, THE SYSTEM SHALL afficher une version simplifiée de l'étape courante. (EX-74)
8. WHEN un minuteur d'étape est lancé sur la montre, THE SYSTEM SHALL l'exécuter en arrière-plan via un service de premier plan avec Ongoing Activity. (EX-75)
9. WHEN un minuteur de la montre arrive à échéance, THE SYSTEM SHALL faire vibrer la montre. (EX-75)
10. WHEN une recette « en cours » est présente dans l'état cloud, THE SYSTEM SHALL proposer sa reprise sur la montre. (EX-76)
11. WHEN l'utilisateur accepte la reprise, THE SYSTEM SHALL ouvrir le mode cuisine de la montre à l'étape enregistrée. (EX-76)
12. WHEN l'utilisateur change d'étape sur la montre, THE SYSTEM SHALL enregistrer l'étape courante dans `user_recipe_state`. (§2.1)

### Requirement 36: Liste de courses, Tile et complication
Traçabilité : EX-77, EX-78, EX-79

**User Story:** En tant qu'utilisateur en magasin, je veux cocher ma liste au poignet et accéder vite à mes recettes.

#### Acceptance Criteria
1. THE SYSTEM SHALL afficher la liste de courses sur la montre. (EX-77)
2. THE SYSTEM SHALL permettre de cocher et décocher les articles sur la montre, synchronisés via le cloud. (EX-77)
3. THE SYSTEM SHALL fournir une Tile affichant les favoris ou la dernière recette consultée. (EX-78)
4. THE SYSTEM SHALL afficher dans la Tile la liste de courses en cours. (EX-78)
5. WHEN l'utilisateur touche un élément de la Tile, THE SYSTEM SHALL ouvrir l'écran correspondant de l'app montre. (EX-78)
6. WHERE l'utilisateur ajoute la complication à son cadran, THE SYSTEM SHALL y afficher le minuteur en cours. (EX-79)
7. WHERE la complication est ajoutée et qu'aucun minuteur n'est en cours, THE SYSTEM SHALL afficher un état vide. (EX-79)

### Requirement 37: Contraintes d'interface montre
Traçabilité : §6 (Contraintes)

**User Story:** En tant qu'utilisateur de montre, je veux une interface lisible, rapide et économe.

#### Acceptance Criteria
1. THE SYSTEM SHALL adapter l'interface de la montre aux écrans ronds.
2. THE SYSTEM SHALL adapter l'interface de la montre aux écrans carrés.
3. THE SYSTEM SHALL utiliser des tailles de texte conformes aux recommandations Wear OS (Material 3 for Wear).
4. THE SYSTEM SHALL afficher sur la montre des miniatures dédiées de taille réduite plutôt que les images pleine résolution.
5. WHEN la montre affiche une liste depuis le cache, THE SYSTEM SHALL l'afficher sans attendre le réseau.
6. WHILE l'app montre n'est pas au premier plan, THE SYSTEM SHALL ne maintenir aucun abonnement Realtime.
7. WHILE l'app montre n'est pas au premier plan, THE SYSTEM SHALL limiter la synchronisation aux tâches périodiques WorkManager.

_Domaine 10 — Exigences non fonctionnelles_

### Requirement 38: Sécurité et Row Level Security
Traçabilité : §7 (Sécurité), §8

**User Story:** En tant qu'utilisateur, je veux que personne d'autre n'accède à mes données, afin de garder ma bibliothèque privée.

#### Acceptance Criteria
1. THE SYSTEM SHALL activer la Row Level Security sur toutes les tables du schéma, sans exception.
2. THE SYSTEM SHALL restreindre, via les policies RLS, la lecture de chaque table aux lignes appartenant à l'utilisateur authentifié.
3. THE SYSTEM SHALL restreindre, via les policies RLS, l'écriture de chaque table aux lignes appartenant à l'utilisateur authentifié.
4. IF une requête tente de lire les données d'un autre utilisateur, THEN THE SYSTEM SHALL ne renvoyer aucune ligne.
5. IF une requête tente d'écrire les données d'un autre utilisateur, THEN THE SYSTEM SHALL refuser l'écriture.
6. THE SYSTEM SHALL stocker les images dans un bucket Storage privé, avec des policies limitant chaque utilisateur à ses propres fichiers.
7. THE SYSTEM SHALL n'embarquer dans les APK aucune clé secrète.
8. THE SYSTEM SHALL lire la clé publique (anon) et l'URL du projet Supabase depuis `local.properties` au moment du build.
9. THE SYSTEM SHALL exclure `local.properties` du dépôt git.
10. THE SYSTEM SHALL conserver la clé Gemini uniquement dans les secrets des Edge Functions.
11. THE SYSTEM SHALL stocker la session de la montre chiffrée (cf. Requirement 9).
12. THE SYSTEM SHALL garantir que le code de session appareil est à usage unique, valable 60 s et jamais journalisé (cf. Requirement 8).
13. THE SYSTEM SHALL exiger un JWT valide sur `create-device-session` (cf. Requirement 8).
14. THE SYSTEM SHALL appliquer une limitation de fréquence sur `create-device-session` (cf. Requirement 8).

### Requirement 39: Performance
Traçabilité : §7 (Performance), §4

**User Story:** En tant qu'utilisateur, je veux une app réactive, afin de l'utiliser sans attendre.

#### Acceptance Criteria
1. WHEN l'application démarre à froid, THE SYSTEM SHALL afficher son premier écran utile en moins de 2 secondes.
2. WHEN des données sont présentes en cache, THE SYSTEM SHALL les afficher depuis Room avant toute réponse réseau.
3. WHEN l'entrée d'import est un texte ou une URL, THE SYSTEM SHALL proposer la recette en moins de 10 secondes (H4).

### Requirement 40: Accessibilité
Traçabilité : §7 (Accessibilité)

**User Story:** En tant qu'utilisateur en situation de handicap, je veux utiliser l'app avec mes outils d'assistance.

#### Acceptance Criteria
1. THE SYSTEM SHALL fournir une description TalkBack pour chaque élément interactif, sur téléphone et montre.
2. THE SYSTEM SHALL fournir une description TalkBack pour chaque image significative, sur téléphone et montre.
3. THE SYSTEM SHALL respecter un contraste conforme à la cible WCAG AA en thème clair.
4. THE SYSTEM SHALL respecter un contraste conforme à la cible WCAG AA en thème sombre.
5. THE SYSTEM SHALL supporter les tailles de police dynamiques du système sans troncature empêchant la lecture ou l'action.

### Requirement 41: Internationalisation
Traçabilité : §7 (Internationalisation)

**User Story:** En tant qu'utilisateur francophone ou anglophone, je veux l'app dans ma langue.

#### Acceptance Criteria
1. THE SYSTEM SHALL utiliser le français comme langue par défaut.
2. THE SYSTEM SHALL externaliser tous les textes d'interface dans des ressources strings.
3. THE SYSTEM SHALL structurer les ressources de sorte qu'une traduction anglaise s'ajoute sans modification de code.
4. THE SYSTEM SHALL ne contenir aucun texte d'interface codé en dur.

### Requirement 42: Coût 0 € et fiabilité
Traçabilité : §1, §7 (Coût, Fiabilité), §4 (Limitation)

**User Story:** En tant que porteur du projet, je veux un coût d'infrastructure nul, afin de rendre la V1 viable.

#### Acceptance Criteria
1. THE SYSTEM SHALL fonctionner exclusivement sur l'offre gratuite Supabase.
2. THE SYSTEM SHALL fonctionner exclusivement sur le quota gratuit Gemini.
3. THE SYSTEM SHALL n'utiliser aucune dépendance, bibliothèque ou service payant.
4. IF un quota gratuit (Gemini, Supabase) est atteint, THEN THE SYSTEM SHALL afficher un message clair.
5. IF un quota gratuit est atteint, THEN THE SYSTEM SHALL conserver toutes les données locales et les écritures en attente.
6. IF une erreur réseau survient, THEN THE SYSTEM SHALL la gérer sans plantage.
7. IF une erreur réseau survient lors d'une action utilisateur, THEN THE SYSTEM SHALL afficher un message clair et proposer de réessayer.

### Requirement 43: Stack technique et qualité
Traçabilité : §3, §7 (Tests)

**User Story:** En tant que développeur, je veux une stack et une architecture fixées, afin de livrer un code maintenable.

#### Acceptance Criteria
1. THE SYSTEM SHALL être écrit à 100 % en Kotlin, avec coroutines et Flow pour l'asynchronisme.
2. THE SYSTEM SHALL utiliser Jetpack Compose et Material 3 (thème dynamique, mode sombre) sur le téléphone.
3. THE SYSTEM SHALL utiliser Compose for Wear OS (Material 3 for Wear), Horologist et Tiles API sur la montre.
4. THE SYSTEM SHALL suivre Clean Architecture + MVVM (UDF).
5. THE SYSTEM SHALL être organisé en modules Gradle `shared` (domaine, modèles, use cases, data/sync), `app` (téléphone) et `wear` (montre).
6. THE SYSTEM SHALL utiliser Hilt pour l'injection de dépendances.
7. THE SYSTEM SHALL utiliser Room pour le cache local et la file d'écritures, et WorkManager pour les tâches de fond.
8. THE SYSTEM SHALL utiliser supabase-kt (client Ktor) pour l'accès à Supabase.
9. THE SYSTEM SHALL utiliser ML Kit Text Recognition v2 pour l'OCR, Coil pour les images, kotlinx.serialization pour la sérialisation et Ktor pour le HTTP.
10. THE SYSTEM SHALL utiliser Gradle Kotlin DSL et un version catalog (`libs.versions.toml`).
11. THE SYSTEM SHALL passer ktlint et detekt sans erreur.
12. THE SYSTEM SHALL disposer de tests unitaires (JUnit5, Turbine, MockK) et de tests Compose.
13. THE SYSTEM SHALL couvrir par des tests unitaires les use cases.
14. THE SYSTEM SHALL couvrir par des tests unitaires la normalisation des quantités, la fusion de la liste de courses, le moteur de synchronisation et les conflits.

_Domaine 11 — Préparation de la V2 communautaire_

### Requirement 44: Schéma SQL prêt pour la V2
Traçabilité : §8

**User Story:** En tant que porteur du projet, je veux un schéma V1 extensible, afin de lancer la V2 sans migration destructive.

#### Acceptance Criteria
1. THE SYSTEM SHALL définir le schéma par des migrations SQL versionnées dans `supabase/migrations`.
2. THE SYSTEM SHALL créer la table `profiles` (id, pseudo, avatar_url, bio, created_at).
3. THE SYSTEM SHALL créer la table `recipes` (id, owner_id, visibility [PRIVATE|UNLISTED|PUBLIC] DEFAULT PRIVATE, origin [CREATED|IMPORTED|FORKED], forked_from_id NULL, source_url, source_name, title, description, servings, prep_time, cook_time, difficulty, image_path, tags, diet_flags, language, avg_rating NULL, rating_count DEFAULT 0, cooked_count DEFAULT 0, created_at, updated_at, deleted_at).
4. THE SYSTEM SHALL créer les tables `ingredients` et `steps`, liées à `recipes`.
5. THE SYSTEM SHALL créer les tables `collections` et `collection_recipes`.
6. THE SYSTEM SHALL créer les tables `shopping_lists` et `shopping_items`.
7. THE SYSTEM SHALL créer la table `user_recipe_state` (favori, réalisée, note privée, notes libres, progression de cuisson, état « recette en cours »).
8. THE SYSTEM SHALL créer la table `device_sessions` (appareils connectés).
9. THE SYSTEM SHALL mettre en place dès la V1 un index full-text sur les recettes.
10. THE SYSTEM SHALL écrire les policies RLS de façon à pouvoir y ajouter ultérieurement une condition « OR visibility = 'PUBLIC' » sans réécriture destructive.

### Requirement 45: Visibilité, feature flags et règle de droit d'auteur
Traçabilité : §8

**User Story:** En tant que porteur du projet, je veux préparer la V2 sans rien exposer et protéger le droit d'auteur dès maintenant.

#### Acceptance Criteria
1. THE SYSTEM SHALL enregistrer toute recette V1 avec `visibility = PRIVATE`.
2. IF une opération tente de définir en V1 une visibilité autre que PRIVATE, THEN THE SYSTEM SHALL la refuser.
3. THE SYSTEM SHALL centraliser les feature flags dans un objet unique, avec `FeatureFlags.COMMUNITY_ENABLED = false` en V1.
4. WHILE `FeatureFlags.COMMUNITY_ENABLED = false`, THE SYSTEM SHALL ne compiler aucun écran communautaire dans l'UI.
5. IF une recette a `origin = IMPORTED`, THEN THE SYSTEM SHALL interdire, dans la couche domaine, son passage en `visibility = PUBLIC`, quelle que soit la version.
6. WHERE une recette a `origin = CREATED`, THE SYSTEM SHALL la considérer comme éligible à PUBLIC (en V2 seulement).
7. WHERE une recette a `origin = FORKED` avec des modifications substantielles et une attribution à la recette d'origine, THE SYSTEM SHALL la considérer comme éligible à PUBLIC (en V2 seulement).
8. IF une recette a `origin = FORKED` sans modifications substantielles ou sans attribution, THEN THE SYSTEM SHALL la considérer comme non éligible à PUBLIC.
9. THE SYSTEM SHALL couvrir la règle de droit d'auteur par des tests unitaires du domaine.

### Requirement 46: Fonctionnalités V2 non bloquées
Traçabilité : §8

**User Story:** En tant que porteur du projet, je veux que la V1 ne ferme aucune porte aux fonctionnalités V2 prévues.

#### Acceptance Criteria
1. THE SYSTEM SHALL ne pas implémenter en V1 : recettes publiques et non listées (lien de partage), découverte et recherche globale, « Mon frigo » sur la base publique, notes et avis « J'ai testé », classement par moyenne bayésienne, photos de résultats, profils et abonnements aux créateurs, signalement, modération assistée par IA, blocage d'utilisateurs.
2. THE SYSTEM SHALL concevoir le schéma de sorte que l'ajout des tables futures `ratings`, `saved_recipes`, `follows` et `reports` ne nécessite aucune migration destructive.

---

## Hors périmètre (V1)

Conformément à la section 9 du SDD, sont explicitement exclus de la V1 :

- Toute fonctionnalité communautaire visible (recettes publiques / non listées, découverte, recherche globale, avis, notes publiques, « J'ai testé », classement bayésien, photos de résultats, profils publics, abonnements, signalement, modération, blocage ; tables `ratings`, `saved_recipes`, `follows`, `reports`). Ces éléments sont seulement préparés (Domaine 11).
- Le planificateur de repas.
- Les versions iOS et web.
- Tout paiement (achats intégrés, abonnements, services payants).
- Toute écriture de données non personnelles depuis la montre (création / édition de recettes, collections, listes).
- Tout transfert de données métier ou de tokens via la Wearable Data Layer API.
- La synchronisation des minuteurs entre téléphone et montre (H9).

---

## Matrice de traçabilité SDD → exigences

| Référence SDD | Requirement(s) |
|---|---|
| §1 Vision (privé, 0 €, V2) | 42, 44, 45, 46 |
| §2.1 Synchronisation | 1, 2, 3, 4, 5, 28, 34 |
| §2.2 Auth montre | 7, 8, 9, 10, 11, 12 |
| §3 Stack | 7, 15, 18, 31, 43 |
| §4 Pipeline IA | 13, 14, 15, 16, 17, 18, 19 |
| EX-01 à EX-06 | 13 |
| EX-07 à EX-10 | 20 |
| EX-20, EX-21, EX-26 | 21 |
| EX-22, EX-23 | 22 |
| EX-24 | 23 |
| EX-25 | 24 |
| EX-30 à EX-33 | 25 |
| EX-40 à EX-43 | 26 |
| EX-44 à EX-46 | 27 |
| EX-47, EX-48 | 28 |
| EX-50 à EX-52 | 29 |
| EX-53 à EX-56 | 30 |
| EX-60, EX-61 | 31 |
| EX-62 | 32 |
| EX-63 | 33 |
| EX-64 | 10, 11 |
| EX-65 | 6 |
| EX-70 | 7, 10, 34 |
| EX-71, EX-72 | 34 |
| EX-73 à EX-76 | 35 |
| EX-77 | 30, 36 |
| EX-78, EX-79 | 36 |
| §6 Contraintes montre | 37 |
| §7 Non fonctionnel | 1, 3, 4, 16, 19, 29, 38, 39, 40, 41, 42, 43 |
| §8 Préparation V2 | 5, 24, 44, 45, 46 |
| §9 Hors périmètre | Section « Hors périmètre » |
| §10 Instructions | Processus (voir Introduction) |
