# Installation détaillée

Ce document complète le [README.md](README.md) avec les détails d'installation par plateforme et les solutions aux problèmes courants.

## Table des matières

- [Prérequis communs](#prérequis-communs)
- [Installation sur macOS](#installation-sur-macos)
- [Installation sur Windows](#installation-sur-windows)
- [Installation sur Linux et ChromeOS](#installation-sur-linux-et-chromeos)
- [Configuration des polices](#configuration-des-polices)
- [Vérification post-installation](#vérification-post-installation)
- [Dépannage](#dépannage)

---

## Prérequis communs

Quelle que soit votre plateforme, vous aurez besoin de :

- **Emacs ≥ 29.1**
- **Git**
- **Une connexion Internet** au premier démarrage (~500 Mo de paquets à télécharger)
- **2 Go d'espace disque libre** dans votre répertoire utilisateur
- **Police Symbols Nerd Font Mono** (recommandée pour les icônes)

---

## Installation sur macOS

### 1. Installer Homebrew

Si vous n'avez pas Homebrew :

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Installer Emacs et Git

```bash
brew install --cask emacs
brew install git
```

### 3. Sauvegarder une configuration Emacs existante

```bash
[ -d ~/.emacs.d ] && mv ~/.emacs.d ~/.emacs.d.backup-$(date +%Y%m%d)
```

### 4. Cloner MetalEmacs

```bash
git clone https://github.com/LadouceurJacques/metalemacs.git ~/.emacs.d
```

### 5. Premier lancement

```bash
emacs
```

Vous verrez un message de bienvenue. **Patientez 5 à 15 minutes** pendant le téléchargement des paquets.

### 6. Installer les dépendances externes

Une fois le premier démarrage terminé :

```
M-x metal-deps-afficher-etat
```

Cet assistant vous proposera d'installer Python, SWI-Prolog, MiKTeX/TinyTeX et autres outils nécessaires selon votre besoin.

---

## Installation sur Windows

### 1. Installer Scoop

PowerShell (utilisateur, pas admin) :

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
```

### 2. Installer Emacs et Git

```powershell
scoop bucket add extras
scoop install emacs git
```

### 3. Configurer la variable EMACS_DIR

Indispensable pour que MetalEmacs trouve les binaires Emacs. Dans PowerShell :

```powershell
[Environment]::SetEnvironmentVariable("EMACS_DIR", "$env:USERPROFILE\scoop\apps\emacs\current", "User")
```

Fermez et rouvrez votre terminal pour que la variable soit prise en compte.

### 4. Sauvegarder une configuration existante

```powershell
if (Test-Path "$env:USERPROFILE\.emacs.d") {
    Rename-Item "$env:USERPROFILE\.emacs.d" ".emacs.d.backup"
}
```

### 5. Cloner MetalEmacs

```powershell
git clone https://github.com/LadouceurJacques/metalemacs.git "$env:USERPROFILE\.emacs.d"
```

### 6. Premier lancement

```powershell
runemacs
```

Patientez 5 à 15 minutes lors du premier démarrage.

### 7. Installer les dépendances externes

```
M-x metal-deps-afficher-etat
```

L'assistant vous proposera d'installer via Scoop :
- **Python** + Miniconda
- **SWI-Prolog**
- **MiKTeX** (LaTeX)
- **SumatraPDF** (impression PDF native)
- **Pandoc**, **ripgrep**, etc.

---

## Installation sur Linux et ChromeOS

### Distributions Debian/Ubuntu (et ChromeOS Linux)

```bash
sudo apt update
sudo apt install emacs git build-essential

# Cloner MetalEmacs
git clone https://github.com/LadouceurJacques/metalemacs.git ~/.emacs.d

# Lancer
emacs
```

### Distributions Fedora/RHEL

```bash
sudo dnf install emacs git
git clone https://github.com/LadouceurJacques/metalemacs.git ~/.emacs.d
emacs
```

### Distributions Arch

```bash
sudo pacman -S emacs git
git clone https://github.com/LadouceurJacques/metalemacs.git ~/.emacs.d
emacs
```

### Note pour ChromeOS

Activez d'abord **Linux (Beta)** dans les paramètres de ChromeOS (Paramètres → Advanced → Developers → Linux development environment → Turn on). Ensuite, suivez les instructions Debian/Ubuntu ci-dessus dans le terminal Linux.

---

## Configuration des polices

Pour bénéficier des icônes dans les barres d'outils, installez **Symbols Nerd Font Mono** :

### macOS

```bash
brew install --cask font-symbols-only-nerd-font
```

### Windows

```powershell
scoop bucket add nerd-fonts
scoop install Symbols-NF-Mono
```

### Linux

Téléchargez depuis [nerdfonts.com](https://www.nerdfonts.com/font-downloads) ou via votre gestionnaire de paquets. Sur Debian/Ubuntu :

```bash
sudo apt install fonts-noto fonts-firacode
# Pour Nerd Fonts (manuel) :
mkdir -p ~/.local/share/fonts
cd ~/.local/share/fonts
curl -OL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip
unzip NerdFontsSymbolsOnly.zip
fc-cache -fv
```

Au sein d'Emacs, vous pouvez aussi exécuter :

```
M-x nerd-icons-install-fonts
```

---

## Vérification post-installation

Lancez le diagnostic intégré pour vérifier que tout est en place :

```
M-x metal-deps-afficher-etat
```

Vous obtiendrez un tableau listant chaque dépendance avec son statut (✓ installé / ✗ manquant), avec des boutons pour installer ce qui manque.

---

## Dépannage

### « void-variable » ou modules introuvables au premier démarrage

Cela peut arriver si le téléchargement des paquets a été interrompu. Solution :

```bash
rm -rf ~/.emacs.d/straight ~/.emacs.d/eln-cache
emacs
```

### Erreur de compilation native (Mac)

Si Emacs affiche des warnings sur la compilation native, vérifiez que GCC est installé :

```bash
brew install gcc
```

MetalEmacs détecte automatiquement `gcc-13`, `gcc-14`, `gcc-15` ou `gcc` dans le PATH.

### Erreur de compilation native (Windows)

Sur Windows, la compilation native n'est généralement pas disponible avec Emacs Scoop. C'est normal et n'empêche pas l'utilisation d'Emacs — seulement les performances seront légèrement moindres.

### `pdf-tools` ne s'affiche pas correctement

Le binaire `epdfinfo` doit être compilé localement la première fois. Lancez :

```
M-x pdf-tools-install
```

Sur Windows, MiKTeX est requis pour cette compilation.

### Polices manquantes / icônes affichées comme des carrés

Installez les polices Nerd Font (voir [Configuration des polices](#configuration-des-polices)) puis redémarrez Emacs.

### L'impression PDF ne fonctionne pas (Windows)

Si votre visionneuse PDF par défaut est Adobe Acrobat Reader, l'impression directe ne fonctionnera pas. Solution : installer SumatraPDF via l'assistant `metal-deps` :

```
M-x metal-deps-installer-sumatrapdf
```

### Mise à jour qui échoue avec un conflit Git

Si `git pull` signale un conflit (typiquement parce que vous avez modifié un fichier versionné), deux options :

1. **Préserver vos modifications** :
   ```bash
   cd ~/.emacs.d
   git stash
   git pull
   git stash pop
   ```

2. **Tout écraser avec la version officielle** :
   ```bash
   cd ~/.emacs.d
   git fetch
   git reset --hard origin/main
   ```

Pour personnaliser MetalEmacs sans entrer en conflit avec les mises à jour, créez un fichier `~/.emacs.d/perso.el` (ignoré par Git) qui contient vos paramètres personnels.

---

## Support

Pour toute question ou bug, ouvrez une [issue](https://github.com/LadouceurJacques/metalemacs/issues) sur GitHub ou contactez Jacques Ladouceur.
