;;; metal-prolog.el --- Configuration SWI-Prolog pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;;; Commentary:
;; Ce module gère la configuration SWI-Prolog pour MetalEmacs :
;; - Détection automatique de l'interpréteur (Homebrew, Scoop, app, Windows)
;; - Configuration de SWI_HOME_DIR (Windows, requis pour janus-swi)
;; - Position du shell Prolog (bas/droite)
;; - Pliage de code (overlays) : plie/déplie les clauses Prolog
;; - Raccourcis clavier
;;
;; Version 1.1 : Correction SWI_HOME_DIR pour shims Scoop + chemin Scoop

;;; Code:

(require 'cl-lib)
(require 'seq)

;;; ═══════════════════════════════════════════════════════════════════
;;; Détection et configuration de SWI-Prolog
;;; ═══════════════════════════════════════════════════════════════════

;;; -------------------------------------------------------------------
;;; Détection et configuration de SWI-Prolog
;;; -------------------------------------------------------------------
(defun metal-prolog--detecter-swipl ()
  "Détecte et retourne le chemin vers swipl, ou nil si non trouvé."
  (or
   ;; Dans le PATH (inclut Homebrew si configuré)
   (executable-find "swipl")
   ;; Homebrew Apple Silicon
   (let ((p "/opt/homebrew/bin/swipl"))
     (and (file-executable-p p) p))
   ;; Homebrew Intel
   (let ((p "/usr/local/bin/swipl"))
     (and (file-executable-p p) p))
   ;; Application macOS
   (let ((p "/Applications/SWI-Prolog.app/Contents/MacOS/swipl"))
     (and (file-executable-p p) p))
   ;; Windows - Scoop
   (let ((p (expand-file-name "scoop/apps/swipl/current/bin/swipl.exe"
                              (or (getenv "HOME") (getenv "USERPROFILE")))))
     (and (file-executable-p p) p))
   ;; Windows - Installation standard
   (let ((p "C:/Program Files/swipl/bin/swipl.exe"))
     (and (file-executable-p p) p))))

(defun metal-prolog--configurer-swipl-home (swipl-path)
  "Configure SWI_HOME_DIR sur Windows à partir de SWIPL-PATH.
Gère le cas des shims Scoop qui ne sont pas dans le vrai dossier SWI-Prolog."
  (when (and (eq system-type 'windows-nt) swipl-path)
    (let* ((home-dir
            (cond
             ;; Shim Scoop → pointer vers le vrai dossier d'installation
             ((string-match-p "scoop/shims" swipl-path)
              (let ((scoop-app (expand-file-name
                                "scoop/apps/swipl/current"
                                (or (getenv "HOME") (getenv "USERPROFILE")))))
                (and (file-exists-p (expand-file-name "boot.prc" scoop-app))
                     scoop-app)))
             ;; Exécutable direct → remonter depuis bin/
             (t
              (let ((dir (expand-file-name ".." (file-name-directory swipl-path))))
                (and (file-exists-p (expand-file-name "boot.prc" dir))
                     dir))))))
      (when home-dir
        (setenv "SWI_HOME_DIR" (convert-standard-filename
                                 (expand-file-name home-dir)))
        (message "SWI_HOME_DIR configuré : %s" home-dir)))))

;; Configuration automatique au chargement
(let ((swipl-path (metal-prolog--detecter-swipl)))
  (if swipl-path
      (progn
        (metal-prolog--configurer-swipl-home swipl-path)
        (setq prolog-program-name `((swi ,swipl-path)))
        (setq prolog-system 'swi)
        (message "SWI-Prolog configuré : %s" swipl-path))
    (setq prolog-program-name nil)
    (setq prolog-system nil)
    (message "?? SWI-Prolog non trouvé. Installez-le via M-x metal-deps-installer-swi-prolog")))

;;; ═══════════════════════════════════════════════════════════════════
;;; Fonction utilitaire
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-prolog-check ()
  "Afficher le chemin et la version de SWI-Prolog utilisé par Emacs."
  (interactive)
  (let ((prog (metal-prolog--detecter-swipl)))
    (if (and prog (file-executable-p prog))
        (message "SWI-Prolog : %s | Version : %s"
                 prog
                 (string-trim
                  (with-output-to-string
                    (with-current-buffer standard-output
                      (call-process prog nil t nil "--version")))))
      (message "SWI-Prolog non configuré ou introuvable."))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Chargement des modes
;;; ═══════════════════════════════════════════════════════════════════

(autoload 'run-prolog "prolog" "Start a Prolog sub-process." t)
(autoload 'prolog-mode "prolog" "Major mode for editing Prolog programs." t)
(autoload 'mercury-mode "prolog" "Major mode for editing Mercury programs." t)

;; Association avec les interpréteurs et fichiers
(add-to-list 'interpreter-mode-alist '("swipl" . prolog-mode))

(add-to-list 'auto-mode-alist '("\\.pl\\'"  . prolog-mode))
(add-to-list 'auto-mode-alist '("\\.pro\\'" . prolog-mode))

;;; ═══════════════════════════════════════════════════════════════════
;;; Configuration du mode Prolog
;;; ═══════════════════════════════════════════════════════════════════

(add-hook 'prolog-mode-hook
          (lambda ()
            (local-set-key [f5] 'prolog-consult-buffer)
            (setq indent-tabs-mode nil)
            (setq prolog-indent-offset 4)
            (setq tab-width 4)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Pliage de code (overlays maison)
;;; ═══════════════════════════════════════════════════════════════════

;; Pliage par clause Prolog via des overlays « invisible ».
;; N'utilise ni hs-minor-mode ni outline-minor-mode pour éviter
;; tout conflit avec tab-line-mode et metal-outline-cycle.
;; Une clause commence par un atome en début de ligne et se termine
;; par un point final suivi d'un whitespace ou fin de buffer.

(defun metal-prolog--debut-clause-p ()
  "Vrai si la ligne courante est un début de clause Prolog."
  (save-excursion
    (beginning-of-line)
    (looking-at "^[a-z_][a-zA-Z0-9_]*")))

(defun metal-prolog--fin-clause ()
  "Retourne la position de fin de la clause courante (après le point final).
Un point final de clause est un point en fin de ligne (éventuellement
suivi de blancs ou d'un commentaire %). Ceci exclut les points dans
=.. et dans les accesseurs de dicts comme Cat.nbr."
  (save-excursion
    (let ((start (point)))
      (when (re-search-forward "\\.\\s-*\\(%.*\\)?$" nil t)
        (match-end 0)))))

(defun metal-prolog--trouver-overlay ()
  "Retourne l'overlay de pliage sur la ligne courante, ou nil."
  (save-excursion
    (end-of-line)
    (let ((pos (point)))
      (cl-find-if (lambda (ov) (eq (overlay-get ov 'metal-prolog-fold) t))
                  (overlays-at pos)))))

(defun metal-prolog-basculer-pliage ()
  "Basculer le pliage de la clause Prolog sous le curseur."
  (interactive)
  (if (metal-prolog--debut-clause-p)
      (let ((ov (metal-prolog--trouver-overlay)))
        (if ov
            ;; Déplier : supprimer l'overlay
            (delete-overlay ov)
          ;; Plier : créer un overlay du fin de la première ligne jusqu'à fin de clause
          (let* ((fin-ligne (save-excursion (end-of-line) (point)))
                 (fin-clause (metal-prolog--fin-clause)))
            (when (and fin-clause (> fin-clause fin-ligne))
              (let ((new-ov (make-overlay fin-ligne (1- fin-clause))))
                (overlay-put new-ov 'metal-prolog-fold t)
                (overlay-put new-ov 'invisible t)
                (overlay-put new-ov 'display " ⋯")
                (overlay-put new-ov 'evaporate t))))))
    (message "Pas sur une tête de clause.")))

(defun metal-prolog-plier-tout ()
  "Plier toutes les clauses du buffer Prolog."
  (interactive)
  (metal-prolog-deplier-tout)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^[a-z_][a-zA-Z0-9_]*" nil t)
      (beginning-of-line)
      (let* ((fin-ligne (save-excursion (end-of-line) (point)))
             (fin-clause (metal-prolog--fin-clause)))
        (when (and fin-clause (> fin-clause fin-ligne))
          (let ((ov (make-overlay fin-ligne (1- fin-clause))))
            (overlay-put ov 'metal-prolog-fold t)
            (overlay-put ov 'invisible t)
            (overlay-put ov 'display " ⋯")
            (overlay-put ov 'evaporate t))))
      (forward-line 1)))
  (message "Toutes les clauses pliées."))

(defun metal-prolog-deplier-tout ()
  "Déplier toutes les clauses du buffer Prolog."
  (interactive)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'metal-prolog-fold)
      (delete-overlay ov)))
  (message "Toutes les clauses dépliées."))

(defun metal-prolog-basculer-tout ()
  "Plier tout si rien n'est plié, déplier tout sinon."
  (interactive)
  (if (cl-some (lambda (ov) (overlay-get ov 'metal-prolog-fold))
               (overlays-in (point-min) (point-max)))
      (metal-prolog-deplier-tout)
    (metal-prolog-plier-tout)))

(defun metal-prolog-plier-menu ()
  "Menu de pliage pour le code Prolog."
  (interactive)
  (let ((choix (completing-read "Pliage : "
                                '("Plier tout" "Déplier tout" "Basculer clause")
                                nil t)))
    (pcase choix
      ("Plier tout"       (metal-prolog-plier-tout))
      ("Déplier tout"     (metal-prolog-deplier-tout))
      ("Basculer clause"  (metal-prolog-basculer-pliage)))))

;; Raccourcis clavier pour le pliage
;; Note : C-c est déjà utilisé par prolog-mode, on utilise des touches F.
(add-hook 'prolog-mode-hook
          (lambda ()
            (local-set-key (kbd "<f6>")   #'metal-prolog-plier-tout)
            (local-set-key (kbd "S-<f6>") #'metal-prolog-deplier-tout)
            ;; Tab intelligent : plie/déplie sur une tête de clause,
            ;; indente normalement ailleurs.
            (local-set-key (kbd "<tab>")
                           (lambda () (interactive)
                             (if (metal-prolog--debut-clause-p)
                                 (metal-prolog-basculer-pliage)
                               (indent-for-tab-command))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Fonction pour envoyer une commande
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-prolog-send-command (command)
  "Envoyer COMMAND à l'interpréteur Prolog inférieur."
  (interactive "sCommande Prolog : ")
  (let ((proc (get-process "prolog")))
    (if proc
        (comint-send-string proc (concat command "\n"))
      (message "Aucun processus Prolog en cours."))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Position du shell Prolog (bas/droite)
;;; ═══════════════════════════════════════════════════════════════════

(defgroup metal-prolog nil
  "Réglages pour l'ouverture du shell Prolog."
  :group 'prolog)

(defcustom metal-prolog-shell-position-defaut 'bottom
  "Position par défaut : 'bottom (bas) ou 'right (droite)."
  :type '(choice (const bottom) (const right))
  :group 'metal-prolog)

(defcustom metal-prolog-shell-height-frac 0.30
  "Fraction de hauteur quand le shell s'ouvre en bas (0.0–1.0)."
  :type 'number
  :group 'metal-prolog)

(defcustom metal-prolog-shell-width-frac 0.30
  "Fraction de largeur quand le shell s'ouvre à droite (0.0–1.0)."
  :type 'number
  :group 'metal-prolog)

;;; ═══════════════════════════════════════════════════════════════════
;;; Détection / accès au buffer du REPL Prolog
;;; ═══════════════════════════════════════════════════════════════════

(defun metal--inferior-prolog-buffer-p (buf _action)
  "Vrai si BUF est un REPL Prolog (prolog-inferior-mode)."
  (with-current-buffer buf (eq major-mode 'prolog-inferior-mode)))

(defun metal--prolog-get-buffer ()
  "Retourne un buffer de REPL Prolog s'il existe, sinon nil."
  (seq-find (lambda (b)
              (with-current-buffer b
                (eq major-mode 'prolog-inferior-mode)))
            (buffer-list)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Règles d'affichage
;;; ═══════════════════════════════════════════════════════════════════

(defun metal--prolog-regle-affichage (cote)
  "Règle display-buffer pour Prolog relative à la fenêtre sélectionnée."
  (if (eq cote 'bottom)
      `(metal--inferior-prolog-buffer-p
        (display-buffer-reuse-window display-buffer-below-selected)
        (inhibit-same-window . t)
        (window-height . ,metal-prolog-shell-height-frac))
    `(metal--inferior-prolog-buffer-p
      (display-buffer-reuse-window display-buffer-in-direction)
      (direction . right)
      (inhibit-same-window . t)
      (window-width . ,metal-prolog-shell-width-frac))))

(defun metal--prolog-appliquer-regle (cote)
  "Remplace la règle d'affichage du REPL Prolog par celle pour COTE."
  (setq display-buffer-alist
        (cl-remove-if (lambda (r) (eq (car-safe r) #'metal--inferior-prolog-buffer-p))
                      display-buffer-alist))
  (add-to-list 'display-buffer-alist (metal--prolog-regle-affichage cote)))

(defun metal--prolog-afficher-ou-repositionner (buf cote)
  "Afficher BUF à COTE; si déjà visible ailleurs, le repositionner."
  (when-let ((win (get-buffer-window buf t)))
    (when (window-live-p win) (delete-window win)))
  (if (eq cote 'bottom)
      (display-buffer
       buf
       `((display-buffer-reuse-window display-buffer-below-selected)
         (inhibit-same-window . t)
         (window-height . ,metal-prolog-shell-height-frac)))
    (display-buffer
     buf
     `((display-buffer-reuse-window display-buffer-in-direction)
       (direction . right)
       (inhibit-same-window . t)
       (window-width . ,metal-prolog-shell-width-frac)))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Commandes principales
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-prolog-shell-choisir-position ()
  "Choisir « bas » ou « droite », rendre le choix permanent et (ré)afficher le shell Prolog."
  (interactive)
  (let* ((options '("bas" "droite"))
         (defaut (if (eq metal-prolog-shell-position-defaut 'bottom) "bas" "droite"))
         (choix (completing-read "Ouvrir le shell Prolog où ? "
                                 options nil t nil nil defaut))
         (cote (if (string= choix "bas") 'bottom 'right))
         (buf (metal--prolog-get-buffer)))
    ;; 1) Sauver la préférence et appliquer la règle
    (setq metal-prolog-shell-position-defaut cote)
    (customize-save-variable 'metal-prolog-shell-position-defaut cote)
    (metal--prolog-appliquer-regle cote)
    ;; 2) Créer le REPL si nécessaire
    (unless (and buf (buffer-live-p buf))
      (run-prolog)
      (setq buf (metal--prolog-get-buffer)))
    ;; 3) Repositionner/afficher maintenant
    (metal--prolog-afficher-ou-repositionner buf cote)
    (message "✅ Le shell Prolog s'ouvrira désormais %s (%.0f%%)."
             (if (eq cote 'bottom) "en bas" "à droite")
             (* 100 (if (eq cote 'bottom)
                        metal-prolog-shell-height-frac
                      metal-prolog-shell-width-frac)))))

(defun metal-prolog-shell-bascule-position ()
  "Bascule la position du shell Prolog entre bas et droite."
  (interactive)
  (let ((nouvelle-pos (if (eq metal-prolog-shell-position-defaut 'bottom) 'right 'bottom)))
    (setq metal-prolog-shell-position-defaut nouvelle-pos)
    (customize-save-variable 'metal-prolog-shell-position-defaut nouvelle-pos)
    (metal--prolog-appliquer-regle nouvelle-pos)
    (when-let ((buf (metal--prolog-get-buffer)))
      (metal--prolog-afficher-ou-repositionner buf nouvelle-pos))
    (message "Position du shell Prolog : %s"
             (if (eq nouvelle-pos 'bottom) "bas" "droite"))))

;; Appliquer la règle au démarrage selon la préférence enregistrée
(metal--prolog-appliquer-regle metal-prolog-shell-position-defaut)

;;; metal-prolog-toolbar-snippet.el --- À ajouter dans metal-prolog.el -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; À AJOUTER dans `metal-prolog.el', en remplacement de `my/prolog-header-line'
;; qui se trouve actuellement dans `init.el' (et qu'il faut RETIRER après
;; migration, ainsi que le `add-hook' associé).

;;; Code:

(require 'metal-toolbar)

(defcustom metal-prolog-icon-height
  (if (eq system-type 'windows-nt) 0.8 1.2)
  "Hauteur des icônes de la barre Prolog."
  :type 'number
  :group 'metal-prolog)

(defun metal-prolog--icon (name color)
  "Icône NAME (FontAwesome) colorée avec COLOR pour la barre Prolog."
  (metal-toolbar-icon name :color color :height metal-prolog-icon-height))

(defun metal-prolog-toolbar-format ()
  "Construit la barre d'outils Prolog."
  (concat
   (metal-toolbar-vpadding) " "

   (metal-toolbar-button
    (metal-prolog--icon "nf-fa-play" "#34C759")
    "Consulter le programme"
    #'prolog-save-consult)

   (metal-toolbar-button
    (metal-prolog--icon "nf-fa-bug" "#FF3B30")
    "Lancer le débogueur graphique"
    (lambda () (interactive) (prolog-inferior-send-command "gtrace.")))

   (metal-toolbar-button
    (metal-prolog--icon "nf-fa-minus_square_o" "#5AC8FA")
    "Plier / déplier tout"
    #'metal-prolog-basculer-tout)

   (metal-toolbar-separator)

   (metal-toolbar-button
    (metal-prolog--icon "nf-fa-arrows" "#8E8E93")
    (format "Basculer la position du shell Prolog (actuel : %s)"
            (if (eq metal-prolog-shell-position-defaut 'bottom)
                "en bas" "à droite"))
    #'metal-prolog-shell-bascule-position)

   (metal-toolbar-separator)

   (metal-toolbar-button
    (metal-prolog--icon "nf-fa-book" "#FF9500")
    "Documentation"
    #'documentation-prolog)

   (metal-toolbar-button
    (metal-prolog--icon "nf-fa-comments" "#AF52DE")
    "ChatGPT"
    #'chatgpt)

   " " (metal-toolbar-vpadding)))

(defun metal-prolog-header-line ()
  "Active la barre d'outils dans le tampon Prolog courant."
  (setq-local header-line-format
              '(:eval (metal-prolog-toolbar-format))))

(add-hook 'prolog-mode-hook #'metal-prolog-header-line)

(provide 'metal-prolog-toolbar)
;;; metal-prolog-toolbar-snippet.el ends here


(provide 'metal-prolog)

;;; metal-prolog.el ends here
