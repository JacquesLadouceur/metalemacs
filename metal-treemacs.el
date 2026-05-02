;;; metal-treemacs.el --- Configuration Treemacs pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;;; Commentaires:
;; Ce module gère la configuration Treemacs pour MetalEmacs :
;; - Apparence style Finder (lignes alternées)
;; - Gestion des clés USB (ajout/retrait)
;; - Ouverture automatique au démarrage
;; - Raccourcis clavier
;; - Polices harmonisées avec le reste de l'interface

;;; Code:

(require 'cl-lib)
(require 'seq)

;;; ═══════════════════════════════════════════════════════════════════
;;; Configuration de base Treemacs
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-treemacs-width 35
  "Largeur courante de Treemacs (persistée dans metal-prefs.el).
Modifiée automatiquement quand l'utilisateur redimensionne manuellement.")

(use-package treemacs
  :straight t
  :defer t
  :config
  ;; --- Apparence Finder-like ---
  (setq treemacs-space-between-root-nodes t
        treemacs-indentation 2
        treemacs-indentation-string " "
        treemacs-width metal-treemacs-width
        treemacs-width-is-initially-locked t
        treemacs-text-scale 0
        treemacs-collapse-dirs 0
        treemacs-display-in-side-window t
        treemacs-position 'left
        treemacs-no-png-images t
        treemacs-is-never-other-window t)
  (treemacs-git-mode -1)
  ;; --- Bordure douce et épaisse (facilite le drag) ---
  (setq window-divider-default-right-width 6
        window-divider-default-places 'right-only)
  (window-divider-mode 1)
  (set-face-background 'window-divider "#d0d0d0")
  (set-face-background 'window-divider-first-pixel "#d0d0d0")
  (set-face-background 'window-divider-last-pixel "#d0d0d0")

  ;; --- Persistance de la largeur ---
  ;; Treemacs gère lui-même le verrouillage via `t w`.
  ;; On se contente de persister la largeur entre les sessions.

  (defun metal-treemacs--save-width ()
    "Sauvegarde la largeur courante de Treemacs dans metal-prefs."
    (when-let ((tw (treemacs-get-local-window)))
      (let ((new-width (window-width tw)))
        (setq metal-treemacs-width new-width
              treemacs-width new-width)
        (when (fboundp 'metal-prefs-save)
          (metal-prefs-save)))))

  ;; Sauvegarder après un redimensionnement via treemacs-set-width (touche w)
  (advice-add 'treemacs-set-width :after
              (lambda (&rest _) (metal-treemacs--save-width)))

  ;; Sauvegarder périodiquement quand la largeur a changé
  (defvar metal-treemacs--last-saved-width metal-treemacs-width
    "Dernière largeur sauvegardée, pour éviter les écritures inutiles.")

  (defun metal-treemacs--maybe-save-width ()
    "Sauvegarde la largeur si elle a changé depuis la dernière sauvegarde."
    (when-let ((tw (treemacs-get-local-window)))
      (let ((current-width (window-width tw)))
        (unless (= current-width metal-treemacs--last-saved-width)
          (setq metal-treemacs--last-saved-width current-width)
          (metal-treemacs--save-width)))))

  (run-with-idle-timer 3 t #'metal-treemacs--maybe-save-width))

;;; ═══════════════════════════════════════════════════════════════════
;;; Thème et rafraîchissement
;;; ═══════════════════════════════════════════════════════════════════

;;; Thème nerd-icons — icônes vectorielles épurées, multi-plateforme
;;; ═══════════════════════════════════════════════════════════════════

;; nerd-icons + treemacs-nerd-icons : rendu épuré et identique partout
;; nerd-icons + treemacs-nerd-icons : rendu épuré et identique partout
;; (use-package nerd-icons
;;   :straight t
;;   :config
;;   ;; Sous Windows : court-circuiter le read-directory-name interactif
;;   ;; et enregistrer la police dans HKCU sans droits admin
;;   (when (eq system-type 'windows-nt)
;;     (defun metal--install-nerd-font-windows ()
;;       "Enregistre NFM.ttf dans HKCU\\...\\Fonts sans droits administrateur."
;;       (let* ((font-dir (expand-file-name "AppData/Local/Microsoft/Windows/Fonts"
;;                                          (getenv "USERPROFILE")))
;;              (font-file (expand-file-name "NFM.ttf" font-dir)))
;;         (when (file-exists-p font-file)
;;           (call-process "reg" nil nil nil
;;                         "add"
;;                         "HKCU\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
;;                         "/v" "Symbols Nerd Font Mono (TrueType)"
;;                         "/t" "REG_SZ"
;;                         "/d" font-file
;;                         "/f"))))
;;     (advice-add 'nerd-icons-install-fonts :around
;;                 (lambda (orig &optional pfx)
;;                   (cl-letf (((symbol-function 'read-directory-name)
;;                              (lambda (&rest _)
;;                                (expand-file-name
;;                                 "AppData/Local/Microsoft/Windows/Fonts"
;;                                 (getenv "USERPROFILE")))))
;;                     (funcall orig pfx)
;;                     (metal--install-nerd-font-windows)))
;;                 '((name . metal--nerd-icons-no-dialog))))  ; ← ferme le when
;;   ;; Installer la police automatiquement si absente (tous les OS)
;;   (unless (or (find-font (font-spec :family "Symbols Nerd Font Mono"))
;;               (and (eq system-type 'windows-nt)
;;                    (file-exists-p
;;                     (expand-file-name "AppData/Local/Microsoft/Windows/Fonts/NFM.ttf"
;;                                       (getenv "USERPROFILE")))))
;;     (nerd-icons-install-fonts t)
;;     ;; Message bloquant : arrête le chargement d'Emacs tant que
;;     ;; l'utilisateur n'a pas lu le message et confirmé.
;;     (with-output-to-temp-buffer "*MetalEmacs — Redémarrage requis*"
;;       (princ "╔══════════════════════════════════════════════════════════════════╗\n")
;;       (princ "║                                                                  ║\n")
;;       (princ "║   📦  Polices Nerd Fonts installées                              ║\n")
;;       (princ "║                                                                  ║\n")
;;       (princ "║   Pour que les icônes s'affichent correctement,                  ║\n")
;;       (princ "║   fermez Emacs et relancez-le.                                   ║\n")
;;       (princ "║                                                                  ║\n")
;;       (princ "╚══════════════════════════════════════════════════════════════════╝\n"))
;;     (read-from-minibuffer
;;      "Appuyez sur Entrée pour continuer le démarrage (icônes affichées comme carrés jusqu'au redémarrage)... ")))


(use-package nerd-icons
  :straight t
  :config

  ;; ─── Helper multi-plateforme : installer Hack Nerd Font Mono ───
  (defun metal--install-hack-nerd-font ()
    "Installe Hack Nerd Font Mono dans le dossier de fontes utilisateur.
Mapping de codepoints conforme à `nerd-icons.el', contrairement à
Symbols Nerd Font Mono 3.4.x téléchargée par `nerd-icons-install-fonts'.
Retourne le chemin du fichier installé, ou nil en cas d'échec."
    (let* ((url "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/Hack.zip")
           (font-dir (cond ((eq system-type 'darwin)
                            (expand-file-name "~/Library/Fonts"))
                           ((eq system-type 'gnu/linux)
                            (expand-file-name "~/.local/share/fonts"))
                           ((eq system-type 'windows-nt)
                            (expand-file-name "AppData/Local/Microsoft/Windows/Fonts"
                                              (getenv "USERPROFILE")))))
           (zip-file (expand-file-name "Hack.zip" temporary-file-directory))
           (target-font (expand-file-name "HackNerdFontMono-Regular.ttf" font-dir)))
      (unless (file-directory-p font-dir)
        (make-directory font-dir t))
      (message "Téléchargement de Hack Nerd Font Mono...")
      (url-copy-file url zip-file t)
      (let ((default-directory temporary-file-directory))
        (call-process "unzip" nil nil nil "-o" "-j" zip-file
                      "HackNerdFontMono-Regular.ttf"
                      "-d" font-dir))
      (delete-file zip-file)
      ;; Linux : rafraîchir le cache fontconfig
      (when (eq system-type 'gnu/linux)
        (call-process "fc-cache" nil nil nil "-f"))
      ;; Windows : enregistrer dans HKCU
      (when (and (eq system-type 'windows-nt) (file-exists-p target-font))
        (call-process "reg" nil nil nil
                      "add"
                      "HKCU\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
                      "/v" "Hack Nerd Font Mono (TrueType)"
                      "/t" "REG_SZ"
                      "/d" target-font
                      "/f"))
      (and (file-exists-p target-font) target-font)))

  ;; ─── Migration : supprimer NFM.ttf (Symbols Nerd Font Mono) si présent ───
  ;; Cette ancienne fonte 3.4.0 a un mapping incompatible avec nerd-icons.el.
  (let ((legacy-fonts
         (cond ((eq system-type 'darwin)
                (list (expand-file-name "~/Library/Fonts/NFM.ttf")))
               ((eq system-type 'gnu/linux)
                (list (expand-file-name "~/.local/share/fonts/NFM.ttf")))
               ((eq system-type 'windows-nt)
                (list (expand-file-name "AppData/Local/Microsoft/Windows/Fonts/NFM.ttf"
                                        (getenv "USERPROFILE")))))))
    (dolist (f legacy-fonts)
      (when (file-exists-p f)
        (delete-file f)
        (message "Ancienne fonte Symbols Nerd Font Mono supprimée : %s" f))))

  ;; ─── Installer Hack Nerd Font Mono si absente ───
  (unless (find-font (font-spec :family "Hack Nerd Font Mono"))
    (metal--install-hack-nerd-font)
    (with-output-to-temp-buffer "*MetalEmacs — Redémarrage requis*"
      (princ "╔══════════════════════════════════════════════════════════════════╗\n")
      (princ "║                                                                  ║\n")
      (princ "║   📦  Hack Nerd Font Mono installée                              ║\n")
      (princ "║                                                                  ║\n")
      (princ "║   Pour que les icônes s'affichent correctement,                  ║\n")
      (princ "║   fermez Emacs et relancez-le.                                   ║\n")
      (princ "║                                                                  ║\n")
      (princ "╚══════════════════════════════════════════════════════════════════╝\n"))
    (read-from-minibuffer
     "Appuyez sur Entrée pour continuer le démarrage (icônes affichées comme carrés jusqu'au redémarrage)... "))
  (when (find-font (font-spec :family "Hack Nerd Font Mono"))
  (set-fontset-font t '(#xe000 . #xf8ff)   "Hack Nerd Font Mono" nil 'append)
  (set-fontset-font t '(#xf0000 . #xfffff) "Hack Nerd Font Mono" nil 'append)))

(use-package treemacs-nerd-icons
  :straight t
  :after (treemacs nerd-icons)
  :config
  (treemacs-load-theme "nerd-icons")

  ;; ── Personnalisations Metal : palette Finder épurée ──

  ;; Dossiers bleu Finder au lieu de marron
  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-chevron_down"
                                    :face '(:foreground "#8E8E93" :height 0.7))
                 " "
                 (nerd-icons-faicon "nf-fa-folder_open"
                                    :face '(:foreground "#64B5F6"))
                 " ")
   :extensions (dir-open)
   :fallback 'same-as-icon)

  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-chevron_right"
                                    :face '(:foreground "#8E8E93" :height 0.7))
                 " "
                 (nerd-icons-faicon "nf-fa-folder"
                                    :face '(:foreground "#64B5F6"))
                 " ")
   :extensions (dir-closed)
   :fallback 'same-as-icon)

  ;; Root : chevrons discrets
  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-chevron_down"
                                    :face '(:foreground "#8E8E93" :height 0.8))
                 " ")
   :extensions (root-open)
   :fallback 'same-as-icon)

  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-chevron_right"
                                    :face '(:foreground "#8E8E93" :height 0.8))
                 " ")
   :extensions (root-closed)
   :fallback 'same-as-icon)

  ;; Images : icône photo propre au lieu de "PNG" rouge
  (dolist (ext '("png" "jpg" "jpeg" "gif" "bmp" "svg" "ico" "webp" "tiff" "tif"))
    (treemacs-create-icon
     :icon (concat " "
                   (nerd-icons-faicon "nf-fa-file_image_o"
                                      :face '(:foreground "#AF52DE"))
                   " ")
     :extensions (ext)
     :fallback 'same-as-icon))

  ;; Fichiers Prolog (.pl) — icône code au lieu de Perl
  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-code"
                                    :face '(:foreground "#007AFF"))
                 " ")
   :extensions ("pl" "pro" "prolog")
   :fallback 'same-as-icon)

  ;; Fichiers Org — vert distinctif
  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-sucicon "nf-custom-orgmode"
                                     :face '(:foreground "#34C759"))
                 " ")
   :extensions ("org")
   :fallback 'same-as-icon)

  ;; PDF — rouge vif
  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-file_pdf_o"
                                    :face '(:foreground "#FF3B30"))
                 " ")
   :extensions ("pdf")
   :fallback 'same-as-icon)

  ;; Quarto
  (treemacs-create-icon
   :icon (concat " "
                 (nerd-icons-faicon "nf-fa-file_text_o"
                                    :face '(:foreground "#FF9500"))
                 " ")
   :extensions ("qmd")
   :fallback 'same-as-icon))

(with-eval-after-load 'treemacs
  ;; Rafraîchissement automatique après certaines opérations
  (add-hook 'treemacs-delete-file-functions 
            (lambda (&rest _) (treemacs-refresh)))
  (add-hook 'treemacs-delete-project-functions 
            (lambda (&rest _) (treemacs-refresh)))
  
  ;; Rafraîchissement après changement de root
  (advice-add 'treemacs-select-directory :after 
              (lambda (&rest _) (treemacs-refresh))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Lignes alternées style Finder
;;; ═══════════════════════════════════════════════════════════════════

(defface metal-treemacs-stripe-face
  '((t :background "#F5F5F7" :extend t))
  "Face pour les lignes impaires dans Treemacs."
  :group 'treemacs)

;; Alias pour compatibilité
(defface treemacs-stripe-face
  '((t :background "#F5F5F7" :extend t))
  "Face pour les lignes impaires dans Treemacs (alias)."
  :group 'treemacs)

(defun metal-treemacs--stripe-rows ()
  "Ajoute une couleur de fond alternée dans Treemacs."
  (metal-treemacs--clear-stripes)
  (save-excursion
    (goto-char (point-min))
    (let ((line-num 0))
      (while (not (eobp))
        (when (cl-oddp line-num)
          (let ((ov (make-overlay (line-beginning-position) 
                                   (line-end-position))))
            (overlay-put ov 'face 'metal-treemacs-stripe-face)
            (overlay-put ov 'metal-treemacs-stripe t)
            (overlay-put ov 'priority -50)
            (overlay-put ov 'after-string 
                         (propertize " " 'display 
                                     '(space :align-to right-fringe)
                                     'face 'metal-treemacs-stripe-face))))
        (setq line-num (1+ line-num))
        (forward-line 1)))))

;; Alias pour compatibilité avec l'ancien nom
(defalias 'my/treemacs-stripe-rows 'metal-treemacs--stripe-rows)

(defun metal-treemacs--clear-stripes ()
  "Supprime les overlays de bandes."
  (remove-overlays (point-min) (point-max) 'metal-treemacs-stripe t)
  ;; Aussi nettoyer l'ancien format
  (remove-overlays (point-min) (point-max) 'treemacs-stripe t))

;; Alias pour compatibilité
(defalias 'my/treemacs-clear-stripes 'metal-treemacs--clear-stripes)

(defun metal-treemacs--refresh-stripes ()
  "Rafraîchit les bandes alternées."
  (when (eq major-mode 'treemacs-mode)
    (metal-treemacs--clear-stripes)
    (metal-treemacs--stripe-rows)))

;; Alias pour compatibilité
(defalias 'my/treemacs-refresh-stripes 'metal-treemacs--refresh-stripes)


(with-eval-after-load 'treemacs
  (add-hook 'treemacs-mode-hook
            (lambda ()
              (run-with-idle-timer 0.5 nil
                                   (lambda ()
                                     (when (treemacs-get-local-buffer)
                                       (with-current-buffer (treemacs-get-local-buffer)
                                         (metal-treemacs--stripe-rows)))))))
  (add-hook 'treemacs-mode-hook (lambda () (setq-local indicate-empty-lines nil)))
  (add-hook 'treemacs-mode-hook
            (lambda ()
              (setq-local line-spacing
                          (round (* (metal-font-height) 0.04)))))
  (advice-add 'treemacs-refresh :after #'metal-treemacs--refresh-stripes)
  (advice-add 'treemacs-collapse-parent-node :after #'metal-treemacs--refresh-stripes)
  (advice-add 'treemacs-toggle-node :after #'metal-treemacs--refresh-stripes))


(defun metal-treemacs--update-line-spacing ()
  "Met à jour le line-spacing de Treemacs selon la taille de police courante."
  (when-let ((buf (treemacs-get-local-buffer)))
    (with-current-buffer buf
      (setq-local line-spacing
                  (round (* (metal-font-height) 0.04))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Polices harmonisées
;;; ═══════════════════════════════════════════════════════════════════

(with-eval-after-load 'treemacs
  ;; Uniformiser toutes les polices Treemacs avec le reste de l'interface
  (let ((font-height (if (fboundp 'metal-font-height)
                         (metal-font-height)
                       120))
        (mono-font (cond 
                    ((eq system-type 'darwin) "Menlo")
                    ((eq system-type 'windows-nt) "Consolas")
                    (t "DejaVu Sans Mono"))))
    (dolist (face '(treemacs-root-face
                    treemacs-root-unreadable-face
                    treemacs-root-remote-face
                    treemacs-directory-face
                    treemacs-file-face
                    ;; treemacs-git-modified-face
                    ;; treemacs-git-untracked-face
                    ;; treemacs-git-added-face
                    ;; treemacs-git-ignored-face
                    ;; treemacs-git-conflict-face
                    treemacs-tags-face))
      (set-face-attribute face nil :family mono-font :height font-height))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Ouverture au démarrage
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-treemacs--stabilize-width ()
  "Stabilise la largeur de Treemacs pour qu'elle ne change pas
lors du redimensionnement du frame.
Simule un left-click interne qui déclenche le mécanisme de
préservation de la taille de la side-window dans Emacs."
  (when-let ((tw (treemacs-get-local-window)))
    (save-selected-window
      (treemacs-leftclick-action `(down-mouse-1 (,tw 1 (0 . 0) 0))))))

(defun metal-treemacs-open-on-startup ()
  "Ouvre Treemacs au démarrage sans voler le focus."
  (let ((inhibit-message t) 
        (message-log-max nil))
    (require 'treemacs)
    (setq treemacs-python-executable nil)
    ;; (when (fboundp 'treemacs-git-mode)
    ;;   (treemacs-git-mode 'simple))
    (save-selected-window
      (treemacs))
    ;; Stabiliser la largeur après que le layout soit finalisé
    (run-with-idle-timer 0.5 nil #'metal-treemacs--stabilize-width)))

;; Alias pour compatibilité
(defalias 'my/treemacs-open-on-startup 'metal-treemacs-open-on-startup)

(add-hook 'after-init-hook #'metal-treemacs-open-on-startup)

;;; ═══════════════════════════════════════════════════════════════════
;;; Raccourcis globaux
;;; ═══════════════════════════════════════════════════════════════════

(with-eval-after-load 'treemacs
  (global-set-key (kbd "M-0")       #'treemacs-select-window)
  (global-set-key (kbd "C-x t t")   #'treemacs)
  (global-set-key (kbd "C-x t d")   #'treemacs-select-directory)
  (global-set-key (kbd "C-x t C-t") #'treemacs-find-file)
  (global-set-key (kbd "C-x t 1")   #'treemacs-delete-other-windows)
  (global-set-key (kbd "C-x t w")   #'treemacs-set-width))

;;; ═══════════════════════════════════════════════════════════════════
;;; Gestion des clés USB
;;; ═══════════════════════════════════════════════════════════════════

;; --- Utils chemins/canonisation ---
(defun metal--canonical (path)
  "Retourne PATH en forme canonique pour Treemacs (D:/, pas D:\\)."
  (let* ((tru (file-truename path))
         (fwd (subst-char-in-string ?\\ ?/ tru)))
    (file-name-as-directory fwd)))

;; --- Détection des volumes montés ---
(defun metal--usb-roots ()
  "Liste des chemins racine des volumes USB montés."
  (cond
   ((eq system-type 'windows-nt)
    (seq-filter #'file-exists-p
                (mapcar (lambda (d) (concat d ":/"))
                        '("D" "E" "F" "G" "H" "I" "J" "K" "L"))))
   ((eq system-type 'darwin)
    (let ((volumes-dir "/Volumes"))
      (when (file-directory-p volumes-dir)
        (seq-filter #'file-directory-p
                    (directory-files volumes-dir t "^[^.].*")))))
   ((eq system-type 'gnu/linux)
    (let ((media-dirs '("/media" "/run/media")))
      (apply #'append
             (mapcar (lambda (dir)
                       (when (file-directory-p dir)
                         (directory-files dir t "^[^.].*")))
                     media-dirs))))
   (t nil)))

(defun metal--treemacs-project-name (path)
  "Nom court et stable pour PATH."
  (cond
   ((eq system-type 'windows-nt) 
    (upcase (substring (file-truename path) 0 1)))
   (t 
    (file-name-nondirectory (directory-file-name path)))))

;; --- Helpers pour reconnaître et nettoyer les projets ---
(defun metal--usb-project-p (project)
  "Vrai si PROJECT correspond à un volume USB (selon l'OS)."
  (let* ((path (treemacs-project->path project))
         (tru (file-truename path)))
    (cond
     ((eq system-type 'windows-nt)
      (let ((drive (upcase (substring tru 0 1))))
        (member drive '("D" "E" "F" "G" "H" "I" "J" "K" "L"))))
     ((eq system-type 'darwin)
      (string-prefix-p "/Volumes/" tru))
     ((eq system-type 'gnu/linux)
      (or (string-prefix-p "/media/" tru)
          (string-prefix-p "/run/media/" tru)))
     (t nil))))

(defun metal--stale-project-p (project)
  "Vrai si le chemin du PROJECT n'existe plus."
  (let ((path (treemacs-project->path project)))
    (not (file-exists-p path))))

(defun metal-treemacs-ajouter-usb ()
  "Ajoute les volumes USB montés dans Treemacs, sans doublon.
Ouvre Treemacs si nécessaire et, si possible, se place sur le volume ajouté."
  (interactive)
  (require 'treemacs)
  ;; S'assurer que Treemacs et le workspace existent
  (unless (treemacs-get-local-window)
    (treemacs))

  (let* ((roots (mapcar #'metal--canonical (metal--usb-roots)))
         (ws    (treemacs-current-workspace))
         (existing (mapcar #'treemacs-project->name
                           (treemacs-workspace->projects ws)))
         (added-projs '())
         (added-names '()))
    (dolist (path roots)
      (let ((name (metal--treemacs-project-name path)))
        (unless (member name existing)
          (let ((proj
                 (if (fboundp 'treemacs-do-add-project-to-workspace)
                     ;; API programmatique, retourne l'objet projet
                     (treemacs-do-add-project-to-workspace path name)
                   ;; Fallback: API interactive avec args, puis on retrouve l'objet
                   (progn
                     (treemacs-add-project-to-workspace path name)
                     (seq-find (lambda (p)
                                 (string= (treemacs-project->name p) name))
                               (treemacs-workspace->projects
                                (treemacs-current-workspace)))))))
            (when proj (push proj added-projs)))
          (push name added-names)
          (push name existing))))
    (if added-names
        (progn
          (when (treemacs-get-local-window)
            (treemacs-select-window)
            (treemacs-refresh)
            ;; Aller au projet si possible
            (let ((proj (car (last added-projs))))
              (when proj
                (ignore-errors 
                  (when (fboundp 'treemacs-goto-node)
                    (treemacs-goto-node proj))))))
          (message "[USB] %d volume(s) ajouté(s): %s"
                   (length added-names)
                   (mapconcat #'identity (nreverse added-names) ", ")))
      (message "[USB] Aucun nouveau volume à ajouter."))))

;; --- Retrait dans Treemacs ---
(defun metal-treemacs-retirer-usb ()
  "Retire de Treemacs tous les projets USB, montés ou non, et nettoie les chemins invalides."
  (interactive)
  (unless (featurep 'treemacs) (require 'treemacs))
  (let* ((ws (treemacs-current-workspace))
         (projects (treemacs-workspace->projects ws))
         (removed 0))
    ;; Retirer tous les projets reconnus comme USB
    (dolist (p projects)
      (when (metal--usb-project-p p)
        (treemacs-do-remove-project-from-workspace p)
        (cl-incf removed)))
    ;; Retirer les projets dont le chemin n'existe plus
    (setq projects (treemacs-workspace->projects (treemacs-current-workspace)))
    (dolist (p projects)
      (when (metal--stale-project-p p)
        (treemacs-do-remove-project-from-workspace p)
        (cl-incf removed)))
    ;; Si plus aucun projet, ajouter Home comme fallback
    (when (null (treemacs-workspace->projects (treemacs-current-workspace)))
      (let ((fallback (expand-file-name "~")))
        (when (file-directory-p fallback)
          (if (fboundp 'treemacs-do-add-project-to-workspace)
              (treemacs-do-add-project-to-workspace fallback "Home")
            (treemacs-add-project-to-workspace fallback "Home")))))
    ;; Rafraîchir l'affichage
    (when (treemacs-get-local-window)
      (treemacs-select-window)
      (treemacs-refresh))
    (message "[USB] %d projet(s) retiré(s) (USB et/ou invalides)." removed)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Raccourcis USB dans Treemacs
;;; ═══════════════════════════════════════════════════════════════════

;; 1) Keymap local au mode
(defvar metal-treemacs-usb-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "v") #'metal-treemacs-ajouter-usb)
    (define-key map (kbd "V") #'metal-treemacs-retirer-usb)
    map)
  "Keymap pour metal-treemacs-keys-mode (utilisé seulement dans treemacs-mode).")

;; 2) Minor-mode buffer-local, désactivé par défaut
(define-minor-mode metal-treemacs-keys-mode
  "Raccourcis USB pour Treemacs."
  :init-value nil
  :lighter ""
  :keymap metal-treemacs-usb-keymap)

;; 3) L'activer uniquement dans treemacs-mode
(add-hook 'treemacs-mode-hook (lambda () (metal-treemacs-keys-mode 1)))

;; 4) (Optionnel) Nettoyage immédiat dans la session courante si le mode a fui partout
(defun metal-treemacs-keys-mode-off-everywhere ()
  "Désactive metal-treemacs-keys-mode dans tous les buffers."
  (interactive)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (bound-and-true-p metal-treemacs-keys-mode)
        (metal-treemacs-keys-mode -1)))))

;; 5) Support Evil (optionnel) — ces bindings ne s'appliquent qu'à treemacs-mode
(with-eval-after-load 'evil
  (with-eval-after-load 'treemacs
    (evil-define-key 'normal treemacs-mode-map
      (kbd "v") #'metal-treemacs-ajouter-usb
      (kbd "V") #'metal-treemacs-retirer-usb)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Compression/Décompression ZIP dans Treemacs
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-dossier-zip
  (expand-file-name "zip" user-emacs-directory)
  "Dossier contenant zip.exe et unzip.exe sous Windows.")

(defun metal--trouver-unzip ()
  "Retourne le chemin vers unzip (macOS/Linux) ou unzip.exe (Windows)."
  (if (eq system-type 'windows-nt)
      (expand-file-name "unzip.exe" metal-dossier-zip)
    "/usr/bin/unzip"))

(defun metal--trouver-zip ()
  "Retourne le chemin vers zip (macOS/Linux) ou zip.exe (Windows)."
  (if (eq system-type 'windows-nt)
      (expand-file-name "zip.exe" metal-dossier-zip)
    "/usr/bin/zip"))

(defun metal-decompresser-zip ()
  "Décompresse le fichier .zip sélectionné directement dans le dossier actif de Treemacs.
Évite la duplication de dossier (cours1/cours1/)."
  (interactive)
  (let* ((bouton (treemacs-current-button))
         (chemin (and bouton (treemacs-button-get bouton :path))))
    (unless (and chemin
                 (string-equal (downcase (or (file-name-extension chemin) "")) "zip"))
      (user-error "Placez le curseur sur un fichier .zip dans Treemacs"))
    (let* ((unzip (metal--trouver-unzip))
           (dossier-parent (file-name-directory chemin)))
      ;; Extraction directement dans le dossier parent (pas de sous-dossier)
      (let ((default-directory dossier-parent))
        (with-current-buffer (get-buffer-create "*metal-unzip*")
          (erase-buffer)
          (let ((resultat (call-process unzip nil t t "-o" chemin)))
            (unless (= 0 resultat)
              (pop-to-buffer "*metal-unzip*")
              (error "Échec de 'unzip' (code %d) — voir le buffer *metal-unzip*" resultat)))))
      ;; Rafraîchissement Treemacs
      (treemacs-refresh)
      (message "Décompressé : %s dans %s"
               (file-name-nondirectory chemin) dossier-parent))))

(defun metal-compresser-zip ()
  "Compresse le fichier ou dossier sélectionné dans Treemacs en .zip."
  (interactive)
  (let* ((bouton (treemacs-current-button))
         (chemin (and bouton (treemacs-button-get bouton :path))))
    (unless chemin
      (user-error "Placez le curseur sur un fichier ou dossier dans Treemacs"))
    (let* ((commande-zip (metal--trouver-zip))
           (dossier-parent (file-name-directory chemin))
           (nom (file-name-nondirectory (directory-file-name chemin)))
           (fichier-zip (expand-file-name (concat nom ".zip") dossier-parent)))
      ;; Vérifier si le .zip existe déjà
      (when (file-exists-p fichier-zip)
        (unless (y-or-n-p (format "Le fichier %s existe déjà. Écraser ? " fichier-zip))
          (user-error "Opération annulée")))
      ;; Compression
      (let ((default-directory dossier-parent))
        (with-current-buffer (get-buffer-create "*metal-zip*")
          (erase-buffer)
          (let ((resultat (call-process commande-zip nil t t "-r" fichier-zip nom)))
            (unless (= 0 resultat)
              (pop-to-buffer "*metal-zip*")
              (error "Échec de 'zip' (code %d) — voir le buffer *metal-zip*" resultat)))))
      ;; Rafraîchissement Treemacs
      (treemacs-refresh)
      (message "Compressé : %s → %s" nom (file-name-nondirectory fichier-zip)))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Raccourcis ZIP dans Treemacs
;;; ═══════════════════════════════════════════════════════════════════

(with-eval-after-load 'treemacs
  (define-key treemacs-mode-map (kbd "U") #'metal-decompresser-zip)
  (define-key treemacs-mode-map (kbd "Z") #'metal-compresser-zip))


;;; ═══════════════════════════════════════════════════════════════════
;;; Raccourcis dans Treemacs
;;; ═══════════════════════════════════════════════════════════════════

(defun metal/treemacs-save-buffer-here ()
  "Save the previous buffer to the directory at point in Treemacs."
  (interactive)
  (let* ((path (treemacs--nearest-path (treemacs-current-button)))
         (dir (file-name-as-directory
               (if (file-directory-p path)
                   path
                 (file-name-directory path))))
         (buf (window-buffer (next-window)))
         (base-name (with-current-buffer buf
                      (or (and (buffer-file-name)
                               (file-name-nondirectory (buffer-file-name)))
                          (buffer-name))))
         (target (read-file-name "Save as: " dir nil nil base-name)))
    (with-current-buffer buf
      (write-region (point-min) (point-max) target nil nil nil t))
    (message "Saved to %s" target)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Création de fichiers/dossiers via dialogue graphique (c f / c d)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-treemacs-create-file ()
  "Créer un fichier via dialogue graphique natif."
  (interactive)
  (let* ((btn (treemacs-current-button))
         (path (when btn (treemacs-button-get btn :path)))
         (dir (if path
                  (if (file-directory-p path)
                      (file-name-as-directory path)
                    (file-name-directory path))
                (expand-file-name "~/Documents/")))
         (filepath (if (fboundp 'x-file-dialog)
                       (x-file-dialog "Créer fichier" dir nil nil)
                     (read-file-name "Créer fichier : " dir))))
    (when (and filepath (not (string-empty-p filepath)))
      (when (or (not (file-exists-p filepath))
                (yes-or-no-p (format "« %s » existe déjà. Écraser ? "
                                     (file-name-nondirectory filepath))))
        (write-region "" nil filepath nil 'silent)
        (treemacs-refresh)
        (find-file filepath)))))

(defun metal-treemacs-create-dir ()
  "Créer un dossier via dialogue graphique natif."
  (interactive)
  (let* ((btn (treemacs-current-button))
         (path (when btn (treemacs-button-get btn :path)))
         (dir (if path
                  (if (file-directory-p path)
                      (file-name-as-directory path)
                    (file-name-directory path))
                (expand-file-name "~/Documents/")))
         ;; Utiliser le mode fichier (nil) pour permettre de taper un nom
         (new-dir (if (fboundp 'x-file-dialog)
                      (x-file-dialog "Nom du nouveau dossier" dir nil nil)
                    (read-file-name "Nom du nouveau dossier : " dir))))
    (when (and new-dir (not (string-empty-p new-dir)))
      (if (file-exists-p new-dir)
          (message "« %s » existe déjà." (file-name-nondirectory new-dir))
        (make-directory new-dir t)
        (treemacs-refresh)
        (message "Dossier créé : %s" new-dir)))))

(with-eval-after-load 'treemacs
  (define-key treemacs-mode-map (kbd "n") nil)
  (define-key treemacs-mode-map (kbd "U") #'metal-decompresser-zip)
  (define-key treemacs-mode-map (kbd "Z") #'metal-compresser-zip)
  (define-key treemacs-mode-map (kbd "S") #'metal/treemacs-save-buffer-here)
  (define-key treemacs-mode-map (kbd "c f") #'metal-treemacs-create-file)
  (define-key treemacs-mode-map (kbd "c d") #'metal-treemacs-create-dir))

(with-eval-after-load 'treemacs
  (when (eq system-type 'windows-nt)
    (advice-add 'treemacs-root-up :override
                (lambda (&optional _)
                  (interactive "P")
                  (let* ((project (car (treemacs-workspace->projects
                                        (treemacs-current-workspace))))
                         (old-root (treemacs-project->path project))
                         (new-root (file-name-directory
                                    (directory-file-name old-root)))
                         (new-name (file-name-nondirectory
                                    (directory-file-name new-root))))
                    (treemacs-do-remove-project-from-workspace
                     project :ignore-last-project-restriction)
                    (treemacs-do-add-project-to-workspace new-root new-name)
                    (treemacs--reset-dom)))
                '((name . metal--treemacs-root-up-fast)))))

(with-eval-after-load 'treemacs
  (defun metal-treemacs-monter-dossier ()
    "Remonte d'un niveau dans Treemacs sans dialogue."
    (interactive)
    (let* ((project (car (treemacs-workspace->projects
                          (treemacs-current-workspace))))
           (old-root (treemacs-project->path project))
           (new-root (file-name-directory
                      (directory-file-name old-root))))
      (cl-letf (((symbol-function 'read-directory-name)
                 (lambda (&rest _) new-root)))
        (treemacs-select-directory))))

  (defun metal-treemacs-descendre-dossier ()
    "Descend dans le dossier sélectionné dans Treemacs."
    (interactive)
    (let* ((btn (treemacs-current-button))
           (path (and btn (treemacs-button-get btn :path))))
      (if (and path (file-directory-p path))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _) path)))
            (treemacs-select-directory))
        (message "Placez le curseur sur un dossier dans Treemacs"))))

  (define-key treemacs-mode-map (kbd "M-H") #'metal-treemacs-monter-dossier)
  (define-key treemacs-mode-map (kbd "M-L") #'metal-treemacs-descendre-dossier))


(provide 'metal-treemacs)

;;; metal-treemacs.el ends here
