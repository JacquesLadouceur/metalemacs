;;; metal-quarto.el --- Mode Quarto pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;;; Commentaires:
;; Ce module gère la configuration Quarto pour MetalEmacs :
;; - Mode poly-quarto avec polymode
;; - Pliage automatique des sections
;; - Barre d'outils header-line
;; - Formatage (gras, italique, souligné, barré, code)
;; - Rendu Quarto (F8)
;; - Conversion Org-mode vers Quarto (.qmd)

;;; Code:

(require 'cl-lib)

;;; ═══════════════════════════════════════════════════════════════════
;;; Dépendances : Polymode et Markdown
;;; ═══════════════════════════════════════════════════════════════════

(use-package polymode
  :straight t)

(use-package poly-markdown
  :straight t)

(use-package markdown-mode
  :straight t)

(use-package quarto-mode
  :straight t
  :mode ("\\.qmd\\'" . poly-quarto-mode)
  :hook ((poly-quarto-mode . visual-line-mode))
  :init
  (setq quarto-preview-browser nil))

;;; ═══════════════════════════════════════════════════════════════════
;;; Vérification automatique de TinyTeX / TeX Live
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-quarto--tinytex-ok nil
  "Non-nil si TinyTeX a été vérifié dans cette session.")

(defvar metal-quarto--tinytex-updating nil
  "Non-nil si une mise à jour TinyTeX est en cours.")

(defvar metal-quarto--tinytex-after-update nil
  "Fonction à appeler après une mise à jour TinyTeX réussie.
Utilisé pour relancer le rendu automatiquement.")

(defun metal-quarto--tinytex-annee-locale ()
  "Retourne l'année TeX Live locale (ex: 2025), ou nil si introuvable."
  (let ((out (shell-command-to-string "tlmgr --version 2>/dev/null")))
    (when (string-match "TeX Live (\\([0-9]\\{4\\}\\))" out)
      (string-to-number (match-string 1 out)))))

(defun metal-quarto--tinytex-obsolete-p ()
  "Retourne non-nil si tlmgr ne peut plus se connecter au dépôt distant.
Contacte le réseau — à n'appeler qu'une fois (au démarrage)."
  (let ((out (shell-command-to-string "tlmgr update --list 2>&1 | head -20")))
    (string-match-p "is older than remote repository" out)))

(defun metal-quarto--strip-ansi (str)
  "Retire les séquences d'échappement ANSI de STR."
  (replace-regexp-in-string "\033\\[[0-9;]*[a-zA-Z]" "" str))

(defvar metal-quarto--tinytex-last-message-time 0
  "Timestamp du dernier message affiché dans le minibuffer.")

(defun metal-quarto--tinytex-filter (proc string)
  "Filtre de processus : affiche la progression dans le minibuffer.
Gère les retours chariot (\\r) pour écraser la ligne courante dans le buffer.
Limite la fréquence d'affichage dans le minibuffer pour éviter le flood."
  (let ((clean (metal-quarto--strip-ansi string)))
    ;; Écriture dans le buffer avec gestion du \r
    (when (buffer-live-p (process-buffer proc))
      (with-current-buffer (process-buffer proc)
        ;; Découper par \r : seul le dernier segment compte pour la ligne
        (let ((segments (split-string clean "\r")))
          (dolist (seg segments)
            (when (> (length seg) 0)
              ;; Effacer la ligne courante (depuis le dernier \n)
              (goto-char (point-max))
              (let ((bol (save-excursion
                           (beginning-of-line)
                           (point))))
                ;; Si ce segment ne commence pas par \n, écraser la ligne
                (unless (string-prefix-p "\n" seg)
                  (delete-region bol (point-max))))
              (goto-char (point-max))
              (insert seg))))))
    ;; Affichage minibuffer : max 2 fois par seconde
    (let ((now (float-time)))
      (when (> (- now metal-quarto--tinytex-last-message-time) 0.5)
        (setq metal-quarto--tinytex-last-message-time now)
        ;; Extraire la dernière ligne significative
        (let* ((segments (split-string clean "\r"))
               (last-seg (car (last segments)))
               (lines (when last-seg (split-string last-seg "\n" t "[ \t]+")))
               (last-line (when lines (car (last lines)))))
          (when (and last-line (> (length last-line) 0))
            (when (> (length last-line) 80)
              (setq last-line (concat (substring last-line 0 77) "...")))
            (message "⟳ TinyTeX : %s" last-line)))))))

(defun metal-quarto--tinytex-sentinel (proc event)
  "Sentinel : gère la fin du processus de mise à jour TinyTeX."
  (setq metal-quarto--tinytex-updating nil)
  (let ((callback metal-quarto--tinytex-after-update))
    (setq metal-quarto--tinytex-after-update nil)
    (cond
     ((string-match-p "finished" event)
      (setq metal-quarto--tinytex-ok t)
      (message "✓ MetalEmacs : TinyTeX mis à jour avec succès.")
      (when (buffer-live-p (process-buffer proc))
        (kill-buffer (process-buffer proc)))
      ;; Relancer le rendu si un callback est en attente
      (when callback
        (message "✓ TinyTeX à jour — relance du rendu...")
        (run-at-time 0.5 nil callback)))
     (t
      (message "✗ MetalEmacs : Échec mise à jour TinyTeX. Voir *TinyTeX Update*.")
      (when (buffer-live-p (process-buffer proc))
        (display-buffer (process-buffer proc)))))))

(defun metal-quarto--tinytex-reinstall-async (&optional after-callback)
  "Réinstalle TinyTeX via Quarto de façon asynchrone.
AFTER-CALLBACK sera appelé après une mise à jour réussie."
  (setq metal-quarto--tinytex-updating t)
  (setq metal-quarto--tinytex-after-update after-callback)
  (let ((buf (get-buffer-create "*TinyTeX Update*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "═══ Mise à jour TinyTeX ═══  %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S")))))
    (message "⟳ MetalEmacs : Mise à jour TinyTeX en cours...")
    (let ((proc (make-process
                 :name "metal-tinytex-update"
                 :buffer buf
                 :command '("quarto" "install" "tinytex" "--update-path" "--no-prompt")
                 :filter #'metal-quarto--tinytex-filter
                 :sentinel #'metal-quarto--tinytex-sentinel)))
      (display-buffer buf '(display-buffer-at-bottom . ((window-height . 8))))
      proc)))

(defun metal-quarto--ensure-tinytex (&optional after-callback)
  "Vérifie que TinyTeX est à jour avant un rendu.
Si une mise à jour est nécessaire, la lance de façon asynchrone et
appelle AFTER-CALLBACK une fois terminée.
Retourne t si le rendu peut continuer immédiatement, nil s'il faut attendre."
  (cond
   ;; Déjà vérifié cette session → continuer
   (metal-quarto--tinytex-ok t)
   ;; Mise à jour déjà en cours → attendre
   (metal-quarto--tinytex-updating
    (message "⟳ MetalEmacs : Mise à jour TinyTeX en cours, patientez...")
    nil)
   ;; tlmgr ou quarto absent → on laisse Quarto gérer
   ((not (and (executable-find "tlmgr") (executable-find "quarto")))
    (setq metal-quarto--tinytex-ok t)
    t)
   ;; Pas de décalage → tout va bien
   ((not (metal-quarto--tinytex-obsolete-p))
    (setq metal-quarto--tinytex-ok t)
    t)
   ;; Décalage détecté → lancer la mise à jour asynchrone
   (t
    (metal-quarto--tinytex-reinstall-async after-callback)
    nil)))

;; -----------------------------------------------------------------------
;; Vérification au démarrage d'Emacs
;; -----------------------------------------------------------------------

(defun metal-quarto--check-tinytex-at-startup ()
  "Vérifie TinyTeX au démarrage d'Emacs.
Étape 1 : compare l'année TeX Live locale à l'année courante (instantané).
Étape 2 : si différentes, contacte le dépôt distant (asynchrone) pour confirmer.
Étape 3 : si obsolète, demande confirmation à l'utilisateur."
  (when (and (executable-find "quarto")
             (executable-find "tlmgr")
             (not metal-quarto--tinytex-ok))
    (let ((annee-texlive (metal-quarto--tinytex-annee-locale))
          (annee-courante (string-to-number (format-time-string "%Y"))))
      (if (or (not annee-texlive)
              (>= annee-texlive annee-courante))
          ;; Même année → pas besoin de vérifier le réseau
          (setq metal-quarto--tinytex-ok t)
        ;; Année différente → vérifier auprès du dépôt distant
        (let ((proc (start-process "metal-tinytex-check" "*TinyTeX Check*"
                                   "bash" "-c" "tlmgr update --list 2>&1 | head -20")))
          (set-process-sentinel
           proc
           (lambda (p _event)
             (when (and (eq (process-status p) 'exit)
                        (buffer-live-p (process-buffer p)))
               (let ((output (with-current-buffer (process-buffer p)
                               (buffer-string))))
                 (kill-buffer (process-buffer p))
                 (if (string-match-p "is older than remote repository" output)
                     ;; Confirmé obsolète → demander à l'utilisateur
                     (if (y-or-n-p
                          (format "MetalEmacs : TinyTeX (TeX Live %d) est obsolète. Mettre à jour ? "
                                  annee-texlive))
                         (metal-quarto--tinytex-reinstall-async)
                       (message "MetalEmacs : Mise à jour reportée. Elle sera relancée au prochain F8."))
                   ;; Le dépôt n'a pas encore basculé → tout va bien
                   (setq metal-quarto--tinytex-ok t)))))))))))

(add-hook 'emacs-startup-hook #'metal-quarto--check-tinytex-at-startup)

;;; ═══════════════════════════════════════════════════════════════════
;;; Pliage avec outline-minor-mode
;;; ═══════════════════════════════════════════════════════════════════

;; Activation de outline-minor-mode dans markdown/quarto
(add-hook 'markdown-mode-hook #'outline-minor-mode)

;; Titres markdown (un ou plusieurs #)
(setq markdown-mode-outline-regexp "^#+ ")

;; TAB : plier/déplier la section courante
(defun metal-outline-cycle ()
  "Sur un titre : plier/déplier. Sinon : TAB normal."
  (interactive)
  (if (and outline-minor-mode
           (save-excursion
             (beginning-of-line)
             (looking-at outline-regexp)))
      (outline-toggle-children)
    (indent-for-tab-command)))

(define-key outline-minor-mode-map (kbd "<tab>") #'metal-outline-cycle)
(define-key outline-minor-mode-map (kbd "TAB")   #'metal-outline-cycle)

(add-hook 'outline-minor-mode-hook
          (lambda ()
            (setq-local minor-mode-overriding-map-alist
                        (list (cons 'outline-minor-mode
                                    outline-minor-mode-map)))))

;; S-TAB : plier tout ou tout déplier
(defvar metal-outline-global-state 'expanded
  "Mémorise l'état global du pliage.")

(defun metal-outline-shifttab ()
  "Bascule entre tout plié et tout déplié."
  (interactive)
  (if (eq metal-outline-global-state 'expanded)
      (progn
        (hide-sublevels 1)
        (setq metal-outline-global-state 'collapsed))
    (progn
      (show-all)
      (setq metal-outline-global-state 'expanded))))

(define-key outline-minor-mode-map (kbd "<backtab>") #'metal-outline-shifttab)

;; M-up / M-down : déplacer une section (diapositive) vers le haut/bas
(define-key outline-minor-mode-map (kbd "M-<up>")   #'outline-move-subtree-up)
(define-key outline-minor-mode-map (kbd "M-<down>") #'outline-move-subtree-down)

;;; ═══════════════════════════════════════════════════════════════════
;;; Pliage automatique à l'ouverture des .qmd
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-outline-initial-level 1
  "Niveau de titre à garder visible au chargement.
1 = seuls les titres `#` restent visibles, 2 = `##` aussi, etc.")

(defun metal--collapse-buffer-on-open ()
  "Activer outline-minor-mode et plier le buffer si c'est un .qmd."
  (when (and buffer-file-name
             (string-match-p "\\.qmd\\'" buffer-file-name))
    (outline-minor-mode 1)
    (setq-local markdown-mode-outline-regexp "^#+ ")
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       0.1 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (save-excursion
               (goto-char (point-min))
               (outline-hide-body)))))))))

(add-hook 'markdown-mode-hook #'metal--collapse-buffer-on-open)

;;; ═══════════════════════════════════════════════════════════════════
;;; Projet Quarto et rendu
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-quarto-ensure-project-at (dir)
  "Créer _quarto.yml dans DIR si absent."
  (let* ((dir   (file-name-as-directory dir))
         (qfile (expand-file-name "_quarto.yml" dir)))
    (unless (file-exists-p qfile)
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file qfile
          (insert "project:\n  type: default\n\n")
          (insert "metadata:\n  mediabag-output: true\n")))
      (message "_quarto.yml créé dans %s" dir))))

(defun metal-quarto-rendre-fichier ()
  "Rendre le fichier Quarto courant avec 'quarto render'.
Crée _quarto.yml si nécessaire. Vérifie TinyTeX avant le rendu.
Si TinyTeX doit être mis à jour, le rendu est relancé automatiquement après."
  (interactive)
  (when buffer-file-name
    (let ((buf (current-buffer)))
      (if (metal-quarto--ensure-tinytex
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (metal-quarto-rendre-fichier)))))
          ;; TinyTeX OK → procéder au rendu
          (progn
            (save-buffer)
            (let* ((file buffer-file-name)
                   (dir  (file-name-directory file))
                   (name (file-name-nondirectory file)))
              (metal-quarto-ensure-project-at dir)
              (let ((default-directory dir))
                (message "Quarto: rendu de %s..." name)
                (let* ((output-buf (get-buffer-create "*Quarto Render*"))
                       (exit-code (call-process "quarto" nil output-buf t
                                                "render" name)))
                  (if (zerop exit-code)
                      (progn
                        (kill-buffer output-buf)
                        (message "Quarto: rendu terminé pour %s" name))
                    (message "Quarto: ERREUR (code %d) pour %s" exit-code name)
                    (display-buffer output-buf))))))
        ;; TinyTeX en cours de mise à jour → message déjà affiché
        nil))))

(defun metal-quarto--detect-output-format ()
  "Détecte le format de sortie depuis le YAML front-matter."
  (save-excursion
    (goto-char (point-min))
    (cond
     ((re-search-forward "^format:[ \t]*beamer" nil t) 'beamer)
     ((re-search-forward "^format:[ \t]*pdf" nil t) 'pdf)
     ((re-search-forward "^format:[ \t]*html" nil t) 'html)
     ((re-search-forward "^  beamer:" nil t) 'beamer)
     ((re-search-forward "^  pdf:" nil t) 'pdf)
     ((re-search-forward "^  html:" nil t) 'html)
     (t nil))))

(defun metal-quarto-render ()
  "Rendu Quarto adapté au format détecté (beamer/pdf/html).
Vérifie TinyTeX avant le rendu. Relance automatiquement après mise à jour."
  (interactive)
  (let ((buf (current-buffer)))
    (if (metal-quarto--ensure-tinytex
         (lambda ()
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (metal-quarto-render)))))
        ;; TinyTeX OK → procéder au rendu
        (progn
          (save-buffer)
          (let* ((format (metal-quarto--detect-output-format))
                 (cmd (pcase format
                        ('beamer (format "quarto render \"%s\" --to beamer" buffer-file-name))
                        ('pdf    (format "quarto render \"%s\" --to pdf" buffer-file-name))
                        ('html   (format "quarto render \"%s\" --to html" buffer-file-name))
                        (_       (format "quarto render \"%s\"" buffer-file-name)))))
            (message "Rendu Quarto en cours (%s)..." format)
            (async-shell-command cmd "*Quarto Render*")))
      ;; TinyTeX en cours de mise à jour
      nil)))

;; Raccourcis clavier
(with-eval-after-load 'quarto-mode
  (define-key poly-quarto-mode-map (kbd "<S-f8>") #'quarto-preview)
  (define-key poly-quarto-mode-map (kbd "<f8>") #'metal-quarto-rendre-fichier))

;; Raccourci global F8
(global-set-key (kbd "<f8>") #'metal-quarto-render)

;;; ═══════════════════════════════════════════════════════════════════
;;; Formatage : helpers
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-quarto--wrap-or-insert (before after)
  "Entoure la région active avec BEFORE et AFTER, ou insère autour du point."
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (region-end)))
        (save-excursion
          (goto-char end) (insert after)
          (goto-char beg) (insert before)))
    (insert before after)
    (backward-char (length after))))

(defun metal-quarto-bold ()
  "Gras (**...**) sur la région ou le mot au point (toggle).
Gère également le cas du passage gras+italique (***w***)."
  (interactive)
  (let ((delim "**"))
    ;; Détection spéciale : si on est déjà en *w* et qu'on appuie sur Gras,
    ;; on veut passer à ***w*** et non **(*w*)**
    (if (and (use-region-p)
             (let* ((beg (region-beginning))
                    (end (region-end))
                    (len1 (length "*"))
                    (len2 (length "**"))
                    (len3 (length "***")))
               (and (>= beg len1)
                    (<= (+ end len1) (point-max))
                    (string= (buffer-substring-no-properties (- beg len1) beg) "*")
                    (string= (buffer-substring-no-properties end (+ end len1)) "*")
                    ;; Mais pas déjà **w** ni ***w***
                    (not (and (>= beg len2)
                              (string= (buffer-substring-no-properties (- beg len2) beg) "**")
                              (string= (buffer-substring-no-properties end (+ end len2)) "**")))
                    (not (and (>= beg len3)
                              (string= (buffer-substring-no-properties (- beg len3) beg) "***")
                              (string= (buffer-substring-no-properties end (+ end len3)) "***"))))))
        ;; On est dans *w* : on ajoute ** externe ⇒ ***w***
        (let ((beg (region-beginning))
              (end (region-end)))
          (save-excursion
            (goto-char end) (insert "**")
            (goto-char beg) (insert "**")))
      ;; Autres cas gérés par le toggle générique
      (my/org-toggle-wrap-with delim))))

(defun metal-quarto-italic ()
  "Italique (*...*) sur la région ou le mot au point (toggle).
Gère également le cas du passage gras+italique (***w***)."
  (interactive)
  (let ((delim "*"))
    ;; Détection spéciale : si on est déjà en **w** et qu'on appuie sur Italique,
    ;; on veut passer à ***w*** et non *(**w**)*
    (if (and (use-region-p)
             (let* ((beg (region-beginning))
                    (end (region-end))
                    (len2 (length "**"))
                    (len3 (length "***")))
               (and (>= beg len2)
                    (<= (+ end len2) (point-max))
                    (string= (buffer-substring-no-properties (- beg len2) beg) "**")
                    (string= (buffer-substring-no-properties end (+ end len2)) "**")
                    ;; Mais pas déjà ***w***
                    (not (and (>= beg len3)
                              (string= (buffer-substring-no-properties (- beg len3) beg) "***")
                              (string= (buffer-substring-no-properties end (+ end len3)) "***"))))))
        ;; On est dans **w** : on ajoute un * externe ⇒ ***w***
        (save-excursion
          (goto-char end) (insert "*")
          (goto-char beg) (insert "*"))
      ;; Autres cas gérés par le toggle générique
      (my/org-toggle-wrap-with delim))))

;; (defun metal-quarto-underline ()
;;   "Souligne avec <u>...</u> la région ou le texte autour du point (toggle)."
;;   (interactive)
;;   (let ((tag-open "<u>")
;;         (tag-close "</u>"))
;;     (if (use-region-p)
;;         ;; CAS RÉGION
;;         (progn
;;           (when (fboundp 'trim-selection-to-word-boundaries)
;;             (trim-selection-to-word-boundaries))
;;           (let* ((beg (region-beginning))
;;                  (end (region-end))
;;                  (open-len (length tag-open))
;;                  (close-len (length tag-close)))
;;             (save-excursion
;;               (if (and (>= beg open-len)
;;                        (<= (+ end close-len) (point-max))
;;                        (string= (buffer-substring-no-properties (- beg open-len) beg) tag-open)
;;                        (string= (buffer-substring-no-properties end (+ end close-len)) tag-close))
;;                   ;; Déjà souligné -> on retire
;;                   (progn
;;                     (delete-region end (+ end close-len))
;;                     (delete-region (- beg open-len) beg))
;;                 ;; Sinon on ajoute
;;                 (goto-char end) (insert tag-close)
;;                 (goto-char beg) (insert tag-open)))))
;;       ;; CAS SANS RÉGION
;;       (let* ((pos (point))
;;              (line-beg (line-beginning-position))
;;              (line-end (line-end-position))
;;              (open (save-excursion
;;                      (goto-char pos)
;;                      (when (search-backward tag-open line-beg t) (point))))
;;              (close (save-excursion
;;                       (goto-char pos)
;;                       (when (search-forward tag-close line-end t) (point)))))
;;         (cond
;;          ;; Entre <u> et </u> -> on enlève
;;          ((and open close (< open pos) (> close pos))
;;           (save-excursion
;;             (delete-region (- close (length tag-close)) close)
;;             (delete-region open (+ open (length tag-open)))))
;;          ;; Sinon, on applique au mot au point
;;          (t
;;           (let ((bounds (bounds-of-thing-at-point 'word)))
;;             (if (not bounds)
;;                 (message "Aucun mot trouvé.")
;;               (let ((beg (car bounds))
;;                     (end (cdr bounds)))
;;                 (save-excursion
;;                   (if (and (>= beg (length tag-open))
;;                            (<= (+ end (length tag-close)) (point-max))
;;                            (string= (buffer-substring-no-properties (- beg (length tag-open)) beg) tag-open)
;;                            (string= (buffer-substring-no-properties end (+ end (length tag-close))) tag-close))
;;                       ;; Déjà souligné -> on retire
;;                       (progn
;;                         (delete-region end (+ end (length tag-close)))
;;                         (delete-region (- beg (length tag-open)) beg))
;;                     ;; Sinon, on ajoute
;;                     (goto-char end) (insert tag-close)
;;                     (goto-char beg) (insert tag-open))))))))))))


(defun metal-quarto-underline ()
  "Souligne avec \\uline{...} (compatible PDF + HTML via Pandoc). Toggle."
  (interactive)
  (let ((tag-open "\\uline{")
        (tag-close "}"))
    (if (use-region-p)
        ;; CAS RÉGION
        (progn
          (when (fboundp 'trim-selection-to-word-boundaries)
            (trim-selection-to-word-boundaries))
          (let* ((beg (region-beginning))
                 (end (region-end))
                 (open-len (length tag-open))
                 (close-len (length tag-close)))
            (save-excursion
              (if (and (>= beg open-len)
                       (<= (+ end close-len) (point-max))
                       (string= (buffer-substring-no-properties (- beg open-len) beg) tag-open)
                       (string= (buffer-substring-no-properties end (+ end close-len)) tag-close))
                  ;; Déjà souligné -> on retire
                  (progn
                    (delete-region end (+ end close-len))
                    (delete-region (- beg open-len) beg))
                ;; Sinon on ajoute
                (goto-char end) (insert tag-close)
                (goto-char beg) (insert tag-open)))))
      
      ;; CAS SANS RÉGION
      (let* ((pos (point))
             (line-beg (line-beginning-position))
             (line-end (line-end-position))
             (open (save-excursion
                     (goto-char pos)
                     (when (search-backward tag-open line-beg t) (point))))
             (close (save-excursion
                      (goto-char pos)
                      (when (search-forward tag-close line-end t) (point)))))
        (cond
         ;; Entre \uline{ et } -> on enlève
         ((and open close (< open pos) (> close pos))
          (save-excursion
            (delete-region (1- close) close)
            (delete-region open (+ open (length tag-open)))))
         
         ;; Sinon, appliquer au mot
         (t
          (let ((bounds (bounds-of-thing-at-point 'word)))
            (if (not bounds)
                (message "Aucun mot trouvé.")
              (let ((beg (car bounds))
                    (end (cdr bounds)))
                (save-excursion
                  (if (and (>= beg (length tag-open))
                           (<= (+ end (length tag-close)) (point-max))
                           (string= (buffer-substring-no-properties (- beg (length tag-open)) beg) tag-open)
                           (string= (buffer-substring-no-properties end (+ end (length tag-close))) tag-close))
                      ;; Déjà souligné -> on retire
                      (progn
                        (delete-region end (+ end (length tag-close)))
                        (delete-region (- beg (length tag-open)) beg))
                    ;; Sinon on ajoute
                    (goto-char end) (insert tag-close)
                    (goto-char beg) (insert tag-open))))))))))))

(defun metal-quarto-strike ()
  "Bascule le barré en Markdown (~~...~~) sur la région ou le mot au point."
  (interactive)
  (my/org-toggle-wrap-with "~~"))

(defun metal-quarto-code ()
  "Code inline (`...`) sur la région ou le mot au point (toggle)."
  (interactive)
  (my/org-toggle-wrap-with "`"))

(defun metal-quarto-code-block ()
  "Insère un bloc de code clôturé pour Quarto/Markdown."
  (interactive)
  (let ((lang (read-string "Langage (vide pour aucun) : ")))
    (insert "```" lang "\n")
    (save-excursion
      (insert "\n```"))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Documentation et aide
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-quarto-doc-buffer ()
  "Ouvrir le guide officiel Quarto.
Si xwidget-webkit est disponible, l'ouvrir dans Emacs, sinon navigateur externe."
  (interactive)
  (let ((url "https://quarto.org/docs/guide/"))
    (cond
     ((and (featurep 'xwidget-internal)
           (display-graphic-p)
           (fboundp 'xwidget-webkit-browse-url))
      (require 'xwidget)
      (xwidget-webkit-browse-url url))
     (t
      (browse-url url)))))

(defun metal-quarto-open-cheatsheet ()
  "Ouvre la feuille de référence quarto-aide-memoire.pdf dans Emacs."
  (interactive)
  (let ((pdf-file (expand-file-name "Quarto_Cheat_Sheet.pdf" user-emacs-directory)))
    (if (file-exists-p pdf-file)
        (find-file pdf-file)
      (user-error "Fichier introuvable : %s" pdf-file))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Barre d'outils header-line
;;; ═══════════════════════════════════════════════════════════════════

(require 'metal-toolbar)

(defun metal-quarto-toolbar-format ()
  "Construit la barre d'outils Quarto."
  (concat
   (metal-toolbar-vpadding) " "

   ;; ----- Formatage de texte -----
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-format_bold" :color "#2c3e50")
    "Gras" #'metal-quarto-bold)
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-format_italic" :color "#2c3e50")
    "Italique" #'metal-quarto-italic)
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-format_underline" :color "#2980b9")
    "Souligné" #'metal-quarto-underline)
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-format_strikethrough" :color "#c0392b")
    "Barré" #'metal-quarto-strike)
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-code_tags" :color "#8e44ad")
    "Code inline" #'metal-quarto-code)

   (metal-toolbar-separator)

   ;; ----- Production -----
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-file_pdf_box" :color "#c0392b")
    "Produire le document (F8)" #'metal-quarto-rendre-fichier)

   (metal-toolbar-separator)

   ;; ----- Référence -----
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-book_open_page_variant" :color "#1e8449")
    "Wiktionnaire" #'search-wiktionary)
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-wikipedia" :color "#5d6d7e")
    "Wikipédia" #'search-wikipedia)
   (metal-toolbar-button
    (metal-toolbar-icon "nf-md-book_open_variant" :color "#2980b9")
    "Documentation Quarto" #'metal-quarto-doc-buffer)

   " " (metal-toolbar-vpadding)))

(defun metal-quarto-header-line ()
  "Active la barre d'outils si le tampon courant est un fichier .qmd."
  (when (and buffer-file-name
             (string-match-p "\\.qmd\\'" buffer-file-name))
    (metal-toolbar-setup-header-line-style)
    (setq-local header-line-format
                '(:eval (metal-quarto-toolbar-format)))))

;; Activer cette barre pour les fichiers .qmd ouverts en markdown-mode
(add-hook 'markdown-mode-hook #'metal-quarto-header-line)

;;; ═══════════════════════════════════════════════════════════════════
;;; Conversion Org-mode vers Quarto (.qmd)
;;; ═══════════════════════════════════════════════════════════════════

(defgroup metal-org-to-qmd nil
  "Conversion de fichiers Org-mode vers Quarto."
  :group 'quarto
  :prefix "metal-org-to-qmd-")

(defcustom metal-org-to-qmd-default-theme "default"
  "Thème RevealJS par défaut pour les présentations."
  :type 'string
  :group 'metal-org-to-qmd)

(defcustom metal-org-to-qmd-slide-number t
  "Afficher les numéros de diapositives."
  :type 'boolean
  :group 'metal-org-to-qmd)

(defcustom metal-org-to-qmd-transition "slide"
  "Type de transition entre diapositives."
  :type '(choice (const "slide")
                 (const "fade")
                 (const "convex")
                 (const "concave")
                 (const "zoom")
                 (const "none"))
  :group 'metal-org-to-qmd)

(defcustom metal-org-to-qmd-heading-offset 1
  "Décalage des niveaux de titres Org vers Markdown.
Avec 1, un titre * en Org devient ## en QMD (niveau 2 = diapositive)."
  :type 'integer
  :group 'metal-org-to-qmd)

(defcustom metal-org-to-qmd-include-yaml-header nil
  "Si non-nil, génère l'en-tête YAML pour Quarto.
Par défaut nil (pas d'en-tête généré)."
  :type 'boolean
  :group 'metal-org-to-qmd)

(defun metal-org-to-qmd--extract-keyword (keyword)
  "Extraire la valeur d'un KEYWORD du buffer Org courant."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.+\\)$" keyword) nil t)
      (match-string-no-properties 1))))

(defun metal-org-to-qmd--generate-yaml-header ()
  "Générer l'en-tête YAML pour Quarto RevealJS."
  (let ((title (or (metal-org-to-qmd--extract-keyword "TITLE") "Présentation"))
        (subtitle (metal-org-to-qmd--extract-keyword "SUBTITLE")))
    (concat "---\n"
            (format "title: \"%s\"\n" title)
            (when subtitle (format "subtitle: \"%s\"\n" subtitle))
            "format: \n"
            "  revealjs:\n"
            (format "    theme: %s\n" metal-org-to-qmd-default-theme)
            (format "    slide-number: %s\n" (if metal-org-to-qmd-slide-number "true" "false"))
            (format "    transition: %s\n" metal-org-to-qmd-transition)
            "---\n\n")))

(defun metal-org-to-qmd--convert-heading (level text)
  "Convertir un titre Org de niveau LEVEL avec TEXT en Markdown.
Les titres sont décalés selon `metal-org-to-qmd-heading-offset'."
  (let ((md-level (+ level metal-org-to-qmd-heading-offset)))
    (concat (make-string md-level ?#) " " text "\n")))

(defun metal-org-to-qmd--convert-list-item (text indent-level)
  "Convertir un élément de liste avec TEXT et INDENT-LEVEL."
  (let ((indent (make-string (* indent-level 2) ?\s)))
    (concat indent "- " (string-trim text) "\n")))

(defun metal-org-to-qmd--convert-remarque (content)
  "Convertir un bloc remarque avec CONTENT en callout Quarto."
  (concat "::: {.callout-note}\n"
          (string-trim content) "\n"
          ":::\n\n"))

(defun metal-org-to-qmd--convert-code-block (lang content)
  "Convertir un bloc de code avec LANG et CONTENT."
  (concat "```" (or lang "") "\n"
          content
          "```\n\n"))

(defun metal-org-to-qmd--process-buffer ()
  "Traiter le buffer Org courant et retourner le contenu QMD."
  (let ((output (if metal-org-to-qmd-include-yaml-header
                    (metal-org-to-qmd--generate-yaml-header)
                  ""))
        (in-code nil)
        (code-lang nil)
        (code-content "")
        (in-remarque nil)
        (remarque-content ""))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
          (cond
           ;; Ignorer les lignes de configuration Org
           ((string-match-p "^#\\+\\(SETUPFILE\\|TITLE\\|SUBTITLE\\|OPTIONS\\):" line)
            nil)

           ;; Début de bloc remarque LaTeX
           ((string-match "^\\\\begin{remarque}" line)
            (setq in-remarque t
                  remarque-content ""))

           ;; Fin de bloc remarque
           ((string-match "^\\\\end{remarque}" line)
            (setq output (concat output (metal-org-to-qmd--convert-remarque remarque-content)))
            (setq in-remarque nil))

           ;; Contenu de remarque
           (in-remarque
            (setq remarque-content (concat remarque-content line "\n")))

           ;; Début de bloc code Org
           ((string-match "^#\\+begin_\\(src\\|code\\|example\\)\\(?:[ \t]+\\([a-zA-Z0-9_-]+\\)\\)?" line)
            (setq in-code t
                  code-lang (match-string 2 line)
                  code-content ""))

           ;; Fin de bloc code
           ((string-match "^#\\+end_\\(src\\|code\\|example\\)" line)
            (setq output (concat output (metal-org-to-qmd--convert-code-block code-lang code-content)))
            (setq in-code nil))

           ;; Contenu de code
           (in-code
            (setq code-content (concat code-content line "\n")))

           ;; Titres Org (* ** *** etc.)
           ((string-match "^\\(\\*+\\)[ \t]+\\(.+\\)$" line)
            (let ((level (length (match-string 1 line)))
                  (text (match-string 2 line)))
              (setq output (concat output "\n" (metal-org-to-qmd--convert-heading level text)))))

           ;; Éléments de liste Org
           ((string-match "^\\([ \t]*\\)-[ \t]+\\(.+\\)$" line)
            (let ((indent (/ (length (match-string 1 line)) 2))
                  (text (match-string 2 line)))
              (setq output (concat output (metal-org-to-qmd--convert-list-item text indent)))))

           ;; Commandes LaTeX à ignorer
           ((string-match "^\\\\\\(Large\\|footnotesize\\|center\\|col[GDF]\\|lstinputlisting\\)" line)
            nil)

           ;; Liens Org [[lien][texte]] -> [texte](lien)
           ((string-match "\\[\\[\\([^]]+\\)\\]\\[\\([^]]+\\)\\]\\]" line)
            (let ((url (match-string 1 line))
                  (text (match-string 2 line)))
              (setq line (replace-regexp-in-string
                          "\\[\\[\\([^]]+\\)\\]\\[\\([^]]+\\)\\]\\]"
                          (format "[%s](%s)" text url)
                          line t t))
              (setq output (concat output line "\n"))))

           ;; Lignes normales (non vides, pas de commandes Org/LaTeX)
           ((and (not (string-match-p "^[ \t]*$" line))
                 (not (string-match-p "^#\\+" line))
                 (not (string-match-p "^{{{" line)))
            (setq output (concat output line "\n")))

           ;; Lignes vides
           ((string-match-p "^[ \t]*$" line)
            (setq output (concat output "\n")))))
        (forward-line 1)))
    ;; Nettoyer les lignes vides multiples
    (replace-regexp-in-string "\n\\{3,\\}" "\n\n" output)))

;;;###autoload
(defun metal-org-to-qmd-convert-buffer ()
  "Convertir le buffer Org courant en Quarto et afficher dans un nouveau buffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Ce buffer n'est pas en mode Org"))
  (let ((qmd-content (metal-org-to-qmd--process-buffer))
        (qmd-buffer (get-buffer-create "*Org to QMD*")))
    (with-current-buffer qmd-buffer
      (erase-buffer)
      (insert qmd-content)
      (when (fboundp 'markdown-mode)
        (markdown-mode))
      (goto-char (point-min)))
    (switch-to-buffer-other-window qmd-buffer)
    (message "Conversion terminée. Vérifiez et sauvegardez avec C-x C-w")))

;;;###autoload
(defun metal-org-to-qmd-convert-file (org-file &optional qmd-file)
  "Convertir ORG-FILE en QMD-FILE.
Si QMD-FILE n'est pas spécifié, utilise le même nom avec extension .qmd."
  (interactive "fFichier Org à convertir: ")
  (let* ((qmd-file (or qmd-file
                       (concat (file-name-sans-extension org-file) ".qmd")))
         (qmd-content nil))
    (with-temp-buffer
      (insert-file-contents org-file)
      (org-mode)
      (setq qmd-content (metal-org-to-qmd--process-buffer)))
    (with-temp-file qmd-file
      (insert qmd-content))
    (message "Fichier converti: %s" qmd-file)
    qmd-file))

;;;###autoload
(defun metal-org-to-qmd-export ()
  "Exporter le buffer Org courant vers un fichier .qmd dans le même répertoire."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Ce buffer n'est pas en mode Org"))
  (let* ((org-file (buffer-file-name))
         (qmd-file (concat (file-name-sans-extension org-file) ".qmd")))
    (when (or (not (file-exists-p qmd-file))
              (yes-or-no-p (format "Le fichier %s existe. Écraser? " qmd-file)))
      (metal-org-to-qmd-convert-file org-file qmd-file)
      (find-file-other-window qmd-file))))

;; Raccourci dans org-mode
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c q") #'metal-org-to-qmd-export))

;;; ═══════════════════════════════════════════════════════════════════
;;; Conversion texte → tableau LaTeX / Markdown
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-quarto--parse-table-lines (text separator)
  "Parse TEXT en liste de paires (col1 . col2) selon SEPARATOR."
  (let ((lines (split-string text "\n" t "[ \t]*"))
        (result '()))
    (dolist (line lines)
      (let* ((parts (split-string line (regexp-quote separator)))
             (col1 (string-trim (or (nth 0 parts) "")))
             (col2 (string-trim (or (nth 1 parts) ""))))
        (when (and (> (length col1) 0) (> (length col2) 0))
          (push (cons col1 col2) result))))
    (nreverse result)))

(defun metal-quarto--max-width (pairs accessor)
  "Retourne la largeur max des éléments de PAIRS via ACCESSOR."
  (apply #'max (mapcar (lambda (p) (length (funcall accessor p))) pairs)))

(defun metal-quarto-texte-vers-tableau-latex (beg end separator)
  "Convertit la région en tableau LaTeX.
Demande le séparateur (ex. : ou | ou , ou \\t) puis le style :
  1. Grillage complet (lignes verticales + horizontales)
  2. Lignes verticales seulement
  3. Booktabs (style académique)"
  (interactive "r\nsSéparateur: ")
  (let* ((sep (if (string= separator "\\t") "\t" separator))
         (text (buffer-substring-no-properties beg end))
         (pairs (metal-quarto--parse-table-lines text sep))
         (w1 (metal-quarto--max-width pairs #'car))
         (style (completing-read "Style: "
                                 '("1 - Grillage complet"
                                   "2 - Lignes verticales"
                                   "3 - Booktabs")
                                 nil t))
         (style-num (string-to-number (substring style 0 1)))
         (output "```{=latex}\n"))
    (pcase style-num
      ;; Grillage complet
      (1
       (setq output (concat output "\\begin{tabular}{|l|l|}\n\\hline\n"))
       (dolist (p pairs)
         (let ((col1 (car p))
               (col2 (cdr p)))
           (setq output (concat output
                                col1 (make-string (- w1 (length col1)) ?\s)
                                " & " col2 " \\\\ \\hline\n"))))
       (setq output (concat output "\\end{tabular}\n")))
      ;; Lignes verticales seulement
      (2
       (setq output (concat output "\\begin{tabular}{|l|l|}\n\\hline\n"))
       (dolist (p pairs)
         (let ((col1 (car p))
               (col2 (cdr p)))
           (setq output (concat output
                                col1 (make-string (- w1 (length col1)) ?\s)
                                " & " col2 " \\\\\n"))))
       (setq output (concat output "\\hline\n\\end{tabular}\n")))
      ;; Booktabs
      (3
       (setq output (concat output "\\begin{tabular}{ll}\n\\toprule\n"))
       (let ((last-p (car (last pairs))))
         (dolist (p pairs)
           (let ((col1 (car p))
                 (col2 (cdr p)))
             (setq output (concat output
                                  col1 (make-string (- w1 (length col1)) ?\s)
                                  " & " col2 " \\\\\n")))))
       (setq output (concat output "\\bottomrule\n\\end{tabular}\n"))))
    (setq output (concat output "```\n"))
    (delete-region beg end)
    (insert output)))

(defun metal-quarto-texte-vers-tableau-md (beg end separator)
  "Convertit la région en tableau Markdown.
Demande le séparateur (ex. : ou | ou , ou \\t).
La région doit contenir des lignes au format :
  colonne1 SEPARATEUR colonne2"
  (interactive "r\nsSéparateur: ")
  (let* ((sep (if (string= separator "\\t") "\t" separator))
         (text (buffer-substring-no-properties beg end))
         (pairs (metal-quarto--parse-table-lines text sep))
         (w1 (metal-quarto--max-width pairs #'car))
         (w2 (metal-quarto--max-width pairs #'cdr))
         (header (concat "| " (make-string w1 ?\s) " | " (make-string w2 ?\s) " |\n"))
         (sep-line (concat "|-" (make-string w1 ?-) "-|-" (make-string w2 ?-) "-|\n"))
         (output (concat header sep-line)))
    (dolist (p pairs)
      (let ((col1 (car p))
            (col2 (cdr p)))
        (setq output (concat output
                             "| " col1 (make-string (- w1 (length col1)) ?\s)
                             " | " col2 (make-string (- w2 (length col2)) ?\s)
                             " |\n"))))
    (delete-region beg end)
    (insert output)))



(provide 'metal-quarto)

;;; metal-quarto.el ends here
