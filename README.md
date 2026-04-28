# MetalEmacs

Distribution Emacs personnalisée conçue au départ pour les étudiants inscrits aux cours de traitement automatique du langage à l'Université Laval.

MetalEmacs offre un environnement Emacs préconfiguré, multiplateforme et accompagné d'un assistant d'installation interactif pour certains outils : Python/Conda, Prolog, Quarto, LaTeX, etc.

## Plateformes supportées

- **macOS** (Apple Silicon et Intel)
- **Windows 10/11**
- **ChromeOS** (avec environnement Linux activé) et distributions Linux Debian/Ubuntu

## Fonctionnalités

- **Interface unifiée** : tableau de bord (`F1`) et explorateur de fichiers Treemacs (`F2`)
- **Assistant d'installation interactif** pour les outils externes
- **Édition de code** : Python, SWI-Prolog
- **Édition de documents** : Quarto, Org-mode
- **Visualisation PDF** intégrée
- **Calendrier** avec import ICS
- **Synchronisation iOS** d'Org-mode via Beorg
- **Mises à jour automatiques**

## Installation

### macOS

> **Note** : sur macOS, la touche `Option` correspond à `M` dans Emacs (par exemple `M-x` = `Option-x`).

1. Télécharger et installer **Emacs pour macOS** depuis <https://emacsformacosx.com/>
2. Ouvrir un Terminal et cloner MetalEmacs :
   ```bash
   git clone https://github.com/JacquesLadouceur/metalemacs.git ~/.emacs.d
   ```
   Si Git n'est pas installé, macOS proposera d'installer les **outils de ligne de commande Xcode** — accepter.
3. Lancer Emacs (premier démarrage : 5 à 15 minutes pour le téléchargement des paquets)
4. **À la question sur la compilation de `pdfinfo`, répondre non.**
5. Une fois le démarrage terminé, ouvrir l'**Assistant** et installer dans l'ordre :
   - Homebrew
   - Poppler
   - pdf-tools
   - Miniconda

### Windows

> **Note** : sur Windows, la touche `Alt` correspond à `M` dans Emacs (par exemple `M-x` = `Alt-x`).

1. Télécharger et installer **Emacs** depuis <https://ftp.gnu.org/gnu/emacs/windows/> (choisir le sous-dossier de la dernière version et lancer le fichier `emacs-XX.X-installer.exe`)
2. Ouvrir un terminal (`cmd` ou PowerShell) et exécuter :
   ```
   winget install --id Git.Git -e --source winget
   
   setx HOME %USERPROFILE%
   ```
3. **Fermer puis rouvrir** le terminal pour que Git et la nouvelle variable `HOME` soient disponibles, puis cloner MetalEmacs :

- Powershell

   ```
   git clone https://github.com/JacquesLadouceur/metalemacs.git $HOME\.emacs.d
   ```
   
- CMD

   ```
   git clone https://github.com/JacquesLadouceur/metalemacs.git %HOME%\.emacs.d
   ```

4. Démarrer Emacs — premier démarrage : 5 à 15 minutes
5. Une fois le démarrage terminé, ouvrir l'**Assistant** et installer :
   - Scoop
   - Miniconda

### ChromeOS / Linux

> **Note** : la touche `Alt` correspond à `M` dans Emacs (par exemple `M-x` = `Alt-x`).

1. Sur Chromebook : activer l'environnement Linux dans **Paramètres → À propos de ChromeOS → Développeurs**
2. Ouvrir le Terminal et installer les prérequis (un seul copier-coller) :
   ```bash
   sudo apt update && sudo apt upgrade -y
   echo "deb http://deb.debian.org/debian bookworm-backports main" \
       | sudo tee /etc/apt/sources.list.d/backports.list
   sudo apt update
   sudo apt install -y -t bookworm-backports emacs
   sudo apt install -y git curl fonts-noto fonts-firacode fonts-hack \
       build-essential libpng-dev zlib1g-dev \
       libpoppler-glib-dev libpoppler-private-dev
   ```
3. Cloner MetalEmacs :
   ```bash
   git clone https://github.com/JacquesLadouceur/metalemacs.git ~/.emacs.d
   ```
4. Lancer Emacs depuis le lanceur d'applications
5. **À la question sur la compilation de `pdfinfo`, répondre non.**
6. Une fois le démarrage terminé, ouvrir l'**Assistant** et installer :
   - Poppler (si disponible)
   - pdf-tools
   - Miniconda

## Mise à jour

Depuis Emacs (recommandé) :

```
M-x metal-git-mise-a-jour
```

Ou en ligne de commande :

```bash
cd ~/.emacs.d           # Sous Windows : cd %HOME%\.emacs.d
git pull
```

Redémarrer Emacs ensuite. Les nouveaux paquets sont téléchargés automatiquement si nécessaire.

## Modules

| Module | Rôle |
|---|---|
| `metal-toolbar.el` | Primitives de barre d'outils header-line |
| `metal-pdf.el` | Visualisation et impression de PDF |
| `metal-python.el` | Environnement Python, REPL IPython, gestion Conda |
| `metal-prolog.el` | Environnement SWI-Prolog avec pliage et tracing |
| `metal-org.el` | Org-mode étendu, drag-and-drop, sync Beorg |
| `metal-quarto.el` | Édition Quarto, gestion TinyTeX |
| `metal-calendrier.el` | Calendrier calfw avec import ICS |
| `metal-deps.el` | Assistant d'installation des dépendances |
| `metal-distribution.el` | Mises à jour cloud |
| `metal-dashboard.el` | Tableau de bord d'accueil |
| `metal-treemacs.el` | Explorateur de fichiers |
| `metal-securite.el` | Corbeille interne avec restauration |

## Signalement de problèmes

Pour les bugs ou suggestions, ouvrir une [issue](https://github.com/JacquesLadouceur/metalemacs/issues).

## Licence

Copyright © 2026 Jacques Ladouceur — distribué sous licence GPL v3.

## Auteur

**Jacques Ladouceur**
[jacques.ladouceur@gmail.com](mailto:jacques.ladouceur@gmail.com)
