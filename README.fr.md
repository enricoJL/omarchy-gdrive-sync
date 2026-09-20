# Google Drive pour Omarchy

*[English version](README.md)* — l'interface du plugin est en anglais.

Plugin Omarchy (`com.github.enricojl.gdrive-sync`) qui remplace « Google Drive pour ordinateur » sur Arch/Omarchy :
synchronisation bidirectionnelle entre Google Drive et un dossier local avec `rclone bisync`,
indicateur dans la barre, suivi en direct, problèmes visibles, choix du dossier.

## Prérequis

Omarchy fournit tout ce qu'il faut sauf **rclone**, à installer et configurer soi-même (l'installateur de
plugins Omarchy n'installe jamais de paquet et n'exécute aucun script) :

```bash
omarchy pkg add rclone
rclone config          # créer un distant de type « drive », par exemple nommé « gdrive »
```

### Créer son propre identifiant client Google (requis)

Le `client_id` Google Drive partagé de rclone est retiré en 2026 et fortement limité en débit : le distant
doit utiliser ton propre client OAuth. Ça prend environ cinq minutes et ne demande pas de compte payant.

1. Ouvre la [console Google Cloud](https://console.cloud.google.com/) avec le compte Google propriétaire
   du Drive et crée un projet (ex. `rclone`) via le sélecteur de projet en haut.
2. **API et services → Bibliothèque** : cherche **Google Drive API** et clique **Activer**.
3. **API et services → Écran de consentement OAuth** (aussi appelé *Google Auth Platform → Branding/Audience*) :
   - Nom de l'application : `rclone` ; adresse d'assistance et contact développeur : ton adresse.
   - Audience : **Externe**.
   - Dans **Audience → Utilisateurs test**, ajoute ta propre adresse Gmail. Tant que l'application reste
     en mode *Test*, seuls les utilisateurs test peuvent l'autoriser — c'est suffisant pour un usage personnel.
   - Facultatif : clique **Publier l'application** pour sortir du mode *Test*. Sinon Google fait expirer le
     jeton après 7 jours et rclone te redemandera de te reconnecter chaque semaine. Publier une application
     personnelle ne demande pas de validation tant que tu n'utilises que la portée Drive pour toi-même.
4. **API et services → Identifiants → Créer des identifiants → ID client OAuth** :
   type **Application de bureau**, n'importe quel nom. Copie l'**ID client** et le **code secret du client**
   (ou télécharge le JSON — les valeurs sont dans `installed.client_id` / `installed.client_secret`).
5. Applique-les au distant et ré-autorise (une fenêtre de navigateur s'ouvre ; accepte l'avertissement
   « Google n'a pas validé cette application » avec *Continuer*, puisque c'est ta propre application) :

   ```bash
   rclone config update gdrive client_id "TON_ID.apps.googleusercontent.com" client_secret "TON_SECRET"
   rclone config reconnect gdrive:
   rclone lsd gdrive:          # doit lister tes dossiers de premier niveau
   ```

Si tu crées le distant depuis zéro avec `rclone config`, colle le même ID client et le même secret quand il
te les demande. Aucune resynchronisation n'est nécessaire après un changement de client ID — seul le jeton change.

Voir aussi [rclone.org/drive — Making your own client_id](https://rclone.org/drive/#making-your-own-client-id).

## Composants

| Fichier | Rôle |
|---|---|
| `manifest.json` | Déclaration du plugin (widget de barre, réglages) |
| `Panel.qml` | Icône dans la barre + panneau (état, progression, actions, erreurs, fichiers, historique, sélecteur de dossier) |
| `Service.qml` | État partagé : appelle `gdrive-sync.py`, rafraîchit, applique les réglages |
| `Model.js` | Analyse du JSON d'état et formatage (français) |
| `DriveIcon.qml` | Icône triangle Drive avec point d'état |
| `gdrive-sync.py` | Lanceur de `rclone bisync` (unité systemd) **et** commande d'état/contrôle pour le panneau |

## Fonctionnement

- Une unité `systemd --user` (`gdrive-sync.timer` → `gdrive-sync.service`) lance
  `gdrive-sync.py run` toutes les *N* secondes (mesurées après la fin du passage précédent).
- Chaque passage exécute `rclone bisync <distant> <dossier> --rc --use-json-log …`, journalise dans
  `~/.local/state/gdrive-sync/logs/run-*.log` (12 derniers conservés), puis écrit `last-run.json`
  et une ligne dans `history.jsonl`.
- Pendant un passage, le panneau lit la progression en direct via l'API `rclone rc` (`127.0.0.1:5573`).
- Avec `watchLocal`, `gdrive-sync-watch.service` exécute `inotifywait -m -r` sur le dossier local et lance
  une synchro après 20 s de calme (120 s au maximum). Les événements produits par la synchro elle-même sont
  ignorés, ainsi que les entrées cachées (`.obsidian/…`, `.git/…`) et les fichiers temporaires — ils sont
  quand même synchronisés au passage du minuteur. Google Drive n'offre pas de signal équivalent : les
  changements distants ne sont vus qu'au passage du minuteur.
- Une notification est envoyée quand la synchronisation passe de OK à échec (et inversement).
- La configuration du lanceur est dans `~/.config/gdrive-sync/config.json` ; elle est écrite
  automatiquement à partir des réglages du widget (`shell.json`), qui font foi.

## Réglages du widget (`omarchy bar set com.github.enricojl.gdrive-sync <clé> <valeur>`)

| Clé | Défaut | Description |
|---|---|---|
| `remote` | `gdrive:` | Distant rclone (`gdrive:` ou `gdrive:SousDossier`) |
| `localDir` | `~/GoogleDrive` | Dossier local synchronisé |
| `intervalSec` | `300` | Intervalle entre les vérifications sur Drive, mesuré après la fin du passage précédent (30–3600 s). C'est le délai maximal pour voir un changement fait depuis un autre appareil. |
| `watchLocal` | `true` | Surveille le dossier local avec inotify et synchronise quelques secondes après une modification (`omarchy bar set … watchLocal false --json` pour désactiver) |
| `refreshIntervalSec` | `15` | Rafraîchissement de l'état quand rien ne tourne |

Options rclone supplémentaires : clé `extraArgs` dans `~/.config/gdrive-sync/config.json`
(défaut : `["--drive-skip-gdocs"]`).

## Utilisation

- Clic gauche sur l'icône : ouvrir le panneau · clic droit : synchroniser maintenant · clic milieu : ouvrir le dossier.
- Dans le panneau : `s` synchroniser, `p` pause/reprise, `o` ouvrir le dossier, `f` choisir le dossier,
  `r` resynchroniser (quand requis), `c` annuler (pendant un passage), `Échap` fermer.
- IPC : `omarchy-shell com.github.enricojl.gdrive-sync <toggle|syncNow|resync|pause|resume|status>`.
- Ligne de commande : `python3 gdrive-sync.py <status|sync-now|resync|cancel|pause|resume|install|uninstall|watch|dirs [chemin]|set-folder <chemin>>`.

## Resynchronisation

`rclone bisync` exige un passage `--resync` à la première synchronisation, après un changement de
dossier, ou après une erreur critique (« path1 and path2 are out of sync »). Le panneau l'indique et
propose le bouton. Le passage utilise `--resync-mode newer` : les fichiers présents d'un seul côté sont
copiés de l'autre côté (rien n'est supprimé), et en cas de différence le plus récent l'emporte.

## Développement

Le plugin vit dans `~/.config/omarchy/plugins/com.github.enricojl.gdrive-sync/` (le shell recharge à chaque
sauvegarde) ; `~/Projects/omarchy-gdrive-sync` est un lien symbolique vers ce dossier.
Vérifier le manifeste : `omarchy plugin validate ~/Projects/omarchy-gdrive-sync`.
Journal du shell : `journalctl --user -f | grep -i -E 'gdrive|qml'`.
