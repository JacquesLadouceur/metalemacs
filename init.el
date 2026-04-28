;; -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

(setq custom-file (expand-file-name "metal-custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))

;; Désactiver complètement vc-mode (cause de lenteur avec M-H)
(setq vc-handled-backends nil)

(setq warning-suppress-log-types '((initialization)))

;; Note: La configuration précoce (HOME, Git Portable, PATH) est dans early-init.el

;; Désactiver les écrans de démarrage par défaut
(setq-default inhibit-startup-screen t
              inhibit-startup-message t
              inhibit-startup-echo-area-message user-login-name)

;; Désactiver complètement le chiffrement GPG pour plstore
(setq plstore-encrypt-to nil)
(setq plstore-select-keys nil)

(advice-add 'epg-encrypt-string :override
            (lambda (context plain recipients &optional sign always-trust)
              plain))
(advice-add 'epg-decrypt-string :override
            (lambda (context cipher)
              cipher))

(when (eq system-type 'windows-nt)
  (let ((emacs-bin (expand-file-name "bin" (getenv "EMACS_DIR"))))
    ;; ou directement :
    ;; (let ((emacs-bin "C:/Program Files/Emacs/emacs-29.1/bin"))
    (setenv "PATH" (concat emacs-bin ";" (getenv "PATH")))
    (add-to-list 'exec-path emacs-bin)))

(setq epg-gpg-program "")
(setq org-gcal-token-file "~/.emacs.d/org-gcal-token.el")

;; Forcer UTF-8 partout
(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(setq default-buffer-file-coding-system 'utf-8)


;; Spécifique Windows
(when (eq system-type 'windows-nt)
  (set-selection-coding-system 'utf-16-le))



;; INDICATEUR DE TRAITTEMENT DÉBUT

;; ------------------------------------------------------------
;; jl-busy-mode : indicateur global "Emacs travaille..."
;; ------------------------------------------------------------


;; NOTE: Configuration police déplacée dans early-init.el
;; Les fontsets pour emojis/symboles sont configurés après le démarrage
(when (eq system-type 'windows-nt)
  (add-hook 'emacs-startup-hook
            (lambda ()
              (set-fontset-font t 'unicode (font-spec :family "Segoe UI Symbol"))
              (set-fontset-font t '(#x1F300 . #x1FAF8) "Segoe UI Emoji" nil 'prepend)
              (when (find-font (font-spec :family "Symbols Nerd Font Mono"))
                (set-fontset-font t 'unicode (font-spec :family "Symbols Nerd Font Mono") nil 'append)))
            95))


(defgroup jl-busy nil
  "Indicateur global quand Emacs travaille."
  :group 'convenience)

(defcustom jl/busy-delay 0.5
  "Delai (en secondes) avant d afficher l indicateur de travail.
Si une commande termine avant ce delai, rien ne s affiche."
  :type 'number
  :group 'jl-busy)

(defcustom jl/busy-show-message t
  "Si non-nil, afficher aussi un message dans le minibuffer
quand Emacs active le mode 'busy'."
  :type 'boolean
  :group 'jl-busy)

(defvar jl/busy--timer nil
  "Timer interne pour l indicateur de travail.")
(defvar jl/busy--command nil
  "Commande courante pour laquelle l indicateur a ete arme.")
(defvar jl/busy--active nil
  "Non-nil si l indicateur est actuellement actif.")

(defvar jl/busy-mode-line-string nil
  "Texte affiche dans la mode-line quand Emacs travaille.")

;; Ajouter l indicateur a la mode-line globale
(setq global-mode-string '("" jl/busy-mode-line-string))

(defun jl/busy--activate ()
  "Activer l indicateur de travail si la commande est toujours en cours."
  (setq jl/busy--timer nil)
  ;; On active seulement si la commande n a pas deja fini.
  (unless jl/busy--active
    (setq jl/busy--active t)
    (setq jl/busy-mode-line-string
          (format " [Emacs travaille: %s]" jl/busy--command))
    (force-mode-line-update t)
    (when jl/busy-show-message
      (message "Emacs travaille..."))))

(defun jl/busy--pre-command ()
  "Fonction de pre-command pour armer l indicateur."
  (condition-case nil
      (progn
        (setq jl/busy--command this-command)
        ;; Annuler un ancien timer au cas ou
        (when jl/busy--timer
          (cancel-timer jl/busy--timer)
          (setq jl/busy--timer nil))
        ;; On arme un nouveau timer
        (setq jl/busy--timer
              (run-at-time jl/busy-delay nil #'jl/busy--activate)))
    (error nil)))

(defun jl/busy--post-command ()
  "Fonction de post-command pour desarmer l indicateur."
  (condition-case nil
      (progn
        ;; Annuler le timer si la commande a fini assez vite
        (when jl/busy--timer
          (cancel-timer jl/busy--timer)
          (setq jl/busy--timer nil))
        ;; Nettoyer l indicateur s il etait actif
        (when jl/busy--active
          (setq jl/busy--active nil)
          (setq jl/busy-mode-line-string nil)
          (force-mode-line-update t)
          (when jl/busy-show-message
            (message nil))))
    (error nil)))

;;;###autoload
(define-minor-mode jl-busy-mode
  "Mode global affichant un indicateur quand Emacs travaille.
Quand une commande interactive dure plus que `jl/busy-delay`,
un indicateur est affiche dans la mode-line, et eventuellement
un message dans le minibuffer."
  :global t
  :group 'jl-busy
  (if jl-busy-mode
      (progn
        (add-hook 'pre-command-hook #'jl/busy--pre-command)
        (add-hook 'post-command-hook #'jl/busy--post-command))
    (remove-hook 'pre-command-hook #'jl/busy--pre-command)
    (remove-hook 'post-command-hook #'jl/busy--post-command)
    ;; Nettoyage
    (when jl/busy--timer
      (cancel-timer jl/busy--timer)
      (setq jl/busy--timer nil))
    (setq jl/busy--active nil)
    (setq jl/busy-mode-line-string nil)
    (force-mode-line-update t)))


(defun jl/insert-for-yank-safe (orig-fn string &rest args)
  "Remplacer la region active par STRING de facon plus sure.
Si une region est active, la supprimer puis inserer STRING dans un bloc
avec redisplay limite. Sinon, laisser le comportement normal."
  (if (and (use-region-p)
           (stringp string))
      (let ((beg (region-beginning))
            (end (region-end))
            (inhibit-redisplay t)
            (inhibit-message t))
        (undo-boundary)
        (delete-region beg end)
        (goto-char beg)
        (apply orig-fn string args)
        (undo-boundary)
        (redisplay))
    ;; Pas de region active (ou arg bizarre) -> comportement normal
    (apply orig-fn string args)))

(with-eval-after-load 'simple
  (advice-add 'insert-for-yank :around #'jl/insert-for-yank-safe))

  
(setq frame-title-format "🤖 – MetalEmacs 1.1")

(setq write-region-inhibit-fsync t)

;; ✅ Compilation native : détecter dynamiquement un GCC disponible
;; (Homebrew sur macOS, MinGW/MSYS2 sur Windows, gcc système sur Linux)
(when (and (fboundp 'native-comp-available-p) (native-comp-available-p))
  (let ((gcc (or (executable-find "gcc-15")
                 (executable-find "gcc-14")
                 (executable-find "gcc-13")
                 (executable-find "gcc"))))
    (cond
     (gcc
      (setenv "CC" gcc)
      (message "✅ Compilation native avec GCC : %s" gcc))
     (t
      (message "⚠ GCC introuvable — compilation native désactivée")
      (setq comp-enable-subr-trampolines nil)))))

;; Désactive les warnings de compilation native dans le minibuffer
(setq native-comp-async-report-warnings-errors nil)
(setq native-comp-deferred-compilation nil)


(defvar metal-encoding-candidates
  '("windows-1252" "latin-1" "utf-8" "iso-8859-1" "mac-roman")
  "List of coding systems offered for manual decode.")

(defun metal-read-coding-from-list ()
  "Prompt user to pick a coding from `metal-encoding-candidates` (no default)."
  (let ((choice (completing-read
                 "Coding: " metal-encoding-candidates nil t "")))
    (if (and choice (not (string-empty-p choice)))
        (intern choice)
      (user-error "No coding selected"))))

(defun metal-decode-encode-buffer (coding)
  "Décode le buffer entier comme si ses octets étaient encodés avec CODING.
Ignore les buffers spéciaux comme Treemacs, Dashboard, etc."
  (interactive (list (metal-read-coding-from-list)))
  (cond
   ((eq major-mode 'treemacs-mode)
    (user-error "Impossible de décoder le buffer Treemacs"))
   ((eq major-mode 'dashboard-mode)
    (user-error "Impossible de décoder le buffer Dashboard"))
   ((and (not (buffer-file-name))
         (not (y-or-n-p "Ce buffer n'a pas de fichier. Décoder quand même ? ")))
    (message "Décodage annulé"))
   (t
    (let ((inhibit-read-only t))
      (save-excursion
        (decode-coding-region (point-min) (point-max) coding)))
    (message "Buffer décodé avec %s" coding))))

(defun metal-decode-encode-selection (beg end coding)
  "Decode region BEG..END as if its bytes were encoded with CODING."
  (interactive (list (region-beginning) (region-end) (metal-read-coding-from-list)))
  (let ((inhibit-read-only t))
    (save-excursion
      (decode-coding-region beg end coding))))

;; Convenience wrappers
(defun my/decode-raw-bytes-in-buffer (coding)
  "Decode current buffer with CODING."
  (interactive (list (metal-read-coding-from-list)))
  (metal-decode-encode-buffer coding))

(defun my/decode-raw-bytes-latin1 ()
  (interactive)
  (my/decode-raw-bytes-in-buffer 'latin-1))

(defun my/decode-raw-bytes-cp1252 ()
  (interactive)
  (my/decode-raw-bytes-in-buffer 'windows-1252))


;; Désactiver cua-mode
(cua-mode 1)

;; Shift + flèches pour sélectionner visuellement
(setq shift-select-mode t)

;; Intégration propre avec le presse-papiers système
(setq select-enable-clipboard t)
(setq save-interprogram-paste-before-kill t)
(set-selection-coding-system 'utf-8)

;; Définir des raccourcis globaux plus intuitifs,
;; uniquement en dehors des modes majeurs connus
(defun my-intuitive-copy-cut-paste ()
  (unless (derived-mode-p 'special-mode 'magit-mode 'org-mode 'dired-mode)
    (local-set-key (kbd "C-c") #'kill-ring-save)
 ;;   (local-set-key (kbd "C-x") #'kill-region)
    (local-set-key (kbd "C-v") #'yank)
    (local-set-key (kbd "C-z") #'undo)))

;; Activer ces raccourcis dans les buffers standards
(add-hook 'text-mode-hook #'my-intuitive-copy-cut-paste)
(add-hook 'prog-mode-hook #'my-intuitive-copy-cut-paste)

;; Optionnel : les mêmes avec Cmd sur macOS
(when (eq system-type 'darwin)
  (global-set-key (kbd "s-c") #'kill-ring-save)
  (global-set-key (kbd "s-x") #'kill-region)
  (global-set-key (kbd "s-v") #'yank)
  (global-set-key (kbd "s-z") #'undo))

(defun lisp-db-activate ()
  "Active debug-on-error et le rend persistant avec custom-set-variables."
  (interactive)
  (setq debug-on-error t)
  (customize-save-variable 'debug-on-error t))

(defun lisp-db-deactivate ()
  "Désactive debug-on-error et le rend persistant avec custom-set-variables."
  (interactive)
  (setq debug-on-error nil)
  (customize-save-variable 'debug-on-error nil))


(when (eq system-type 'darwin)  ;; Si macOS
  (let ((autoreconf-path (executable-find "autoreconf")))
    (when autoreconf-path
      (setenv "PATH" (concat (file-name-directory autoreconf-path) ":" (getenv "PATH")))
      (setq exec-path (append `(,autoreconf-path) exec-path)))))

;; Ajuster la taille initiale de Emacs
(defun tailleInitiale ()
  (let* ((base-factor 0.70)
         ;; Hauteur réduite sur Windows (barre des tÃ¢ches)
         (height-factor (if (eq system-type 'windows-nt) 0.60 0.70))
         ;; Utiliser la taille du moniteur principal
         (screen-width (display-pixel-width))
         (screen-height (display-pixel-height))
         (a-width (* screen-width base-factor))
         (a-height (* screen-height height-factor))
         ;; Centrer horizontalement et verticalement
         (a-left (truncate (/ (- screen-width a-width) 2)))
         (a-top (truncate (/ (- screen-height a-height) 2))))
    ;; Appliquer la taille d'abord
    (set-frame-size (selected-frame) (truncate a-width) (truncate a-height) t)
    ;; Puis la position
    (set-frame-position (selected-frame) a-left a-top)
    ;; Réajuster Treemacs Ã  sa largeur normale
    (when (and (fboundp 'treemacs-get-local-window)
               (treemacs-get-local-window))
      (with-selected-window (treemacs-get-local-window)
        (treemacs--set-width treemacs-width)))))

(setq frame-resize-pixelwise t)

(add-hook 'emacs-startup-hook
          (lambda ()
            ;; Ne redimensionner que si des preferences existent (pas au premier demarrage)
            (when (file-exists-p (expand-file-name "metal-prefs.el" user-emacs-directory))
              (tailleInitiale))
            (setq frame-title-format "MetalEmacs 1.1")))


;; Apparence et interface
(column-number-mode 1)
(context-menu-mode 1)
(load-theme 'modus-operandi t)
(header-line-indent-mode 1)
(setq debug-on-error nil)

;; macOS : touche Option droite pour accents
(when (eq system-type 'darwin)
  (setq ns-right-alternate-modifier 'none))


(setq initial-scratch-message nil)
(setq-default major-mode 'fundamental-mode)


(defun toggle-treemacs-and-fullscreen ()
  "Bascule l'affichage de Treemacs. Ouvre si fermé (et quitte le plein écran), ouvre sinon."
  (interactive)
  (if (treemacs-is-treemacs-window-selected?)
      (progn
        (treemacs-quit)    ;; Ferme l'explorateur de fichiers
        (toggle-frame-fullscreen))  ;; Active le mode plein écran
    (progn
      (treemacs)           ;; Ouvre Treemacs
      (toggle-frame-fullscreen))))  ;; Active le mode plein écran

 

(global-set-key (kbd "<f1>") #'metal-dashboard-open)


(global-set-key (kbd "<f2>") 'toggle-treemacs-and-fullscreen)


(setq warning-minimum-level :error)

(setq gc-cons-threshold 50000000)  ;; 50 MB - compromis performance/stabilité
(setq max-specpdl-size 5000)
(setq
 inhibit-startup-screen t
 sentence-end-double-space nil
 ring-bell-function 'ignore
 save-interprogram-paste-before-kill t
 mark-even-if-inactive nil
 kill-whole-line t
 use-short-answers t
 load-prefer-newer t
 confirm-kill-processes nil
 truncate-string-ellipsis "â€¦"
 help-window-select t
 delete-by-moving-to-trash t
 scroll-preserve-screen-position t
 completions-detailed t
 next-error-message-highlight t
 read-minibuffer-restore-windows t
 save-some-buffers-default-predicate 'save-some-buffers-root
 kill-do-not-save-duplicates t
 )

(setq inhibit-startup-message t
      inhibit-startup-buffer-menu t)


(setq-default indent-tabs-mode nil)
(set-charset-priority 'unicode)
;; (prefer-coding-system 'utf-8-unix)
(delete-selection-mode t)
(column-number-mode)
(savehist-mode)
(global-hl-line-mode 1)
(add-hook 'prog-mode-hook #'hl-line-mode)
(add-hook 'text-mode-hook #'hl-line-mode)
(setq
 make-backup-files nil
 auto-save-default nil
 create-lockfiles nil)


(setq-default buffer-file-coding-system 'utf-8)
(set-selection-coding-system 'utf-8)

;; Configuration de base - DÉBUT
;;
;; Bootstrap straight.el : détecte le premier démarrage et affiche un
;; message à l'utilisateur (utile pour les étudiants qui clonent le
;; dépôt depuis GitHub la première fois).

(defvar bootstrap-version)

(let* ((straight-dir (expand-file-name "straight" user-emacs-directory))
       (premier-demarrage (not (file-directory-p straight-dir)))
       (bootstrap-file
        (expand-file-name "straight/repos/straight.el/bootstrap.el"
                          user-emacs-directory))
       (bootstrap-version 7))

  ;; Message de bienvenue au premier démarrage
  (when premier-demarrage
    (let ((buf (get-buffer-create "*MetalEmacs - Premier démarrage*")))
      (with-current-buffer buf
        (erase-buffer)
        (insert "
╔══════════════════════════════════════════════════════════════════╗
║              Bienvenue dans MetalEmacs                           ║
╚══════════════════════════════════════════════════════════════════╝

Premier démarrage détecté.  MetalEmacs va maintenant télécharger
et installer toutes ses dépendances.

⏱  Cette opération peut prendre 5 à 15 minutes selon votre
    connexion Internet (~100 paquets à télécharger et compiler).

📋 Étapes en cours :
   1. Installation de straight.el (gestionnaire de paquets)
   2. Téléchargement des paquets MELPA et GNU ELPA
   3. Compilation native (Emacs 29+) en arrière-plan

💡 Pour suivre la progression en détail :
   M-x view-echo-area-messages

Après ce premier démarrage, les lancements ultérieurs seront
quasi-instantanés.

Pour les mises à jour futures :
   cd ~/.emacs.d && git pull
   puis redémarrez Emacs.
")
        (goto-char (point-min))
        (setq buffer-read-only t))
      ;; Afficher le buffer seul en plein écran pendant l'installation,
      ;; sans le *scratch* à côté. Le layout normal (dashboard, tab-line,
      ;; treemacs…) s'installera après, au démarrage suivant.
      (switch-to-buffer buf)
      (delete-other-windows)
      (redisplay)))

  ;; Installation de straight.el si absent
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

(straight-use-package 'use-package)

(use-package straight
  :custom
  (straight-use-package-by-default t))

(if (eq system-type 'darwin)
(use-package exec-path-from-shell
  :config
  (setq exec-path-from-shell-variables
        '("LANG" "LC_ALL" "PATH" "PYTHONPATH"))  ;; Ajoute d'autres variables si nécessaire
  (exec-path-from-shell-initialize)))



;; ============================================================
;; MetalEmacs - Polices (taille physique) + Prefs + Frame geometry
;; Emacs 30.2 compatible - copie/colle tel quel
;; ============================================================

(require 'frameset)

(defgroup metal-font nil
  "Outils pour le dimensionnement physique des polices."
  :group 'faces)

(defconst metal-font-base 120
  "Hauteur de base de la police (en dixiemes de point). 120 = 12pt.")

(defcustom metal-font-size-offset 0
  "Correction utilisateur ajoutee a la hauteur de base.
Increments de 10 (1pt)."
  :type 'integer
  :group 'metal-font)

;; ------------------------------------------------------------
;; Preferences MetalEmacs: sauvegarde/restauration (offset + geometrie)
;; IMPORTANT: on sauvegarde la taille en pixels pour etre stable meme si la police change.
;; ------------------------------------------------------------

(defvar metal-prefs-file (expand-file-name "metal-prefs.el" user-emacs-directory)
  "Fichier de sauvegarde des preferences MetalEmacs (variables + geometrie du frame).")

(defvar metal-frame-left nil
  "Position X (pixels) du frame.")

(defvar metal-frame-top nil
  "Position Y (pixels) du frame.")

(defvar metal-frame-px-width nil
  "Largeur du frame en pixels.")

(defvar metal-frame-px-height nil
  "Hauteur du frame en pixels.")

(defvar metal-frame-fullscreen nil
  "Etat fullscreen (nil, maximized, fullboth, etc.).")

(defun metal-frame--lire-geom (&optional frame)
  "Lit la geometrie du FRAME courant (position + taille en pixels)."
  (let* ((frame (or frame (selected-frame)))
         (left (frame-parameter frame 'left))
         (top  (frame-parameter frame 'top))
         (fs   (frame-parameter frame 'fullscreen)))
    ;; left/top peuvent etre (cons ..) selon plateforme; on normalise
    (setq metal-frame-left (if (consp left) (car left) left))
    (setq metal-frame-top  (if (consp top)  (car top)  top))
    (setq metal-frame-px-width  (frame-pixel-width frame))
    (setq metal-frame-px-height (frame-pixel-height frame))
    (setq metal-frame-fullscreen fs)))

(defun metal-frame-appliquer-geom (&optional frame)
  "Applique la geometrie sauvegardee au FRAME (si disponible)."
  (let ((frame (or frame (selected-frame))))
    ;; Position d abord
    (when (and (numberp metal-frame-left) (numberp metal-frame-top))
      (set-frame-position frame metal-frame-left metal-frame-top))
    ;; Taille en pixels (3e argument t = pixels)
    (when (and (numberp metal-frame-px-width) (numberp metal-frame-px-height))
      (set-frame-size frame metal-frame-px-width metal-frame-px-height t))
    ;; Fullscreen a la fin
    (when metal-frame-fullscreen
      (set-frame-parameter frame 'fullscreen metal-frame-fullscreen))))

(defun metal-prefs-load ()
  "Charge les preferences sauvegardees."
  (when (file-exists-p metal-prefs-file)
    (load metal-prefs-file t t)))


(defun metal-prefs-save ()
  "Sauvegarde les preferences (variables + geometrie du frame).
Ne sauvegarde la position/taille que si les valeurs sont numeriques
(evite les symboles comme + qui causent des erreurs au rechargement)."
  (metal-frame--lire-geom)
  (with-temp-file metal-prefs-file
    (insert ";; Preferences MetalEmacs - genere automatiquement\n")
    (insert (format "(setq metal-font-size-offset %d)\n" metal-font-size-offset))
    ;; Largeur Treemacs
    (insert (format "(setq metal-treemacs-width %d)\n" metal-treemacs-width))
    ;; Position: seulement si numerique (pas de symboles comme +)
    (when (numberp metal-frame-left)
      (insert (format "(setq metal-frame-left %d)\n" metal-frame-left)))
    (when (numberp metal-frame-top)
      (insert (format "(setq metal-frame-top %d)\n" metal-frame-top)))
    ;; Taille: seulement si numerique et raisonnable
    (when (and (numberp metal-frame-px-width) (> metal-frame-px-width 100))
      (insert (format "(setq metal-frame-px-width %d)\n" metal-frame-px-width)))
    (when (and (numberp metal-frame-px-height) (> metal-frame-px-height 100))
      (insert (format "(setq metal-frame-px-height %d)\n" metal-frame-px-height)))
    ;; Fullscreen: quoter le symbole (maximized, fullboth, etc.)
    (insert (format "(setq metal-frame-fullscreen %s)\n"
                    (if metal-frame-fullscreen
                        (format "'%s" metal-frame-fullscreen)
                      "nil")))))

(defun metal-prefs-save-all ()
  "Sauvegarde toutes les preferences MetalEmacs."
  (interactive)
  (metal-prefs-save))

(defun metal-prefs-load-all ()
  "Charge toutes les preferences MetalEmacs."
  (metal-prefs-load))

;; ------------------------------------------------------------
;; Calcul de la hauteur de police
;; ------------------------------------------------------------

(defun metal-font-height (&optional _frame)
  "Retourne la hauteur de police: base (120) + offset utilisateur.
L'argument FRAME est ignore (garde pour compatibilite)."
  (+ metal-font-base metal-font-size-offset))

(defun metal-font-appliquer (&optional frame)
  "Applique la hauteur calculee a la police par defaut."
  (interactive)
  (set-face-attribute 'default frame :height (metal-font-height frame)))

;; ------------------------------------------------------------
;; Commandes utilisateur (offset) + raccourcis
;; ------------------------------------------------------------

(defun metal-font-increase ()
  "Augmente la taille des polices de 10 (1pt)."
  (interactive)
  (setq metal-font-size-offset (+ metal-font-size-offset 10))
  (metal-setup-fonts)
  (metal-prefs-save-all)
  (message "Taille police: %d" (metal-font-height)))

(defun metal-font-decrease ()
  "Diminue la taille des polices de 10 (1pt)."
  (interactive)
  (setq metal-font-size-offset (- metal-font-size-offset 10))
  (metal-setup-fonts)
  (metal-prefs-save-all)
  (message "Taille police: %d" (metal-font-height)))

(defun metal-font-reset ()
  "Reinitialise la taille des polices a la valeur de base (120)."
  (interactive)
  (setq metal-font-size-offset 0)
  (metal-setup-fonts)
  (metal-prefs-save-all)
  (message "Taille police reinitialisee: %d" (metal-font-height)))

(global-set-key (kbd "C-+") #'metal-font-increase)
(global-set-key (kbd "C--") #'metal-font-decrease)
(global-set-key (kbd "C-0") #'metal-font-reset)

;; ------------------------------------------------------------
;; Application des polices (interface + code)
;; ------------------------------------------------------------

(defun metal-setup-fonts ()
  "Configurer les polices pour MetalEmacs."
  (let* ((prop-font (cond
                     ((eq system-type 'darwin) "Helvetica Neue")   ;; Mac
                     ((eq system-type 'windows-nt) "Segoe UI")     ;; Windows
                     (t "Sans Serif")))                            ;; Linux
         (mono-font (cond
                     ((eq system-type 'darwin) "Menlo")            ;; Mac
                     ((eq system-type 'windows-nt) "Consolas")     ;; Windows
                     (t "DejaVu Sans Mono")))                      ;; Linux
         (font-height (metal-font-height)))

    ;; Police par defaut (monospace pour le code)
    (set-face-attribute 'default nil
                        :family mono-font
                        :height font-height)

    ;; Police proportionnelle (pour l interface)
    (set-face-attribute 'variable-pitch nil
                        :family prop-font
                        :height font-height)

    ;; Appliquer aux elements d interface (faces toujours presentes)
    (dolist (face '(header-line
                    mode-line
                    mode-line-inactive))
      (when (facep face)
        (set-face-attribute face nil :family prop-font :height font-height)))

    ;; Tab-line : seulement quand tab-line est charge (sinon faces absentes)
    (with-eval-after-load 'tab-line
      (dolist (face '(tab-line
                      tab-line-tab
                      tab-line-tab-current
                      tab-line-tab-inactive))
        (when (facep face)
          (set-face-attribute face nil :family prop-font :height font-height))))

    ;; Mettre a jour Treemacs si charge (tous les systemes)
    (when (featurep 'treemacs)
      (dolist (face '(treemacs-root-face
                      treemacs-root-unreadable-face
                      treemacs-root-remote-face
                      treemacs-directory-face
                      treemacs-file-face
                      treemacs-git-modified-face
                      treemacs-git-untracked-face
                      treemacs-git-added-face
                      treemacs-git-ignored-face
                      treemacs-git-conflict-face
                      treemacs-tags-face))
        (when (facep face)
          (set-face-attribute face nil :family mono-font :height font-height))))
    (when (fboundp 'metal-treemacs--update-line-spacing)
      (metal-treemacs--update-line-spacing))

    (message "Polices: %s / %s (taille: %d)" prop-font mono-font font-height)))

;; ------------------------------------------------------------
;; Demarrage / Theme / Sauvegardes
;; ------------------------------------------------------------

;; Charger les preferences (offset) des le demarrage
(metal-prefs-load-all)


;; Restaurer taille/position du frame APRES affichage complet (plus fiable)
(add-hook 'window-setup-hook
          (lambda ()
            (run-at-time 0 nil #'metal-frame-appliquer-geom)))

;; Si Emacs cree d autres frames (daemon, emacsclient, etc.)
(add-hook 'after-make-frame-functions
          (lambda (f)
            (with-selected-frame f
              (run-at-time 0 nil (lambda () (metal-frame-appliquer-geom f))))))

;; Appliquer les polices au demarrage
(add-hook 'after-init-hook #'metal-setup-fonts)

;; Appliquer les polices quand Treemacs est charge
(with-eval-after-load 'treemacs
  (metal-setup-fonts))

;; Reappliquer apres changement de theme
(add-hook 'after-load-theme-hook #'metal-setup-fonts)

;; Sauver a la sortie (offset + frame)
(add-hook 'kill-emacs-hook #'metal-prefs-save-all)

;; Optionnel: sauvegarder aussi quand Emacs perd le focus
(add-hook 'focus-out-hook #'metal-prefs-save-all)

;; fin polices


(use-package recentf
  :init
  (setq recentf-max-saved-items 50
        recentf-auto-cleanup 'never)
  :config
  (recentf-mode 1))


;; Petites fonctions/utilitaires communs
(defun metal/pdf-sync-colors (&rest _)
  "Calquer les couleurs PDF sur le theme actif."
  (setq pdf-view-midnight-colors
        (cons (face-foreground 'default nil t)
              (face-background 'default nil t))))

(add-hook 'pdf-view-mode-hook
          (lambda ()
            (metal/pdf-sync-colors)
            (pdf-view-midnight-minor-mode 1)   ;; recoloriage actif
            (pdf-view-redisplay t)))

(advice-add 'load-theme :after #'metal/pdf-sync-colors)

;; Forcer tab-line-mode dans les PDF (surtout pour Windows)
(add-hook 'pdf-view-mode-hook
          (lambda ()
            (setq-local tab-line-exclude nil)
            (tab-line-mode 1)))

;; === PDF-TOOLS ===
(if (eq system-type 'windows-nt)
    (use-package pdf-tools
      :init
      (setenv "PATH" (concat "~/.emacs.d/pdf-tools/;" (getenv "PATH")))
      (add-to-list 'exec-path "~/.emacs.d/pdf-tools/")
      :custom
      (pdf-info-epdfinfo-program "~/.emacs.d/pdf-tools/epdfinfo.exe")
      :config
      (pdf-tools-install)
      (setq-default pdf-view-display-size 'fit-width))
  (use-package pdf-tools
    :defer t
    :config
    (pdf-tools-install)
    (setq-default pdf-view-display-size 'fit-width)))


(defun jl/init-file-p ()
  (and buffer-file-name
       user-init-file
       (string= (file-truename buffer-file-name)
                (file-truename user-init-file))))

(defun jl/init-safe-write-region (orig-fn &rest args)
  "Simplifie la sauvegarde du fichier init.el pour limiter les blocages."
  (if (jl/init-file-p)
      (let ((before-save-hook nil)
            (after-save-hook  nil)
            (write-file-functions nil)
            (file-name-handler-alist nil)
            (auto-save-visited-mode nil)
            (auto-save-default nil)
            (inhibit-redisplay t)
            (inhibit-message t)
            ;; Eviter les fsync bloquants
            (write-region-inhibit-fsync t)
            ;; Eviter des copies/renames lourds
            (file-precious-flag nil)
            (backup-by-copying nil)
            ;; Eviter que le GC intervienne pendant le save
            (gc-cons-threshold most-positive-fixnum))
        (apply orig-fn args))
    (apply orig-fn args)))

(advice-add 'basic-save-buffer :around #'jl/init-safe-write-region)


(use-package highlight-indent-guides
  :hook (prog-mode . highlight-indent-guides-mode)
  :config
  (setq highlight-indent-guides-method 'character))


;; Reveal


(add-hook 'pdf-view-mode-hook (lambda () (auto-revert-mode 1)))

(global-visual-line-mode 1)

(require 'printing)
(pr-update-menus)


;; ===============================
;;  METAL-DEPS - Assistant d'installation des dépendances
;; ===============================

;; Charger metal-deps.el depuis le répertoire de configuration
(add-to-list 'load-path user-emacs-directory)
(require 'metal-deps)

;; ===============================
;;  TREEMACS [EXTERNE]
;; ===============================
(require 'metal-treemacs)

;; Vertico : minibuffer moderne
(use-package vertico
  :init
  (vertico-mode))

;; Marginalia : infos contextuelles dans les menus
(use-package marginalia
  :init
  (marginalia-mode))

;; ;; Orderless: complétion flexible
(use-package orderless
  :custom
  (completion-styles '(basic partial-completion orderless))
  (completion-category-defaults nil)
  :config
  (setq orderless-component-separator " *& *"))


;; ============================================================
;; METAL SEARCH & REPLACE
;; - C-s : recherche (consult-line)
;; - C-r : recherche/remplacement visuel (visual-regexp)
;; - C-e : iedit depuis consult (remplacer toutes les occurrences)
;; ============================================================

;; Consult : recherche moderne
(use-package consult
  :bind (("C-s" . consult-line)))

;; Visual-regexp : remplacement avec preview en temps réel
;; Note: utilise la syntaxe regex Emacs (ex: théories\? pour théorie/théories)
(use-package visual-regexp
  :bind (("C-r" . query-replace-regexp)))

;; Iedit : édition multiple simultanée
(use-package iedit)

;; --- Iedit depuis Consult (C-e) ---

(defvar metal-iedit--pending nil
  "Motif en attente pour demarrer iedit apres sortie du minibuffer.")

(defvar metal-iedit--pending-window nil
  "Fenetre a re-selectionner apres sortie du minibuffer.")

(defun metal-iedit--start-pending ()
  "Demarre iedit si un motif est en attente."
  (when metal-iedit--pending
    (let ((pattern metal-iedit--pending)
          (win metal-iedit--pending-window))
      (setq metal-iedit--pending nil
            metal-iedit--pending-window nil)
      (when (window-live-p win)
        (select-window win))
      (when (and (stringp pattern) (> (length pattern) 0))
        (iedit-start pattern (point-min) (point-max))))))

(defun metal-iedit-from-consult ()
  "Prend le motif saisi dans Consult et lance iedit."
  (interactive)
  (if (minibufferp)
      (progn
        (setq metal-iedit--pending (minibuffer-contents-no-properties)
              metal-iedit--pending-window (minibuffer-selected-window))
        (add-hook 'minibuffer-exit-hook #'metal-iedit--start-pending 0 t)
        (abort-recursive-edit))
    ;; Hors minibuffer : demander le motif
    (let ((pattern (read-string "Iedit (motif) : "
                                (or (thing-at-point 'symbol t)
                                    (thing-at-point 'word t)
                                    ""))))
      (when (> (length pattern) 0)
        (iedit-start pattern (point-min) (point-max))))))

;; C-e dans le minibuffer pour iedit
(define-key minibuffer-local-map (kbd "C-e") #'metal-iedit-from-consult)


(defun mon/configure-tab-indentation ()
  "TAB/S-TAB : décale via mes fonctions custom, sauf en Org/Markdown."
  (unless (or (derived-mode-p 'org-mode 'markdown-mode)
              (minibufferp))
    (local-set-key (kbd "<tab>")   #'metal-shift-right-at-point-or-region)
    (local-set-key (kbd "TAB")     #'metal-shift-right-at-point-or-region)
    (local-set-key (kbd "<S-tab>") #'metal-shift-left-at-point-or-region)
    (local-set-key [backtab]       #'metal-shift-left-at-point-or-region)))

(add-hook 'prog-mode-hook #'mon/configure-tab-indentation)
(add-hook 'text-mode-hook
          (lambda ()
            (unless (derived-mode-p 'org-mode)
              (mon/configure-tab-indentation))))

;; Configuration de base - FIN

;; Configuration pour tous les modes de programmation

(add-hook 'prog-mode-hook 'display-line-numbers-mode )

(add-hook 'prog-mode-hook
          (lambda ()
            (auto-fill-mode 1)
            (setq comment-auto-fill-only-comments t)
            (setq comment-multi-line t)
            (setq fill-column 79)))


;; Configuration CSV mode

(use-package csv-mode
  :mode (".tsv" ".csv" ".tabular" ".vcf"))

(use-package vlf
  :ensure t
  :config (require 'vlf-setup))

;; Fin CSV mode


;; ===============================
;;  METAL-PYTHON - Configuration Python et Conda
;; ===============================

(require 'metal-python)


;; ===============================
;;  METAL-PROLOG - Configuration SWI-Prolog
;; ===============================

(require 'metal-prolog)

;; ChatGPT - Début

(defun chatgpt ()
  "Ouvre ChatGPT (web) dans un navigateur externe avec le code sélectionné ou la ligne courante copié dans le presse-papiers, suivi d'une consigne."
  (interactive)
  (let* ((code (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (thing-at-point 'line t)))
         (texte-a-copier (concat code "\n\nExplique ce code."))
         (url "https://chat.openai.com"))
    (kill-new texte-a-copier)
    (browse-url url)
    (message "✅ Code copié. ChatGPT ouvert dans le navigateur. Collez-le avec Ctrl-V ou Cmd-V.")))

;; ChatGPT - Fin

(define-key comint-mode-map [up] 'comint-previous-input)
(define-key comint-mode-map [down] 'comint-next-input)


;; ===============================
;;  METAL-ORG - Configuration Org-mode
;; ===============================

;; Remappe les S-<flèche> d'Org vers C-S-<flèche> dans les contextes spéciaux
;; (TODO, priorité, timestamps, tableaux). Doit être défini AVANT le chargement
;; d'Org pour être pris en compte.
;; Résultat :
;;   S-<flèche>    → metal-buf-move-* (déplacement de buffer global)
;;   C-S-<flèche>  → commandes contextuelles Org (cycler TODO, modifier date…)
(setq org-replace-disputed-keys t)

(require 'metal-org)

;; (require 'metal-securite)

(use-package yasnippet
  :ensure t
  :demand t
  :config
  (yas-reload-all)
  (yas-global-mode 1))   ;; active YAS dans tous les buffers

(global-set-key [f10] 'yas-insert-snippet)


;; Début Onglets

(use-package powerline)
(defvar my/tab-height 22)
(defvar my/tab-left (powerline-wave-right 'tab-line nil my/tab-height))
(defvar my/tab-right (powerline-wave-left nil 'tab-line my/tab-height))

(defun my/tab-line-tab-name-buffer (buffer &optional _buffers)
  (powerline-render (list my/tab-left
                          (format " %s  " (buffer-name buffer))
                          my/tab-right)))
(setq tab-line-tab-name-function #'my/tab-line-tab-name-buffer)
(setq tab-line-new-button-show nil)
;; (setq tab-line-close-button-show nil)

(define-advice tab-line-close-tab (:override (&optional e))
  "Ferme l'onglet actif.
Si l'onglet apparait dans une autre fenêtre, ferme l'onglet en utilisant la fonction `bury-buffer'.
Si l'onglet est unique, ferme l'onglet avec la fonction `kill-buffer`.
Finalement, si c'est le dernier onglet d'une fenêtre,la fenêtre est fermée avec la fonction `delete-window`."
  (interactive "e")
  (let* ((posnp (event-start e))
         (window (posn-window posnp))
         (buffer (get-pos-property 1 'tab (car (posn-string posnp)))))
    (with-selected-window window
      (let ((tab-list (tab-line-tabs-window-buffers))
            (buffer-list (flatten-list
                          (seq-reduce (lambda (list window)
                                        (select-window window t)
                                        (cons (tab-line-tabs-window-buffers) list))
                                      (window-list) nil))))
        (select-window window)
        (if (> (seq-count (lambda (b) (eq b buffer)) buffer-list) 1)
            (progn
              (if (eq buffer (current-buffer))
                  (bury-buffer)
                (set-window-prev-buffers window (assq-delete-all buffer (window-prev-buffers)))
                (set-window-next-buffers window (delq buffer (window-next-buffers))))
              (unless (cdr tab-list)
                (ignore-errors (delete-window window))))
          (and (kill-buffer buffer)
               (unless (cdr tab-list)
                 (ignore-errors (delete-window window)))))))
    (force-mode-line-update)))

(global-tab-line-mode)


;; Fin Onglets

(put 'dired-find-alternate-file 'disabled nil)

(defun yank-with-indent ()
  (interactive)
  (let ((indent
         (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
    (message indent)
    (yank)
    (narrow-to-region (mark t) (point))
    (pop-to-mark-command)
    (replace-string "\n" (concat "\n" indent))
    (widen)))

;; (use-package buffer-move
;;   :config
;;      (setq buffer-move-behavior 'move)
;; )


;; (defun metal-buf-move-advice (orig-fn &rest args)
;;   "Après un `buf-move-*', ferme la fenêtre source si le buffer déplacé
;; était le seul jamais affiché dans cette fenêtre."
;;   (let* ((source-window (selected-window))
;;          (source-buffer (window-buffer source-window))
;;          (autre-buffer-dans-historique
;;           (cl-some (lambda (entry)
;;                      (not (eq (car entry) source-buffer)))
;;                    (window-prev-buffers source-window))))
;;     (apply orig-fn args)
;;     (when (and (window-live-p source-window)
;;                (not (eq source-window (selected-window)))
;;                (not (one-window-p))
;;                (not autre-buffer-dans-historique))
;;       (delete-window source-window))))

;; (dolist (fn '(buf-move-up buf-move-down buf-move-left buf-move-right))
;;   (advice-add fn :around #'metal-buf-move-advice))

;; (global-set-key (kbd "<S-up>")     'buf-move-up)
;; (global-set-key (kbd "<S-down>")   'buf-move-down)
;; (global-set-key (kbd "<S-left>")   'buf-move-left)
;; (global-set-key (kbd "<S-right>")  'buf-move-right)

;; Version 2

;; (require 'cl-lib)
;; (require 'windmove)

;; (defun metal-buf-move--usable-window (direction)
;;   "Retourne la fenêtre dans DIRECTION, ou nil s'il n'y en a pas
;; d'exploitable. Exclut minibuffer, fenêtres latérales et dédiées."
;;   (let ((win (condition-case nil
;;                  (windmove-find-other-window direction)
;;                (error nil))))
;;     (and win
;;          (window-live-p win)
;;          (not (window-minibuffer-p win))
;;          (not (window-parameter win 'window-side))
;;          (not (window-dedicated-p win))
;;          win)))

;; (defun metal-buf-move--pick-main-window ()
;;   "Retourne une fenêtre 'main' (ni side, ni dédiée, ni minibuffer).
;; À appeler après un `delete-window' pour garantir qu'on ne splitte
;; pas une side-window comme Treemacs."
;;   (cl-find-if (lambda (w)
;;                 (and (not (window-parameter w 'window-side))
;;                      (not (window-dedicated-p w))
;;                      (not (window-minibuffer-p w))))
;;               (window-list nil 'no-minibuf)))

;; (defun metal-buf-move--vacate-source (source-window source-buffer)
;;   "Affiche un buffer autre que SOURCE-BUFFER dans SOURCE-WINDOW.
;; Préfère le buffer le plus récemment affiché dans cette fenêtre,
;; en ignorant les buffers tués."
;;   (let* ((prev (cl-find-if (lambda (entry)
;;                              (let ((buf (car entry)))
;;                                (and (buffer-live-p buf)
;;                                     (not (eq buf source-buffer)))))
;;                            (window-prev-buffers source-window)))
;;          (replacement (or (and prev (car prev))
;;                           (other-buffer source-buffer t))))
;;     (when (or (null replacement)
;;               (not (buffer-live-p replacement))
;;               (eq replacement source-buffer))
;;       (setq replacement (get-buffer-create "*scratch*")))
;;     (set-window-buffer source-window replacement)))

;; (defun metal-buf-move--forget-buffer (window buffer)
;;   "Retire BUFFER de l'historique (prev et next) de WINDOW."
;;   (set-window-prev-buffers
;;    window
;;    (cl-remove-if (lambda (entry) (eq (car entry) buffer))
;;                  (window-prev-buffers window)))
;;   (set-window-next-buffers
;;    window
;;    (remq buffer (window-next-buffers window))))

;; (defun metal-buf-move--clear-history (window)
;;   "Efface complètement l'historique de WINDOW.
;; À utiliser sur une fenêtre fraîchement créée dont l'historique
;; hérité de la fenêtre parente ne reflète pas la réalité."
;;   (set-window-prev-buffers window nil)
;;   (set-window-next-buffers window nil))

;; (defun metal-buf-move (direction-windmove direction-split)
;;   "Déplace le buffer courant vers la fenêtre en DIRECTION-WINDMOVE.

;; S'il n'y a pas de fenêtre cible exploitable (side-windows,
;; minibuffer et fenêtres dédiées sont exclus) :
;; - si la source ne contient que ce buffer et qu'il y a d'autres
;;   fenêtres main, on supprime la source puis on splitte une
;;   fenêtre main dans la direction voulue ;
;; - sinon on splitte la source dans la direction.

;; S'il y a une cible, on y déplace le buffer et on ferme la source
;; si ce buffer était le seul jamais affiché dans la source. Le
;; buffer est retiré de l'historique de la source pour éviter les
;; onglets fantômes (tab-line, centaur-tabs basés sur
;; `window-prev-buffers')."
;;   (let* ((source-window (selected-window))
;;          (source-buffer (window-buffer source-window))
;;          (target-window (metal-buf-move--usable-window direction-windmove))
;;          (autre-buffer-dans-historique
;;           (cl-some (lambda (entry)
;;                      (let ((buf (car entry)))
;;                        (and (buffer-live-p buf)
;;                             (not (eq buf source-buffer)))))
;;                    (window-prev-buffers source-window))))
;;     (cond
;;      ;; Cas 1 : aucune fenêtre cible -> création
;;      ((null target-window)
;;       (cond
;;        ;; 1a : source a d'autres buffers OU c'est la seule fenêtre
;;        ((or (one-window-p) autre-buffer-dans-historique)
;;         (let ((new-window (split-window source-window nil direction-split)))
;;           (set-window-buffer new-window source-buffer)
;;           (metal-buf-move--clear-history new-window)
;;           (metal-buf-move--vacate-source source-window source-buffer)
;;           (metal-buf-move--forget-buffer source-window source-buffer)
;;           (select-window new-window)))
;;        ;; 1b : source n'a que ce buffer et d'autres fenêtres existent
;;        (t
;;         (delete-window source-window)
;;         ;; Après delete-window, Emacs peut sélectionner une side-window
;;         ;; (Treemacs). On bascule sur une fenêtre main avant de splitter.
;;         (let ((anchor (or (metal-buf-move--pick-main-window)
;;                           (selected-window))))
;;           (select-window anchor)
;;           (let ((new-window (split-window anchor nil direction-split)))
;;             (set-window-buffer new-window source-buffer)
;;             (metal-buf-move--clear-history new-window)
;;             (select-window new-window))))))
;;      ;; Cas 2 : fenêtre cible existante
;;      (t
;;       (set-window-buffer target-window source-buffer)
;;       (metal-buf-move--vacate-source source-window source-buffer)
;;       (metal-buf-move--forget-buffer source-window source-buffer)
;;       (select-window target-window)
;;       (when (and (window-live-p source-window)
;;                  (not (one-window-p))
;;                  (not autre-buffer-dans-historique))
;;         (delete-window source-window))))))

;; (defun metal-buf-move-up ()    (interactive) (metal-buf-move 'up    'above))
;; (defun metal-buf-move-down ()  (interactive) (metal-buf-move 'down  'below))
;; (defun metal-buf-move-left ()  (interactive) (metal-buf-move 'left  'left))
;; (defun metal-buf-move-right () (interactive) (metal-buf-move 'right 'right))

;; (global-set-key (kbd "<S-up>")    #'metal-buf-move-up)
;; (global-set-key (kbd "<S-down>")  #'metal-buf-move-down)
;; (global-set-key (kbd "<S-left>")  #'metal-buf-move-left)
;; (global-set-key (kbd "<S-right>") #'metal-buf-move-right)


(require 'cl-lib)
(require 'windmove)

;;; Predicats sur les fenêtres

(defun metal-buf-move--main-window-p (window)
  "Retourne t si WINDOW est une fenêtre 'main' (ni side ni minibuffer)."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))))

(defun metal-buf-move--main-windows (&optional frame)
  "Liste des fenêtres main de FRAME."
  (cl-remove-if-not #'metal-buf-move--main-window-p
                    (window-list frame 'no-minibuf)))

(defun metal-buf-move--last-main-window-p (window)
  "Retourne t si WINDOW est la seule fenêtre main de sa frame.
Remplace (one-window-p) qui ne sait pas ignorer les side-windows."
  (let ((mains (metal-buf-move--main-windows (window-frame window))))
    (and (memq window mains)
         (null (cdr mains)))))

(defun metal-buf-move--usable-window (direction)
  "Fenêtre dans DIRECTION exploitable comme cible, ou nil."
  (let ((win (condition-case nil
                 (windmove-find-other-window direction)
               (error nil))))
    (and win
         (metal-buf-move--main-window-p win)
         (not (window-dedicated-p win))
         win)))

(defun metal-buf-move--pick-main-window ()
  "Retourne une fenêtre main non-dédiée, ou nil."
  (cl-find-if (lambda (w) (not (window-dedicated-p w)))
              (metal-buf-move--main-windows)))

;;; Manipulation des buffers et historiques

(defun metal-buf-move--vacate-source (source-window source-buffer)
  "Affiche un buffer autre que SOURCE-BUFFER dans SOURCE-WINDOW."
  (let* ((prev (cl-find-if (lambda (entry)
                             (let ((buf (car entry)))
                               (and (buffer-live-p buf)
                                    (not (eq buf source-buffer)))))
                           (window-prev-buffers source-window)))
         (replacement (or (and prev (car prev))
                          (other-buffer source-buffer t))))
    (when (or (null replacement)
              (not (buffer-live-p replacement))
              (eq replacement source-buffer))
      (setq replacement (get-buffer-create "*scratch*")))
    (set-window-buffer source-window replacement)))

(defun metal-buf-move--forget-buffer (window buffer)
  "Retire BUFFER de l'historique (prev et next) de WINDOW."
  (when (window-live-p window)
    (set-window-prev-buffers
     window
     (cl-remove-if (lambda (entry) (eq (car entry) buffer))
                   (window-prev-buffers window)))
    (set-window-next-buffers
     window
     (remq buffer (window-next-buffers window)))))

(defun metal-buf-move--forget-buffer-everywhere (buffer keep-window)
  "Retire BUFFER de l'historique de toutes les fenêtres sauf KEEP-WINDOW.
C'est ce qui évite qu'un buffer ayant transité par plusieurs fenêtres
laisse des onglets fantômes un peu partout."
  (dolist (win (window-list nil 'no-minibuf))
    (unless (eq win keep-window)
      (metal-buf-move--forget-buffer win buffer))))

(defun metal-buf-move--clear-history (window)
  "Efface complètement l'historique de WINDOW."
  (when (window-live-p window)
    (set-window-prev-buffers window nil)
    (set-window-next-buffers window nil)))

(defun metal-buf-move--safe-delete-window (window)
  "Supprime WINDOW sauf si c'est la dernière fenêtre main.
Retourne t en cas de suppression effective, nil sinon."
  (when (and (window-live-p window)
             (not (metal-buf-move--last-main-window-p window)))
    (condition-case nil
        (progn (delete-window window) t)
      (error nil))))

;;; Opérations composées

(defun metal-buf-move--split-source-and-move
    (source-window source-buffer direction-split)
  (let ((new-window (split-window source-window nil direction-split)))
    (set-window-buffer new-window source-buffer)
    (metal-buf-move--clear-history new-window)
    (metal-buf-move--vacate-source source-window source-buffer)
    (metal-buf-move--forget-buffer source-window source-buffer)
    (metal-buf-move--forget-buffer-everywhere source-buffer new-window)
    (select-window new-window)))

(defun metal-buf-move--split-anchor-and-move (source-buffer direction-split)
  (let* ((anchor (or (metal-buf-move--pick-main-window)
                     (selected-window)))
         (new-window (split-window anchor nil direction-split)))
    (set-window-buffer new-window source-buffer)
    (metal-buf-move--clear-history new-window)
    (metal-buf-move--forget-buffer-everywhere source-buffer new-window)
    (select-window new-window)))

;;; Commande principale

(defun metal-buf-move (direction-windmove direction-split)
  "Déplace le buffer courant vers la fenêtre en DIRECTION-WINDMOVE.

En l'absence de cible exploitable (side-windows, dédiées et
minibuffer exclus), crée une fenêtre. Si la source est la
dernière fenêtre main ou a un historique à préserver, on la
splitte ; sinon on la supprime et on splitte une autre main.

Avec cible, on déplace le buffer et ferme la source si elle
n'héberge plus rien d'autre, sauf si c'est la dernière main.

Les historiques des autres fenêtres sont nettoyés du buffer
déplacé pour éviter les onglets fantômes."
  (let* ((source-window (selected-window))
         (source-buffer (window-buffer source-window))
         (target-window (metal-buf-move--usable-window direction-windmove))
         (autre-buffer-dans-historique
          (cl-some (lambda (entry)
                     (let ((buf (car entry)))
                       (and (buffer-live-p buf)
                            (not (eq buf source-buffer)))))
                   (window-prev-buffers source-window)))
         (source-is-last-main
          (metal-buf-move--last-main-window-p source-window)))
    (cond
     ;; Cas 1 : aucune cible -> création
     ((null target-window)
      (cond
       ;; 1a : split de la source (historique riche, dernière main, ou seule)
       ((or (one-window-p)
            source-is-last-main
            autre-buffer-dans-historique)
        (metal-buf-move--split-source-and-move
         source-window source-buffer direction-split))
       ;; 1b : suppression de la source + split ailleurs
       (t
        (if (metal-buf-move--safe-delete-window source-window)
            (metal-buf-move--split-anchor-and-move
             source-buffer direction-split)
          ;; Fallback défensif : suppression impossible, on splitte la source
          (metal-buf-move--split-source-and-move
           source-window source-buffer direction-split)))))
     ;; Cas 2 : cible existante -> déplacement
     (t
      (set-window-buffer target-window source-buffer)
      (metal-buf-move--vacate-source source-window source-buffer)
      (metal-buf-move--forget-buffer source-window source-buffer)
      (metal-buf-move--forget-buffer-everywhere source-buffer target-window)
      (select-window target-window)
      (when (and (window-live-p source-window)
                 (not autre-buffer-dans-historique))
        (metal-buf-move--safe-delete-window source-window))))))

(defun metal-buf-move-up ()    (interactive) (metal-buf-move 'up    'above))
(defun metal-buf-move-down ()  (interactive) (metal-buf-move 'down  'below))
(defun metal-buf-move-left ()  (interactive) (metal-buf-move 'left  'left))
(defun metal-buf-move-right () (interactive) (metal-buf-move 'right 'right))

(global-set-key (kbd "<S-up>")    #'metal-buf-move-up)
(global-set-key (kbd "<S-down>")  #'metal-buf-move-down)
(global-set-key (kbd "<S-left>")  #'metal-buf-move-left)
(global-set-key (kbd "<S-right>") #'metal-buf-move-right)

(add-to-list 'exec-path "~/.emacs.d/zip300xn")

(setq ns-pop-up-frames nil)  ;; Empêche la création de nouveaux frames

;; *******************************************
;; Mise à jour de .emacs.d :
;;    Dans Treemacs, sélectionner emacs.d.zip, .emacs.d.zip,
;;    le dossier .emacs.d directement, ou n'importe quel
;;    dossier contenant un sous-dossier .emacs.d
;;    puis appuyer sur M (Shift+M)
;; *******************************************
(defun metal-mettre-a-jour-emacs-d ()
  "Met à jour .emacs.d depuis un ZIP ou un dossier sélectionné dans Treemacs.
Accepte les sources suivantes :
  - Un fichier emacs.d.zip ou .emacs.d.zip (sera extrait)
  - Le dossier .emacs.d directement
  - N'importe quel dossier contenant un sous-dossier .emacs.d

Processus :
1. Vérifie la source sélectionnée
2. Crée un backup (.emacs.d.backup-YYYYMMDD-HHMMSS)
3. Extrait ou copie le nouveau .emacs.d
4. Remplace la configuration actuelle
5. Propose de redémarrer Emacs

Raccourci Treemacs : M (Shift+M)"
  (interactive)
  (let* ((bouton (treemacs-current-button))
         (chemin (and bouton (treemacs-button-get bouton :path))))
    ;; Vérification 1 : quelque chose est sélectionné
    (unless chemin
      (user-error "Placez le curseur sur un fichier ou dossier dans Treemacs"))

    ;; Déterminer le type de source
    (let* ((nom (file-name-nondirectory (directory-file-name chemin)))
           ;; ZIP : accepter emacs.d.zip ou .emacs.d.zip
           (est-zip (and (not (file-directory-p chemin))
                         (member nom '("emacs.d.zip" ".emacs.d.zip"))))
           ;; Dossier .emacs.d sélectionné directement
           (est-emacs-d-direct
            (and (file-directory-p chemin)
                 (string-equal nom ".emacs.d")))
           ;; N'importe quel dossier contenant directement .emacs.d
           (est-dossier-avec-emacs-d
            (and (file-directory-p chemin)
                 (not est-emacs-d-direct)
                 (file-directory-p (expand-file-name ".emacs.d" chemin)))))

      ;; Vérification 2 : source valide
      (unless (or est-zip est-emacs-d-direct est-dossier-avec-emacs-d)
        (user-error "Sélectionnez un fichier 'emacs.d.zip' / '.emacs.d.zip', le dossier '.emacs.d', ou un dossier contenant '.emacs.d' (trouvé : %s)" nom))

      ;; Confirmation avant de continuer
      (unless (yes-or-no-p
               (format "⚠️  Cette opération va remplacer votre configuration .emacs.d actuelle.\nSource : %s\nUn backup sera créé automatiquement.\n\nContinuer ? "
                       (abbreviate-file-name chemin)))
        (user-error "Mise à jour annulée"))

      (let* ((unzip (metal--trouver-unzip))
             (emacs-d-dir (expand-file-name user-emacs-directory))
             (parent-dir (file-name-directory (directory-file-name emacs-d-dir)))
             (timestamp (format-time-string "%Y%m%d-%H%M%S"))
             (backup-name (concat ".emacs.d.backup-" timestamp))
             (backup-dir (expand-file-name backup-name parent-dir))
             (temp-dir (make-temp-file "metal-update-" t)))

        (message "🔄 Début de la mise à jour de .emacs.d...")

        ;; Étape 1 : Créer le backup
        (condition-case err
            (progn
              (message "📦 Création du backup : %s..." backup-name)
              (copy-directory emacs-d-dir backup-dir t t t)
              (message "✅ Backup créé avec succès"))
          (error
           (user-error "❌ Échec de la création du backup : %s" (error-message-string err))))

        ;; Étape 2 : Obtenir le nouveau .emacs.d
        (let ((nouveau-emacs-d nil))
          (cond
           ;; Source = emacs.d.zip ou .emacs.d.zip
           (est-zip
            (condition-case err
                (progn
                  (message "📂 Extraction de %s..." nom)
                  (let ((default-directory temp-dir))
                    (with-current-buffer (get-buffer-create "*metal-update*")
                      (erase-buffer)
                      (let ((resultat (call-process unzip nil t t "-o" chemin)))
                        (unless (= 0 resultat)
                          (pop-to-buffer "*metal-update*")
                          (error "Échec de 'unzip' (code %d)" resultat)))))
                  (setq nouveau-emacs-d (expand-file-name ".emacs.d" temp-dir))
                  (message "✅ Extraction réussie"))
              (error
               (ignore-errors (delete-directory temp-dir t))
               (user-error "❌ Échec de l'extraction : %s" (error-message-string err)))))

           ;; Source = dossier .emacs.d sélectionné directement
           (est-emacs-d-direct
            (setq nouveau-emacs-d (directory-file-name chemin))
            (message "📂 Source : dossier .emacs.d direct"))

           ;; Source = dossier quelconque contenant .emacs.d
           (est-dossier-avec-emacs-d
            (setq nouveau-emacs-d (expand-file-name ".emacs.d" chemin))
            (message "📂 Source : dossier %s contenant .emacs.d" nom)))

          ;; Vérification : le .emacs.d existe dans la source
          (unless (and nouveau-emacs-d (file-directory-p nouveau-emacs-d))
            (ignore-errors (delete-directory temp-dir t))
            (user-error "❌ Pas de dossier .emacs.d trouvé dans la source"))

          ;; Étape 3 : Supprimer l'ancien .emacs.d (sans passer par la corbeille)
          (condition-case err
              (let ((metal-securite-inhiber t)
                    (delete-by-moving-to-trash nil))
                (message "🗑️  Suppression de l'ancien .emacs.d...")
                (delete-directory emacs-d-dir t)
                (message "✅ Ancien .emacs.d supprimé"))
            (error
             (ignore-errors (delete-directory temp-dir t))
             (user-error "❌ Échec de la suppression : %s\nBackup disponible : %s"
                        (error-message-string err) backup-dir)))

          ;; Étape 4 : Copier le nouveau .emacs.d
          (condition-case err
              (progn
                (message "📥 Installation du nouveau .emacs.d...")
                (copy-directory nouveau-emacs-d emacs-d-dir t t t)
                (message "✅ Nouveau .emacs.d installé"))
            (error
             (message "❌ Échec de l'installation : %s" (error-message-string err))
             (message "⚠️  RESTAURATION DU BACKUP...")
             (condition-case _restore-err
                 (let ((metal-securite-inhiber t)
                       (delete-by-moving-to-trash nil))
                   (when (file-directory-p emacs-d-dir)
                     (delete-directory emacs-d-dir t))
                   (copy-directory backup-dir emacs-d-dir t t t)
                   (user-error "Installation échouée. Backup restauré automatiquement."))
               (error
                (user-error "❌❌ CRITIQUE : Échec de la restauration ! Backup manuel requis : %s"
                           backup-dir))))))

        ;; Étape 5 : Nettoyage du dossier temporaire (sans corbeille)
        (let ((metal-securite-inhiber t)
              (delete-by-moving-to-trash nil))
          (ignore-errors (delete-directory temp-dir t)))

        ;; Étape 6 : Rafraîchir Treemacs si ouvert
        (when (treemacs-get-local-window)
          (treemacs-refresh))

        ;; Étape 7 : Message final et proposition de redémarrage
        (message "✨ Mise à jour terminée avec succès !")
        (message "📦 Backup disponible : %s" backup-dir)

        (when (yes-or-no-p "🔄 Voulez-vous redémarrer Emacs maintenant pour appliquer les changements ? ")
          (save-some-buffers)
          (kill-emacs))))))

(with-eval-after-load 'treemacs
  (define-key treemacs-mode-map (kbd "M") #'metal-mettre-a-jour-emacs-d))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Bouton "Récents"
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun modeline-bouton-fichiers-recents ()
  "Affiche un bouton  dans la modeline pour recentf."
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'recentf-open-files)
    (propertize
     " 🕐 "
     'mouse-face 'mode-line-highlight
     'local-map map
     'help-echo "Clique pour ouvrir les fichiers recents")))


(setq-default mode-line-format
  (append mode-line-format
          '((:eval (modeline-bouton-fichiers-recents)))))


;; *******************************************
;;  Wikitionnaire
;; *******************************************


  (defun search-wiktionary (word)
  "Rechercher le mot WORD dans le Wiktionnaire et afficher le résultat dans un buffer.
   Si aucun mot n'est sélectionné, utiliser le mot sous le curseur ou permettre la saisie du mot."
  (interactive
   (list (if (use-region-p)
             (buffer-substring-no-properties (region-beginning) (region-end))
           (let ((word-under-cursor (thing-at-point 'word t)))
             (if word-under-cursor
                 word-under-cursor
               (read-string "Rechercher sur Wiktionnaire : "))))))
  (let ((url (concat "https://fr.wiktionary.org/wiki/" (url-hexify-string (downcase word))))
        (buffer-name "*Résultat de Wiktionnairet*"))
    (if (featurep 'xwidget-internal)
        (xwidget-webkit-browse-url url)
        (browse-url url))))


(global-set-key (kbd "C-c w") 'search-wiktionary)

;; ############################################################################
;; Wipipedia
;; ############################################################################

  (defun search-wikipedia (word)
  "Rechercher le mot WORD dans wikipedia et afficher le résultat dans un buffer.
   Si aucun mot n'est sélectionné, utiliser le mot sous le curseur ou permettre la saisie du mot."
  (interactive
   (list (if (use-region-p)
             (buffer-substring-no-properties (region-beginning) (region-end))
           (let ((word-under-cursor (thing-at-point 'word t)))
             (if word-under-cursor
                 word-under-cursor
               (read-string "Rechercher dans Wikipedia : "))))))
  (let ((url (concat "https://fr.wikipedia.org/wiki/" (url-hexify-string (downcase word))))
        (buffer-name "*Résultat de Wikipedia*"))
    (if (featurep 'xwidget-internal)
        (xwidget-webkit-browse-url url)
        (browse-url url))))


(global-set-key (kbd "C-c w") 'search-wiktionary)

;; ##########################################################


(defun metal-python-shell-bascule-position ()
  "Bascule la position du shell Python (bas â†” droite), la rend permanente et (ré)affiche le shell."
  (interactive)
  (let* ((nouveau (if (eq metal-python-shell-position-defaut 'bottom) 'right 'bottom))
         (buf (python-shell-get-buffer)))
    ;; Sauvegarder la préférence
    (setq metal-python-shell-position-defaut nouveau)
    (customize-save-variable 'metal-python-shell-position-defaut nouveau)
    ;; Appliquer la règle dâ€™affichage
    (metal--python-appliquer-regle nouveau)
    ;; Créer le shell si besoin
    (unless (and buf (buffer-live-p buf))
      (run-python)
      (setq buf (python-shell-get-buffer)))
    ;; Repositionner/afficher
    (metal--python-afficher-ou-repositionner buf nouveau)
    (message "✅ Shell Python désormais %s."
             (if (eq nouveau 'bottom) "en bas" "Ã  droite"))))

(defun aide-memoire-python ()
  (interactive)
  (find-file  "~/.emacs.d/AideMemoire-Python.pdf"))



;; (defun my/format-toolbar-button-icon (icon tooltip action)
;;   "Créer un bouton cliquable avec une icône colorée."
;;   (propertize (format " %s " icon)
;;               'mouse-face '(:background "#e0e0e0")
;;               'help-echo tooltip
;;               'keymap (let ((map (make-sparse-keymap)))
;;                         (define-key map [header-line mouse-1] action)
;;                         map)))


(defun documentation-prolog ()
  (interactive)
  (find-file  "~/.emacs.d/SWI-Prolog-9.2.2.pdf"))

(defun prolog-save-consult ()
  "Sauvegarde le buffer courant puis lance `prolog-consult-buffer`."
  (interactive)
  (when (and (buffer-file-name)
             (buffer-modified-p))
    (save-buffer))
  (prolog-consult-file))




;; (defun metal-prolog-shell-bascule-position ()
;;   "Bascule la position du shell Prolog (bas â†” droite), la rend permanente et (ré)affiche le REPL."
;;   (interactive)
;;   (let* ((nouveau (if (eq metal-prolog-shell-position-defaut 'bottom) 'right 'bottom))
;;          (buf (metal--prolog-get-buffer)))
;;     ;; Sauvegarder la préférence
;;     (setq metal-prolog-shell-position-defaut nouveau)
;;     (customize-save-variable 'metal-prolog-shell-position-defaut nouveau)
;;     ;; Appliquer la règle dâ€™affichage
;;     (metal--prolog-appliquer-regle nouveau)
;;     ;; Créer le REPL si besoin
;;     (unless (and buf (buffer-live-p buf))
;;       (run-prolog)
;;       (setq buf (metal--prolog-get-buffer)))
;;     ;; Repositionner/afficher
;;     (metal--prolog-afficher-ou-repositionner buf nouveau)
;;     (message "✅ Shell Prolog désormais %s."
;;              (if (eq nouveau 'bottom) "en bas" "Ã  droite"))))





;; (add-hook 'python-mode-hook #'my/python-header-line)
;; (add-hook 'prolog-mode-hook #'my/prolog-header-line)


(add-to-list 'auto-mode-alist
             (cons "\\.pdf\\'"
                   (cond
                    ((fboundp 'pdf-view-mode) 'pdf-view-mode)
                    ((fboundp 'doc-view-mode) 'doc-view-mode)
                    (t 'fundamental-mode))))

;; (find-file "~/.emacs.d/METAL.pdf")


(use-package shackle
  :config
  (setq shackle-rules
        '(
          ;; Pour les résultats de consult
          ("\\*Consult.*\\*" :align below :size 0.4 :select t)

          ;; Pour les occur classiques aussi
          ("\\*Occur\\*" :align below :size 0.4 :select t)

          ;; Autres suggestions
          ("\\*Help\\*" :align below :size 0.3 :select t)
          ("\\*Warnings\\*" :align below :size 0.3 :select nil)
          ))
  (shackle-mode 1))


;; ===============================
;;  METAL-QUARTO - Mode Quarto
;; ===============================

(load (expand-file-name "metal-quarto.el" user-emacs-directory))


;; Calendrier


(load (expand-file-name "metal-calendrier.el" user-emacs-directory))


;; Calendrier Fin


;; ===============================
;;  METAL-DASHBOARD - Tableau de bord
;; ===============================

(load (expand-file-name "metal-dashboard.el" user-emacs-directory))


;; ===============================
;;  METAL-TREEMACS - Gestionnaire de fichiers
;;  (inclut gestion USB et compression ZIP)
;; ===============================

(load (expand-file-name "metal-treemacs.el" user-emacs-directory))

(require 'metal-securite)


;; (defun trace-save-hooks ()
;;   (message "before-save-hook triggered"))

;; (add-hook 'before-save-hook #'trace-save-hooks)



;;; Fonctions d'impression


;;; Metal-Emacs Print - Dialogue système natif avec couleurs
(use-package htmlize
  :ensure t)

(use-package deadgrep
  :if (executable-find "rg")
  :bind ("C-c g" . deadgrep))

(defun metal/print-buffer ()
  "Ouvre le dialogue d'impression système (avec couleurs pour le code)."
  (interactive)
  (let ((file (buffer-file-name)))
    (cond
     ;; PDF : ouvrir directement
     ((and file (string-suffix-p ".pdf" file t))
      (metal/open-print-dialog file))
     ;; Code/Texte : exporter en HTML pour conserver les couleurs
     (t
      (let* ((buffer-name (if file (file-name-nondirectory file) (buffer-name)))
             (html-file (expand-file-name (concat buffer-name ".html") temporary-file-directory)))
        (metal/htmlize-buffer-to-file html-file buffer-name)
        (metal/open-print-dialog html-file))))))

(defun metal/open-print-dialog (file)
  "Ouvre le dialogue d'impression système pour FILE."
  (cond
   ((eq system-type 'darwin)
    (shell-command (format "open %s" (shell-quote-argument file)))
    (run-at-time 0.5 nil 
      (lambda () (shell-command "osascript -e 'tell application \"System Events\" to keystroke \"p\" using command down'"))))
   ((eq system-type 'windows-nt)
    (shell-command (format "start \"\" \"%s\"" file)))
   (t
    (shell-command (format "xdg-open %s" (shell-quote-argument file))))))

(defun metal/htmlize-buffer-to-file (file title)
  "Exporte le buffer en HTML avec couleurs et TITLE comme nom."
  (let ((html-buffer (htmlize-buffer)))
    (with-current-buffer html-buffer
      ;; Ajouter CSS pour cacher l'URL dans le pied de page Ã  l'impression
      (goto-char (point-min))
      (when (re-search-forward "</head>" nil t)
        (replace-match "<style>@page { margin: 1cm; } @media print { footer, .url { display: none; } }</style></head>"))
      ;; Remplacer le titre
      (goto-char (point-min))
      (when (re-search-forward "<title>\\(.*\\)</title>" nil t)
        (replace-match (format "<title>%s</title>" title)))
      (write-file file))
    (kill-buffer html-buffer)))

;;; Remplacer le menu Print sous File
(with-eval-after-load 'menu-bar
  (define-key global-map [menu-bar file print] 
    '(menu-item "Imprimer..." metal/print-buffer :keys "C-c p p")))

;;; Raccourci
(global-set-key (kbd "C-c p p") #'metal/print-buffer)

;; Rendre la fenêtre visible avec tout chargé et afficher le dashboard
(add-hook 'prog-mode-hook
          (lambda ()
            (auto-fill-mode 1)
            (setq comment-auto-fill-only-comments t)
            (setq comment-multi-line t)
            (setq fill-column 79)
            (setq comment-column 0)))

;; Forcer le dashboard après un court délai (après que tout soit chargé)
(run-with-idle-timer
 0.1 nil
 (lambda ()
   (when (fboundp 'metal-dashboard-open)
     (let ((dash-buf (metal-dashboard-open)))
       (when dash-buf
         ;; Trouver la fenêtre qui n'est pas treemacs
         (catch 'done
           (dolist (win (window-list))
             (unless (string-match-p "Treemacs" (buffer-name (window-buffer win)))
               (select-window win)
               (switch-to-buffer dash-buf)
               (throw 'done nil)))))))))

(defun metal-preparer-distribution ()
  "Prépare une distribution MetalEmacs en ZIP dans le dossier sélectionné dans Treemacs."
  (interactive)
  (let* ((dest-base
          (let* ((tb (treemacs-get-local-buffer))
                 (node (when tb
                         (with-current-buffer tb
                           (save-excursion
                             (treemacs--prop-at-point :path))))))
            (cond
             ((null node)
              (user-error "Cliquez d'abord sur un dossier dans Treemacs"))
             ((file-directory-p node)
              (file-name-as-directory node))
             (t
              (file-name-directory node)))))
         (source (expand-file-name "~/.emacs.d/"))
         (timestamp (format-time-string "%Y%m%d"))
         (dest-name (format "MetalEmacs-%s" timestamp))
         (dist-dir (expand-file-name (concat dest-name "/") dest-base))
         (emacs-dir (expand-file-name ".emacs.d/" dist-dir))
         (zip-file (expand-file-name "emacs.d.zip" dist-dir))
         ;; Fichiers .el : tous ceux à la racine sauf les exclus
         (el-exclus '("metal-prefs.el" "metal-custom.el"))
         (fichiers-el (cl-remove-if
                       (lambda (f) (member (file-name-nondirectory f) el-exclus))
                       (directory-files source nil "^.*\\.el$")))
         ;; Autres fichiers à copier (non-.el)
         (fichiers-autres '("metal-news.org"
                            "Document.cfg" "METAL.cfg" "Presentation.cfg"
                            "MetalEmacs-lisez-moi.txt"
                            "TAL-MacIntel-Windows-Linux.yml" "TAL-MacM.yml"
                            "METAL.org" "METAL.pdf"
                            "AideMemoire-Python.pdf" "orgcard.pdf"
                            "Quarto_Cheat_Sheet.pdf" "SWI-Prolog-9.2.2.pdf"))
         ;; Tous les fichiers à copier
         (fichiers (append fichiers-el fichiers-autres))
         ;; Dossiers à copier intégralement
         (dossiers '("icons" "modeles" "snippets" ".cache"
                     "zip" "PortableGit" "quarto" "pdf-tools" "straight")))
    ;; Confirmation graphique
    (unless (x-popup-dialog
             t
             `(,(format "Créer la distribution MetalEmacs ?\n\n📁 Destination : %s\n📄 %d fichiers .el détectés"
                        (abbreviate-file-name dist-dir)
                        (length fichiers-el))
               ("✓ Créer" . t)
               ("✗ Annuler" . nil)))
      (user-error "Opération annulée"))
    (message "▶ Préparation de la distribution MetalEmacs en cours...")
    (redisplay)
    ;; Nettoyage si une ancienne préparation existe (sans corbeille)
    (when (file-exists-p dist-dir)
      (let ((metal-securite-inhiber t)
            (delete-by-moving-to-trash nil))
        (delete-directory dist-dir t)))
    ;; Créer le répertoire .emacs.d dans la distribution
    (make-directory emacs-dir t)
    ;; Copier les fichiers individuels
    (dolist (f fichiers)
      (let ((src (concat source f)))
        (when (file-exists-p src)
          (copy-file src (concat emacs-dir f) t))))
    ;; Copier les dossiers (sans .elc)
    (dolist (d dossiers)
      (let ((src (concat source d)))
        (when (file-directory-p src)
          (copy-directory src (concat emacs-dir d) nil t t))))
    ;; Supprimer tous les .elc et .DS_Store (sans corbeille)
    (let ((metal-securite-inhiber t)
          (delete-by-moving-to-trash nil))
      (dolist (elc (directory-files-recursively emacs-dir "\\.elc$"))
        (delete-file elc))
      (dolist (ds (directory-files-recursively emacs-dir "^\\.DS_Store$"))
        (delete-file ds)))
    ;; Créer le ZIP
    (call-process-shell-command
     (format "cd %s && zip -r emacs.d.zip .emacs.d"
             (shell-quote-argument dist-dir))
     nil nil nil)
    ;; Supprimer le dossier .emacs.d temporaire, ne garder que le ZIP (sans corbeille)
    (let ((metal-securite-inhiber t)
          (delete-by-moving-to-trash nil))
      (delete-directory emacs-dir t))
    ;; Rafraîchir Treemacs pour voir le résultat
    (treemacs-refresh)
    ;; Confirmation finale
    (x-popup-dialog
     t
     `(,(format "✓ Distribution MetalEmacs créée !\n\n📦 %s"
                (abbreviate-file-name zip-file))
       ("OK" . t)))
    (message "✓ Distribution créée : %s" zip-file)))


(with-eval-after-load 'markdown-mode
  (define-key markdown-mode-map (kbd "<f6>") #'markdown-table-align))

(defun metal-text-scale-in-mouse-buffer (fn)
  "Applique une fonction text-scale dans le buffer sous la souris."
  (let ((win (window-at (cadr (mouse-position))
                        (cddr (mouse-position))
                        (car (mouse-position)))))
    (when win
      (with-selected-window win
        (funcall fn 1)))))

(defun metal-text-scale-increase-mouse ()
  (interactive)
  (metal-text-scale-in-mouse-buffer #'text-scale-increase))

(defun metal-text-scale-decrease-mouse ()
  (interactive)
  (metal-text-scale-in-mouse-buffer #'text-scale-decrease))

(defun metal-text-scale-reset-all ()
  "Remet tous les buffers à la taille définie au dashboard."
  (interactive)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (boundp 'text-scale-mode) text-scale-mode)
        (text-scale-set 0)))))


(global-set-key (kbd "C-=") 'metal-text-scale-increase-mouse)
(global-set-key (kbd "C--") 'metal-text-scale-decrease-mouse)
(global-set-key (kbd "C-0") 'metal-text-scale-reset-all)

(require 'metal-toolbar)   ; en premier
(require 'metal-quarto)
(require 'metal-pdf)
(require 'metal-git)

(server-start)

;; Message de démarrage avec info MetalEmacs
(message "init.el chargé - MetalEmacs v1.1 actif (C-c m a = Assistant, C-c m d = Diagnostic)")
