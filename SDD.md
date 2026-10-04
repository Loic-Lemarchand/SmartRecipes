# Cahier des charges : SmartRecipes (Android + Wear OS)

## 1. Vision du produit
SmartRecipes est une application Android et Wear OS qui centralise les recettes d'un
utilisateur dans le cloud. Sa fonction principale : importer une recette depuis n'importe
quelle source (réseau social, page web, image, texte), facilement et automatiquement.
Une IA la structure ensuite en recette propre : titre, image, ingrédients, étapes.

- V1 : application PERSONNELLE (bibliothèque privée), coût d'infrastructure de 0 €.
- V2 (future) : plateforme communautaire. L'architecture et la base de données V1 doivent
  rendre cette évolution fluide, sans migration destructive (voir section 8).
- La montre sert surtout à consulter les recettes et à cuisiner avec la recette au poignet.

## 2. Principe de synchronisation et d'authentification (IMPORTANT)

### 2.1 Données (recettes, collections, listes de courses…)
- Le cloud (Supabase) est la source de vérité unique.
- Le téléphone ET la montre lisent et écrivent chacun directement dans Supabase.
- AUCUNE donnée métier ne transite entre les apps via la Wearable Data Layer API.
- Chaque appareil dispose d'un cache local Room (lecture hors ligne).
- Téléphone : écritures hors ligne mises en file d'attente (WorkManager), envoyées au retour
  du réseau. Résolution de conflit : last-write-wins sur `updated_at`.
- Montre : lecture seule en V1, sauf les états personnels (favori, « réalisée », articles
  cochés de la liste de courses, progression en cours de cuisson).
- Mises à jour rapides : Supabase Realtime quand l'app est ouverte, sinon synchronisation
  incrémentale (`updated_at > dernier_sync`) à l'ouverture et périodiquement (WorkManager).
- Suppressions : soft delete (`deleted_at`) pour qu'elles se propagent aux autres appareils.

### 2.2 Authentification de la montre (via le téléphone)
- La Wearable Data Layer API sert UNIQUEMENT à l'authentification et à la déconnexion.
- La montre ne propose aucun formulaire de connexion.
- Flux de connexion :
  1. La montre, non connectée, affiche « Ouvrez SmartRecipes sur votre téléphone » et
     envoie une demande de connexion au téléphone (MessageClient, chemin `/auth/request`).
  2. Le téléphone, si l'utilisateur est connecté, appelle l'Edge Function
     `create-device-session` avec son JWT.
  3. L'Edge Function génère un code à usage unique, valable 60 s, lié à l'utilisateur
     (via l'API admin Supabase, ex. generateLink de type magiclink → hashed token / OTP).
  4. Le téléphone transmet ce code à la montre (MessageClient, chemin `/auth/token`).
  5. La montre échange ce code contre SA PROPRE session Supabase (verifyOtp) et la stocke
     de façon chiffrée (DataStore chiffré / Android Keystore).
- INTERDIT : copier l'access token ou le refresh token du téléphone sur la montre
  (la rotation des refresh tokens Supabase provoquerait la déconnexion des deux appareils).
- Connexion automatique : quand l'utilisateur se connecte sur le téléphone et qu'une montre
  est appairée avec l'app installée (CapabilityClient), le téléphone envoie le code de
  lui-même.
- Si le téléphone n'est pas connecté : la montre affiche « Connectez-vous d'abord sur
  votre téléphone ».
- Une fois connectée, la montre fonctionne de manière autonome (Wi-Fi / LTE), sans le
  téléphone, et renouvelle elle-même sa session.
- Déconnexion : une déconnexion sur le téléphone envoie `/auth/logout` à la montre, qui
  efface sa session et son cache Room. La montre peut aussi se déconnecter seule.
- Prérequis : même applicationId et même clé de signature pour `app` et `wear`
  (obligatoire pour la Data Layer). Le documenter dans le README.

## 3. Stack technique
- Langage : Kotlin 100 %, coroutines + Flow.
- UI téléphone : Jetpack Compose + Material 3 (thème dynamique, mode sombre).
- UI montre : Compose for Wear OS (Material 3 for Wear), Horologist, Tiles API.
- Architecture : Clean Architecture + MVVM (UDF), modules Gradle :
  `shared` (domaine, modèles, use cases, data/sync), `app` (téléphone), `wear` (montre).
- Injection de dépendances : Hilt.
- Base locale : Room (cache + file d'écritures en attente).
- Tâches de fond : WorkManager.
- Backend : Supabase, offre gratuite (PostgreSQL, Auth, Storage, Edge Functions, Realtime)
  via supabase-kt (client Ktor).
- Authentification téléphone : Google (Credential Manager) + e-mail / mot de passe.
- Communication montre ↔ téléphone : Wearable Data Layer API (MessageClient,
  CapabilityClient), limitée strictement à l'authentification (voir 2.2).
- IA : Google Gemini (modèle Flash), appelée UNIQUEMENT depuis une Edge Function Supabase
  (`parse-recipe`). La clé API n'est jamais présente dans l'app.
- OCR : ML Kit Text Recognition v2 (sur l'appareil, gratuit, hors ligne).
- Images : Coil. Compression avant envoi (WebP, max ~1600 px).
- Sérialisation : kotlinx.serialization. Réseau HTTP : Ktor.
- Build : Gradle Kotlin DSL + version catalog (libs.versions.toml).
- Qualité : ktlint/detekt, tests unitaires (JUnit5, Turbine, MockK), tests Compose.

## 4. Pipeline d'import et de parsing IA
1. Acquisition de l'entrée (texte, URL, image(s), partage).
2. Pré-traitement local :
   - URL : téléchargement de la page via l'Edge Function. Extraction prioritaire des données
     structurées schema.org/Recipe (JSON-LD, microdata). Si absentes : texte principal
     nettoyé envoyé à l'IA.
   - Image : OCR ML Kit sur l'appareil, puis envoi du texte (et optionnellement de l'image)
     à l'IA.
   - Réseaux sociaux : récupération de la légende / description et de la miniature
     (Open Graph). Si le contenu est inaccessible, proposer une capture d'écran → OCR.
3. Edge Function `parse-recipe` : appel Gemini avec sortie JSON contrainte (schéma strict).
   Champs : title, description, servings, prep_time, cook_time, total_time, difficulty,
   ingredients[{quantity, unit, name, note, group}], steps[{order, text, timer_seconds?}],
   tags, cuisine, diet_flags, image_url, source_url, source_name, language, confidence.
4. Normalisation : unités (métrique par défaut), quantités en nombres, regroupement des
   ingrédients, détection des minuteurs dans les étapes.
5. Écran de validation obligatoire avant enregistrement (l'utilisateur corrige si besoin).
6. Image : celle de la source, sinon la photo importée, sinon proposition de prendre une
   photo, sinon visuel par défaut. Stockage dans Supabase Storage (bucket privé).
- Objectif de performance : recette proposée en moins de 10 s pour un texte ou une URL.
- Erreurs : message clair, réessai, et création manuelle pré-remplie avec le texte brut.
- Limitation : quota d'imports IA par utilisateur et par jour (protection du quota gratuit).

## 5. Fonctionnalités téléphone (V1)

### 5.1 Import
- EX-01 Partage Android (Intent ACTION_SEND texte, URL, image(s)) depuis Instagram,
  TikTok, Facebook, Pinterest, YouTube, navigateur, galerie…
- EX-02 Collage d'un lien de page web.
- EX-03 Collage d'un texte libre.
- EX-04 Photo ou image depuis la galerie (livre de cuisine, carte manuscrite, capture
  d'écran), plusieurs images possibles pour une même recette.
- EX-05 Appareil photo intégré avec cadrage.
- EX-06 Détection du presse-papiers à l'ouverture (« Importer le lien copié ? »).
- EX-07 Création manuelle complète.
- EX-08 Détection des doublons (même URL source ou titre très proche).
- EX-09 Conservation de la source (URL, nom du site / créateur) et affichage du lien.
- EX-10 File d'imports : plusieurs imports en arrière-plan, notification à la fin.

### 5.2 Bibliothèque
- EX-20 Liste / grille des recettes avec image, titre, temps et tags.
- EX-21 Recherche plein texte (titre, ingrédients, tags), locale et cloud.
- EX-22 Filtres : collection, tags, temps total, difficulté, régime (végétarien, sans
  gluten…), favoris, déjà réalisée / jamais réalisée.
- EX-23 Tris : récentes, alphabétique, plus réalisées, temps.
- EX-24 « Mon frigo » : saisir des ingrédients disponibles et voir les recettes de sa
  bibliothèque réalisables (avec le nombre d'ingrédients manquants).
- EX-25 Favoris, historique « réalisée le… », note personnelle privée (1 à 5) et notes
  libres.
- EX-26 Tags générés par l'IA, modifiables.

### 5.3 Collections
- EX-30 Créer, renommer, supprimer, réordonner des collections (nom, emoji / couleur,
  image de couverture).
- EX-31 Une recette peut appartenir à plusieurs collections.
- EX-32 Ajout par appui long ou sélection multiple.
- EX-33 Collections intelligentes optionnelles (ex. « Rapides < 30 min », basées sur des
  filtres).

### 5.4 Fiche recette et mode cuisine
- EX-40 Fiche : image, infos, ingrédients, étapes, source, notes.
- EX-41 Ajustement des portions avec recalcul des quantités.
- EX-42 Conversion d'unités (métrique / impériale).
- EX-43 Édition complète de la recette.
- EX-44 Mode cuisine : une étape par écran, texte grand, écran toujours allumé,
  ingrédients de l'étape mis en évidence.
- EX-45 Minuteurs détectés dans les étapes, lancés en un geste, plusieurs en parallèle,
  notification et alarme même si l'app est en arrière-plan.
- EX-46 Cases à cocher pour les ingrédients préparés.
- EX-47 Action « Envoyer en mode cuisine sur la montre » : écrit dans le cloud l'état
  « recette en cours » (pas de transfert direct).
- EX-48 Partage externe en texte formaté ou PDF (sans fonction communautaire).

### 5.5 Liste de courses
- EX-50 Sélection d'une ou plusieurs recettes (avec leur nombre de portions) → génération
  de la liste.
- EX-51 Fusion intelligente des ingrédients identiques avec addition des quantités et
  conversion d'unités compatibles (« 200 g + 0,5 kg farine » → « 700 g farine »).
- EX-52 Classement par rayon (fruits et légumes, crèmerie, épicerie…), via l'IA ou un
  dictionnaire local.
- EX-53 Ajout manuel d'articles, édition, suppression.
- EX-54 Cocher les articles achetés (synchronisé avec la montre via le cloud).
- EX-55 Marquer les produits « déjà dans le placard » à exclure.
- EX-56 Plusieurs listes possibles, partage externe en texte.

### 5.6 Compte et paramètres
- EX-60 Inscription / connexion (Google, e-mail).
- EX-61 Profil minimal (pseudo, avatar), prévu pour la V2.
- EX-62 Préférences : unités, langue, portions par défaut, régimes alimentaires.
- EX-63 RGPD : export de toutes les données (JSON), suppression du compte et de toutes
  les données (cloud + images), politique de confidentialité (mentionnant le traitement
  IA par Google Gemini).
- EX-64 À la connexion sur le téléphone, connexion automatique de la montre appairée
  (voir 2.2). Écran « Appareils connectés » listant la montre, avec un bouton pour la
  déconnecter.
- EX-65 Indicateur d'état de synchronisation et action « Synchroniser maintenant ».

## 6. Fonctionnalités Wear OS (V1)
- EX-70 Connexion via le téléphone uniquement (flux décrit en 2.2) : aucun champ de saisie
  sur la montre. Écran d'attente explicite avec bouton « Ouvrir sur le téléphone »
  (Remote Activity) et gestion des cas : téléphone absent, app non installée sur le
  téléphone, utilisateur non connecté, code expiré (nouvel essai automatique).
- EX-71 Accès aux recettes depuis le cloud (Supabase), cache Room pour le hors ligne.
- EX-72 Navigation : favoris, récentes, collections, recherche (vocale + liste).
- EX-73 Fiche compacte : temps, portions, ingrédients cochables.
- EX-74 Mode cuisine : une étape par écran, navigation par swipe ou couronne rotative,
  écran toujours allumé (mode ambiant géré).
- EX-75 Minuteurs d'étapes avec vibrations, fonctionnant en arrière-plan (service de
  premier plan / Ongoing Activity).
- EX-76 Reprise automatique de la recette « en cours » envoyée depuis le téléphone (via
  l'état cloud).
- EX-77 Liste de courses au poignet : cocher les articles en magasin.
- EX-78 Tile : favoris / dernière recette et liste de courses en cours.
- EX-79 Complication optionnelle : minuteur en cours.
- Contraintes : interface ronde et carrée, textes lisibles, chargement rapide, images
  réduites (miniatures dédiées), consommation batterie minimale.

## 7. Exigences non fonctionnelles
- Coût : 0 € en V1 (offre gratuite Supabase, quota gratuit Gemini). Aucune dépendance
  payante.
- Performance : démarrage < 2 s, affichage depuis le cache instantané, import IA < 10 s.
- Hors ligne : consultation complète des recettes déjà synchronisées sur les deux
  appareils.
- Sécurité :
  Row Level Security activée sur TOUTES les tables (un utilisateur n'accède qu'à ses
  données). Bucket Storage privé avec URLs signées. Aucune clé secrète dans l'APK : seule
  la clé publique (anon) et l'URL du projet, lues depuis `local.properties` (exclu de git).
  Clé Gemini uniquement dans les secrets des Edge Functions.
  Code de session appareil : usage unique, durée de vie 60 s, jamais journalisé.
  Session de la montre stockée chiffrée. L'Edge Function `create-device-session` exige
  un JWT valide et est limitée en fréquence.
- Accessibilité : TalkBack, contrastes, tailles de police dynamiques.
- Internationalisation : français par défaut, anglais prêt (ressources strings).
- Fiabilité : maintien de l'activité du projet Supabase (synchro périodique), gestion
  propre des erreurs réseau et des quotas.
- Tests : use cases, normalisation des quantités, fusion de la liste de courses, moteur de
  synchronisation et conflits.

## 8. Préparation de la V2 communautaire (prévoir, NE PAS exposer)
- Schéma SQL V1 (migrations versionnées dans `supabase/migrations`) :
  - `profiles` (id, pseudo, avatar_url, bio, created_at)
  - `recipes` (id, owner_id, visibility [PRIVATE|UNLISTED|PUBLIC] DEFAULT PRIVATE,
    origin [CREATED|IMPORTED|FORKED], forked_from_id NULL, source_url, source_name,
    title, description, servings, prep_time, cook_time, difficulty, image_path,
    tags, diet_flags, language, avg_rating NULL, rating_count DEFAULT 0,
    cooked_count DEFAULT 0, created_at, updated_at, deleted_at)
  - `ingredients`, `steps` (liés à recipes)
  - `collections`, `collection_recipes`
  - `shopping_lists`, `shopping_items`
  - `user_recipe_state` (favori, réalisée, note privée, progression de cuisson)
  - `device_sessions` (appareils connectés)
- En V1, visibility vaut toujours PRIVATE.
- Table `profiles` existante (pseudo, avatar).
- Policies RLS écrites pour accepter un futur « OR visibility = 'PUBLIC' ».
- Index full-text déjà en place.
- Feature flags centralisés (`FeatureFlags.COMMUNITY_ENABLED = false`) ; aucun écran
  communautaire compilé dans l'UI en V1.
- Règle de droit d'auteur codée dès maintenant dans le domaine : une recette
  origin = IMPORTED ne pourra JAMAIS passer en PUBLIC. Seules les recettes CREATED
  (ou FORKED avec modifications substantielles et attribution) le pourront.
- Fonctionnalités prévues pour la V2 (NE PAS implémenter, mais ne pas bloquer) :
  recettes publiques et non listées (lien de partage), découverte et recherche globale,
  « Mon frigo » sur la base publique, notes et avis réservés aux personnes ayant réalisé la
  recette (« J'ai testé »), classement par moyenne bayésienne, photos de résultats, profils
  et abonnements aux créateurs, signalement, modération assistée par IA, blocage
  d'utilisateurs. Tables futures : ratings, saved_recipes, follows, reports.

## 9. Hors périmètre V1
Toute fonctionnalité communautaire visible, planificateur de repas, version iOS ou web,
paiement.

## 10. Instructions pour Kiro
1. Générer requirements.md au format EARS à partir de ce document.
2. Proposer design.md : modules, schéma SQL et policies RLS, Edge Functions
   (`parse-recipe` : prompt et schéma JSON ; `create-device-session`), stratégie de
   synchronisation et de conflits, flux d'authentification de la montre via le téléphone.
   Attendre ma validation avant de continuer.
3. Découper tasks.md en petites tâches incrémentales, dans cet ordre :
   module shared + modèles → Room → Supabase (Auth, schéma, RLS, migrations)
   → moteur de synchronisation → import texte + Edge Function IA → écran de validation
   → import URL → OCR → partage Android → bibliothèque et recherche → collections
   → fiche et mode cuisine → liste de courses → compte et RGPD → Wear OS
   (authentification via le téléphone + Edge Function create-device-session,
   synchronisation cloud, écrans, mode cuisine, tile).
4. Chaque tâche doit compiler et être testée avant de passer à la suivante.