# Revue du design technique — SmartRecipes V1

Documents relus : `SDD.md` (source de vérité), `requirements.md` (46 exigences, H1 à H9), `design.md` (§1 à §18). J'ai aussi vérifié les fichiers du projet cités par le design (`gradle/libs.versions.toml`, `gradle.properties`, wrapper, `settings.gradle.kts`, `app|wear/build.gradle.kts`, manifeste `wear`). Aucune build ni aucun test n'a été lancé (travail documentaire).

Le design est complet par rapport à la section 10.2 du SDD et très détaillé. Il reste deux défauts bloquants qui casseraient des fonctions à l'exécution (recherche full-text / écriture des recettes, ré-enregistrement d'une montre) et plusieurs points à préciser ou à aligner avec les exigences.

Échelle : HIGH = défaut qui casse une exigence ou la sécurité ; MEDIUM = ambiguïté, incohérence ou cas non spécifié qui forcerait le codeur à deviner ; NIT (= LOW) = amélioration non bloquante.

## Constats

### 1. HIGH — `unaccent(text)` échoue avec `search_path = ''` : toute écriture de recette serait refusée
- Où : §4.4 `refresh_recipe_search`, `search_recipes` (migration `…0009_search.sql`).
- SDD : §8 « Index full-text déjà en place », EX-21.
- Problème : la forme à un argument `extensions.unaccent(text)` cherche le dictionnaire `unaccent` via le `search_path`. Les fonctions sont déclarées `set search_path = ''`, donc l'appel lève `text search dictionary "unaccent" does not exist`. `refresh_recipe_search` est appelée par les triggers AFTER de `recipes` et `ingredients` : l'erreur annulerait l'INSERT/UPDATE de chaque recette et de chaque ingrédient (le push échouerait en rejet « définitif »), et `search_recipes` échouerait aussi.
- Correction attendue : utiliser la forme à deux arguments, qualifiée, partout :
  ```sql
  extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(r.title, ''))
  ```
  (idem pour tags, ingrédients, description et `p_query`). Ajouter au test pgTAP `lww_trigger`/`search` : insertion d'une recette + d'un ingrédient et appel de `search_recipes('creme')` qui retrouve « Crème ».

### 2. HIGH — Une montre déjà enregistrée ne peut plus ré-enregistrer sa ligne `device_sessions`
- Où : §5.2 policies `device_sessions_insert_self` / `device_sessions_update_self`, §9.3 (étape « upsert device_sessions »), §9.4 (id = UUID v5(owner_id, device_id)), §9.5 cas C.
- SDD : §2.2 (connexion et reconnexion de la montre), EX-64 (écran « Appareils connectés »). Exigences 9.8, 11.7.
- Problème : l'id de la ligne est déterministe. Après une déconnexion (cas C : `revoked_at` posé), une révocation par le téléphone, ou un simple `LocalDataWiper` suivi d'une reconnexion, la montre obtient un NOUVEAU `session_id`. L'upsert PostgREST (`INSERT … ON CONFLICT DO UPDATE`) tombe sur la ligne existante ; la policy UPDATE exige `revoked_at is null and auth_session_id = <nouveau session_id>`, ce qui est faux pour l'ancienne ligne. PostgreSQL lève alors une violation RLS (42501), traitée comme rejet définitif. Résultat : la montre reconnectée n'apparaît pas (ou plus correctement) dans « Appareils connectés » et ne peut plus être révoquée par le téléphone (son `auth_session_id` reste l'ancien). En plus, §7.9 dit que `LocalDataWiper` « efface les DataStore » sans dire si l'`InstallationId` (`device_id`) survit : s'il est effacé, chaque reconnexion crée une nouvelle ligne et les anciennes restent « actives » quand la déconnexion vient d'un refresh refusé (Ex. 9.9).
- Correction attendue (choix recommandé) : remplacer l'upsert client par une RPC dédiée, la seule autorisée pour l'enregistrement :
  ```sql
  create or replace function public.register_device_session(p_device_id uuid, p_device_name text)
  returns uuid language plpgsql security definer set search_path = '' as $$
  declare v_uid uuid := auth.uid();
          v_sid uuid := ((select auth.jwt()) ->> 'session_id')::uuid;
          v_id  uuid;
  begin
    if v_uid is null or v_sid is null then raise exception 'unauthorized' using errcode = '42501'; end if;
    if char_length(p_device_name) not between 1 and 80 then raise exception 'invalid name' using errcode = '22023'; end if;
    insert into public.device_sessions (id, owner_id, device_id, device_name, auth_session_id, last_seen_at, revoked_at, updated_at)
    values (gen_random_uuid(), v_uid, p_device_id, p_device_name, v_sid, now(), null, now())
    on conflict (owner_id, device_id) do update
      set auth_session_id = excluded.auth_session_id, device_name = excluded.device_name,
          revoked_at = null, deleted_at = null, last_seen_at = now(),
          updated_at = greatest(now(), public.device_sessions.updated_at + interval '1 millisecond')
    returning id into v_id;
    return v_id;
  end $$;
  revoke execute on function public.register_device_session(uuid, text) from public, anon;
  grant execute on function public.register_device_session(uuid, text) to authenticated;
  ```
  Supprimer alors la policy `device_sessions_insert_self`. Garder `device_sessions_update_self` uniquement pour `last_seen_at` et l'auto-révocation. Écrire explicitement dans §7.9 : « `InstallationId` n'est PAS effacé par `LocalDataWiper` ». Mettre à jour §3.3, §9.3, §9.4, §14 (test pgTAP : connexion → déconnexion → reconnexion de la même montre) et la liste des fonctions exposées de §4.6 (D-6 : il y en aura deux).

### 3. MEDIUM — `profiles` n'a pas de policy INSERT alors que les éditions de profil passent par UPSERT
- Où : §5.2 (« profiles : insertion par trigger uniquement »), §7.2 (« UPSERT = ligne complète (création ou édition sur le téléphone) »), §7.3 (`upsert(list) { onConflict = "id" }`).
- SDD : EX-61. Exigence 31.6.
- Problème : un upsert PostgREST est un `INSERT … ON CONFLICT`, qui exige une policy INSERT même si la ligne existe. Sans elle, chaque modification de pseudo ou d'avatar est rejetée en `42501`, puis retirée de la file comme rejet définitif. L'édition du profil serait cassée.
- Correction attendue : écrire dans §7.2 que `profiles` est écrite UNIQUEMENT en `PATCH` (colonnes `pseudo`, `avatar_url`, `bio`, `updated_at`) via `update().eq("id", uid)`, jamais en UPSERT. Ou ajouter `create policy profiles_insert_own on public.profiles for insert to authenticated with check (id = (select auth.uid()));`. Choisir l'une des deux et le préciser. Ajouter un cas pgTAP.

### 4. MEDIUM — Rejet définitif dans un lot de 100 : la ligne fautive n'est pas identifiable
- Où : §7.3 (« regroupées par lots de 100 » + tableau « définitive → ligne retirée de la file »).
- SDD : §2.1 (file d'écritures). Exigences 2.6, 2.7.
- Problème : un upsert en lot est une seule instruction SQL. Une seule ligne invalide (CHECK `23514`, FK `23503`, RLS `42501`, `P0001`) fait échouer tout le lot, et PostgREST ne dit pas quelle ligne est en cause. Le design ne précise pas si les 100 lignes sont retirées (perte de 99 écritures valides) ou seulement une.
- Correction attendue : ajouter la règle « sur une erreur définitive d'un lot de plus d'une ligne, le worker renvoie ce lot ligne par ligne (même ordre `seq`) ; seule la ligne qui échoue seule est retirée de la file et restaurée depuis le serveur ». Ajouter le cas aux tests `PushWorker` de §14.

### 5. MEDIUM — Déconnexion du téléphone avec des écritures en attente : perte silencieuse
- Où : §7.9 `LocalDataWiper` (`clearAllTables()` vide aussi `pending_writes` et `pending_uploads`), §8 (`NotAuthenticated` → `LocalDataWiper`), §9.5 cas A.
- SDD : §2.1 (« écritures hors ligne mises en file, envoyées au retour du réseau »). Exigences 2.8, 6.5, 11.2, H6.
- Problème : rien n'est spécifié quand l'utilisateur se déconnecte alors que des écritures ou des images ne sont pas encore poussées. Elles seraient effacées sans avertissement, ce qui contredit l'esprit de l'exigence 6.5.
- Correction attendue : spécifier le flux de déconnexion volontaire : 1) si en ligne, `SyncEngine.push()` (timeout 10 s) ; 2) si `pending_writes + pending_uploads > 0` ensuite, dialogue « n modifications ne sont pas encore synchronisées et seront perdues. Se déconnecter quand même ? » ; 3) seulement après confirmation, révocation des montres, `signOut(LOCAL)` et `LocalDataWiper`. Pour une déconnexion subie (refresh refusé), garder la file jusqu'à reconnexion du MÊME `user_id` (ou l'effacer) : choisir et écrire la règle. Même règle sur la montre (§9.4).

### 6. MEDIUM — Image de la source ignorée pour les pages web sans données structurées
- Où : §6.2 algorithme (branche Readability `K`) et règles de mappage.
- SDD : §4 étape 6 (« Image : celle de la source… »). Exigence 18.1.
- Problème : `og:image` (et `og:site_name`) n'est lu que pour les domaines « réseau social ». Pour une page de blog sans JSON-LD/microdata, Readability ne garde que le texte : Gemini n'a aucune URL d'image et renvoie `image_url = null`, alors que la page en fournit une. Exigence 18.1 non tenue.
- Correction attendue : pour tout `kind = URL`, extraire `og:image`, `og:site_name` et `og:title` de la page avant la branche Readability. Après validation de la réponse Gemini : `image_url := image_url ?? og:image` et `source_name := source_name ?? og:site_name`. Même repli dans le mappage JSON-LD/microdata si `image` est absent. Ajouter un test `deno test` « page sans JSON-LD avec og:image ».

### 7. MEDIUM — Exigences contredites par des décisions de design (D-2, D-3, D-15)
- Où : `requirements.md` 8.4, 4.4, 20.2 vs `design.md` §6.3/§6.4 (D-2), §4.1/§7.4 (D-3), §10.3 (D-15).
- SDD : §2.2 étape 3, §2.1, EX-07.
- Problème :
  - Ex. 8.4 : « générer **via l'API admin Supabase** un code à usage unique ». Le design génère un code aléatoire opaque dans `create-device-session` et n'appelle l'API admin (`generateLink`) que dans une 3ᵉ fonction, `redeem-device-session`. Le choix est justifié (la durée OTP est globale au projet) et conforme au « ex. » du SDD, mais l'exigence telle qu'écrite est contredite.
  - Ex. 4.4 : « `updated_at` postérieur au dernier sync ». Le design utilise `synced_at` comme curseur.
  - Ex. 20.2 : « créée manuellement → `origin = CREATED` ». Le design enregistre en `IMPORTED` la création manuelle issue d'un échec d'import.
- Correction attendue : reformuler les exigences pour qu'elles collent aux décisions (sous réserve de validation de D-2, D-3 et D-15). Par exemple :
  - 8.4 : « WHEN la requête est valide, THE SYSTEM SHALL générer un code opaque à usage unique lié à l'utilisateur du JWT ; WHEN la montre présente ce code valide, THE SYSTEM SHALL obtenir via l'API admin Supabase (generateLink) un jeton à usage unique échangeable par verifyOtp. »
  - 4.4 : « … dont l'horodatage serveur de dernière écriture (`synced_at`) est postérieur au dernier sync ».
  - 20.2 : « … depuis l'écran de création, `origin = CREATED` ; depuis le repli d'un import échoué, `origin = IMPORTED` ».
  Ajouter `redeem-device-session` aux exigences 8 et 38 (fonction sans JWT, code à usage unique, `no-store`, jamais journalisée).

### 8. NIT — Commentaire trompeur dans `tg_sync_columns`
- Où : §4.2, branche `if new.updated_at is null then new.updated_at := now(); -- écriture sans horodatage client (RPC)`.
- Problème : dans un UPDATE, une colonne absente du SET garde sa valeur OLD ; `new.updated_at` n'est donc jamais null, et une écriture serveur qui oublie `updated_at` est silencieusement ignorée par la règle `<=`.
- Correction : remplacer le commentaire par « toute écriture hors `server_write` DOIT poser `updated_at` (sinon elle est ignorée) » et ajouter un cas pgTAP.

### 9. NIT — Contraintes de clé étrangère Room non précisées
- Où : §7.1 (`IngredientEntity` « FK `recipe_id` sans `onDelete` »).
- Problème : une FK Room est appliquée par SQLite. Un événement Realtime ou une page de pull reçue avant le parent (ex. `user_recipe_state` d'une recette pas encore reçue sur la montre) lèverait `SQLiteConstraintException`.
- Correction : ne déclarer aucune `@ForeignKey` sur les entités synchronisées (index simples uniquement), ou `deferred = true` dans la transaction de merge. Écrire le choix.

### 10. NIT — Deep link `smartrecipes://open` non déclaré côté téléphone
- Où : §9.2 (bouton « Ouvrir sur le téléphone »), §10.1.
- Correction : déclarer sur `MainActivity` (app) un `intent-filter` `VIEW` + `DEFAULT` + `BROWSABLE`, `scheme="smartrecipes" host="open"` (et `host="auth"` pour le callback de §8). Sinon `RemoteActivityHelper` échoue.

### 11. NIT — Dépendances Wear manquantes au tableau de stack
- Où : §1.1. `AmbientLifecycleObserver` (§12.3) vient de `androidx.wear:wear` (≥ 1.3), absent de la liste. Ajouter aussi `androidx.wear.compose:compose-foundation` (déjà dans le catalogue) pour `rotaryScrollable`.

### 12. NIT — Nommage incohérent du service de minuteurs du téléphone
- Où : §2.3 liste `app/timers/PhoneTimerScheduler`, alors que §12.2 parle de `CookingTimerService` pour le téléphone (classe placée dans `wear/timers`). Préciser : `app/timers/PhoneCookingTimerService` + `PhoneTimerScheduler`, ou une implémentation commune dans `shared`.

### 13. NIT — Tile : « dernier favori consulté » sans source de donnée
- Où : §12.4 vs exigence 36.3. Aucune colonne ni clé DataStore ne mémorise la dernière recette consultée sur la montre. Ajouter une clé DataStore locale `last_viewed_recipe_id` (non synchronisée), mise à jour à l'ouverture d'une fiche.

### 14. NIT — Recherche trigramme sans usage d'index
- Où : §4.4 `search_recipes` : `extensions.similarity(r.title, p_query) > 0.3` n'utilise pas l'index GIN `recipes_title_trgm_idx`. Utiliser l'opérateur `operator(extensions.%)` (seuil `pg_trgm.similarity_threshold`) ou accepter le scan (volumétrie personnelle). Préciser le choix.

### 15. NIT — Résurrection après purge
- Où : §4.5. Une écriture en attente de plus de 90 jours, poussée après la purge du tombstone, recrée la ligne supprimée (l'INSERT ne voit pas d'ancienne version). Règle simple : à la resynchronisation complète (> 80 jours), abandonner les `pending_writes` dont `updated_at` < `now() − 90 j`.

### 16. NIT — `storage.list` n'est pas récursif
- Où : §6.5. `supabase-js` `storage.from().list(prefix)` ne liste qu'un niveau. Préciser le parcours : `list(uid)` → dossiers `recipes`, `collections`, `avatar` → `list(uid/recipes/<id>)`… (ou requête SQL sur `storage.objects` via service role, puis `remove`).

## Hypothèses vérifiées
- Projet existant : AGP 9.4.1, Kotlin 2.2.20, Compose BOM 2025.09.01, wearCompose 1.5.0, `composeMaterial3 = "1.3.2"`, Gradle 9.6.0, `android.builtInKotlin=false`, `android.newDsl=false`, `jvmTarget = "11"`, `minSdk 26` : conformes à §1.1 et §1.2.
- `applicationId` actuellement différents (`com.example.androidwearoshello` / `.wear`) : constat exact. Le design les unifie et unifie la signature (SDD §2.2, Ex. 12), avec documentation README.
- Manifeste `wear` : `uses-feature android.hardware.type.watch` et meta-data `standalone=true` présents, conservés par le design (règle de steering).
- `rootProject.name = "android-wearos-hello"`, `include(":app", ":wear")` : la modification §1.2.1 est cohérente.
- Couverture SDD §10.2 : modules shared/app/wear + Clean Archi/MVVM/Hilt (§2) ; toutes les tables §8 + `ai_import_quota`/`ai_global_usage` (§4.3) ; index full-text (§4.4) ; soft delete + triggers `updated_at` (§4.2, §4.5) ; RLS sur toutes les tables avec extension PUBLIC par policy permissive additionnelle (§5.1, §5.2) ; bucket privé + URLs signées + policies (§5.3) ; `supabase/migrations` (§5.4) ; `parse-recipe` avec prompt, schéma JSON strict couvrant les 17 champs de §4.3 (dont `steps[].timer_seconds` seul optionnel), JSON-LD/microdata/Open Graph et quota quotidien (§6.2) ; `create-device-session` avec JWT, limitation 3/min 10/h, code 60 s à usage unique stocké haché et jamais journalisé (§6.3, §2.6, §6.1) ; Room + file d'écritures (§7.1, §7.2) ; sync incrémentale/Realtime/WorkManager/LWW/soft delete (§7) ; chemins `/auth/request`, `/auth/token`, `/auth/logout`, CapabilityClient, verifyOtp, stockage chiffré Tink + Keystore, interdiction de copier les tokens, états d'erreur EX-70, diagrammes mermaid (§9) ; IMPORTED ≠ PUBLIC (domaine + contrainte SQL + `origin` immuable) et `COMMUNITY_ENABLED = false` (§2.4, §3.2) ; normalisation et fusion (§10.4, §11.6) ; minuteurs (§12.2) ; Tile et complication (§12.2, §12.4) ; tests (§14) ; coût 0 € (§17).
- Policies RLS d'isolation : `owner_id = (select auth.uid())` en lecture/insert/update, contrôle du parent sur les tables enfants, aucune policy DELETE, tables serveur sans policy. Les policies permissives se combinent par OR : l'ajout d'une policy `visibility = 'PUBLIC'` en V2 est bien non destructif.
- Ordre des triggers BEFORE sur `recipes` (`recipes_protect` avant `recipes_sync`, ordre alphabétique PostgreSQL) : correct. Le trigger `recipes_search` (`after … update of title, tags, description`) ne se redéclenche pas sur l'UPDATE de `search_document`.
- supabase-js : `auth.admin.generateLink({ type: 'magiclink', email })` renvoie `properties.hashed_token` sans envoyer d'e-mail ; `verifyOtp({ token_hash, type: 'email' })` crée une session neuve. supabase-kt fournit `verifyEmailOtp(type = OtpType.Email.EMAIL, tokenHash = …)`, `signInWith(IDToken)` avec `nonce`, `signOut(SignOutScope.LOCAL)`, `SessionManager` personnalisable, `postgresChangeFlow` avec filtre.
- Le JWT Supabase porte le claim `session_id` ; supprimer la ligne `auth.sessions` invalide ses refresh tokens.
- Wear OS : MessageClient/CapabilityClient/NodeClient, `WearableListenerService` avec `pathPrefix`, livraison limitée aux apps de même applicationId et même signature, `RemoteActivityHelper.startRemoteActivity(intent, nodeId)`, `OngoingActivity`, `SuspendingComplicationDataSourceService`, `TimeDifferenceComplicationText`, `NoDataComplicationData`, Horologist `SuspendingTileService`, Compose for Wear M3 (`AppScaffold`, `ScreenScaffold`, `TransformingLazyColumn`, `EdgeButton`), `SwipeDismissableNavHost` : API existantes et bien utilisées.
- Gemini : endpoint `v1beta/models/{model}:generateContent`, en-tête `x-goog-api-key`, `responseMimeType` + `responseJsonSchema` (repli `responseSchema`), `thinkingBudget: 0` sur Flash.
- Offre gratuite Supabase : 500 Mo base, 1 Go Storage, 5 Go de bande passante, 500 000 invocations, 200 connexions Realtime, 2 M messages, pause après 7 jours d'inactivité, `pg_cron` disponible.

## Hypothèses non vérifiées ou fausses
- FAUX : `extensions.unaccent(text)` utilisable avec `search_path = ''` (constat 1).
- FAUX : l'upsert de `device_sessions` par la montre fonctionne à chaque reconnexion (constat 2).
- FAUX : un UPSERT client de `profiles` passe sans policy INSERT (constat 3).
- FAUX (commentaire) : `new.updated_at` est null pour une écriture serveur sans horodatage (constat 8).
- NON VÉRIFIÉ : le rôle propriétaire des fonctions `security definer` garde le droit `DELETE` sur `auth.sessions` après les restrictions Supabase de 2025 sur le schéma `auth`. Le design le signale (D-6) ; le test pgTAP de §14 devrait vérifier que la ligne `auth.sessions` est bien supprimée, pas seulement l'absence d'effet sur un autre utilisateur.
- NON VÉRIFIÉ : limites quotidiennes actuelles de l'offre gratuite Gemini pour `gemini-2.5-flash` et disponibilité de cette offre pour un projet situé dans l'UE. Le design le signale (D-4 « À VÉRIFIER »).
- NON VÉRIFIÉ : support des unions de types avec `null` (`"type": ["string","null"]`, `enum` contenant `null`) par `responseJsonSchema`. Le repli `responseSchema` + zod couvre le risque.
- NON VÉRIFIÉ : compatibilité `@mozilla/readability` + `linkedom` sous Deno 2 Edge Runtime.
- NON VÉRIFIÉ (justification probablement inexacte) : D-12 affirme que Wear Compose M3, Tiles M3 et Horologist « exigent Wear OS 3+ ». Leur `minSdk` est plus bas ; `minSdk 30` reste un choix acceptable, mais la justification doit être corrigée ou vérifiée.
- NON VÉRIFIÉ : compatibilité Hilt, KSP2 et android-junit5 avec AGP 9.4.1 (le design le signale en D-11, avec repli).

## Verdict
2 HIGH, 5 MEDIUM, 9 NIT → **CHANGES_REQUESTED**.
