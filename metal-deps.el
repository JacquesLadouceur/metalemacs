;;; metal-deps.el --- Installation des dépendances externes pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 3.8

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
;; Version 3.8 : Seuil macOS « moderne » (>= 14, Sonoma) pour la chaîne PDF
;;               et Node.js.  Au-delà, Homebrew fournit des bottles fiables
;;               (Intel comme Apple Silicon) : Poppler/pdf-tools sont offerts
;;               et Node.js s'installe via Homebrew.  En dessous, ces binaires
;;               se compileraient depuis la source : Poppler/pdf-tools sont
;;               masqués (repli sur le visionneur intégré doc-view) et Node.js
;;               passe par l'installeur .pkg.  Critère désormais fondé sur la
;;               version de macOS plutôt que sur l'architecture.
;;               SWI-Prolog : sur Mac < 14, installeur officiel .dmg
;;               (universel, macOS 10.15+) au lieu de Homebrew.  ripgrep
;;               n'est pas offert sur Mac < 14.
;;               Ghostscript : proposé sur Mac < 14 comme moteur de rendu
;;               de doc-view (sans lui, doc-view affiche le PDF en texte
;;               brut au lieu des pages).  Sur Mac < 14, installé via le
;;               .pkg autonome officiel (Koch/MacTeX), Homebrew étant Tier 3
;;               sur ces systèmes (compilation depuis la source).
;;
;; Commandes principales :
;;   M-x metal-deps-afficher-etat     - Interface graphique avec boutons
;;   M-x metal-deps-installer-logiciels   - Installe tous les logiciels
;;   M-x metal-deps-installer-tout    - Installe tous les composants

;;; Code:

(require 'cl-lib)
(require 'widget)
(require 'url)
(require 'ansi-color)
(eval-when-compile (require 'wid-edit))

;; Les commandes d'installation lancées via `compile' (ex. « brew install
;; node » sur macOS) émettent de la sortie colorée par séquences ANSI.
;; Le mode Compilation ne les interprète pas par défaut : sans ce filtre,
;; le buffer *Installation Node.js* affiche des codes bruts du type
;; « ^[[32m…^[[0m ».  On colorise donc la sortie de compilation.
;; `ansi-color-compilation-filter' existe depuis Emacs 28 ; on protège pour
;; les Emacs plus anciens (ex. sur macOS Catalina).
(when (fboundp 'ansi-color-compilation-filter)
  (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter))

(defgroup metal-deps nil
  "Gestion des dépendances MetalEmacs."
  :group 'convenience)

(defcustom metal-deps-tampon-journal "*MetalEmacs Journal*"
  "Tampon pour les journaux d'installation."
  :type 'string)

(defcustom metal-deps--largeur-colonne-nom 22
  "Largeur cible (en colonnes d'affichage) pour la colonne « nom »
de l'Assistant.  Les boutons commencent à cette position, donnant un
alignement vertical propre.  Augmenter si certains noms sont tronqués
ou que les boutons commencent trop tôt sur des noms longs."
  :type 'integer
  :group 'metal-deps)

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

(defcustom metal-deps-macos-seuil-moderne 14
  "Version majeure de macOS à partir de laquelle MetalEmacs considère
le système comme « moderne ».  Au-delà (>=), Homebrew fournit des
bottles fiables — y compris sur Intel, qui retombe sur les bottles de
la version précédente — donc on offre toute la chaîne PDF (Poppler /
pdf-tools) et l'installation de Node.js via Homebrew.  En dessous, ces
binaires se compileraient depuis la source (lent, fragile) : on bascule
alors sur des solutions sans compilation (visionneur PDF intégré
`doc-view', installeur .pkg pour Node.js).

Le seuil par défaut (14 = Sonoma) correspond à la dernière version
officiellement supportée par Homebrew.  Ajuster ici si la politique
de support évolue."
  :type 'integer
  :group 'metal-deps)

(defun metal-deps--macos-moderne-p ()
  "Retourne t si macOS >= `metal-deps-macos-seuil-moderne'.
Sur les systèmes non-macOS, retourne nil (le concept ne s'applique pas)."
  (let ((v (metal-deps--version-macos)))
    (and v (>= (car v) metal-deps-macos-seuil-moderne))))

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

(defvar metal-deps--sudo-amorce nil
  "Non-nil si sudo a été amorcé pour la session d'installation en cours.
Réinitialisé à nil à la fin de chaque installation séquentielle.")

(defun metal-deps--amorcer-sudo ()
  "Amorce sudo en demandant le mot de passe une seule fois (Linux).
Le mot de passe est saisi via `read-passwd' qui masque les caractères
dans le minibuffer, puis envoyé à `sudo -S -v' qui valide l'authen-
tification et met à jour le timestamp sudo.  Les commandes `sudo apt
...' suivantes héritent du cache sudo (~15 min par défaut) et ne
demandent plus rien.

Ne fait rien sur macOS ou Windows.  Ne redemande pas si sudo est déjà
amorcé pour cette session ou si le timestamp sudo système est encore
valide."
  (when (and (eq system-type 'gnu/linux)
             (executable-find "sudo")
             (not metal-deps--sudo-amorce))
    (cond
     ;; sudo déjà actif au niveau système : pas besoin du mot de passe
     ((zerop (call-process "sudo" nil nil nil "-n" "-v"))
      (setq metal-deps--sudo-amorce t)
      (metal-deps--journaliser "sudo déjà actif (timestamp système valide)"))
     (t
      ;; Demander le mot de passe (saisie masquée par read-passwd)
      (let ((pw (read-passwd
                 "Mot de passe sudo (saisi une seule fois pour toute l'installation) : ")))
        (unwind-protect
            (with-temp-buffer
              (insert pw "\n")
              (let ((res (call-process-region
                          (point-min) (point-max)
                          "sudo" nil t nil "-S" "-v")))
                (if (zerop res)
                    (progn
                      (setq metal-deps--sudo-amorce t)
                      (metal-deps--journaliser "sudo amorcé avec succès"))
                  (user-error "Échec d'authentification sudo"))))
          ;; Effacer le mot de passe de la mémoire dans tous les cas
          (clear-string pw)))))))

(defun metal-deps--lancer-file-attente (outils &optional callback)
  "Lance l'installation séquentielle des OUTILS.
OUTILS est une liste de paires (NOM . FONCTION).
Chaque installation attend la fin de la précédente avant de démarrer.
CALLBACK est appelé quand toutes les installations sont terminées."
  (when metal-deps--installation-en-cours
    (user-error "Une installation séquentielle est déjà en cours"))
  ;; Amorcer sudo sur Linux pour éviter mot de passe affiché en clair
  ;; dans les buffers async-shell-command (un seul prompt pour toute la file)
  (metal-deps--amorcer-sudo)
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
    (setq metal-deps--sudo-amorce nil)
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

(defun metal-deps--nodejs-present-p ()
  "Retourne t si Node.js et npm sont disponibles dans le PATH."
  (and (executable-find "node") (executable-find "npm")))

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
  "Retourne t si SWI-Prolog est installé.
Cherche `swipl' dans le PATH, et sur macOS aussi dans le bundle
applicatif officiel (/Applications/SWI-Prolog.app), où l'installeur
.dmg place l'exécutable hors du PATH."
  (or (not (null (executable-find "swipl")))
      (and (eq system-type 'darwin)
           (file-executable-p
            "/Applications/SWI-Prolog.app/Contents/MacOS/swipl"))))

(defun metal-deps--poppler-present-p ()
  "Retourne t si Poppler est installé."
  (or (executable-find "pdfinfo")
      (executable-find "pdftoppm")))

(defun metal-deps--ghostscript-present-p ()
  "Retourne t si Ghostscript (gs) est installé.
Ghostscript est le moteur de rendu par défaut de `doc-view', utilisé
pour afficher les PDF sur les Mac < 14 où pdf-tools n'est pas proposé.
Sans lui, doc-view ne peut pas rasteriser et affiche le source brut."
  (not (null (executable-find "gs"))))

(defun metal-deps--miktex-present-p ()
  "Retourne t si MiKTeX est installé (via Scoop)."
  (and (eq system-type 'windows-nt)
       (or (executable-find "xelatex")
           (let ((miktex-bin (expand-file-name
                              "scoop/apps/miktex/current/texmfs/install/miktex/bin/x64"
                              (or (getenv "HOME") (getenv "USERPROFILE")))))
             (file-exists-p (expand-file-name "xelatex.exe" miktex-bin))))))

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

(defun metal-deps--ligne-node-pour-macos ()
  "Retourne la ligne majeure de Node.js compatible avec ce macOS.
Les binaires Node ont un macOS minimum (deployment target) qui monte
avec les versions :
- macOS >= 11 (Big Sur+) : dernière LTS (laisser nil → « latest LTS »)
- macOS 10.15 (Catalina) : Node 18.x (dernière ligne au minimum 10.15)
- macOS 10.14 et antérieur : Node 16.x (au-delà, .pkg non installable)
Retourne une chaîne « latest-vXX.x » identifiant le dossier de release,
ou nil pour « dernière LTS » (résolue séparément)."
  (let ((v (metal-deps--version-macos)))
    (cond
     ((null v) "latest-v18.x")              ; prudence si version indéterminée
     ((>= (car v) 11) nil)                  ; Big Sur+ : dernière LTS
     ((and (= (car v) 10) (= (nth 1 v) 15)) "latest-v18.x")  ; Catalina
     (t "latest-v16.x"))))                  ; Mojave et antérieur

(defun metal-deps--derniere-lts-node ()
  "Interroge l'index Node.js et retourne le numéro de la dernière LTS.
Ex: \"v24.15.0\".  Retourne nil en cas d'échec réseau ou de parsing."
  (ignore-errors
    (with-temp-buffer
      (let ((url-request-method "GET"))
        (when (= 0 (call-process "curl" nil t nil "-fsSL"
                                 "https://nodejs.org/dist/index.json"))
          (goto-char (point-min))
          (let* ((data (json-parse-buffer :object-type 'alist
                                          :array-type 'list))
                 (lts (cl-find-if
                       (lambda (rel)
                         (let ((l (alist-get 'lts rel)))
                           ;; json-parse-buffer rend `false' JSON comme :false
                           ;; et une string (nom de LTS) sinon.
                           (and l (stringp l))))
                       data)))
            (and lts (alist-get 'version lts))))))))

(defun metal-deps--url-pkg-node ()
  "Construit l'URL du .pkg Node.js adapté à ce macOS.
Privilégie la dernière LTS sur macOS récent ; plafonne sur les anciens."
  (let ((ligne (metal-deps--ligne-node-pour-macos)))
    (if ligne
        ;; macOS ancien : dossier de ligne figé (latest-v18.x / latest-v16.x).
        ;; On lit SHASUMS256.txt pour extraire le numéro de version exact
        ;; (le .pkg n'y figure pas toujours, mais les .tar.* oui), puis on
        ;; construit l'URL du .pkg à partir de ce numéro.
        (let* ((base (format "https://nodejs.org/download/release/%s/" ligne))
               (ver (ignore-errors
                      (with-temp-buffer
                        (when (= 0 (call-process
                                    "curl" nil t nil "-fsSL"
                                    (concat base "SHASUMS256.txt")))
                          (goto-char (point-min))
                          (when (re-search-forward
                                 "node-\\(v[0-9]+\\.[0-9]+\\.[0-9]+\\)-darwin"
                                 nil t)
                            (match-string 1)))))))
          (and ver (format "%snode-%s.pkg" base ver)))
      ;; macOS récent : dernière LTS via l'index JSON.
      (let ((ver (metal-deps--derniere-lts-node)))
        (and ver (format "https://nodejs.org/dist/%s/node-%s.pkg" ver ver))))))

(defun metal-deps--installer-nodejs-pkg ()
  "Télécharge le .pkg Node.js adapté au macOS et l'ouvre pour installation.
L'étudiant n'a plus qu'à double-cliquer « Continuer » dans l'installeur
Apple.  Évite toute compilation Homebrew (lente/impossible sur vieux Mac)."
  (let ((url (metal-deps--url-pkg-node)))
    (if (not url)
        (metal-deps--afficher-aide
         "Installer Node.js — téléchargement impossible"
         (concat
          "Impossible de déterminer la version de Node.js à télécharger\n"
          "(réseau indisponible ?).\n\n"
          "Téléchargez manuellement l'installeur .pkg depuis :\n"
          "  https://nodejs.org/en/download\n\n"
          "Choisissez « macOS Installer (.pkg) », puis double-cliquez\n"
          "le fichier téléchargé pour l'installer."))
      (let* ((dest (expand-file-name
                    (file-name-nondirectory url) "~/Downloads"))
             (buf "*Installation Node.js*"))
        (metal-deps--journaliser "Installation de Node.js via .pkg : %s" url)
        (with-current-buffer (get-buffer-create buf)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Téléchargement de Node.js…\n  %s\n\n" url))
            (insert "L'installeur Apple s'ouvrira automatiquement à la fin.\n"
                    "Suivez les étapes (« Continuer » / « Installer »).\n")))
        (display-buffer buf)
        ;; Télécharger puis ouvrir le .pkg (open déclenche l'installeur Apple).
        ;; `-sS' (silent + show-errors) supprime la barre de progression de
        ;; curl — qui s'affiche avec des retours chariot ^M illisibles dans
        ;; un buffer Emacs — tout en conservant les messages d'erreur.
        ;; (On évite `--no-progress-meter', absent du curl 7.64 de Catalina.)
        (let* ((cmd (format
                     "curl -fSL -sS -o %s %s && echo TERMINE && open %s"
                     (shell-quote-argument dest)
                     (shell-quote-argument url)
                     (shell-quote-argument dest)))
               (proc (start-process-shell-command
                      "metal-node-pkg" buf cmd)))
          (set-process-sentinel
           proc
           (lambda (_p event)
             (with-current-buffer (get-buffer-create buf)
               (let ((inhibit-read-only t))
                 (goto-char (point-max))
                 (if (string-match-p "finished" event)
                     (insert "\n✓ Installeur ouvert.  Terminez l'installation,\n"
                             "  puis cliquez « Rafraîchir » dans l'Assistant.\n")
                   (insert (format "\n⚠ Problème : %s\n" (string-trim event))))))
             (run-with-timer 1 nil #'metal-deps-afficher-etat))))))))

(defun metal-deps-installer-nodejs ()
  "Installe Node.js (et npm) selon l'OS (et la version sur macOS).
- macOS >= 14 (Sonoma+) : Homebrew (brew install node — bottle, rapide),
                          Intel comme Apple Silicon
- macOS < 14            : installeur .pkg officiel (évite la compilation
                          Homebrew depuis la source, faute de bottle)
- Linux                 : affiche les commandes apt/dnf/pacman (nécessite sudo)
- Windows               : utilise Scoop si disponible, sinon pointe vers nodejs.org"
  (interactive)
  (cond
   ;; Déjà installé
   ((metal-deps--nodejs-present-p)
    (message "✓ Node.js déjà installé (npm version : %s)"
             (string-trim (shell-command-to-string "npm --version"))))
   ;; macOS : >= 14 → Homebrew ; < 14 → .pkg officiel
   ((eq system-type 'darwin)
    (if (metal-deps--macos-moderne-p)
        ;; macOS moderne : bottle disponible, installation rapide via Homebrew
        (if (executable-find "brew")
            (when (yes-or-no-p "Installer Node.js via Homebrew (brew install node) ? ")
              (metal-deps--journaliser "Installation de Node.js via Homebrew (Apple Silicon)")
              (let ((compilation-buffer-name-function
                     (lambda (_) "*Installation Node.js*")))
                (compile "brew install node")))
          (metal-deps--afficher-aide
           "Installer Node.js — Homebrew requis"
           (concat
            "Homebrew n'est pas installé.\n\n"
            "Installez d'abord Homebrew via la section « 📦 Gestionnaires de\n"
            "paquets » de l'Assistant (bouton [Installer] à côté de Homebrew),\n"
            "puis revenez ici pour installer Node.js.")))
      ;; macOS < 14 : pas de bottle → Homebrew compilerait tout depuis la
      ;; source (node → ada-url → llvm…).  On passe par l'installeur .pkg
      ;; officiel.
      (when (yes-or-no-p
             "Installer Node.js via l'installeur officiel (.pkg) ? ")
        (metal-deps--installer-nodejs-pkg))))
   ;; Linux : instructions manuelles (sudo requis)
   ((eq system-type 'gnu/linux)
    (metal-deps--afficher-aide
     "Installer Node.js sur Linux"
     (concat
      "Node.js (qui inclut npm) doit être installé via votre gestionnaire de\n"
      "paquets système.  Ouvrez un terminal et exécutez selon votre distribution :\n\n"
      "  Debian / Ubuntu / ChromeOS Linux :\n"
      "    sudo apt update\n"
      "    sudo apt install -y nodejs npm\n\n"
      "  Fedora / RHEL :\n"
      "    sudo dnf install -y nodejs npm\n\n"
      "  Arch Linux :\n"
      "    sudo pacman -S nodejs npm\n\n"
      "Documentation officielle :\n"
      "  https://nodejs.org/en/download/package-manager\n\n"
      "Note : si « npm install -g » échoue plus tard avec EACCES,\n"
      "configurez npm pour installer en mode utilisateur :\n\n"
      "  mkdir -p ~/.npm-global\n"
      "  npm config set prefix ~/.npm-global\n"
      "  echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc\n"
      "  source ~/.bashrc\n\n"
      "Une fois Node.js installé, revenez à l'Assistant et cliquez sur\n"
      "« Rafraîchir » pour voir les agents IA disponibles à l'installation.")))
   ;; Windows : Scoop si disponible
   ((eq system-type 'windows-nt)
    (if (metal-deps--scoop-present-p)
        (progn
          (metal-deps--journaliser "Installation de Node.js via Scoop")
          (when (yes-or-no-p "Installer Node.js via Scoop (scoop install nodejs) ? ")
            (compile "scoop install nodejs")))
      (metal-deps--afficher-aide
       "Installer Node.js sur Windows"
       (concat
        "Deux options pour installer Node.js sur Windows :\n\n"
        "1. Via Scoop (recommandé, sans admin) :\n"
        "   Installez d'abord Scoop via la section « 📦 Gestionnaires de paquets »\n"
        "   de l'Assistant, puis revenez ici cliquer sur Installer.\n\n"
        "2. Installateur officiel :\n"
        "   https://nodejs.org/en/download/\n\n"
        "Une fois Node.js installé, redémarrez Emacs puis revenez à l'Assistant."))))
   (t (user-error "OS non supporté pour l'installation automatique de Node.js"))))

(defun metal-deps-desinstaller-nodejs ()
  "Désinstalle Node.js + npm selon l'OS.
Avertit que d'autres outils peuvent en dépendre (yarn, Electron, etc.)."
  (interactive)
  (cond
   ((not (metal-deps--nodejs-present-p))
    (message "Node.js n'est pas installé"))
   ;; macOS : >= 14 → brew uninstall ; < 14 → suppression manuelle (.pkg)
   ((eq system-type 'darwin)
    (if (metal-deps--macos-moderne-p)
        ;; macOS moderne : installé via Homebrew
        (if (executable-find "brew")
            (when (yes-or-no-p
                   "Désinstaller Node.js (brew uninstall node) ?  D'autres outils peuvent en dépendre. ")
              (metal-deps--journaliser "Désinstallation Node.js via Homebrew")
              (let ((compilation-buffer-name-function
                     (lambda (_) "*Désinstallation Node.js*")))
                (compile "brew uninstall node")))
          (metal-deps--afficher-aide
           "Désinstaller Node.js"
           (concat
            "Node.js a été installé via Homebrew, mais la commande « brew »\n"
            "est introuvable dans le PATH.  Ouvrez un terminal, assurez-vous\n"
            "que Homebrew est accessible, puis exécutez :\n\n"
            "  brew uninstall node")))
      ;; Intel : installé via l'installeur .pkg → suppression manuelle
      (metal-deps--afficher-aide
       "Désinstaller Node.js"
       (concat
        "Node.js a été installé via l'installeur officiel (.pkg).\n"
        "Apple ne fournit pas de désinstalleur ; supprimez les fichiers\n"
        "installés.  Ouvrez un terminal et exécutez :\n\n"
        "  sudo rm -rf /usr/local/bin/node /usr/local/bin/npm \\\n"
        "    /usr/local/bin/npx /usr/local/include/node \\\n"
        "    /usr/local/lib/node_modules \\\n"
        "    /usr/local/share/man/man1/node.1 \\\n"
        "    /usr/local/share/doc/node\n\n"
        "Vérifiez ensuite que plus rien ne répond :\n"
        "  which node    (ne doit rien afficher)\n\n"
        "Note : d'autres outils (yarn, applications Electron) peuvent\n"
        "dépendre de Node.js."))))
   ;; Linux : instructions manuelles
   ((eq system-type 'gnu/linux)
    (metal-deps--afficher-aide
     "Désinstaller Node.js sur Linux"
     (concat
      "Selon votre gestionnaire de paquets, ouvrez un terminal et exécutez :\n\n"
      "  Debian / Ubuntu / ChromeOS Linux :\n"
      "    sudo apt remove nodejs npm\n\n"
      "  Fedora / RHEL :\n"
      "    sudo dnf remove nodejs npm\n\n"
      "  Arch Linux :\n"
      "    sudo pacman -R nodejs npm\n\n"
      "⚠ Attention : d'autres outils sur votre système peuvent dépendre de\n"
      "Node.js (yarn, certaines applications Electron, etc.).  Vérifiez\n"
      "avant de désinstaller.")))
   ;; Windows : Scoop si utilisé
   ((eq system-type 'windows-nt)
    (if (metal-deps--scoop-present-p)
        (when (yes-or-no-p
               "Désinstaller Node.js (scoop uninstall nodejs) ?  D'autres outils peuvent en dépendre. ")
          (metal-deps--journaliser "Désinstallation Node.js via Scoop")
          (compile "scoop uninstall nodejs"))
      (metal-deps--afficher-aide
       "Désinstaller Node.js sur Windows"
       "Désinstaller via :\n  • Panneau de configuration > Programmes\n  • ou la commande Scoop si vous l'avez utilisée à l'install")))))

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

(defun metal-deps--installer-swipl-dmg ()
  "Télécharge et monte le .dmg universel officiel de SWI-Prolog.
Destiné aux Mac < 14, où Homebrew compilerait depuis la source.  Le
bundle officiel couvre macOS 10.15+ et contient des binaires universels
(Intel + Apple Silicon).  On télécharge la dernière version stable via
l'URL `latest' (le serveur répond par une redirection 303 que `curl -L'
suit), on monte l'image avec `hdiutil', puis on ouvre le volume dans le
Finder : l'étudiant n'a plus qu'à glisser SWI-Prolog.app dans
/Applications.

Note : un .dmg ne s'installe pas via un installeur Apple comme un .pkg ;
le glisser-déposer final reste manuel (norme macOS pour les bundles)."
  (let* ((url "https://www.swi-prolog.org/download/stable/bin/swipl-latest.fat.dmg")
         (dest (expand-file-name "swipl-latest.fat.dmg" "~/Downloads"))
         (buf "*Installation SWI-Prolog*"))
    (metal-deps--journaliser "Installation de SWI-Prolog via .dmg : %s" url)
    (with-current-buffer (get-buffer-create buf)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Téléchargement de SWI-Prolog…\n  %s\n\n" url))
        (insert "Une fenêtre du Finder s'ouvrira à la fin du téléchargement.\n"
                "Glissez « SWI-Prolog.app » dans le dossier « Applications »,\n"
                "puis cliquez « Rafraîchir » dans l'Assistant.\n")))
    (display-buffer buf)
    ;; Télécharge (curl -L suit la redirection 303 « latest »), monte le
    ;; .dmg sans interaction (-nobrowse -accept), puis ouvre le volume.
    ;; `-sS' masque la barre de progression (illisible dans un buffer) tout
    ;; en conservant les erreurs.
    (let* ((cmd (format
                 "curl -fSL -sS -o %s %s && echo TELECHARGE && \
hdiutil attach %s -nobrowse -accept && \
open /Volumes/SWI-Prolog* 2>/dev/null; \
open -R /Volumes/SWI-Prolog*/SWI-Prolog.app 2>/dev/null"
                 (shell-quote-argument dest)
                 (shell-quote-argument url)
                 (shell-quote-argument dest)))
           (proc (start-process-shell-command "metal-swipl-dmg" buf cmd)))
      (set-process-sentinel
       proc
       (lambda (_p event)
         (with-current-buffer (get-buffer-create buf)
           (let ((inhibit-read-only t))
             (goto-char (point-max))
             (if (string-match-p "finished" event)
                 (insert "\n✓ Image montée.  Glissez SWI-Prolog.app dans\n"
                         "  Applications, puis cliquez « Rafraîchir ».\n")
               (insert (format "\n⚠ Problème : %s\n" (string-trim event))
                       "Téléchargez manuellement depuis :\n"
                       "  https://www.swi-prolog.org/download/stable\n"))))
         (run-with-timer 1 nil #'metal-deps-afficher-etat))))))

(defun metal-deps-installer-swi-prolog ()
  "Installe SWI-Prolog.
- macOS >= 14 : Homebrew (bottle, rapide)
- macOS < 14  : .dmg universel officiel (évite la compilation Homebrew
                depuis la source, faute de bottle)"
  (interactive)
  (if (metal-deps--swipl-present-p)
      (message "✓ SWI-Prolog déjà installé")
    (metal-deps--journaliser "Installation de SWI-Prolog")
    (pcase system-type
      ('darwin
       (if (metal-deps--macos-moderne-p)
           (if (metal-deps--brew-present-p)
               (async-shell-command "brew install swi-prolog" "*SWI-Prolog Install*")
             (browse-url "https://www.swi-prolog.org/download/stable")
             (message "Installez d'abord Homebrew, ou téléchargez depuis le site"))
         ;; macOS < 14 : installeur officiel (.dmg universel)
         (when (yes-or-no-p
                "Installer SWI-Prolog via l'installeur officiel (.dmg) ? ")
           (metal-deps--installer-swipl-dmg))))
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
         (cond
          ;; Bundle officiel (.dmg) dans /Applications
          ((file-directory-p "/Applications/SWI-Prolog.app")
           (when (yes-or-no-p
                  "Supprimer /Applications/SWI-Prolog.app ? ")
             (delete-directory "/Applications/SWI-Prolog.app" t)
             (message "✓ SWI-Prolog.app supprimé")))
          ;; Installé via Homebrew
          ((and (metal-deps--brew-present-p)
                (= 0 (call-process "brew" nil nil nil "list" "swi-prolog")))
           (async-shell-command "brew uninstall swi-prolog" "*SWI-Prolog Uninstall*"))
          (t
           (message "SWI-Prolog installé à l'extérieur de MetalEmacs. Désinstallez manuellement."))))
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

(defcustom metal-deps-ghostscript-pkg-url
  "https://pages.uoregon.edu/koch/Ghostscript-10.07.0.pkg"
  "URL du .pkg Ghostscript autonome pour macOS (binaires universels).
Maintenu par Richard Koch (mainteneur de MacTeX) ; indépendant de
Homebrew, il installe `gs' dans /usr/local/bin et fonctionne sur
macOS Big Sur (11) et ultérieur — donc sur les Mac < 14 où Homebrew
est en Tier 3 et compilerait depuis la source.

Ces URLs sont versionnées (pas de lien « latest ») : si elle devient
obsolète, l'installateur ouvre la page de téléchargement dans le
navigateur.  Mettre à jour la version ici au besoin (voir
https://pages.uoregon.edu/koch/)."
  :type 'string
  :group 'metal-deps)

(defun metal-deps--installer-ghostscript-pkg ()
  "Télécharge et ouvre le .pkg Ghostscript autonome (macOS < 14).
Évite Homebrew (Tier 3 sur ces systèmes).  En cas d'échec du
téléchargement (URL périmée, réseau), ouvre la page de Koch dans le
navigateur pour un téléchargement manuel."
  (let* ((url metal-deps-ghostscript-pkg-url)
         (dest (expand-file-name (file-name-nondirectory url) "~/Downloads"))
         (buf "*Installation Ghostscript*"))
    (metal-deps--journaliser "Installation de Ghostscript via .pkg : %s" url)
    (with-current-buffer (get-buffer-create buf)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Téléchargement de Ghostscript…\n  %s\n\n" url))
        (insert "L'installeur Apple s'ouvrira automatiquement à la fin.\n"
                "Suivez les étapes, puis cliquez « Rafraîchir » dans l'Assistant.\n")))
    (display-buffer buf)
    (let* ((cmd (format
                 "curl -fSL -sS -o %s %s && echo TELECHARGE && open %s"
                 (shell-quote-argument dest)
                 (shell-quote-argument url)
                 (shell-quote-argument dest)))
           (proc (start-process-shell-command "metal-gs-pkg" buf cmd)))
      (set-process-sentinel
       proc
       (lambda (_p event)
         (with-current-buffer (get-buffer-create buf)
           (let ((inhibit-read-only t))
             (goto-char (point-max))
             (if (string-match-p "finished" event)
                 (insert "\n✓ Installeur ouvert.  Terminez l'installation,\n"
                         "  puis cliquez « Rafraîchir ».\n")
               (insert (format "\n⚠ Téléchargement impossible : %s\n" (string-trim event))
                       "Ouverture de la page de téléchargement…\n")
               (browse-url "https://pages.uoregon.edu/koch/"))))
         (run-with-timer 1 nil #'metal-deps-afficher-etat))))))

(defun metal-deps-installer-ghostscript ()
  "Installe Ghostscript (gs), moteur de rendu de `doc-view'.
Sur les Mac < 14, MetalEmacs n'offre pas pdf-tools et affiche les PDF
avec `doc-view', qui a besoin de `gs' pour convertir les pages en
images.  Sans Ghostscript, doc-view ne montre que le source brut.

- macOS < 14 : .pkg autonome officiel (Homebrew est Tier 3 et
               compilerait depuis la source)
- macOS >= 14 : Homebrew (bottle)
- Linux/Windows : gestionnaire système"
  (interactive)
  (if (metal-deps--ghostscript-present-p)
      (message "✓ Ghostscript déjà installé")
    (metal-deps--journaliser "Installation de Ghostscript")
    (pcase system-type
      ('darwin
       (if (metal-deps--macos-moderne-p)
           (if (metal-deps--brew-present-p)
               (async-shell-command "brew install ghostscript" "*Ghostscript Install*")
             (message "Installez d'abord Homebrew"))
         ;; macOS < 14 : installeur .pkg autonome
         (when (yes-or-no-p
                "Installer Ghostscript via l'installeur officiel (.pkg) ? ")
           (metal-deps--installer-ghostscript-pkg))))
      ('windows-nt
       (if (metal-deps--scoop-present-p)
           (async-shell-command "scoop install ghostscript" "*Ghostscript Install*")
         (message "⚠ Scoop requis. Lancez d'abord M-x metal-deps-installer-scoop")))
      ('gnu/linux
       (if (metal-deps--apt-present-p)
           (async-shell-command "sudo apt install -y ghostscript" "*Ghostscript Install*")
         (message "Installez ghostscript avec votre gestionnaire de paquets"))))))

(defun metal-deps-desinstaller-ghostscript ()
  "Désinstalle Ghostscript."
  (interactive)
  (if (not (metal-deps--ghostscript-present-p))
      (message "Ghostscript n'est pas installé")
    (when (yes-or-no-p "Voulez-vous vraiment désinstaller Ghostscript ? ")
      (metal-deps--journaliser "Désinstallation de Ghostscript")
      (pcase system-type
        ('darwin
         (cond
          ;; Installé via Homebrew (Mac >= 14)
          ((and (metal-deps--brew-present-p)
                (= 0 (call-process "brew" nil nil nil "list" "ghostscript")))
           (async-shell-command "brew uninstall ghostscript" "*Ghostscript Uninstall*"))
          ;; Installé via le .pkg autonome : binaires dans /usr/local/bin.
          ;; La suppression nécessite root ; on guide plutôt que de tenter
          ;; un rm -rf silencieux sur /usr/local.
          ((file-executable-p "/usr/local/bin/gs")
           (metal-deps--afficher-aide
            "Désinstaller Ghostscript (.pkg)"
            (concat
             "Ghostscript a été installé via l'installeur .pkg autonome.\n"
             "Pour le retirer, ouvrez un terminal et exécutez :\n\n"
             "  sudo rm -f /usr/local/bin/gs /usr/local/bin/gs-noX11 \\\n"
             "    /usr/local/bin/gs-X11\n"
             "  sudo rm -rf /usr/local/share/ghostscript\n\n"
             "(Les binaires appartiennent à root : sudo est requis.)")))
          (t
           (message "Ghostscript installé à l'extérieur de MetalEmacs. Désinstallez manuellement."))))
        ('windows-nt
         (if (metal-deps--scoop-present-p)
             (async-shell-command "scoop uninstall ghostscript" "*Ghostscript Uninstall*")
           (message "Ghostscript installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))
        ('gnu/linux
         (if (= 0 (call-process "dpkg" nil nil nil "-s" "ghostscript"))
             (async-shell-command "sudo apt remove ghostscript -y" "*Ghostscript Uninstall*")
           (message "Ghostscript installé à l'extérieur de MetalEmacs. Désinstallez manuellement.")))))))

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
  
  ;; ;; Configurer les variables d'environnement pour la compilation sur macOS
  ;; (when (eq system-type 'darwin)
  ;;   (setenv "PKG_CONFIG_PATH" "/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig")
  ;;   (setenv "ACLOCAL_PATH" "/opt/homebrew/share/aclocal"))

  ;; Configurer les variables d'environnement pour la compilation sur macOS
  (when (eq system-type 'darwin)
    (let* ((brew (metal-deps--chemin-brew))
           (prefix (cond
                    ((and brew (string-prefix-p "/opt/" brew)) "/opt/homebrew")
                    (brew "/usr/local")
                    (t "/opt/homebrew")))
           ;; Sur macOS Tahoe arm64, poppler 26+ tire gpgmepp qui dépend
           ;; transitivement de libgpg-error. Or libgpg-error est keg-only
           ;; chez brew : son gpg-error.pc n'est PAS dans le PKG_CONFIG_PATH
           ;; par défaut. Sans ce chemin, autoconf échoue avec
           ;; « Package 'gpg-error', required by 'gpgmepp', not found ».
           (pkg-paths (list (format "%s/opt/libgpg-error/lib/pkgconfig" prefix)
                            (format "%s/lib/pkgconfig" prefix)
                            (format "%s/share/pkgconfig" prefix)
                            (getenv "PKG_CONFIG_PATH"))))
      (setenv "PKG_CONFIG_PATH"
              (mapconcat #'identity
                         (delq nil (delete "" pkg-paths))
                         ":"))
      (setenv "ACLOCAL_PATH" (format "%s/share/aclocal" prefix))))
  
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
;;; Agents IA — Catalogue et gestion
;;; ═══════════════════════════════════════════════════════════════════

;; Déclarations pour satisfaire le byte-compiler (metal-agent.el peut ne
;; pas être chargé au moment où ce fichier est byte-compilé).
(defvar metal-agent-providers)
(defvar metal-agent-provider)
(declare-function metal-agent-authentifier-cli "metal-agent" (&optional id force))

(defvar metal-deps-agents-catalogue
  '((gemini
     :nom         "Gemini"
     :description "Gratuit avec compte Google"
     :gratuit     t
     :paquet-npm  "@google/gemini-cli"
     :commande    "gemini"
     :couleur     "#4285F4"
     :format      claude-style
     :args        nil
     ;; :args ("-p" "") ;; si un problème avec nil
     :auth-args   nil
     :auth-aide   "Choisissez la méthode d'authentification dans le menu (1, 2 ou 3), puis appuyez sur Entrée.  Quand l'authentification est terminée, fermez ce buffer (C-x k)."
     :auth-fichiers ("~/.gemini/oauth_creds.json")
     :auth-env    ("GEMINI_API_KEY" "GOOGLE_GENAI_USE_VERTEXAI" "GOOGLE_GENAI_USE_GCA"))
    (codex
     :nom         "ChatGPT"
     :description "Gratuit avec ChatGPT Free ou abonnement Plus/Pro"
     :gratuit     t
     :paquet-npm  "@openai/codex"
     :paquet-brew "codex"
     :commande    "codex"
     :couleur     "#10A37F"
     :format      codex-style
     :args        ("exec" "--sandbox" "read-only" "--skip-git-repo-check")
     :auth-args   ("login")
     :auth-aide   "Choisissez « Sign in with ChatGPT » (OAuth via navigateur) — fonctionne avec ChatGPT Free.  Ou « Sign in with API key » pour une clé OpenAI.  Une fois connecté, fermez ce buffer (C-x k)."
     :auth-fichiers ("~/.codex/auth.json" "~/.codex/config.toml"))
    (claude
     :nom         "Claude"
     :description "Avec abonnement Claude Pro/Max ou clé API"
     :gratuit     nil
     :paquet-npm  "@anthropic-ai/claude-code"
     :paquet-brew "claude-code"
     :commande    "claude"
     :couleur     "#D97757"
     :format      claude-style
     :args ("-p" "--output-format" "text")
     :via-process t    
     :auth-args   ("auth" "login")
     :auth-aide   "Le navigateur va s'ouvrir pour l'OAuth Anthropic.  Si rien ne s'ouvre, appuyez sur « c » pour copier l'URL et collez-la dans votre navigateur.  Revenez ici après autorisation, puis fermez le buffer (C-x k)."
     :auth-fichiers ("~/.claude/.credentials.json")
     :auth-verifier metal-deps--claude-authentifie-p))
  "Catalogue des agents IA installables via l'Assistant MetalEmacs.
Chaque entrée est (ID . PLIST) où PLIST contient :
  :nom          Nom affiché.
  :description  Description courte.
  :gratuit      Indication de coût/conditions :
                t                → suffixe \"(gratuit)\"
                \"texte libre\"    → suffixe \"(texte libre)\"
                nil              → pas de suffixe (abonnement payant requis)
  :paquet-npm   Nom du paquet npm (ex: \"@google/gemini-cli\").
  :paquet-brew  Nom du paquet brew (optionnel).
  :paquet-pipx  Nom du paquet pipx/pip (optionnel).
  :commande     Commande CLI invoquée.
  :couleur      Couleur hex de l'icône robot dans la toolbar.
  :format       `codex-style' (filtre prompt) ou `claude-style' (générique).
  :args         Arguments par défaut pour proposer sans modifier.
  :auth-args    Arguments à ajouter à la commande pour lancer l'auth
                explicite (ex: (\"login\")).  nil = lancer la commande seule.
  :auth-aide    Instructions affichées en header-line du buffer terminal.
  :auth-fichiers  Liste de chemins (un seul présent suffit) qui indiquent
                  que l'agent est authentifié.  Doit inclure les paths
                  des 3 OS : Linux (~/.config, ~/.local/share),
                  macOS (~/Library/Application Support),
                  Windows (~/AppData/Roaming, ~/AppData/Local).
  :auth-env       Liste de variables d'environnement (une seule définie
                  suffit) qui indiquent que l'agent est authentifié.
  :auth-verifier  Fonction custom (sans argument) qui retourne t si
                  l'agent est authentifié.  Priorité sur :auth-fichiers
                  et :auth-env.
  :install-manuelle  Optionnel : alist ((SYSTEM-TYPE . INSTRUCTIONS) …)
                     d'instructions textuelles à afficher quand aucun
                     gestionnaire automatique ne peut installer l'agent
                     sur l'OS courant.  Clés possibles : windows-nt,
                     darwin, gnu/linux, ou t (fallback générique).")

(defun metal-deps--claude-authentifie-p ()
  "Détection multi-OS pour Claude : fichier credentials OU keychain natif.

- Linux/Windows : présence de ~/.claude/.credentials.json
- macOS         : entrée « Claude Code-credentials » dans le Keychain
- Linux moderne : entrée correspondante dans Secret Service (libsecret)
- Windows       : entrée dans le Credential Manager (via cmdkey)"
  (or (file-exists-p (expand-file-name "~/.claude/.credentials.json"))
      ;; macOS Keychain
      (and (eq system-type 'darwin)
           (executable-find "security")
           (zerop (call-process
                   "security" nil nil nil
                   "find-generic-password" "-s" "Claude Code-credentials")))
      ;; Linux Secret Service (GNOME Keyring, KWallet via libsecret).
      (and (memq system-type '(gnu/linux gnu))
           (executable-find "secret-tool")
           (zerop (call-process
                   "secret-tool" nil nil nil
                   "search" "service" "Claude Code-credentials")))
      ;; Windows Credential Manager.
      (and (eq system-type 'windows-nt)
           (executable-find "cmdkey")
           (with-temp-buffer
             (call-process "cmdkey" nil t nil "/list")
             (goto-char (point-min))
             (re-search-forward "Claude Code-credentials" nil t)))))

(defun metal-deps--agent-authentifie-p (spec)
  "Retourne t si l'agent défini par SPEC semble authentifié.
Vérifie dans l'ordre :
  1. La fonction :auth-verifier (si définie).
  2. Au moins un des :auth-fichiers existe.
  3. Au moins une des :auth-env est définie et non vide."
  (let ((verifier  (plist-get spec :auth-verifier))
        (fichiers  (plist-get spec :auth-fichiers))
        (env-vars  (plist-get spec :auth-env)))
    (or (and verifier
             (functionp verifier)
             (ignore-errors (funcall verifier)))
        (cl-some (lambda (f) (file-exists-p (expand-file-name f))) fichiers)
        (cl-some (lambda (v) (let ((val (getenv v)))
                               (and val (not (string-empty-p val)))))
                 env-vars))))

(defun metal-deps--quote-safe (s)
  "Quote S pour le shell sans backslasher inutilement (cf. `@google/x')."
  (if (string-match-p "\\`[A-Za-z0-9@/._+-]+\\'" s)
      s
    (shell-quote-argument s)))

(defun metal-deps--agent-cli-installee-p (agent-spec)
  "Retourne le chemin de la CLI si elle est installée, sinon nil.
AGENT-SPEC est le PLIST (sans le ID) du catalogue."
  (executable-find (plist-get agent-spec :commande)))

(defun metal-deps--agent-enregistre-p (id)
  "Retourne t si l'agent ID est dans `metal-agent-providers'."
  (and (boundp 'metal-agent-providers)
       (assq id metal-agent-providers)))

(defun metal-deps--agent-complet-p (id agent-spec)
  "Retourne t si l'agent ID est enregistré ET sa CLI est installée."
  (and (metal-deps--agent-enregistre-p id)
       (metal-deps--agent-cli-installee-p agent-spec)))

(defun metal-deps--agent-spec->provider-entry (id spec)
  "Convertit une entrée du catalogue en entrée pour `metal-agent-providers'."
  (cons id
        (list :label       (plist-get spec :nom)
              :color       (plist-get spec :couleur)
              :command     (plist-get spec :commande)
              :args        (plist-get spec :args)
              :buffer-name (format "*Metal %s*" (plist-get spec :nom))
              :format      (plist-get spec :format)
              :auth-args   (plist-get spec :auth-args)
              :auth-aide   (plist-get spec :auth-aide))))

(defun metal-deps--assurer-npm-prefix-user ()
  "Configure npm pour installer en mode utilisateur (~/.npm-global).
Évite les erreurs EACCES sur Linux où `npm install -g' essaie sinon
d'écrire dans /usr/local/lib/node_modules (root requis).

Fonction idempotente — sûre à appeler plusieurs fois.  N'agit que sur
Linux ; sur macOS (npm via Homebrew) et Windows (Scoop), les permissions
sont déjà OK par défaut.

Modifications :
1. Crée ~/.npm-global si nécessaire
2. Configure « npm config set prefix » vers ce dossier
3. Ajoute ~/.npm-global/bin à `exec-path' et `PATH' pour la session
4. Ajoute la ligne export PATH=... à ~/.bashrc et ~/.zshrc si absente"
  (when (and (eq system-type 'gnu/linux)
             (executable-find "npm"))
    (let* ((prefix (expand-file-name "~/.npm-global"))
           (bin (expand-file-name "bin" prefix))
           (prefix-actuel
            (string-trim
             (shell-command-to-string "npm config get prefix 2>/dev/null"))))
      ;; 1) Créer le dossier si nécessaire
      (unless (file-directory-p prefix)
        (make-directory prefix t))
      ;; 2) Configurer npm si pas déjà fait
      (unless (string= prefix-actuel prefix)
        (call-process "npm" nil nil nil "config" "set" "prefix" prefix)
        (metal-deps--journaliser
         "npm configuré pour utiliser ~/.npm-global (évite EACCES sur npm install -g)"))
      ;; 3) Ajouter bin à exec-path et PATH pour la session courante
      (add-to-list 'exec-path bin)
      (let ((path-env (or (getenv "PATH") "")))
        (unless (string-match-p (regexp-quote bin) path-env)
          (setenv "PATH" (concat bin path-separator path-env))))
      ;; 4) Persister dans les shell rc files si présents
      (dolist (rc '("~/.bashrc" "~/.zshrc" "~/.profile"))
        (let ((rc-path (expand-file-name rc)))
          (when (file-exists-p rc-path)
            (with-temp-buffer
              (insert-file-contents rc-path)
              (goto-char (point-min))
              (unless (search-forward "npm-global/bin" nil t)
                (goto-char (point-max))
                (unless (bolp) (insert "\n"))
                (insert "\n# Added by MetalEmacs Assistant for npm user prefix\n"
                        "export PATH=\"$HOME/.npm-global/bin:$PATH\"\n")
                (let ((inhibit-message t))
                  (write-region (point-min) (point-max) rc-path nil 'quiet))
                (metal-deps--journaliser
                 "PATH npm-global ajouté à %s" rc)))))))))

(defun metal-deps--commande-installation-cli (agent-spec)
  "Retourne (PROG ARGS… PAQUET) pour installer la CLI de AGENT-SPEC.
Priorité : pipx > npm > brew.  Sur Linux, configure aussi le prefix
npm en mode utilisateur pour éviter les erreurs EACCES."
  (cond
   ((and (plist-get agent-spec :paquet-pipx) (executable-find "pipx"))
    (list "pipx" "install" (plist-get agent-spec :paquet-pipx)))
   ((and (plist-get agent-spec :paquet-pipx) (executable-find "pip"))
    (list "pip" "install" "--user" (plist-get agent-spec :paquet-pipx)))
   ((and (plist-get agent-spec :paquet-npm) (executable-find "npm"))
    ;; Configurer le prefix user sur Linux avant tout npm install -g.
    (metal-deps--assurer-npm-prefix-user)
    (list "npm" "install" "-g" (plist-get agent-spec :paquet-npm)))
   ((and (plist-get agent-spec :paquet-brew) (executable-find "brew"))
    (list "brew" "install" (plist-get agent-spec :paquet-brew)))
   (t nil)))

(defun metal-deps--commande-desinstallation-cli (agent-spec)
  "Retourne (PROG ARGS… PAQUET) pour désinstaller la CLI de AGENT-SPEC."
  (cond
   ((and (plist-get agent-spec :paquet-pipx) (executable-find "pipx"))
    (list "pipx" "uninstall" (plist-get agent-spec :paquet-pipx)))
   ((and (plist-get agent-spec :paquet-pipx) (executable-find "pip"))
    (list "pip" "uninstall" "-y" (plist-get agent-spec :paquet-pipx)))
   ((and (plist-get agent-spec :paquet-npm) (executable-find "npm"))
    ;; Même prefix user qu'à l'install pour que npm trouve le paquet.
    (metal-deps--assurer-npm-prefix-user)
    (list "npm" "uninstall" "-g" (plist-get agent-spec :paquet-npm)))
   ((and (plist-get agent-spec :paquet-brew) (executable-find "brew"))
    (list "brew" "uninstall" (plist-get agent-spec :paquet-brew)))
   (t nil)))

(defun metal-deps--install-manuelle-pour (spec)
  "Retourne le texte d'instructions d'installation manuelle pour SPEC.
Cherche d'abord une entrée pour `system-type', sinon une entrée
fallback `t', sinon nil."
  (let ((manuelle (plist-get spec :install-manuelle)))
    (or (cdr (assq system-type manuelle))
        (cdr (assq t           manuelle)))))

(defun metal-deps--gestionnaires-suggeres (agent-spec)
  "Retourne une liste textuelle des gestionnaires que AGENT-SPEC pourrait
utiliser, mais qui ne sont pas installés sur le système.  Ex:
\\='(\"npm (Node.js)\" \"brew (Homebrew)\")'."
  (delq nil
        (list (and (plist-get agent-spec :paquet-npm)
                   (not (executable-find "npm"))
                   "npm (installer Node.js)")
              (and (plist-get agent-spec :paquet-pipx)
                   (not (executable-find "pipx"))
                   (not (executable-find "pip"))
                   "pipx ou pip (installer Python)")
              (and (plist-get agent-spec :paquet-brew)
                   (not (executable-find "brew"))
                   (memq system-type '(darwin gnu/linux))
                   "brew (Homebrew)"))))

(defun metal-deps--afficher-aide (titre corps)
  "Affiche un buffer d'aide en help-mode avec TITRE et CORPS.
Les URL dans CORPS deviennent cliquables via `goto-address-mode'."
  (let* ((buf-name (format "*MetalEmacs — %s*" titre))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s\n" titre)
                            'face '(:weight bold :height 1.2)))
        (insert (make-string 60 ?─) "\n\n")
        (insert corps)
        (insert "\n\nFermez ce buffer avec C-x k quand terminé.\n"))
      (goto-char (point-min))
      (help-mode)
      (when (fboundp 'goto-address-mode)
        (goto-address-mode 1))
      (setq buffer-read-only t))
    (display-buffer buf)))

(defun metal-deps--afficher-aide-install (nom corps)
  "Affiche un buffer d'aide à l'installation manuelle.
NOM est le nom de l'agent ; CORPS est le texte des instructions."
  (metal-deps--afficher-aide (format "Installation manuelle — %s" nom) corps))

(defun metal-deps--afficher-procedure-auth (id)
  "Affiche la procédure d'authentification pour l'agent ID.
Utilisé quand la CLI n'est pas installée (impossible de lancer l'auth
en terminal) — pointe l'utilisateur vers l'installation puis détaille
la procédure d'auth pour référence future."
  (let* ((spec (cdr (assq id metal-deps-agents-catalogue)))
         (nom (plist-get spec :nom))
         (aide (plist-get spec :auth-aide)))
    (unless spec
      (user-error "Agent inconnu : %s" id))
    (metal-deps--afficher-aide
     (format "Procédure d'authentification — %s" nom)
     (concat
      "Pour utiliser cet agent, il faut deux étapes :\n\n"
      "  1. Installer la CLI\n"
      "     Cliquez sur le bouton [Installer] de cet agent dans l'Assistant.\n\n"
      "  2. Authentifier la CLI\n"
      (or aide "     Suivez les instructions de la documentation de l'agent.")
      "\n\nUne fois la CLI installée (statut ✓), cliquez sur « authentifier »\n"
      "dans cette section pour lancer le flux d'authentification dans un terminal."))))

(defun metal-deps--installer-agent-ia (id)
  "Installe l'agent ID : enregistre dans `metal-agent-providers' + installe CLI.

Si aucun gestionnaire automatique n'est disponible pour l'OS courant,
affiche un buffer d'aide avec les instructions manuelles (champ
`:install-manuelle' du catalogue) plutôt que de lever une erreur sèche."
  (let* ((spec (cdr (assq id metal-deps-agents-catalogue))))
    (unless spec
      (user-error "Agent inconnu dans le catalogue : %s" id))
    ;; 1) Enregistrer dans metal-agent-providers (persisté via Custom).
    (unless (boundp 'metal-agent-providers)
      (require 'metal-agent nil t))
    (unless (metal-deps--agent-enregistre-p id)
      (customize-save-variable
       'metal-agent-providers
       (append (and (boundp 'metal-agent-providers) metal-agent-providers)
               (list (metal-deps--agent-spec->provider-entry id spec))))
      (metal-deps--journaliser "Agent « %s » enregistré dans metal-agent-providers"
                               (plist-get spec :nom)))
    ;; 2) Installer la CLI si absente.
    (cond
     ((metal-deps--agent-cli-installee-p spec)
      (message "Agent « %s » : déjà configuré et CLI déjà installée."
               (plist-get spec :nom)))
     (t
      (let ((cmd (metal-deps--commande-installation-cli spec)))
        (cond
         ;; Cas 1 : un gestionnaire automatique est disponible → lancer compile.
         (cmd
          (let* ((cmdline (mapconcat #'metal-deps--quote-safe cmd " "))
                 (compilation-buffer-name-function
                  (lambda (_) (format "*Installation %s*" (plist-get spec :nom)))))
            (when (yes-or-no-p
                   (format "Installer « %s » via %s ?  Commande : %s "
                           (plist-get spec :nom) (car cmd) cmdline))
              (metal-deps--journaliser "Installation CLI : %s" cmdline)
              (let ((buf (compile cmdline)))
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (when (fboundp 'ansi-color-compilation-filter)
                      (add-hook 'compilation-filter-hook
                                'ansi-color-compilation-filter nil t)))))
              (message
               "Installation lancée.  Une fois terminée, utiliser le bouton « Authentifier » ou « M-x metal-agent-authentifier-cli »."))))
         ;; Cas 2 : pas de gestionnaire mais des instructions manuelles.
         ((metal-deps--install-manuelle-pour spec)
          (metal-deps--afficher-aide-install
           (plist-get spec :nom)
           (metal-deps--install-manuelle-pour spec)))
         ;; Cas 3 : pas de gestionnaire et pas d'instructions.
         ;; Si l'agent a besoin de npm et que Node.js n'est pas installé,
         ;; proposer directement de l'installer (au lieu d'un buffer
         ;; d'aide qui force l'utilisateur à scroller chercher Node.js).
         ((and (plist-get spec :paquet-npm)
               (not (metal-deps--nodejs-present-p)))
          (if (yes-or-no-p
               (format "« %s » nécessite Node.js (npm), qui n'est pas installé.  L'installer maintenant ? "
                       (plist-get spec :nom)))
              (progn
                (metal-deps--journaliser
                 "Install agent « %s » bloquée : Node.js manquant — lancement de l'installation Node.js"
                 (plist-get spec :nom))
                (metal-deps-installer-nodejs)
                (message
                 "Node.js : installation en cours/instructions affichées.  Une fois terminée, cliquez à nouveau sur « Installer » pour %s."
                 (plist-get spec :nom)))
            (message "Installation de « %s » annulée."
                     (plist-get spec :nom))))
         ;; Sinon : afficher un message générique pointant vers
         ;; les prérequis manquants (pipx, brew…).
         (t
          (let ((manquants (metal-deps--gestionnaires-suggeres spec)))
            (metal-deps--afficher-aide-install
             (plist-get spec :nom)
             (concat
              "Aucun gestionnaire de paquets reconnu n'est installé sur ce système.\n\n"
              "Pour installer « " (plist-get spec :nom) " », vous avez besoin de l'un de :\n"
              (mapconcat (lambda (g) (concat "  • " g)) manquants "\n")
              "\n\nInstallez d'abord l'un de ces prérequis depuis la section "
              "« 📦 Gestionnaires de paquets » de l'Assistant, puis cliquez à "
              "nouveau sur « Installer » pour cet agent.")))))))))) 

(defun metal-deps--desinstaller-agent-ia (id)
  "Désinstalle l'agent ID : retire de `metal-agent-providers' + désinstalle CLI."
  (let* ((spec (cdr (assq id metal-deps-agents-catalogue)))
         (nom  (plist-get spec :nom)))
    (unless spec
      (user-error "Agent inconnu dans le catalogue : %s" id))
    (when (yes-or-no-p (format "Désinstaller complètement « %s » (registre + CLI) ? " nom))
      ;; 1) Désenregistrer.
      (when (metal-deps--agent-enregistre-p id)
        (customize-save-variable
         'metal-agent-providers
         (assq-delete-all id (and (boundp 'metal-agent-providers)
                                  metal-agent-providers)))
        ;; Si c'était l'agent actif, on bascule sur un autre disponible (ou nil).
        (when (and (boundp 'metal-agent-provider)
                   (eq metal-agent-provider id))
          (customize-save-variable
           'metal-agent-provider
           (car-safe (car-safe metal-agent-providers))))
        (metal-deps--journaliser "Agent « %s » retiré de metal-agent-providers" nom))
      ;; 2) Désinstaller la CLI si présente.
      (when (metal-deps--agent-cli-installee-p spec)
        (let ((cmd (metal-deps--commande-desinstallation-cli spec)))
          (when cmd
            (let* ((cmdline (mapconcat #'metal-deps--quote-safe cmd " "))
                   (compilation-buffer-name-function
                    (lambda (_) (format "*Désinstallation %s*" nom))))
              (metal-deps--journaliser "Désinstallation CLI : %s" cmdline)
              (compile cmdline)))))
      (message "« %s » désinstallé." nom))))

(defun metal-deps--authentifier-agent-ia (id)
  "Lance l'authentification interactive pour l'agent ID."
  (let ((spec (cdr (assq id metal-deps-agents-catalogue))))
    (unless (metal-deps--agent-cli-installee-p spec)
      (user-error "CLI de « %s » introuvable — installer d'abord" (plist-get spec :nom)))
    (require 'metal-agent nil t)
    (if (fboundp 'metal-agent-authentifier-cli)
        (metal-agent-authentifier-cli id)
      (user-error "metal-agent.el n'est pas chargé"))))

(defun metal-deps--agent-catalogue->outil (entry)
  "Convertit une entrée du catalogue en outil pour `metal-deps-outils'.
Le statut « installé » signifie : enregistré dans `metal-agent-providers'
ET CLI présente sur le système."
  (let* ((id (car entry))
         (spec (cdr entry))
         (nom (plist-get spec :nom))
         (desc (plist-get spec :description)))
    (list :nom nom
          :verifier      (lambda () (metal-deps--agent-complet-p id spec))
          :installer     (lambda () (metal-deps--installer-agent-ia id))
          :desinstaller  (lambda () (metal-deps--desinstaller-agent-ia id))
          :categorie     'agents-ia
          :description   desc
          :agent-id      id)))

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
     :macos-seulement t)
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
    ;; Node.js / npm : prérequis multi-OS pour les agents IA (Claude,
    ;; ChatGPT, Gemini installés via npm install -g).  Sur Linux il faut
    ;; sudo donc on affiche les commandes ; macOS via brew ; Windows via Scoop.
    (:nom "Node.js (npm)"
     :verifier metal-deps--nodejs-present-p
     :installer metal-deps-installer-nodejs
     :desinstaller metal-deps-desinstaller-nodejs
     :categorie gestionnaire
     :description "Requis pour Claude, ChatGPT et Gemini")
    
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
     :description "Recherche multi-fichiers (C-c g)"
     :condition (lambda () (or (not (eq system-type 'darwin))
                               (metal-deps--macos-moderne-p))))
    
    ;; PDF.  Poppler + pdf-tools nécessitent une compilation native
    ;; (epdfinfo).  Sur macOS, on ne les propose qu'à partir du seuil
    ;; « moderne » (>= 14) où Homebrew fournit des bottles fiables (Intel
    ;; comme Apple Silicon) : sous ce seuil la compilation depuis la source
    ;; est lente et fragile, et MetalEmacs se rabat sur le visionneur PDF
    ;; intégré `doc-view'.  Hors macOS, le seuil ne s'applique pas.
    (:nom "Poppler" 
     :verifier metal-deps--poppler-present-p
     :installer metal-deps-installer-poppler 
     :desinstaller metal-deps-desinstaller-poppler
     :categorie pdf
     :condition (lambda () (and (not (eq system-type 'windows-nt))
                                (or (not (eq system-type 'darwin))
                                    (metal-deps--macos-moderne-p)))))
    (:nom "pdf-tools" 
     :verifier metal-deps--epdfinfo-present-p
     :installer metal-deps-installer-pdf-tools 
     :desinstaller metal-deps-desinstaller-pdf-tools
     :categorie pdf
     :condition (lambda () (and (not (eq system-type 'windows-nt))
                                (or (not (eq system-type 'darwin))
                                    (metal-deps--macos-moderne-p)))))
    ;; Ghostscript : moteur de rendu de `doc-view'.  Proposé seulement là où
    ;; doc-view est le visionneur de repli, c.-à-d. sur les Mac < 14 (où
    ;; pdf-tools n'est pas offert).  Sans lui, doc-view affiche le PDF en
    ;; texte brut au lieu de rendre les pages.
    (:nom "Ghostscript"
     :verifier metal-deps--ghostscript-present-p
     :installer metal-deps-installer-ghostscript
     :desinstaller metal-deps-desinstaller-ghostscript
     :categorie pdf
     :description "Rendu PDF pour doc-view (Mac < 14)"
     :condition (lambda () (and (eq system-type 'darwin)
                                (not (metal-deps--macos-moderne-p))))))
  "Liste des outils gérés par MetalEmacs.")

;; Les outils-agents sont calculés dynamiquement à chaque accès (et non
;; figés au chargement) parce que `metal-agent-providers' peut contenir
;; des agents personnalisés ajoutés par l'utilisateur après le démarrage.

(defun metal-deps--outil-agent-personnalise (provider-entry)
  "Convertit une entrée perso de `metal-agent-providers' en outil.
Un agent perso n'est pas dans le catalogue : pas d'installation auto,
pas de détection d'auth — l'utilisateur a fourni les détails à la main."
  (let* ((id      (car provider-entry))
         (spec    (cdr provider-entry))
         (nom     (or (plist-get spec :label) (symbol-name id)))
         (commande (plist-get spec :command)))
    (list :nom nom
          :verifier      (lambda () (and commande (executable-find commande)))
          :installer     nil
          :desinstaller  (lambda () (metal-deps--retirer-agent-personnalise id))
          :categorie     'agents-ia
          :description   "Agent personnalisé"
          :agent-id      id
          :agent-perso   t)))

(defun metal-deps--definir-agent-defaut (id)
  "Définit l'agent ID comme défaut persistant (via Custom).
Aussi appliqué immédiatement à la session courante."
  (require 'metal-agent nil t)
  (customize-save-variable 'metal-agent-provider id)
  (let* ((spec (cdr (assq id metal-deps-agents-catalogue)))
         (label (or (plist-get spec :nom)
                    (and (boundp 'metal-agent-providers)
                         (plist-get (cdr (assq id metal-agent-providers))
                                    :label))
                    (symbol-name id))))
    (metal-deps--journaliser "Agent par défaut défini : %s (%s)" label id)
    (message "Agent par défaut : %s (sauvegardé)" label))
  (when (fboundp 'force-mode-line-update)
    (force-mode-line-update t))
  (metal-deps-afficher-etat))

(defun metal-deps--retirer-agent-personnalise (id)
  "Retire l'agent personnalisé ID de `metal-agent-providers'.
Ne désinstalle PAS la CLI : l'utilisateur l'a installée à la main,
c'est à lui de la gérer."
  (let* ((spec (and (boundp 'metal-agent-providers)
                    (cdr (assq id metal-agent-providers))))
         (nom (or (plist-get spec :label) (symbol-name id))))
    (when (yes-or-no-p
           (format "Retirer l'agent « %s » de la liste ?  (La CLI ne sera pas désinstallée.) "
                   nom))
      (customize-save-variable
       'metal-agent-providers
       (assq-delete-all id (and (boundp 'metal-agent-providers)
                                metal-agent-providers)))
      ;; Si c'était l'agent actif, basculer vers un autre.
      (when (and (boundp 'metal-agent-provider)
                 (eq metal-agent-provider id))
        (customize-save-variable
         'metal-agent-provider
         (car-safe (car-safe (and (boundp 'metal-agent-providers)
                                  metal-agent-providers)))))
      (metal-deps--journaliser "Agent personnalisé « %s » retiré" nom)
      (message "Agent « %s » retiré." nom))))

(defun metal-deps--ajouter-agent-personnalise ()
  "Ajoute un agent CLI personnalisé à `metal-agent-providers'.
L'utilisateur doit avoir déjà installé la CLI sur son système.
Demande interactivement les informations nécessaires."
  (interactive)
  (require 'metal-agent nil t)
  (let* ((id-str (string-trim
                  (read-string "ID unique (symbole sans espaces, ex: mon-agent) : ")))
         (id (and (not (string-empty-p id-str)) (intern id-str))))
    (unless id
      (user-error "ID requis"))
    (when (assq id metal-deps-agents-catalogue)
      (user-error "L'ID « %s » est utilisé par le catalogue intégré" id-str))
    (when (and (boundp 'metal-agent-providers)
               (assq id metal-agent-providers))
      (user-error "L'ID « %s » est déjà utilisé" id-str))
    (let* ((nom (string-trim
                 (read-string "Nom affiché (ex: Mon Agent) : ")))
           (commande (string-trim
                      (read-string "Commande CLI (ex: mon-cli) : ")))
           (args-str (read-string
                      "Arguments par défaut (séparés par espaces, vide = aucun) : "))
           (args (if (string-empty-p (string-trim args-str))
                     nil
                   (split-string-and-unquote args-str)))
           (format-str
            (completing-read
             "Format de sortie : "
             '("claude-style" "codex-style")
             nil t nil nil "claude-style"))
           (format-sym (intern format-str)))
      (when (string-empty-p nom)
        (user-error "Nom requis"))
      (when (string-empty-p commande)
        (user-error "Commande requise"))
      ;; Avertir si la CLI est introuvable (mais permettre quand même).
      (unless (executable-find commande)
        (unless (yes-or-no-p
                 (format "La commande « %s » est introuvable dans le PATH.  Ajouter quand même ? "
                         commande))
          (user-error "Annulé")))
      (let ((entry (cons id
                         (list :label nom
                               :command commande
                               :args args
                               :buffer-name (format "*Metal %s*" nom)
                               :format format-sym))))
        (customize-save-variable
         'metal-agent-providers
         (append (and (boundp 'metal-agent-providers) metal-agent-providers)
                 (list entry)))
        (metal-deps--journaliser "Agent personnalisé « %s » ajouté (commande : %s)"
                                 nom commande)
        (message "Agent « %s » ajouté." nom)
        (run-with-timer 0.3 nil #'metal-deps-afficher-etat)))))

(defun metal-deps--sync-providers-avec-catalogue ()
  "Synchronise les entrées catalogue dans `metal-agent-providers'.
Quand le catalogue change `:nom' ou d'autres champs (ex: Codex → ChatGPT,
Gemini CLI → Gemini), les entrées persistées dans Custom gardent
l'ancien nom — donc le `:buffer-name' reste figé (ex: « *Metal Codex* »
alors que le buffer attendu serait « *Metal ChatGPT* »).

Cette fonction met à jour les entrées du catalogue dans providers à
chaque ouverture de l'Assistant.  Idempotent.  Ne touche pas aux
agents personnalisés (qui ne sont pas dans le catalogue)."
  (require 'metal-agent nil t)
  (when (boundp 'metal-agent-providers)
    (let (modifie)
      (dolist (entry metal-deps-agents-catalogue)
        (let* ((id (car entry))
               (spec (cdr entry))
               (provider-existant (assq id metal-agent-providers))
               (nouveau-provider (metal-deps--agent-spec->provider-entry id spec)))
          ;; Si l'agent est déjà enregistré et ses champs ont changé,
          ;; mettre à jour l'entrée.
          (when (and provider-existant
                     (not (equal (cdr provider-existant)
                                 (cdr nouveau-provider))))
            (setq metal-agent-providers
                  (cons nouveau-provider
                        (assq-delete-all id metal-agent-providers)))
            (setq modifie t))))
      (when modifie
        (customize-save-variable 'metal-agent-providers metal-agent-providers)
        (metal-deps--journaliser
         "Providers synchronisés avec le catalogue (label/buffer-name mis à jour)")))))

(defun metal-deps--migration-nettoyage-agents-legacy ()
  "Retire de `metal-agent-providers' les anciens IDs d'agents qui ne
sont plus dans le catalogue intégré (opencode, goose, aider, copilot).

Ces agents existaient dans le catalogue historiquement et peuvent
encore persister dans la configuration Custom de l'utilisateur.  Cette
fonction est idempotente — sûre à appeler plusieurs fois.  Pour
réutiliser un de ces agents, passer par « + Ajouter un autre agent… »."
  (when (boundp 'metal-agent-providers)
    (let* ((ids-legacy '(opencode goose aider copilot))
           (avant metal-agent-providers)
           (apres (cl-remove-if (lambda (p) (memq (car p) ids-legacy))
                                avant)))
      (unless (equal avant apres)
        (customize-save-variable 'metal-agent-providers apres)
        ;; Si l'agent actif était un des legacy, basculer vers un autre.
        (when (and (boundp 'metal-agent-provider)
                   (memq metal-agent-provider ids-legacy))
          (customize-save-variable
           'metal-agent-provider
           (car-safe (car-safe apres))))
        (metal-deps--journaliser
         "Migration : %d ancien(s) agent(s) retiré(s) du registre (%s).  Disponibles via « + Ajouter un autre agent… »."
         (- (length avant) (length apres))
         (mapconcat #'symbol-name
                    (cl-set-difference (mapcar #'car avant)
                                       (mapcar #'car apres))
                    ", "))))))

(defun metal-deps--collecter-outils-agents ()
  "Retourne la liste des outils-agents (catalogue + personnalisés).
Les agents personnalisés sont ceux présents dans `metal-agent-providers'
mais absents du catalogue."
  (let* ((ids-catalogue (mapcar #'car metal-deps-agents-catalogue))
         (providers (and (boundp 'metal-agent-providers)
                         metal-agent-providers))
         (perso (cl-remove-if (lambda (p) (memq (car p) ids-catalogue))
                              providers)))
    (append (mapcar #'metal-deps--agent-catalogue->outil
                    metal-deps-agents-catalogue)
            (mapcar #'metal-deps--outil-agent-personnalise perso))))

(defun metal-deps--tous-les-outils ()
  "Retourne la liste complète des outils (statiques + agents dynamiques)."
  (append metal-deps-outils
          (metal-deps--collecter-outils-agents)))

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
    (dolist (outil (metal-deps--tous-les-outils))
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
  ;; Nettoyer les anciens agents qui ne sont plus dans le catalogue.
  ;; Idempotent : si déjà nettoyé, ne fait rien.
  (metal-deps--migration-nettoyage-agents-legacy)
  ;; Synchroniser les entrées du catalogue avec metal-agent-providers
  ;; (pour propager les changements de :nom/:buffer-name aux entrées
  ;; déjà persistées dans Custom).
  (metal-deps--sync-providers-avec-catalogue)
  (let* ((buf (get-buffer-create "*MetalEmacs Assistant*"))
         ;; Mémoriser la position d'affichage si le buffer est déjà ouvert,
         ;; pour la restaurer après le rerendu.  Sans ça, un clic sur ◯
         ;; (changer agent défaut) ferait remonter l'affichage en haut.
         (win-existante (get-buffer-window buf))
         (point-precedent (and win-existante
                               (with-current-buffer buf (point))))
         (start-precedent (and win-existante
                               (window-start win-existante))))
    (with-current-buffer buf
      ;; Désactiver le read-only pour TOUT le rendu : `widget-insert' a
      ;; son propre wrap mais `insert-text-button' (pour les liens
      ;; « authentifier ») n'en a pas, donc faillirait lors d'un
      ;; rafraîchissement après installation (où read-only-mode est actif).
      (let ((inhibit-read-only t))
        (erase-buffer)
        (remove-overlays)
        (widget-insert "\n  ")
        (widget-insert (propertize "Assistant MetalEmacs"
                                   'face '(:weight bold :height 1.4)))
      (widget-insert "\n  ")
      (widget-insert (propertize "Gestion des dépendances et agents IA"
                                 'face 'shadow))
      (widget-insert "\n\n  ")
      (widget-insert (propertize (format "Système : %s"
                                         (metal-deps--nom-systeme))
                                 'face 'shadow))
      (widget-insert "\n")
      (when metal-deps--installation-en-cours
        (widget-insert (format "  ⏳ Installation en cours (%d restant%s)\n"
                               (length metal-deps--file-attente)
                               (if (> (length metal-deps--file-attente) 1) "s" ""))))
      
      (dolist (categorie '((prerequis . "📋 Prérequis système")
                           (gestionnaire . "📦 Gestionnaires de paquets")
                           (logiciels . "🎓 Logiciels")
                           (pdf . "📄 Support PDF")
                           (agents-ia . "🤖 Agents IA")))
        (let* ((cat-id (car categorie))
               (cat-nom (cdr categorie))
               (outils-cat (cl-remove-if-not
                            (lambda (o)
                              (and (eq (plist-get o :categorie) cat-id)
                                   (metal-deps--outil-applicable-p o)))
                            (metal-deps--tous-les-outils))))
          (when outils-cat
            ;; --- En-tête de section ---
            (widget-insert "\n  ")
            (widget-insert (propertize cat-nom 'face '(:weight bold :height 1.05)))
            (widget-insert "\n  ")
            (widget-insert (propertize (make-string 66 ?─) 'face 'shadow))
            (widget-insert "\n\n")
            ;; --- Items ---
            (dolist (outil outils-cat)
              (let* ((nom (plist-get outil :nom))
                     (present (metal-deps--outil-present-p outil))
                     (installeur (plist-get outil :installer))
                     (desinstalleur (plist-get outil :desinstaller))
                     (agent-id (plist-get outil :agent-id))
                     (desc (plist-get outil :description))
                     ;; Pour les agents : déterminer s'il est authentifié,
                     ;; et s'il est le défaut courant.  Le radio ●/◯
                     ;; remplace alors le ✓/✗ habituel.
                     (spec (and agent-id
                                (cdr (assq agent-id metal-deps-agents-catalogue))))
                     (authentifie (and agent-id
                                       (or (not spec)  ; agent perso : on autorise
                                           (metal-deps--agent-authentifie-p spec))))
                     (radio-applicable (and agent-id present authentifie))
                     (est-defaut (and radio-applicable
                                      (boundp 'metal-agent-provider)
                                      (eq metal-agent-provider agent-id)))
                     ;; Largeur du préfixe « statut + 2 espaces » = 6 cells.
                     ;; (3 espaces avant + 1 char statut + 2 espaces après)
                     (largeur-cible (+ 6 metal-deps--largeur-colonne-nom))
                     (largeur-actuelle (+ 6 (string-width nom)))
                     (padding (max 2 (- largeur-cible largeur-actuelle))))
                ;; --- Statut visuel (radio ●/◯ pour agents, sinon ✓/✗) ---
                (widget-insert "   ")
                (cond
                 ;; Agent installé+authentifié + défaut : ● vert (non cliquable)
                 ((and radio-applicable est-defaut)
                  (widget-insert
                   (propertize "●" 'face '(:foreground "#10A37F" :weight bold))))
                 ;; Agent installé+authentifié non-défaut : ◯ cliquable
                 (radio-applicable
                  (let ((id agent-id) (n nom))
                    (insert-text-button
                     "◯"
                     'action (lambda (_)
                               (metal-deps--definir-agent-defaut id))
                     'face '(:foreground "#586069" :weight bold)
                     'follow-link t
                     'help-echo (format "Définir « %s » comme agent par défaut" n))))
                 ;; Autres : ✓ vert si présent, ✗ atténué sinon.
                 (present
                  (widget-insert
                   (propertize "✓" 'face '(:foreground "#10A37F" :weight bold))))
                 (t
                  (widget-insert (propertize "✗" 'face 'shadow))))
                (widget-insert "  ")
                (widget-insert nom)
                (widget-insert (make-string padding ?\s))
                ;; --- Bouton principal : Installer ou Désinstaller ---
                ;; On mémorise la position avant le bouton pour padder ensuite
                ;; à une largeur fixe (sinon la colonne d'auth est désalignée
                ;; entre [Installer] et [Désinstaller]).
                (let ((debut-bouton (point)))
                  (cond
                   ;; Installé → Désinstaller (si supporté).
                   ((and present desinstalleur)
                    (let ((fn desinstalleur))
                      (widget-create 'push-button
                                     :notify (lambda (&rest _)
                                               (metal-deps--executer-et-rafraichir fn))
                                     "Désinstaller")))
                   ;; Non installé → Installer (+ Télécharger sur Linux si défini).
                   ((and (not present) installeur (not (eq installeur 'ignore)))
                    (let ((telecharger (plist-get outil :telecharger)))
                      (when (and telecharger (eq system-type 'gnu/linux))
                        (widget-create 'push-button
                                       :notify (lambda (&rest _)
                                                 (funcall telecharger))
                                       "Télécharger")
                        (widget-insert "  ")))
                    (let ((fn installeur))
                      (widget-create 'push-button
                                     :notify (lambda (&rest _)
                                               (metal-deps--executer-et-rafraichir fn))
                                     "Installer"))))
                  ;; Padder le bouton principal à largeur fixe (16 chars)
                  ;; pour aligner la colonne suivante.
                  (let* ((largeur-bouton (string-width
                                          (buffer-substring-no-properties
                                           debut-bouton (point))))
                         (pad-suite (max 2 (- 16 largeur-bouton))))
                    (widget-insert (make-string pad-suite ?\s))))
                ;; --- Statut / description ---
                (cond
                 ;; Cas agent : "🔑 statut : description"
                 (agent-id
                  (let* ((spec (cdr (assq agent-id metal-deps-agents-catalogue)))
                         (authentifie (and spec
                                           (metal-deps--agent-authentifie-p spec))))
                    (widget-insert
                     (propertize "🔑 " 'face '(:foreground "#10A37F")))
                    (cond
                     ;; Installé + authentifié : texte vert (non cliquable).
                     (authentifie
                      (widget-insert
                       (propertize "authentifié"
                                   'face '(:foreground "#10A37F" :weight bold))))
                     ;; Installé non authentifié : « authentifier » cliquable
                     ;; lance l'auth en terminal (comportement habituel).
                     (present
                      (let ((id agent-id))
                        (insert-text-button
                         "authentifier"
                         'action (lambda (_)
                                   (metal-deps--authentifier-agent-ia id))
                         'face '(:foreground "#0366d6" :underline t :weight bold)
                         'follow-link t
                         'help-echo "Lancer l'authentification dans un terminal")))
                     ;; Pas installé : « authentifier » cliquable affiche
                     ;; la procédure dans un buffer d'aide.
                     (t
                      (let ((id agent-id))
                        (insert-text-button
                         "authentifier"
                         'action (lambda (_)
                                   (metal-deps--afficher-procedure-auth id))
                         'face '(:foreground "#0366d6" :underline t :weight bold)
                         'follow-link t
                         'help-echo "Afficher la procédure d'authentification"))))
                    (when desc
                      (widget-insert
                       (propertize (concat " : " desc) 'face 'shadow)))))
                 ;; Cas non-agent : "— description" (si description)
                 (desc
                  (widget-insert (propertize (concat "— " desc) 'face 'shadow))))
                (widget-insert "\n")))
            ;; --- Bouton spécial pour agents-ia : ajouter un agent perso ---
            (when (eq cat-id 'agents-ia)
              (widget-insert "\n   ")
              (widget-create 'push-button
                             :notify (lambda (&rest _)
                                       (call-interactively
                                        #'metal-deps--ajouter-agent-personnalise))
                             "+ Ajouter un autre agent…")
              (widget-insert "\n   ")
              (widget-insert
               (propertize
                "● = agent par défaut au démarrage ; cliquer sur ◯ pour le changer"
                'face 'shadow))
              (widget-insert "\n"))
            (widget-insert "\n"))))
      
      (widget-insert "\n  ")
      (widget-insert (propertize (make-string 66 ?─) 'face 'shadow))
      (widget-insert "\n\n  ")
      (widget-insert (propertize "Actions rapides : " 'face 'bold))
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
      (widget-insert "\n\n"))
      
      (use-local-map widget-keymap)
      (widget-setup)
      ;; Restaurer la position d'affichage : si on était dans un buffer
      ;; déjà ouvert, garder le point et le window-start ; sinon aller
      ;; au début (premier affichage).
      (if point-precedent
          (goto-char (min point-precedent (point-max)))
        (goto-char (point-min)))
      (read-only-mode 1)
      (setq-local tab-line-exclude nil)
      (tab-line-mode 1))
    ;; Affichage du buffer.  Si l'Assistant a déjà une fenêtre (cas d'un
    ;; rafraîchissement après installation), on la réutilise au lieu de
    ;; faire un `switch-to-buffer' aveugle : sinon, quand le rafraîchissement
    ;; est déclenché depuis la fenêtre de sortie d'`async-shell-command'
    ;; (ex. *Homebrew Install*), l'Assistant s'empilerait par-dessus,
    ;; laissant deux vues *MetalEmacs Assistant* côte à côte.
    (let ((win (get-buffer-window buf)))
      (if win
          (select-window win)
        (switch-to-buffer buf)))
    ;; Le switch-to-buffer peut réinitialiser le window-start ; on
    ;; le restaure explicitement après pour préserver le défilement.
    (when (and start-precedent (get-buffer-window buf))
      (set-window-start (get-buffer-window buf)
                        (min start-precedent (point-max))))))

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
  
  ;; Homebrew sur macOS : Apple Silicon (/opt/homebrew) ou Intel (/usr/local)
  (when (eq system-type 'darwin)
    (dolist (brew-bin '("/opt/homebrew/bin" "/usr/local/bin"))
      (when (file-exists-p (expand-file-name "brew" brew-bin))
        (add-to-list 'exec-path brew-bin)
        (setenv "PATH" (concat brew-bin ":" (getenv "PATH"))))))

  ;; SWI-Prolog sur macOS via le bundle officiel (.dmg) : l'exécutable
  ;; `swipl' vit dans /Applications/SWI-Prolog.app/Contents/MacOS, hors
  ;; PATH.  C'est le cas d'installation sur les Mac < 14 (cf.
  ;; `metal-deps--installer-swipl-dmg').  On l'ajoute pour que metal-prolog
  ;; et les sous-processus trouvent `swipl' sans configuration manuelle.
  (when (eq system-type 'darwin)
    (let ((swipl-bin "/Applications/SWI-Prolog.app/Contents/MacOS"))
      (when (file-executable-p (expand-file-name "swipl" swipl-bin))
        (add-to-list 'exec-path swipl-bin)
        (setenv "PATH" (concat swipl-bin ":" (getenv "PATH"))))))
  
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
