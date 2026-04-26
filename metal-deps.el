;;; metal-deps.el --- Installation des dépendances externes pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 3.7

;;; Commentaire:
;; Ce module gère l'installation automatique des dépendances externes
;; pour MetalEmacs : Git (Scoop ou portable), Xcode CLI (macOS), HOME (Windows),
;; Homebrew/Scoop/apt, Miniconda, Quarto, SWI-Prolog, MiKTeX, Poppler,
;; pdf-tools, draw.io Desktop et ripgrep.
;; Supporte macOS, Windows et Linux (Chromebook/Debian/Ubuntu).
;;
;; Version 3.3 : Ajout de draw.io Desktop (macOS/Windows/Linux)
;;
;; Version 3.4 : Correction automatique des permissions pdf-tools sur Linux/Chromebook
;; Version 3.5 : draw.io Linux — boutons Télécharger/Installer séparés avec sélecteur .deb
;; Version 3.6 : File d'attente séquentielle pour installations asynchrones
;;               installer-logiciels dynamique (catégorie logiciels complète)
;;               Rafraîchissement intelligent de l'interface (sentinelle)
;; Version 3.7 : Ajout de ripgrep (rg) — moteur de recherche récursive rapide,
;;               requis par deadgrep pour la recherche interactive dans Emacs
;;
;; Commandes principales :
;;   M-x metal-deps-afficher-etat     - Interface graphique avec boutons
;;   M-x metal-deps-installer-logiciels   - Installe tous les logiciels
;;   M-x metal-deps-installer-tout    - Installe tous les composants

;;; Code:

(require 'cl-lib)
(require 'widget)
(require 'url)
(eval-when-compile (require 'wid-edit))

(defgroup metal-deps nil
  "Gestion des dépendances MetalEmacs."
  :group 'convenience)

(defcustom metal-deps-tampon-journal "*MetalEmacs Journal*"
  "Tampon pour les journaux d'installation."
  :type 'string)

;;; ═══════════════════════════════════════════════════════════════════
;;; Détection du système
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--version-macos ()
  "Retourne (majeur mineur correctif) de macOS."
  (when (eq system-type 'darwin)
    (let* ((s (string-trim (shell-command-to-string "sw_vers -productVersion")))
           (parts (mapcar #'string-to-number (split-string s "\\."))))
      (pcase (length parts)
        (3 parts)
        (2 (append parts '(0)))
        (_ nil)))))

(defun metal-deps--macos-13-plus-p ()
  "Retourne t si macOS >= 13."
  (let ((v (metal-deps--version-macos)))
    (and v (>= (car v) 13))))

(defun metal-deps--apple-silicon-p ()
  "Retourne t si le Mac utilise Apple Silicon."
  (and (eq system-type 'darwin)
       (string-match-p "arm64" (shell-command-to-string "uname -m"))))

(defun metal-deps--nom-systeme ()
  "Retourne le nom du système pour affichage."
  (pcase system-type
    ('darwin
     (if (metal-deps--apple-silicon-p)
         "macOS (Apple Silicon)"
       "macOS (Intel)"))
    ('windows-nt "Windows")
    ('gnu/linux 
     (if (file-exists-p "/dev/.cros_milestone")
         "Linux (Chromebook)"
       "Linux (Debian/Ubuntu)"))
    (_ "Autre")))

;;; ═══════════════════════════════════════════════════════════════════
;;; Journalisation
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--journaliser (fmt &rest args)
  "Journalise un message avec FMT et ARGS."
  (with-current-buffer (get-buffer-create metal-deps-tampon-journal)
    (goto-char (point-max))
    (insert (format-time-string "[%H:%M:%S] ")
            (apply #'format fmt args) "\n")))

;;; ═══════════════════════════════════════════════════════════════════
;;; Utilitaire : exécuter et rafraîchir l'interface
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--executer-et-rafraichir (fn)
  "Exécute FN et rafraîchit l'état quand le processus associé se termine.
Si FN lance un processus asynchrone, on y attache une sentinelle qui
rafraîchit l'interface à la fin.  Si FN est synchrone, on rafraîchit
après un court délai.  Les erreurs sont capturées et affichées."
  (when metal-deps--installation-en-cours
    (user-error "Une installation séquentielle est en cours — attendez ou annulez"))
  (let ((procs-avant (copy-sequence (process-list))))
    (condition-case err
        (progn
          (funcall fn)
          (let ((nouveau (cl-find-if
                          (lambda (p)
                            (and (not (memq p procs-avant))
                                 (process-live-p p)))
                          (process-list))))
            (if nouveau
                ;; Processus async détecté — chaîner la sentinelle
                (let ((ancien (process-sentinel nouveau)))
                  (set-process-sentinel
                   nouveau
                   (lambda (proc event)
                     (when (and ancien (functionp ancien))
                       (funcall ancien proc event))
                     (when (memq (process-status proc) '(exit signal))
                       (run-with-timer 1 nil #'metal-deps-afficher-etat)))))
              ;; Pas de processus async — rafraîchir après un court délai
              (run-with-timer 2 nil #'metal-deps-afficher-etat))))
      (error
       (message "⚠ %s" (error-message-string err))
       (run-with-timer 2 nil #'metal-deps-afficher-etat)))))

;;; ═══════════════════════════════════════════════════════════════════
;;; File d'attente séquentielle pour installations asynchrones
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-deps--file-attente nil
  "File d'attente des installations à effectuer.
Chaque élément est de la forme (NOM . FONCTION).")

(defvar metal-deps--installation-en-cours nil
  "Non-nil si une installation séquentielle est en cours.")

(defun metal-deps--lancer-file-attente (outils &optional callback)
  "Lance l'installation séquentielle des OUTILS.
OUTILS est une liste de paires (NOM . FONCTION).
Chaque installation attend la fin de la précédente avant de démarrer.
CALLBACK est appelé quand toutes les installations sont terminées."
  (when metal-deps--installation-en-cours
    (user-error "Une installation séquentielle est déjà en cours"))
  (setq metal-deps--file-attente (copy-sequence outils))
  (setq metal-deps--installation-en-cours t)
  (metal-deps--journaliser "Début de l'installation séquentielle (%d éléments)"
                           (length outils))
  (metal-deps--installer-prochain callback))

(defun metal-deps--installer-prochain (callback)
  "Installe le prochain outil dans la file d'attente.
CALLBACK est appelé quand la file est vide.
Si l'installation a été annulée via `metal-deps--annuler-file-attente',
la sentinelle du processus en cours appelle cette fonction mais
`metal-deps--installation-en-cours' est nil : on sort silencieusement."
  (cond
   ;; Annulé — le processus en cours a fini mais on ne continue pas
   ((not metal-deps--installation-en-cours)
    nil)
   ;; File vide — terminé normalement
   ((null metal-deps--file-attente)
    (setq metal-deps--installation-en-cours nil)
    (metal-deps--journaliser "Installation séquentielle terminée")
    (when callback (funcall callback)))
   ;; Continuer — extraire le prochain élément
   (t
    (let* ((item (pop metal-deps--file-attente))
           (nom (car item))
           (installeur (cdr item))
           (restant (length metal-deps--file-attente))
           (procs-avant (copy-sequence (process-list))))
      (metal-deps--journaliser "Installation de %s... (%d restant%s)"
                               nom restant (if (> restant 1) "s" ""))
      (message "📦 [%d restant%s] Installation de %s..."
               restant (if (> restant 1) "s" "") nom)
      (condition-case err
          (progn
            (funcall installeur)
            ;; Chercher un nouveau processus async créé par l'installeur
            (let ((nouveau-proc (cl-find-if
                                 (lambda (p)
                                   (and (not (memq p procs-avant))
                                        (process-live-p p)))
                                 (process-list))))
              (if (and nouveau-proc (process-live-p nouveau-proc))
                  ;; Processus async — chaîner la sentinelle pour enchaîner
                  (let ((ancien-sentinel (process-sentinel nouveau-proc)))
                    (set-process-sentinel
                     nouveau-proc
                     (lambda (proc event)
                       ;; Appeler la sentinelle originale (MiKTeX, draw.io, etc.)
                       (when (and ancien-sentinel (functionp ancien-sentinel))
                         (funcall ancien-sentinel proc event))
                       ;; Passer au suivant quand le processus se termine
                       (when (memq (process-status proc) '(exit signal))
                         (pcase (process-status proc)
                           ('exit
                            (if (= (process-exit-status proc) 0)
                                (metal-deps--journaliser "✓ %s installé" nom)
                              (metal-deps--journaliser "⚠ %s terminé avec code %d"
                                                       nom (process-exit-status proc))))
                           ('signal
                            (metal-deps--journaliser "⚠ %s interrompu par signal" nom)))
                         (run-with-timer 1 nil
                                         #'metal-deps--installer-prochain
                                         callback)))))
                ;; Pas de processus async — installation synchrone, continuer
                (metal-deps--journaliser "✓ %s traité (synchrone)" nom)
                (run-with-timer 1 nil
                                #'metal-deps--installer-prochain callback))))
        ;; Erreur (y compris user-error) — journaliser et continuer
        (error
         (metal-deps--journaliser "❌ Erreur %s : %s"
                                  nom (error-message-string err))
         (run-with-timer 1 nil
                         #'metal-deps--installer-prochain callback))
        ;; C-g (quit) pendant read-file-name, url-copy-file, etc.
        ;; Sans ce handler, quit échappe condition-case, le timer
        ;; l'absorbe, et installation-en-cours reste à t.
        (quit
         (metal-deps--journaliser "⚠ %s annulé par l'utilisateur (C-g)" nom)
         (run-with-timer 1 nil
                         #'metal-deps--installer-prochain callback)))))))

(defun metal-deps--annuler-file-attente ()
  "Annule la file d'attente d'installation en cours."
  (interactive)
  (if (not metal-deps--installation-en-cours)
      (message "Aucune installation en cours")
    (let ((restant (length metal-deps--file-attente)))
      (setq metal-deps--file-attente nil)
      (setq metal-deps--installation-en-cours nil)
      (metal-deps--journaliser "File d'attente annulée (%d éléments ignorés)" restant)
      (message "✓ File d'attente annulée (%d éléments ignorés)" restant))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Exécution avec élévation (Windows)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--run-elevated (command &optional buffer-name)
  "Exécute COMMAND avec élévation de privilèges sur Windows.
BUFFER-NAME est le nom du buffer pour afficher la sortie (optionnel).
Retourne t si la commande a été lancée."
  (when (eq system-type 'windows-nt)
    (let* ((script-file (expand-file-name 
                         (format "metal-cmd-%s.ps1" (format-time-string "%H%M%S"))
                         temporary-file-directory))
           (buf-name (or buffer-name "*MetalEmacs Elevated*")))
      ;; Écrire le script
      (with-temp-file script-file
        (insert command))
      ;; Lancer PowerShell avec élévation
      (message "⚠ Une fenêtre UAC va s'ouvrir - cliquez 'Oui' pour autoriser")
      (shell-command
       (format "powershell -Command \"Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \\\"%s\\\"'\""
               script-file)
       buf-name)
      ;; Nettoyer
      (run-with-timer 5 nil (lambda (f) (when (file-exists-p f) (delete-file f))) script-file)
      t)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Détection des gestionnaires de paquets
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--chemin-brew ()
  "Retourne le chemin vers Homebrew ou nil."
  (or (executable-find "brew")
      (and (file-executable-p "/opt/homebrew/bin/brew") "/opt/homebrew/bin/brew")
      (and (file-executable-p "/usr/local/bin/brew") "/usr/local/bin/brew")))

(defun metal-deps--brew-present-p ()
  "Retourne t si Homebrew est installé."
  (not (null (metal-deps--chemin-brew))))

(defun metal-deps--macports-present-p ()
  "Retourne t si MacPorts est installé."
  (not (null (executable-find "port"))))

(defun metal-deps--scoop-present-p ()
  "Retourne t si Scoop est installé."
  (or (executable-find "scoop")
      ;; Chercher dans HOME d'abord (pour les chemins avec lien symbolique)
      (file-exists-p (expand-file-name "scoop/shims/scoop.ps1" (getenv "HOME")))
      ;; Fallback vers USERPROFILE
      (file-exists-p (expand-file-name "scoop/shims/scoop.ps1" (getenv "USERPROFILE")))))

(defun metal-deps--scoop-path ()
  "Retourne le chemin vers le dossier Scoop."
  (let ((scoop-home (getenv "SCOOP")))
    (cond
     ;; Variable SCOOP définie
     (scoop-home scoop-home)
     ;; Chercher dans HOME d'abord
     ((file-exists-p (expand-file-name "scoop" (getenv "HOME")))
      (expand-file-name "scoop" (getenv "HOME")))
     ;; Fallback vers USERPROFILE
     (t (expand-file-name "scoop" (getenv "USERPROFILE"))))))

(defun metal-deps--scoop-7zip-present-p ()
  "Retourne t si 7zip est installé via Scoop."
  (and (metal-deps--scoop-present-p)
       (or (executable-find "7z")
           (file-exists-p (expand-file-name "apps/7zip/current/7z.exe" (metal-deps--scoop-path))))))

(defun metal-deps--scoop-ensure-7zip ()
  "S'assure que 7zip est installé via Scoop. Retourne t si OK."
  (when (and (eq system-type 'windows-nt)
             (metal-deps--scoop-present-p))
    (unless (metal-deps--scoop-7zip-present-p)
      (message "📦 Installation de 7zip (requis par Scoop)...")
      (call-process "powershell" nil nil nil "-Command" "scoop install 7zip")
      ;; Mettre à jour le PATH
      (let ((7zip-path (expand-file-name "apps/7zip/current" (metal-deps--scoop-path))))
        (when (file-exists-p 7zip-path)
          (setenv "PATH" (concat 7zip-path ";" (getenv "PATH")))
          (add-to-list 'exec-path 7zip-path)))
      (message "✓ 7zip installé"))
    t))

(defun metal-deps--apt-present-p ()
  "Retourne t si apt est disponible."
  (not (null (executable-find "apt"))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Détection des outils
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--xcode-present-p ()
  "Retourne t si Xcode Command Line Tools est installé."
  (and (eq system-type 'darwin)
       (file-exists-p "/Library/Developer/CommandLineTools")))

(defun metal-deps--home-configure-p ()
  "Retourne t si HOME est configuré sur Windows."
  (and (eq system-type 'windows-nt)
       (getenv "HOME")
       (file-directory-p (getenv "HOME"))))

(defvar metal-deps--git-portable-dossier
  (expand-file-name "PortableGit" user-emacs-directory)
  "Dossier d'installation de Git Portable.")

(defvar metal-deps--git-portable-url
  "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/PortableGit-2.47.1.2-64-bit.7z.exe"
  "URL de Git Portable.")

(defun metal-deps--find-git-bin ()
  "Trouve un répertoire bin/cmd Git contenant git.exe. 
Retourne le répertoire ou nil. Aligné avec early-init.el."
  (when (eq system-type 'windows-nt)
    (let* ((home (or (getenv "HOME") (getenv "USERPROFILE") "C:/"))
           (candidates
            (list
             ;; PortableGit dans .emacs.d (installé par early-init.el)
             (expand-file-name "PortableGit/cmd" user-emacs-directory)
             (expand-file-name "PortableGit/bin" user-emacs-directory)
             ;; Scoop
             (expand-file-name "scoop/apps/git/current/bin" home)
             (expand-file-name "scoop/apps/git/current/cmd" home)
             (expand-file-name "scoop/shims" home)
             ;; Installations standard
             "C:/Program Files/Git/cmd"
             "C:/Program Files/Git/bin"
             "C:/Program Files (x86)/Git/bin"
             "C:/ProgramData/chocolatey/bin"
             "C:/tools/git/bin"
             "C:/Git/bin"
             (expand-file-name "AppData/Local/Programs/Git/bin" home))))
      (catch 'found
        (dolist (dir candidates)
          (when (and (stringp dir)
                     (file-exists-p (expand-file-name "git.exe" dir)))
            (throw 'found dir)))
        nil))))

(defun metal-deps--git-portable-present-p ()
  "Retourne t si Git est disponible (PortableGit, Scoop, ou autre installation).
Cette fonction utilise la même logique que early-init.el."
  (if (eq system-type 'windows-nt)
      ;; Sur Windows, utiliser la détection complète
      (or (executable-find "git")
          (not (null (metal-deps--find-git-bin))))
    ;; Sur autres systèmes, vérifier simplement si git est dans le PATH
    (not (null (executable-find "git")))))

(defun metal-deps--git-present-p ()
  "Retourne t si Git est disponible."
  (metal-deps--git-portable-present-p))

(defun metal-deps--miniconda-homebrew-path ()
  "Retourne le chemin Miniconda installé via Homebrew, ou nil."
  (cl-find-if #'file-exists-p
              '("/opt/homebrew/Caskroom/miniconda"
                "/usr/local/Caskroom/miniconda")))

(defun metal-deps--miniconda-present-p ()
  "Retourne t si Miniconda/Anaconda est installé."
  (or (executable-find "conda")
      ;; Installation standard utilisateur
      (file-exists-p (expand-file-name "miniconda3" (getenv "HOME")))
      (file-exists-p (expand-file-name "anaconda3" (getenv "HOME")))
      ;; Homebrew (macOS) - dossier Caskroom
      (metal-deps--miniconda-homebrew-path)
      ;; Windows - Scoop (méthode préférée)
      (and (eq system-type 'windows-nt)
           (or (file-exists-p (expand-file-name "scoop/apps/miniconda3/current" (getenv "HOME")))
               (file-exists-p (expand-file-name "scoop/apps/miniconda3/current" (getenv "USERPROFILE")))))))

(defun metal-deps--quarto-present-p ()
  "Retourne t si Quarto est installé."
  (not (null (executable-find "quarto"))))

(defun metal-deps--swipl-present-p ()
  "Retourne t si SWI-Prolog est installé."
  (not (null (executable-find "swipl"))))

(defun metal-deps--poppler-present-p ()
  "Retourne t si Poppler est installé."
  (or (executable-find "pdfinfo")
      (executable-find "pdftoppm")))

(defun metal-deps--miktex-present-p ()
  "Retourne t si MiKTeX est installé (via Scoop)."
  (and (eq system-type 'windows-nt)
       (or (executable-find "xelatex")
           (let ((miktex-bin (expand-file-name
                              "scoop/apps/miktex/current/texmfs/install/miktex/bin/x64"
                              (or (getenv "HOME") (getenv "USERPROFILE")))))
             (file-exists-p (expand-file-name "xelatex.exe" miktex-bin))))))

(defun metal-deps--sumatrapdf-present-p ()
  "Retourne t si SumatraPDF est installé (Windows uniquement)."
  (and (eq system-type 'windows-nt)
       (or (executable-find "SumatraPDF")
           (executable-find "sumatrapdf")
           (file-exists-p (expand-file-name
                           "scoop/apps/sumatrapdf/current/SumatraPDF.exe"
                           (or (getenv "HOME") (getenv "USERPROFILE")))))))

(defun metal-deps--drawio-present-p ()
  "Retourne t si draw.io Desktop est installé."
  (or (executable-find "drawio")
      ;; macOS : application dans /Applications
      (and (eq system-type 'darwin)
           (file-exists-p "/Applications/draw.io.app"))
      ;; Windows : Scoop
      (and (eq system-type 'windows-nt)
           (file-exists-p (expand-file-name
                           "scoop/apps/draw.io/current/draw.io.exe"
                           (or (getenv "HOME") (getenv "USERPROFILE")))))
      ;; Linux : vérifier le .desktop ou le binaire
      (and (eq system-type 'gnu/linux)
           (or (executable-find "drawio")
               (file-exists-p "/usr/bin/drawio")))))

(defun metal-deps--ripgrep-present-p ()
  "Retourne t si ripgrep (rg) est installé."
  (not (null (executable-find "rg"))))

(defun metal-deps--chemin-epdfinfo ()
  "Retourne le chemin vers epdfinfo ou nil."
  (let ((chemins (list
                  (expand-file-name "straight/build/pdf-tools/epdfinfo" user-emacs-directory)
                  (expand-file-name "elpa/pdf-tools-*/epdfinfo" user-emacs-directory)
                  (expand-file-name ".emacs.d/straight/build/pdf-tools/epdfinfo" (getenv "HOME")))))
    (cl-find-if #'file-executable-p chemins)))

(defun metal-deps--epdfinfo-present-p ()
  "Retourne t si epdfinfo est compilé et exécutable."
  (not (null (metal-deps--chemin-epdfinfo))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - Gestionnaires de paquets
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-homebrew ()
  "Installe Homebrew sur macOS."
  (interactive)
  (unless (eq system-type 'darwin)
    (user-error "Homebrew n'est disponible que sur macOS"))
  (if (metal-deps--brew-present-p)
      (message "✓ Homebrew déjà installé")
    (metal-deps--journaliser "Installation de Homebrew")
    (let ((cmd "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""))
      (async-shell-command cmd "*Homebrew Install*")
      (message "Installation de Homebrew lancée dans un terminal..."))))

(defun metal-deps-desinstaller-homebrew ()
  "Désinstalle Homebrew sur macOS."
  (interactive)
  (unless (eq system-type 'darwin)
    (user-error "Homebrew n'est disponible que sur macOS"))
  (if (not (metal-deps--brew-present-p))
      (message "Homebrew n'est pas installé")
    (when (yes-or-no-p "⚠ Ceci supprimera aussi tous les paquets installés via Homebrew. Continuer ? ")
      (metal-deps--journaliser "Désinstallation de Homebrew")
      (let ((cmd "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)\""))
        (async-shell-command cmd "*Homebrew Uninstall*")
        (message "Désinstallation de Homebrew lancée...")))))

(defun metal-deps-installer-scoop ()
  "Installe Scoop sur Windows (sans privilèges admin)."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "Scoop n'est disponible que sur Windows"))
  (if (metal-deps--scoop-present-p)
      (message "✓ Scoop déjà installé")
    (metal-deps--journaliser "Installation de Scoop")
    (message "📦 Installation de Scoop en cours...")
    ;; Configurer SCOOP vers HOME pour éviter les problèmes d'accents
    (let* ((scoop-dir (expand-file-name "scoop" (getenv "HOME")))
           (cmd (format "powershell -Command \"$env:SCOOP = '%s'; [Environment]::SetEnvironmentVariable('SCOOP', '%s', 'User'); Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; irm get.scoop.sh | iex\""
                        scoop-dir scoop-dir)))
      (async-shell-command cmd "*Scoop Install*"))
    ;; Mettre à jour le PATH pour cette session
    (let ((scoop-shims (expand-file-name "scoop/shims" (getenv "HOME"))))
      (when (file-exists-p scoop-shims)
        (setenv "PATH" (concat scoop-shims ";" (getenv "PATH")))
        (add-to-list 'exec-path scoop-shims)))
    (message "📦 Installation de Scoop lancée. Redémarrez Emacs après l'installation.")))

(defun metal-deps--scoop-add-extras-bucket ()
  "Ajoute le bucket 'extras' à Scoop si nécessaire."
  (when (and (eq system-type 'windows-nt)
             (metal-deps--scoop-present-p))
    (let* ((scoop-shims (expand-file-name "scoop/shims" (getenv "HOME")))
           (scoop-cmd (expand-file-name "scoop.cmd" scoop-shims))
           (buckets (if (file-exists-p scoop-cmd)
                        (shell-command-to-string (format "\"%s\" bucket list 2>nul" scoop-cmd))
                      (shell-command-to-string "scoop bucket list 2>nul"))))
      (unless (string-match-p "extras" buckets)
        (message "📦 Ajout du bucket 'extras' à Scoop...")
        (if (file-exists-p scoop-cmd)
            (call-process scoop-cmd nil nil nil "bucket" "add" "extras")
          (shell-command "scoop bucket add extras"))))))

(defun metal-deps-desinstaller-scoop ()
  "Désinstalle Scoop sur Windows."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "Scoop n'est disponible que sur Windows"))
  (if (not (metal-deps--scoop-present-p))
      (message "Scoop n'est pas installé")
    (when (yes-or-no-p "⚠ Ceci supprimera Scoop et tous les paquets installés. Continuer ? ")
      (metal-deps--journaliser "Désinstallation de Scoop")
      (let ((scoop-dir (metal-deps--scoop-path)))
        (message "⏳ Désinstallation de Scoop en cours...")
        (shell-command
         (format "powershell -Command \"Remove-Item -Recurse -Force '%s'\"" scoop-dir))
        (message "✓ Scoop désinstallé")))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - Git Portable (Windows)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-git-portable ()
  "Télécharge et installe Git Portable pour Windows.
Note: Cette fonction est un backup - early-init.el installe Git automatiquement."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "Git Portable est uniquement pour Windows"))
  (if (metal-deps--git-present-p)
      (message "✓ Git déjà disponible")
    (metal-deps--journaliser "Installation de Git Portable")
    (let ((temp-file (expand-file-name "git-portable.exe" temporary-file-directory)))
      (message "📦 Téléchargement de Git Portable...")
      (url-copy-file metal-deps--git-portable-url temp-file t)
      (message "📂 Extraction en cours...")
      (make-directory metal-deps--git-portable-dossier t)
      (call-process temp-file nil nil nil
                    (concat "-o" metal-deps--git-portable-dossier) "-y")
      ;; Ajouter au PATH
      (let ((git-bin (expand-file-name "bin" metal-deps--git-portable-dossier)))
        (add-to-list 'exec-path git-bin)
        (setenv "PATH" (concat git-bin ";" (getenv "PATH"))))
      (delete-file temp-file)
      (message "✓ Git Portable installé dans %s" metal-deps--git-portable-dossier))))

(defun metal-deps-desinstaller-git-portable ()
  "Désinstalle Git Portable."
  (interactive)
  (let ((git-dir metal-deps--git-portable-dossier))
    (if (not (file-exists-p git-dir))
        (message "Git Portable n'est pas installé dans %s" git-dir)
      (when (yes-or-no-p (format "Supprimer Git Portable dans %s ? " git-dir))
        (metal-deps--journaliser "Désinstallation de Git Portable")
        (delete-directory git-dir t)
        (message "✓ Git Portable désinstallé")))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - Xcode Command Line Tools (macOS)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-xcode-clt ()
  "Installe Xcode Command Line Tools sur macOS."
  (interactive)
  (unless (eq system-type 'darwin)
    (user-error "Cette fonction est uniquement pour macOS"))
  (if (metal-deps--xcode-present-p)
      (message "✓ Command Line Tools déjà installé")
    (metal-deps--journaliser "Installation de Command Line Tools")
    (async-shell-command "xcode-select --install" "*Xcode CLT Install*")
    (message "Suivez les instructions de la fenêtre qui s'ouvre...")))

(defun metal-deps-desinstaller-xcode-clt ()
  "Désinstalle Xcode Command Line Tools sur macOS."
  (interactive)
  (unless (eq system-type 'darwin)
    (user-error "Cette fonction est uniquement pour macOS"))
  (if (not (metal-deps--xcode-present-p))
      (message "Command Line Tools n'est pas installé")
    (metal-deps--journaliser "Désinstallation de Command Line Tools")
    (kill-new "sudo rm -rf /Library/Developer/CommandLineTools")
    (let ((buf (get-buffer-create "*MetalEmacs - Désinstallation*")))
      (with-current-buffer buf
        (erase-buffer)
        (insert "\n")
        (insert "  ╔═══════════════════════════════════════════════════════════╗\n")
        (insert "  ║      Désinstallation de Command Line Tools                 ║\n")
        (insert "  ╚═══════════════════════════════════════════════════════════╝\n")
        (insert "\n")
        (insert "  La commande suivante a été copiée dans le presse-papiers :\n")
        (insert "\n")
        (insert "      sudo rm -rf /Library/Developer/CommandLineTools\n")
        (insert "\n")
        (insert "  Instructions :\n")
        (insert "\n")
        (insert "    1. Ouvrez le Terminal\n")
        (insert "    2. Collez la commande (Cmd+V) et appuyez sur Entrée\n")
        (insert "    3. Entrez votre mot de passe administrateur\n")
        (insert "    4. Une fois terminé, appuyez sur Entrée ci-dessous\n")
        (insert "\n")
        (setq buffer-read-only t)
        (goto-char (point-min)))
      (tab-bar-new-tab)
      (switch-to-buffer buf)
      (delete-other-windows)
      (read-string "Appuyez sur Entrée une fois la désinstallation terminée...")
      (kill-buffer buf)
      (tab-bar-close-tab))
    (if (not (metal-deps--xcode-present-p))
        (message "✓ Command Line Tools désinstallé")
      (message "⚠ Command Line Tools toujours présent."))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - Miniconda
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-miniconda ()
  "Installe Miniconda dans le dossier utilisateur (sans privilèges admin)."
  (interactive)
  (if (metal-deps--miniconda-present-p)
      (message "✓ Miniconda déjà installé")
    (metal-deps--journaliser "Installation de Miniconda")
    (pcase system-type
      ('darwin
       (if (metal-deps--brew-present-p)
           (progn
             (message "Installation de Miniconda via Homebrew...")
             (async-shell-command "brew install --cask miniconda" "*Miniconda Install*"))
         (let* ((arch (if (metal-deps--apple-silicon-p) "arm64" "x86_64"))
                (url (format "https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-%s.sh" arch))
                (script (expand-file-name "miniconda-installer.sh" temporary-file-directory)))
           (message "📦 Téléchargement de Miniconda...")
           (url-copy-file url script t)
           (async-shell-command (format "bash %s -b" script) "*Miniconda Install*"))))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (progn
             (metal-deps--scoop-ensure-7zip)
             (metal-deps--scoop-add-extras-bucket)
             (message "📦 Installation de Miniconda via Scoop...")
             (async-shell-command "scoop install miniconda3" "*Miniconda Install*"))
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (let* ((url "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh")
              (script (expand-file-name "miniconda-installer.sh" temporary-file-directory)))
         (message "📦 Téléchargement de Miniconda...")
         (url-copy-file url script t)
         (chmod script #o755)
         (async-shell-command (format "bash %s -b" script) "*Miniconda Install*"))))))

(defun metal-deps-desinstaller-miniconda ()
  "Désinstalle Miniconda."
  (interactive)
  (if (not (metal-deps--miniconda-present-p))
      (message "Miniconda n'est pas installé")
    (cond
     ((and (eq system-type 'darwin)
           (metal-deps--miniconda-homebrew-path))
      (let ((caskroom-path (metal-deps--miniconda-homebrew-path)))
        (when (yes-or-no-p (format "Supprimer Miniconda dans %s ? " caskroom-path))
          (metal-deps--journaliser "Désinstallation de Miniconda : %s" caskroom-path)
          (async-shell-command (format "rm -rf %s" (shell-quote-argument caskroom-path)) "*Miniconda Uninstall*")
          (let ((conda-link "/opt/homebrew/bin/conda"))
            (when (file-symlink-p conda-link)
              (delete-file conda-link)))
          (message "Désinstallation de Miniconda lancée..."))))
     ((eq system-type 'windows-nt)
      (if (metal-deps--scoop-present-p)
          (when (yes-or-no-p "Supprimer Miniconda ? ")
            (metal-deps--journaliser "Désinstallation de Miniconda via Scoop")
            (message "⏳ Désinstallation de Miniconda en cours...")
            (async-shell-command "scoop uninstall miniconda3" "*Miniconda Uninstall*"))
        (message "Miniconda a été installé à l'extérieur de Scoop. Désinstallez manuellement.")))
     (t
      (let ((chemins (list
                      (expand-file-name "miniconda3" (getenv "HOME"))
                      (expand-file-name "anaconda3" (getenv "HOME")))))
        (let ((trouve (cl-find-if #'file-exists-p chemins)))
          (if trouve
              (when (yes-or-no-p (format "Supprimer Miniconda dans %s ? " trouve))
                (metal-deps--journaliser "Désinstallation de Miniconda : %s" trouve)
                (async-shell-command (format "rm -rf %s" (shell-quote-argument trouve)) "*Miniconda Uninstall*"))
            (message "Miniconda détecté mais emplacement non trouvé. Désinstallez manuellement."))))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - Quarto
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-quarto ()
  "Installe Quarto et TinyTeX."
  (interactive)
  (if (metal-deps--quarto-present-p)
      (message "✓ Quarto déjà installé")
    (metal-deps--journaliser "Installation de Quarto")
    (pcase system-type
      ('darwin
       (if (metal-deps--brew-present-p)
           (progn
             (message "📦 Installation de Quarto et TinyTeX via Homebrew...")
             (async-shell-command "brew install --cask quarto && quarto install tinytex --no-prompt" "*Quarto Install*"))
         (browse-url "https://quarto.org/docs/get-started/")
         (message "Téléchargez Quarto depuis le site web")))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (progn
             (metal-deps--scoop-ensure-7zip)
             (metal-deps--scoop-add-extras-bucket)
             (message "📦 Installation de Quarto via Scoop...")
             (async-shell-command "scoop install quarto && quarto install tinytex --no-prompt" "*Quarto Install*"))
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (let* ((url "https://github.com/quarto-dev/quarto-cli/releases/download/v1.4.553/quarto-1.4.553-linux-amd64.deb")
              (deb (expand-file-name "quarto.deb" temporary-file-directory)))
         (message "📦 Téléchargement de Quarto...")
         (url-copy-file url deb t)
         (async-shell-command (format "sudo dpkg -i %s && quarto install tinytex --no-prompt" deb) "*Quarto Install*"))))))

(defun metal-deps-desinstaller-quarto ()
  "Désinstalle Quarto."
  (interactive)
  (if (not (metal-deps--quarto-present-p))
      (message "Quarto n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller Quarto ? ")
      (metal-deps--journaliser "Désinstallation de Quarto")
      (pcase system-type
        ('darwin
         (if (or (file-exists-p "/opt/homebrew/Caskroom/quarto")
                 (file-exists-p "/usr/local/Caskroom/quarto"))
             (async-shell-command "brew uninstall --cask quarto" "*Quarto Uninstall*")
           (message "Quarto installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('windows-nt
         (if (metal-deps--scoop-present-p)
             (async-shell-command "scoop uninstall quarto" "*Quarto Uninstall*")
           (message "Quarto installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('gnu/linux
         (if (= 0 (call-process "dpkg" nil nil nil "-s" "quarto"))
             (async-shell-command "sudo apt remove quarto -y" "*Quarto Uninstall*")
           (message "Quarto installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - SWI-Prolog
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-swi-prolog ()
  "Installe SWI-Prolog."
  (interactive)
  (if (metal-deps--swipl-present-p)
      (message "✓ SWI-Prolog déjà installé")
    (metal-deps--journaliser "Installation de SWI-Prolog")
    (pcase system-type
      ('darwin
       (if (metal-deps--brew-present-p)
           (async-shell-command "brew install swi-prolog" "*SWI-Prolog Install*")
         (browse-url "https://www.swi-prolog.org/download/stable")
         (message "Téléchargez SWI-Prolog depuis le site web")))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (progn
             (metal-deps--scoop-ensure-7zip)
             (metal-deps--scoop-add-extras-bucket)
             (message "📦 Installation de SWI-Prolog via Scoop...")
             (async-shell-command "scoop install swipl" "*SWI-Prolog Install*"))
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (if (metal-deps--apt-present-p)
           (async-shell-command "sudo apt install swi-prolog -y" "*SWI-Prolog Install*")
         (message "Installez swi-prolog avec votre gestionnaire de paquets"))))))

(defun metal-deps-desinstaller-swi-prolog ()
  "Désinstalle SWI-Prolog."
  (interactive)
  (if (not (metal-deps--swipl-present-p))
      (message "SWI-Prolog n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller SWI-Prolog ? ")
      (metal-deps--journaliser "Désinstallation de SWI-Prolog")
      (pcase system-type
        ('darwin
         (if (and (metal-deps--brew-present-p)
                  (= 0 (call-process "brew" nil nil nil "list" "swi-prolog")))
             (async-shell-command "brew uninstall swi-prolog" "*SWI-Prolog Uninstall*")
           (message "SWI-Prolog installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('windows-nt
         (if (metal-deps--scoop-present-p)
             (async-shell-command "scoop uninstall swipl" "*SWI-Prolog Uninstall*")
           (message "SWI-Prolog installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('gnu/linux
         (if (= 0 (call-process "dpkg" nil nil nil "-s" "swi-prolog"))
             (async-shell-command "sudo apt remove swi-prolog -y" "*SWI-Prolog Uninstall*")
           (message "SWI-Prolog installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - Poppler et pdf-tools
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-poppler ()
  "Installe Poppler (requis pour pdf-tools)."
  (interactive)
  (if (metal-deps--poppler-present-p)
      (message "✓ Poppler déjà installé")
    (metal-deps--journaliser "Installation de Poppler")
    (pcase system-type
      ('darwin
       (if (metal-deps--brew-present-p)
           (async-shell-command "brew install poppler automake autoconf pkg-config" "*Poppler Install*")
         (message "Installez d'abord Homebrew")))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (progn
             (metal-deps--scoop-ensure-7zip)
             (message "📦 Installation de Poppler via Scoop...")
             (async-shell-command "scoop install poppler" "*Poppler Install*"))
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (if (metal-deps--apt-present-p)
           (async-shell-command "sudo apt install -y libpoppler-dev libpoppler-glib-dev poppler-utils autoconf automake" "*Poppler Install*")
         (message "Installez poppler avec votre gestionnaire de paquets"))))))

(defun metal-deps-installer-pdf-tools ()
  "Installe et compile pdf-tools."
  (interactive)
  (metal-deps--journaliser "Installation de pdf-tools")
  
  ;; Vérifier et installer Poppler si nécessaire
  (unless (metal-deps--poppler-present-p)
    (metal-deps-installer-poppler)
    (message "⚠ Attendez l'installation de Poppler puis relancez cette commande")
    (user-error "Poppler requis"))
  
  ;; Nettoyer le dossier de build existant
  (let ((build-dir (expand-file-name "straight/build/pdf-tools" user-emacs-directory)))
    (when (file-directory-p build-dir)
      (message "🧹 Nettoyage du dossier de build existant...")
      (delete-directory build-dir t)))
  
  ;; Configurer les variables d'environnement pour la compilation sur macOS
  (when (eq system-type 'darwin)
    (setenv "PKG_CONFIG_PATH" "/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig")
    (setenv "ACLOCAL_PATH" "/opt/homebrew/share/aclocal"))
  
  ;; Installer pdf-tools
  (message "📦 Installation de pdf-tools...")
  (straight-use-package 'pdf-tools)
  (require 'pdf-tools)
  
  ;; Sur Linux/Chromebook : corriger les permissions du script autobuild
  (when (eq system-type 'gnu/linux)
    (let ((autobuild (expand-file-name
                      "straight/build/pdf-tools/build/server/autobuild"
                      user-emacs-directory)))
      (when (file-exists-p autobuild)
        (set-file-modes autobuild #o755)
        (metal-deps--journaliser "chmod +x appliqué sur %s" autobuild))))
  
  ;; Compiler epdfinfo si nécessaire
  (unless (metal-deps--epdfinfo-present-p)
    (message "🔧 Compilation de epdfinfo...")
    (pdf-tools-install t t))
  
  ;; (message "✓ pdf-tools installé")
  )

(defun metal-deps-reparer-epdfinfo ()
  "Répare l'attribut quarantine de epdfinfo sur macOS."
  (interactive)
  (unless (eq system-type 'darwin)
    (user-error "Cette fonction est uniquement pour macOS"))
  (let ((chemin (metal-deps--chemin-epdfinfo)))
    (if chemin
        (progn
          (shell-command (format "xattr -d com.apple.quarantine %s 2>/dev/null" 
                                 (shell-quote-argument chemin)))
          (message "✓ Attribut quarantine supprimé de %s" chemin))
      (message "⚠ epdfinfo non trouvé"))))

(defun metal-deps-desinstaller-pdf-tools ()
  "Désinstalle pdf-tools."
  (interactive)
  (when (yes-or-no-p "Voulez-vous vraiment désinstaller pdf-tools ? ")
    (metal-deps--journaliser "Désinstallation de pdf-tools")
    (let ((repos-dir (expand-file-name "straight/repos/pdf-tools" user-emacs-directory))
          (build-dir (expand-file-name "straight/build/pdf-tools" user-emacs-directory)))
      (when (file-exists-p repos-dir)
        (delete-directory repos-dir t))
      (when (file-exists-p build-dir)
        (delete-directory build-dir t)))
    (when (boundp 'straight--build-cache)
      (remhash "pdf-tools" straight--build-cache))
    (when (boundp 'straight--recipe-cache)
      (remhash 'pdf-tools straight--recipe-cache))
    (message "✓ pdf-tools désinstallé. Redémarrez Emacs avant de réinstaller.")))

(defun metal-deps-desinstaller-poppler ()
  "Désinstalle poppler."
  (interactive)
  (if (not (metal-deps--poppler-present-p))
      (message "Poppler n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller Poppler ? ")
      (metal-deps--journaliser "Désinstallation de Poppler")
      (pcase system-type
        ('darwin
         (if (and (metal-deps--brew-present-p)
                  (= 0 (call-process "brew" nil nil nil "list" "poppler")))
             (async-shell-command "brew uninstall poppler" "*Poppler Uninstall*")
           (message "Poppler installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('gnu/linux
         (if (= 0 (call-process "dpkg" nil nil nil "-s" "poppler-utils"))
             (async-shell-command "sudo apt remove poppler-utils -y" "*Poppler Uninstall*")
           (message "Poppler installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - draw.io Desktop
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-telecharger-drawio ()
  "Ouvre la page de téléchargement de draw.io Desktop sur GitHub."
  (interactive)
  (browse-url "https://github.com/jgraph/drawio-desktop/releases/latest")
  (message "Téléchargez le fichier .deb depuis la page GitHub"))

(defun metal-deps-installer-drawio-deb ()
  "Installe draw.io Desktop à partir d'un fichier .deb téléchargé.
Ouvre un sélecteur de fichiers pour choisir le .deb."
  (interactive)
  (let* ((default-dir (if (file-directory-p "/mnt/chromeos/MyFiles/Downloads")
                          "/mnt/chromeos/MyFiles/Downloads/"
                        "~/Downloads/"))
         (deb (read-file-name "Choisir le fichier .deb de draw.io : "
                             default-dir nil t nil
                             (lambda (f)
                               (or (file-directory-p f)
                                   (string-match-p "\\.deb\\'" f))))))
    (unless (and deb (string-match-p "\\.deb\\'" deb))
      (user-error "Aucun fichier .deb sélectionné"))
    (unless (file-exists-p deb)
      (user-error "Fichier introuvable : %s" deb))
    (metal-deps--journaliser "Installation de draw.io depuis %s" deb)
    (message "📦 Installation de draw.io...")
    (let ((buf-name "*draw.io Install*"))
      (set-process-sentinel
       (start-process-shell-command
        "drawio-install" buf-name
        (format "sudo dpkg -i %s; sudo apt install -f -y"
                (shell-quote-argument (expand-file-name deb))))
       (lambda (proc _event)
         (when (eq (process-status proc) 'exit)
           (if (= (process-exit-status proc) 0)
               (progn
                 (message "✅ draw.io installé avec succès")
                 (run-with-timer 1 nil #'metal-deps-afficher-etat))
             (message "❌ Erreur lors de l'installation de draw.io. Voir %s" buf-name)))))
      (display-buffer buf-name))))

(defun metal-deps-installer-drawio ()
  "Installe draw.io Desktop."
  (interactive)
  (if (metal-deps--drawio-present-p)
      (message "✓ draw.io déjà installé")
    (metal-deps--journaliser "Installation de draw.io Desktop")
    (pcase system-type
      ('darwin
       (if (metal-deps--brew-present-p)
           (progn
             (message "📦 Installation de draw.io via Homebrew...")
             (async-shell-command "brew install --cask drawio" "*draw.io Install*"))
         (browse-url "https://github.com/jgraph/drawio-desktop/releases")
         (message "Téléchargez draw.io depuis le site web")))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (progn
             (metal-deps--scoop-ensure-7zip)
             (metal-deps--scoop-add-extras-bucket)
             (message "📦 Installation de draw.io via Scoop...")
             (async-shell-command "scoop install draw.io" "*draw.io Install*"))
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (metal-deps-installer-drawio-deb)))))

(defun metal-deps-desinstaller-drawio ()
  "Désinstalle draw.io Desktop."
  (interactive)
  (if (not (metal-deps--drawio-present-p))
      (message "draw.io n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller draw.io ? ")
      (metal-deps--journaliser "Désinstallation de draw.io")
      (pcase system-type
        ('darwin
         (if (and (metal-deps--brew-present-p)
                  (file-exists-p "/Applications/draw.io.app"))
             (async-shell-command "brew uninstall --cask drawio" "*draw.io Uninstall*")
           (message "draw.io installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('windows-nt
         (if (metal-deps--scoop-present-p)
             (async-shell-command "scoop uninstall draw.io" "*draw.io Uninstall*")
           (message "draw.io installé à l'extérieur de Scoop. Désinstallez manuellement.")))
        ('gnu/linux
         (if (= 0 (call-process "dpkg" nil nil nil "-s" "draw.io"))
             (async-shell-command "sudo apt remove draw.io -y" "*draw.io Uninstall*")
           (message "draw.io installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - ripgrep
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-ripgrep ()
  "Installe ripgrep (rg), un outil de recherche récursive ultra-rapide.
Requis par le paquet Emacs `deadgrep' pour la recherche interactive
dans les fichiers de projet."
  (interactive)
  (if (metal-deps--ripgrep-present-p)
      (message "✓ ripgrep déjà installé")
    (metal-deps--journaliser "Installation de ripgrep")
    (pcase system-type
      ('darwin
       (if (metal-deps--brew-present-p)
           (async-shell-command "brew install ripgrep" "*ripgrep Install*")
         (browse-url "https://github.com/BurntSushi/ripgrep/releases")
         (message "Téléchargez ripgrep depuis le site web")))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (progn
             (metal-deps--scoop-ensure-7zip)
             (message "📦 Installation de ripgrep via Scoop...")
             (async-shell-command "scoop install ripgrep" "*ripgrep Install*"))
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (if (metal-deps--apt-present-p)
           (async-shell-command "sudo apt install ripgrep -y" "*ripgrep Install*")
         (message "Installez ripgrep avec votre gestionnaire de paquets"))))))

(defun metal-deps-desinstaller-ripgrep ()
  "Désinstalle ripgrep."
  (interactive)
  (if (not (metal-deps--ripgrep-present-p))
      (message "ripgrep n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller ripgrep ? ")
      (metal-deps--journaliser "Désinstallation de ripgrep")
      (pcase system-type
        ('darwin
         (if (and (metal-deps--brew-present-p)
                  (= 0 (call-process "brew" nil nil nil "list" "ripgrep")))
             (async-shell-command "brew uninstall ripgrep" "*ripgrep Uninstall*")
           (message "ripgrep installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('windows-nt
         (if (metal-deps--scoop-present-p)
             (async-shell-command "scoop uninstall ripgrep" "*ripgrep Uninstall*")
           (message "ripgrep installé à l'extérieur de Scoop. Désinstallez manuellement.")))
        ('gnu/linux
         (if (= 0 (call-process "dpkg" nil nil nil "-s" "ripgrep"))
             (async-shell-command "sudo apt remove ripgrep -y" "*ripgrep Uninstall*")
           (message "ripgrep installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - MiKTeX (Windows)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-miktex ()
  "Installe MiKTeX via Scoop et configure l'auto-installation des paquets."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "MiKTeX est géré uniquement sur Windows dans MetalEmacs"))
  (if (metal-deps--miktex-present-p)
      (message "✓ MiKTeX déjà installé")
    (unless (metal-deps--scoop-present-p)
      (user-error "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop"))
    (metal-deps--journaliser "Installation de MiKTeX")
    (metal-deps--scoop-ensure-7zip)
    (message "📦 Installation de MiKTeX via Scoop (peut prendre plusieurs minutes)...")
    (let ((buf-name "*MiKTeX Install*"))
      (set-process-sentinel
       (start-process-shell-command "miktex-install" buf-name
                                   "scoop install miktex")
       (lambda (proc _event)
         (when (eq (process-status proc) 'exit)
           (if (= (process-exit-status proc) 0)
               (progn
                 ;; Configurer auto-installation des paquets manquants
                 (let ((initexmf (expand-file-name
                                  "scoop/apps/miktex/current/texmfs/install/miktex/bin/x64/initexmf.exe"
                                  (or (getenv "HOME") (getenv "USERPROFILE")))))
                   (when (file-exists-p initexmf)
                     (call-process initexmf nil nil nil
                                   "--set-config-value=[MPM]AutoInstall=1")
                     (metal-deps--journaliser "MiKTeX configuré : auto-installation activée")))
                 ;; Mettre à jour le PATH
                 (metal-deps--configurer-chemin-miktex)
                 (message "✅ MiKTeX installé et configuré (auto-installation des paquets activée)"))
             (message "❌ Erreur lors de l'installation de MiKTeX. Voir %s" buf-name)))))
      (display-buffer buf-name))))

(defun metal-deps--configurer-chemin-miktex ()
  "Ajoute MiKTeX au PATH d'Emacs si installé via Scoop."
  (when (eq system-type 'windows-nt)
    (let ((miktex-bin (expand-file-name
                       "scoop/apps/miktex/current/texmfs/install/miktex/bin/x64"
                       (or (getenv "HOME") (getenv "USERPROFILE")))))
      (when (file-directory-p miktex-bin)
        (add-to-list 'exec-path miktex-bin)
        (setenv "PATH" (concat miktex-bin ";" (getenv "PATH")))))))

(defun metal-deps-desinstaller-miktex ()
  "Désinstalle MiKTeX via Scoop."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "MiKTeX est géré uniquement sur Windows dans MetalEmacs"))
  (if (not (metal-deps--miktex-present-p))
      (message "MiKTeX n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller MiKTeX ? ")
      (metal-deps--journaliser "Désinstallation de MiKTeX")
      (if (metal-deps--scoop-present-p)
          (async-shell-command "scoop uninstall miktex" "*MiKTeX Uninstall*")
        (message "MiKTeX installé à l'extérieur de Scoop. Désinstallez manuellement.")))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Installateurs - SumatraPDF (Windows)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-sumatrapdf ()
  "Installe SumatraPDF via Scoop (Windows uniquement).
SumatraPDF est utilisé par `metal-pdf' pour afficher le dialogue
d'impression natif Windows avec fermeture automatique."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "SumatraPDF est géré uniquement sur Windows dans MetalEmacs"))
  (if (metal-deps--sumatrapdf-present-p)
      (message "✓ SumatraPDF déjà installé")
    (unless (metal-deps--scoop-present-p)
      (user-error "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop"))
    (metal-deps--journaliser "Installation de SumatraPDF")
    (message "📦 Installation de SumatraPDF via Scoop...")
    (let ((buf-name "*SumatraPDF Install*"))
      (set-process-sentinel
       (start-process-shell-command "sumatrapdf-install" buf-name
                                    "scoop install sumatrapdf")
       (lambda (proc _event)
         (when (eq (process-status proc) 'exit)
           (if (= (process-exit-status proc) 0)
               (progn
                 ;; Ajouter le dossier Scoop au PATH d'Emacs pour que
                 ;; `executable-find' le trouve immédiatement.
                 (let ((sumatra-bin (expand-file-name
                                     "scoop/apps/sumatrapdf/current"
                                     (or (getenv "HOME") (getenv "USERPROFILE")))))
                   (when (file-directory-p sumatra-bin)
                     (add-to-list 'exec-path sumatra-bin)
                     (setenv "PATH" (concat sumatra-bin ";" (getenv "PATH")))))
                 (message "✅ SumatraPDF installé (impression PDF native disponible)"))
             (message "❌ Erreur lors de l'installation de SumatraPDF. Voir %s" buf-name)))))
      (display-buffer buf-name))))

(defun metal-deps-desinstaller-sumatrapdf ()
  "Désinstalle SumatraPDF via Scoop."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "SumatraPDF est géré uniquement sur Windows dans MetalEmacs"))
  (if (not (metal-deps--sumatrapdf-present-p))
      (message "SumatraPDF n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller SumatraPDF ? ")
      (metal-deps--journaliser "Désinstallation de SumatraPDF")
      (if (metal-deps--scoop-present-p)
          (async-shell-command "scoop uninstall sumatrapdf" "*SumatraPDF Uninstall*")
        (message "SumatraPDF installé à l'extérieur de Scoop. Désinstallez manuellement.")))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Liste des outils
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-deps-outils
  '(;; Prérequis système
    (:nom "HOME (Windows)" 
     :verifier metal-deps--home-configure-p
     :installer ignore 
     :desinstaller nil
     :categorie prerequis 
     :windows-seulement t)
    (:nom "Git" 
     :verifier metal-deps--git-portable-present-p
     :installer metal-deps-installer-git-portable 
     :desinstaller metal-deps-desinstaller-git-portable
     :categorie prerequis 
     :windows-seulement t)
    (:nom "Command Line Tools" 
     :verifier metal-deps--xcode-present-p
     :installer metal-deps-installer-xcode-clt 
     :desinstaller metal-deps-desinstaller-xcode-clt
     :categorie prerequis 
     :macos-seulement t)
    
    ;; Gestionnaires de paquets
    (:nom "Homebrew" 
     :verifier metal-deps--brew-present-p
     :installer metal-deps-installer-homebrew 
     :desinstaller metal-deps-desinstaller-homebrew
     :categorie gestionnaire 
     :macos-seulement t
     :condition metal-deps--macos-13-plus-p)
    (:nom "Scoop" 
     :verifier metal-deps--scoop-present-p
     :installer metal-deps-installer-scoop 
     :desinstaller metal-deps-desinstaller-scoop
     :categorie gestionnaire 
     :windows-seulement t)
    (:nom "apt" 
     :verifier metal-deps--apt-present-p
     :installer ignore 
     :desinstaller nil
     :categorie gestionnaire 
     :linux-seulement t)
    
    ;; Logiciels
    (:nom "Miniconda" 
     :verifier metal-deps--miniconda-present-p
     :installer metal-deps-installer-miniconda 
     :desinstaller metal-deps-desinstaller-miniconda
     :categorie logiciels)
    (:nom "Quarto" 
     :verifier metal-deps--quarto-present-p
     :installer metal-deps-installer-quarto 
     :desinstaller metal-deps-desinstaller-quarto
     :categorie logiciels)
    (:nom "SWI-Prolog" 
     :verifier metal-deps--swipl-present-p
     :installer metal-deps-installer-swi-prolog 
     :desinstaller metal-deps-desinstaller-swi-prolog
     :categorie logiciels)
    (:nom "MiKTeX" 
     :verifier metal-deps--miktex-present-p
     :installer metal-deps-installer-miktex 
     :desinstaller metal-deps-desinstaller-miktex
     :categorie logiciels 
     :windows-seulement t)
    (:nom "SumatraPDF"
     :verifier metal-deps--sumatrapdf-present-p
     :installer metal-deps-installer-sumatrapdf
     :desinstaller metal-deps-desinstaller-sumatrapdf
     :categorie logiciels
     :windows-seulement t
     :description "Visionneuse PDF (impression native depuis MetalEmacs)")
    (:nom "draw.io" 
     :verifier metal-deps--drawio-present-p
     :installer metal-deps-installer-drawio 
     :desinstaller metal-deps-desinstaller-drawio
     :telecharger metal-deps-telecharger-drawio
     :categorie logiciels
     :condition (lambda () (not (eq system-type 'gnu/linux))))
    (:nom "ripgrep" 
     :verifier metal-deps--ripgrep-present-p
     :installer metal-deps-installer-ripgrep 
     :desinstaller metal-deps-desinstaller-ripgrep
     :categorie logiciels
     :description "Recherche multi-fichiers (C-c g)")
    
    ;; PDF
    (:nom "Poppler" 
     :verifier metal-deps--poppler-present-p
     :installer metal-deps-installer-poppler 
     :desinstaller metal-deps-desinstaller-poppler
     :categorie pdf
     :condition (lambda () (not (eq system-type 'windows-nt))))
    (:nom "pdf-tools" 
     :verifier metal-deps--epdfinfo-present-p
     :installer metal-deps-installer-pdf-tools 
     :desinstaller metal-deps-desinstaller-pdf-tools
     :categorie pdf
     :condition (lambda () (not (eq system-type 'windows-nt)))))
  "Liste des outils gérés par MetalEmacs.")

;;; ═══════════════════════════════════════════════════════════════════
;;; Filtrage et vérification des outils
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--outil-applicable-p (outil)
  "Retourne t si OUTIL s'applique au système actuel."
  (let ((macos-seulement (plist-get outil :macos-seulement))
        (windows-seulement (plist-get outil :windows-seulement))
        (linux-seulement (plist-get outil :linux-seulement))
        (condition-fn (plist-get outil :condition)))
    (and (or (not macos-seulement) (eq system-type 'darwin))
         (or (not windows-seulement) (eq system-type 'windows-nt))
         (or (not linux-seulement) (eq system-type 'gnu/linux))
         (or (not condition-fn) (funcall condition-fn)))))

(defun metal-deps--outil-present-p (outil)
  "Retourne t si OUTIL est installé."
  (let ((verifier (plist-get outil :verifier)))
    (when verifier
      (funcall verifier))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Collecte des outils à installer (par catégorie ou tous)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--collecter-a-installer (&optional categorie)
  "Retourne une liste de paires (NOM . INSTALLEUR) pour les outils manquants.
Si CATEGORIE est non-nil, filtre par cette catégorie.
Exclut les outils déjà installés, non applicables, ou sans installeur."
  (let (resultat)
    (dolist (outil metal-deps-outils)
      (when (and (metal-deps--outil-applicable-p outil)
                 (not (metal-deps--outil-present-p outil))
                 (or (null categorie)
                     (eq (plist-get outil :categorie) categorie)))
        (let ((installeur (plist-get outil :installer)))
          (when (and installeur (not (eq installeur 'ignore)))
            (push (cons (plist-get outil :nom) installeur) resultat)))))
    (nreverse resultat)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Interface graphique avec widgets
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-afficher-etat ()
  "Affiche l'état des dépendances avec interface graphique."
  (interactive)
  (let ((buf (get-buffer-create "*MetalEmacs Assistant*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (remove-overlays)
      (widget-insert "\n")
      (widget-insert "╔═══════════════════════════════════════════════════════════════╗\n")
      (widget-insert "║              Assistant MetalEmacs - Dépendances               ║\n")
      (widget-insert "╚═══════════════════════════════════════════════════════════════╝\n\n")
      (widget-insert (format "Système : %s\n" (metal-deps--nom-systeme)))
      (when metal-deps--installation-en-cours
        (widget-insert (format "⏳ Installation en cours (%d restant%s)\n"
                               (length metal-deps--file-attente)
                               (if (> (length metal-deps--file-attente) 1) "s" ""))))
      (widget-insert "\n")
      
      (dolist (categorie '((prerequis . "📋 Prérequis système")
                           (gestionnaire . "📦 Gestionnaires de paquets")
                           (logiciels . "🎓 Logiciels")
                           (pdf . "📄 Support PDF")))
        (let* ((cat-id (car categorie))
               (cat-nom (cdr categorie))
               (outils-cat (cl-remove-if-not
                            (lambda (o) 
                              (and (eq (plist-get o :categorie) cat-id)
                                   (metal-deps--outil-applicable-p o)))
                            metal-deps-outils)))
          (when outils-cat
            (widget-insert (format "\n%s\n" cat-nom))
            (widget-insert "────────────────────────────────────────\n")
            (dolist (outil outils-cat)
              (let* ((nom (plist-get outil :nom))
                     (present (metal-deps--outil-present-p outil))
                     (installeur (plist-get outil :installer))
                     (desinstalleur (plist-get outil :desinstaller))
                     (statut (if present "✓" "✗")))
                (widget-insert (format "  %s %s" statut nom))
                (when (and (not present) 
                           installeur 
                           (not (eq installeur 'ignore)))
                  ;; Bouton Télécharger (si défini, affiché sur Linux seulement)
                  (let ((telecharger (plist-get outil :telecharger)))
                    (when (and telecharger (eq system-type 'gnu/linux))
                      (widget-insert "  ")
                      (widget-create 'push-button
                                     :notify (lambda (&rest _)
                                               (funcall telecharger))
                                     "Télécharger")))
                  (widget-insert "  ")
                  ;; Bouton Installer — utilise la sentinelle pour rafraîchir
                  (let ((fn installeur))
                    (widget-create 'push-button
                                   :notify (lambda (&rest _)
                                             (metal-deps--executer-et-rafraichir fn))
                                   "Installer")))
                (when (and present desinstalleur)
                  (widget-insert "  ")
                  ;; Bouton Désinstaller — même mécanique
                  (let ((fn desinstalleur))
                    (widget-create 'push-button
                                   :notify (lambda (&rest _)
                                             (metal-deps--executer-et-rafraichir fn))
                                   "Désinstaller")))
                ;; Description optionnelle (ex: raccourci clavier)
                (let ((desc (plist-get outil :description)))
                  (when desc
                    (widget-insert (format "  — %s" desc))))
                (widget-insert "\n"))))))
      
      (widget-insert "\n────────────────────────────────────────\n")
      (widget-insert "Actions rapides : ")
      (widget-create 'push-button
                     :notify (lambda (&rest _) (metal-deps-installer-logiciels))
                     "Installer les logiciels")
      (widget-insert "  ")
      (widget-create 'push-button
                     :notify (lambda (&rest _) (metal-deps-installer-tout))
                     "Tout installer")
      (widget-insert "  ")
      (widget-create 'push-button
                     :notify (lambda (&rest _) (metal-deps-afficher-etat))
                     "Rafraîchir")
      (when metal-deps--installation-en-cours
        (widget-insert "  ")
        (widget-create 'push-button
                       :notify (lambda (&rest _)
                                 (metal-deps--annuler-file-attente)
                                 (run-with-timer 1 nil #'metal-deps-afficher-etat))
                       "Annuler"))
      (widget-insert "\n\n")
      
      (use-local-map widget-keymap)
      (widget-setup)
      (goto-char (point-min))
      (read-only-mode 1)
      (setq-local tab-line-exclude nil)
      (tab-line-mode 1))
    (switch-to-buffer buf)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Commandes d'installation groupées (séquentielles)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps-installer-logiciels ()
  "Installe tous les logiciels manquants de la catégorie `logiciels'.
Les installations sont exécutées séquentiellement pour éviter les
conflits entre gestionnaires de paquets (Homebrew, Scoop, apt)."
  (interactive)
  (let ((a-installer (metal-deps--collecter-a-installer 'logiciels)))
    (if (null a-installer)
        (message "✓ Tous les logiciels sont déjà installés")
      (message "Installation séquentielle de %d logiciel%s : %s"
               (length a-installer)
               (if (> (length a-installer) 1) "s" "")
               (mapconcat #'car a-installer ", "))
      (metal-deps--lancer-file-attente
       a-installer
       (lambda ()
         (message "✓ Installation des logiciels terminée. Cliquez Rafraîchir pour vérifier.")
         (run-with-timer 1 nil #'metal-deps-afficher-etat))))))

(defun metal-deps-installer-tout ()
  "Installe tous les composants manquants (prérequis, gestionnaires, logiciels, PDF).
Les installations sont exécutées séquentiellement pour éviter les
conflits entre gestionnaires de paquets."
  (interactive)
  (let ((a-installer (metal-deps--collecter-a-installer)))
    (if (null a-installer)
        (message "✓ Tous les composants sont déjà installés")
      (message "Installation séquentielle de %d composant%s : %s"
               (length a-installer)
               (if (> (length a-installer) 1) "s" "")
               (mapconcat #'car a-installer ", "))
      (metal-deps--lancer-file-attente
       a-installer
       (lambda ()
         (message "✓ Installation complète terminée. Cliquez Rafraîchir pour vérifier.")
         (run-with-timer 1 nil #'metal-deps-afficher-etat))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Vérification au démarrage
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--verifier-au-demarrage ()
  "Vérifie les dépendances au démarrage et affiche un avertissement si nécessaire."
  (let ((manquants (cl-remove-if
                    (lambda (o)
                      (or (not (metal-deps--outil-applicable-p o))
                          (not (eq (plist-get o :categorie) 'logiciels))
                          (metal-deps--outil-present-p o)))
                    metal-deps-outils)))
    (when manquants
      (run-with-idle-timer
       2 nil
       (lambda ()
         (message "⚠ Logiciels disponibles : %s — M-x metal-deps-afficher-etat"
                  (mapconcat (lambda (o) (plist-get o :nom)) manquants ", ")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Configuration des chemins
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-deps--configurer-chemins ()
  "Configure les chemins pour les outils installés."
  ;; Git sur Windows (plusieurs sources possibles)
  (when (eq system-type 'windows-nt)
    (let ((git-bin (metal-deps--find-git-bin)))
      (when git-bin
        (add-to-list 'exec-path git-bin)
        (setenv "PATH" (concat git-bin ";" (getenv "PATH"))))))
  
  ;; Homebrew sur macOS Apple Silicon
  (when (and (eq system-type 'darwin)
             (metal-deps--apple-silicon-p)
             (file-exists-p "/opt/homebrew/bin"))
    (add-to-list 'exec-path "/opt/homebrew/bin")
    (setenv "PATH" (concat "/opt/homebrew/bin:" (getenv "PATH"))))
  
  ;; Scoop sur Windows
  (when (and (eq system-type 'windows-nt)
             (metal-deps--scoop-present-p))
    (let ((scoop-shims (expand-file-name "shims" (metal-deps--scoop-path))))
      (when (file-exists-p scoop-shims)
        (add-to-list 'exec-path scoop-shims)
        (setenv "PATH" (concat scoop-shims ";" (getenv "PATH"))))))
  
  ;; MiKTeX sur Windows (via Scoop)
  (metal-deps--configurer-chemin-miktex)
  
  ;; Miniconda - dossier utilisateur
  (let ((conda-paths (list
                      (expand-file-name "miniconda3" (getenv "USERPROFILE"))
                      (expand-file-name "scoop/apps/miniconda3/current" (getenv "HOME"))
                      (expand-file-name "scoop/apps/miniconda3/current" (getenv "USERPROFILE"))
                      (expand-file-name "miniconda3" (getenv "HOME"))
                      (expand-file-name "anaconda3" (getenv "HOME")))))
    (dolist (p conda-paths)
      (when (and p (file-exists-p p))
        (add-to-list 'exec-path p)
        (add-to-list 'exec-path (expand-file-name "Scripts" p))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Initialisation
;;; ═══════════════════════════════════════════════════════════════════

(metal-deps--configurer-chemins)
(add-hook 'emacs-startup-hook #'metal-deps--verifier-au-demarrage)

;; Raccourcis clavier pour pdf-view
(with-eval-after-load 'pdf-tools
  (define-key pdf-view-mode-map (kbd "<right>") 'pdf-view-next-page)
  (define-key pdf-view-mode-map (kbd "<left>") 'pdf-view-previous-page))

;; Linux/Chromebook : corriger automatiquement les permissions d'autobuild
;; avant chaque compilation de pdf-tools (straight.el recrée le fichier
;; sans le bit exécutable, ce qui cause « Permission denied » code 126).
(when (eq system-type 'gnu/linux)
  (advice-add 'pdf-tools-install :before
              (lambda (&rest _)
                (let ((autobuild (expand-file-name
                                  "straight/build/pdf-tools/build/server/autobuild"
                                  user-emacs-directory)))
                  (when (file-exists-p autobuild)
                    (set-file-modes autobuild #o755))))))

(provide 'metal-deps)

;;; metal-deps.el ends here
