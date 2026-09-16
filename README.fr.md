# Google Drive pour Omarchy

*[English version](README.md)* — l'interface du plugin est en anglais.

Plugin Omarchy (`com.github.enricojl.gdrive-sync`) qui remplace « Google Drive pour ordinateur » sur Arch/Omarchy :
synchronisation bidirectionnelle entre Google Drive et un dossier local avec `rclone bisync`,
indicateur dans la barre, suivi en direct, problèmes visibles, choix du dossier.

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
- Une notification est envoyée quand la synchronisation passe de OK à échec (et inversement).
- La configuration du lanceur est dans `~/.config/gdrive-sync/config.json` ; elle est écrite
  automatiquement à partir des réglages du widget (`shell.json`), qui font foi.

## Réglages du widget (`omarchy bar set com.github.enricojl.gdrive-sync <clé> <valeur>`)

| Clé | Défaut | Description |
|---|---|---|
| `remote` | `gdrive:` | Distant rclone (`gdrive:` ou `gdrive:SousDossier`) |
| `localDir` | `~/GoogleDrive` | Dossier local synchronisé |
| `intervalSec` | `60` | Intervalle entre les passages (30–3600 s) |
| `refreshIntervalSec` | `15` | Rafraîchissement de l'état quand rien ne tourne |

Options rclone supplémentaires : clé `extraArgs` dans `~/.config/gdrive-sync/config.json`
(défaut : `["--drive-skip-gdocs"]`).

## Utilisation

- Clic gauche sur l'icône : ouvrir le panneau · clic droit : synchroniser maintenant · clic milieu : ouvrir le dossier.
- Dans le panneau : `s` synchroniser, `p` pause/reprise, `o` ouvrir le dossier, `f` choisir le dossier,
  `r` resynchroniser (quand requis), `c` annuler (pendant un passage), `Échap` fermer.
- IPC : `omarchy-shell com.github.enricojl.gdrive-sync <toggle|syncNow|resync|pause|resume|status>`.
- Ligne de commande : `python3 gdrive-sync.py <status|sync-now|resync|cancel|pause|resume|install|uninstall|dirs [chemin]|set-folder <chemin>>`.

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
