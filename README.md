# MetalEmacs

Distribution Emacs personnalisée pour l'enseignement de la **linguistique informatique** et du **traitement automatique des langues** à l'Université Laval.

Conçue pour les cours **LNG-3108** (Traitement automatique du langage), **LNG-3102** et **LNG-2003**, MetalEmacs offre un environnement clé-en-main pour étudiants comme pour professeurs : Python, Prolog, Quarto, Org-mode, et tous les outils nécessaires à la pratique du TAL.

## Caractéristiques principales

- **Multiplateforme** : macOS (Apple Silicon et Intel), Windows, Linux/ChromeOS
- **Installation guidée** : assistant d'installation des dépendances externes (Python, SWI-Prolog, MiKTeX/TinyTeX, SumatraPDF, etc.)
- **Interface unifiée** : barres d'outils cohérentes pour PDF, Python, Prolog, Org-mode, Quarto
- **Modules pédagogiques** :
  - Parser DCG / coin gauche en SWI-Prolog
  - Sémantique formelle de style Montague
  - Outils de POS-tagging avec CRF (corpus Sequoia UD)
  - Traduction automatique français-anglais
- **Productivité** :
  - Tableau de bord personnalisé (`F1`)
  - Explorateur de fichiers Treemacs (`F2`)
  - Système de corbeille interne avec restauration
  - Synchronisation Beorg (iOS) via iCloud Drive
  - Mises à jour cloud via Synology

## Prérequis

- **Emacs 29.1 ou plus récent** (`emacs --version` pour vérifier)
- **Git** (pour cloner le dépôt et recevoir les mises à jour)
- **Connexion Internet** au premier démarrage (pour le téléchargement des paquets, ~15 minutes)

Voir [INSTALL.md](INSTALL.md) pour les instructions détaillées par plateforme.

## Installation rapide

### macOS

```bash
# Installer Emacs si nécessaire
brew install --cask emacs

# Sauvegarder une éventuelle configuration existante
[ -d ~/.emacs.d ] && mv ~/.emacs.d ~/.emacs.d.backup

# Cloner MetalEmacs
git clone https://github.com/LadouceurJacques/metalemacs.git ~/.emacs.d

# Lancer Emacs (premier démarrage : 5-15 minutes)
emacs
```

### Windows

```powershell
# Installer Emacs si nécessaire (avec Scoop)
scoop install emacs

# Sauvegarder une éventuelle configuration existante
if (Test-Path "$env:USERPROFILE\.emacs.d") {
    Rename-Item "$env:USERPROFILE\.emacs.d" ".emacs.d.backup"
}

# Cloner MetalEmacs
git clone https://github.com/LadouceurJacques/metalemacs.git $env:USERPROFILE\.emacs.d

# Lancer Emacs
runemacs
```

### Linux / ChromeOS

```bash
# Installer Emacs si nécessaire
sudo apt install emacs git

# Sauvegarder une éventuelle configuration existante
[ -d ~/.emacs.d ] && mv ~/.emacs.d ~/.emacs.d.backup

# Cloner MetalEmacs
git clone https://github.com/LadouceurJacques/metalemacs.git ~/.emacs.d

# Lancer Emacs
emacs
```

## Premier démarrage

Au tout premier lancement, MetalEmacs affiche un message de bienvenue et télécharge automatiquement une centaine de paquets via [straight.el](https://github.com/radian-software/straight.el). Cette opération prend **5 à 15 minutes** selon la connexion Internet. Les démarrages suivants seront quasi-instantanés.

Après ce premier démarrage, lancez l'**assistant d'installation** pour configurer les dépendances externes (Python, Prolog, LaTeX, etc.) :

```
M-x metal-deps-afficher-etat
```

L'assistant détecte automatiquement votre système d'exploitation et propose les commandes appropriées.

## Mise à jour

Pour mettre à jour MetalEmacs à la dernière version :

```bash
cd ~/.emacs.d
git pull
```

Puis redémarrez Emacs. Les nouveaux paquets sont téléchargés automatiquement si nécessaire.

## Modules principaux

| Module | Rôle |
|---|---|
| `metal-toolbar.el` | Primitives de barre d'outils header-line |
| `metal-pdf.el` | Visualisation et impression de PDF |
| `metal-python.el` | Environnement Python avec REPL et débogueur |
| `metal-prolog.el` | Environnement SWI-Prolog avec pliage et tracing |
| `metal-org.el` | Org-mode étendu avec drag-and-drop et Beorg |
| `metal-quarto.el` | Édition de documents Quarto avec aperçu |
| `metal-deps.el` | Assistant d'installation des dépendances externes |
| `metal-distribution.el` | Système de mise à jour cloud |
| `metal-dashboard.el` | Tableau de bord d'accueil personnalisé |
| `metal-treemacs.el` | Explorateur de fichiers style Finder |
| `metal-securite.el` | Corbeille interne avec restauration |

## Raccourcis essentiels

| Raccourci | Action |
|---|---|
| `F1` | Ouvrir le tableau de bord |
| `F2` | Basculer Treemacs (explorateur) et plein écran |
| `C-c m a` | Assistant d'installation |
| `C-c m d` | Diagnostic du système |
| `C-c m u` | Désinstallation guidée |

Pour les raccourcis spécifiques à chaque mode (Python, Prolog, Org, etc.), consultez la barre d'outils en haut de chaque tampon.

## Contribution

Ce dépôt est destiné aux étudiants des cours LNG-3108, LNG-3102 et LNG-2003. Si vous trouvez un bug ou avez une suggestion, ouvrez une [issue](https://github.com/LadouceurJacques/metalemacs/issues) — votre retour est bienvenu.

## Licence

Copyright © 2026 Jacques Ladouceur

Le code de MetalEmacs est distribué sous licence GPL v3 (compatible avec Emacs lui-même). Les paquets tiers chargés via straight.el conservent leur licence d'origine.

## Auteur

**Jacques Ladouceur**
Université Laval — Linguistique informatique
[jacques.ladouceur@lli.ulaval.ca](mailto:jacques.ladouceur@lli.ulaval.ca)
