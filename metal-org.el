;; -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;; ============================================================
;; METAL-ORG — Configuration Org-mode pour MetalEmacs
;; ============================================================

;; ============================================================
;;  1. APPARENCE ET DÉMARRAGE
;; ============================================================

;; Faces des titres Org
(eval-after-load 'org
  '(progn
     (set-face-attribute 'org-level-1 nil :foreground "dark blue" :weight 'bold :height 1.3 :family "Arial")
     (set-face-attribute 'org-level-2 nil :foreground "dark green" :weight 'bold :height 1.3 :family "Arial")
     (set-face-attribute 'org-level-3 nil :foreground "dark red" :weight 'bold :height 1.2 :family "Arial")))

;; Options de démarrage
(setq org-startup-folded 'overview)
(setq org-cycle-global-at-bob t)
(setq org-cycle-separator-lines 0)

;; Style bloc-note (OneNote)
(setq-default org-startup-indented t
              org-pretty-entities t
              org-use-sub-superscripts "{}"
              org-startup-with-inline-images t
              org-image-actual-width '(300)
              org-startup-folded 'overview)

;; Espacement des lignes en Org
(add-hook 'org-mode-hook (lambda () (setq line-spacing 0.3)))

;; ;; Replier toutes les sections à l'ouverture
;; (add-hook 'org-mode-hook
;;           (lambda ()
;;             (org-overview)))

;; Ouvrir les liens dans la même fenêtre
(setq org-link-frame-setup
   '((vm . vm-visit-folder-other-frame)
     (vm-imap . vm-visit-imap-folder-other-frame)
     (gnus . org-gnus-no-new-news)
     (file . find-file)
     (wl . wl-other-frame)))

;; ============================================================
;;  2. EXPORT LATEX / BEAMER / ODT
;; ============================================================

;; Sauvegarde automatique avant export
(defun metal-org-save-before-any-export (&rest _args)
  "Save current Org buffer if modified, before any export-to-file."
  (when (and (derived-mode-p 'org-mode)
             (buffer-file-name)
             (buffer-modified-p))
    (save-buffer)))

(with-eval-after-load 'ox
  (advice-add 'org-export-to-file :before #'metal-org-save-before-any-export))

;; Chemin TeX sur macOS
(if (eq system-type 'darwin)
    (progn
      (setenv "PATH" (concat "/Library/TeX/texbin:/opt/local/bin:" (getenv "PATH")))
      (add-to-list 'exec-path "/Library/TeX/texbin")
      (add-to-list 'exec-path "/opt/local/bin")))

;; Compilateur LaTeX
(setq org-latex-compiler "xelatex")
(setq org-latex-pdf-process
      '("xelatex -interaction nonstopmode -output-directory %o %f"
        "xelatex -interaction nonstopmode -output-directory %o %f"))

;; Listings pour les blocs de code
(setq org-latex-src-block-backend 'listings)

;; AUCTeX
(use-package auctex
  :ensure t)

(require 'ox-latex)
(require 'ox-beamer)
(require 'ox-odt)

;; Reveal.js
(use-package ox-reveal
  :ensure t
  :after org
  :config
  (setq org-reveal-root
        (concat "file://" (expand-file-name "~/.emacs.d/reveal.js"))))

;; PDF dans Org
(use-package org-pdfview
  :config
  (add-to-list 'org-file-apps '("\\.pdf\\'" . (lambda (file link)
                                                 (org-pdfview-open link)))))

;; Classes LaTeX personnalisées
(seq-map (apply-partially #'add-to-list 'org-latex-classes)
         '(("koma-letter"
            "\\documentclass{scrlttr2}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("koma-article"
            "\\documentclass{scrartcl}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("koma-book"
            "\\documentclass{scrbook}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("koma-book-chapters"
            "\\documentclass{scrbook}"
            ("\\chapter{%s}" . "\\chapter*{%s}")
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("koma-report"
            "\\documentclass{scrreprt}"
            ("\\chapter{%s}" . "\\chapter*{%s}")
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("memoir"
            "\\documentclass{memoir}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("hitec"
            "\\documentclass{hitec}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("paper"
            "\\documentclass{paper}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("letter"
            "\\documentclass{letter}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("tufte-handout"
            "\\documentclass{tufte-handout}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("tufte-book"
            "\\documentclass{tufte-book}"
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("tufte-book-chapters"
            "\\documentclass{tufte-book}"
            ("\\chapter{%s}" . "\\chapter*{%s}")
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\subsection*{%s}")
            ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}"))
           ("labbook"
            "\\documentclass{labbook}"
            ("\\chapter{%s}" . "\\chapter*{%s}")
            ("\\section{%s}" . "\\section*{%s}")
            ("\\subsection{%s}" . "\\labday{%s}")
            ("\\subsubsection{%s}" . "\\experiment{%s}")
            ("\\paragraph{%s}" . "\\paragraph*{%s}")
            ("\\subparagraph{%s}" . "\\subparagraph*{%s}")
            ("beamer"
                ,(concat "\\documentclass[presentation]{beamer}\n"
                         "[DEFAULT-PACKAGES]"
                         "[PACKAGES]"
                         "[EXTRA]\n")
                ("\\section{%s}" . "\\section*{%s}")
                ("\\subsection{%s}" . "\\subsection*{%s}")
                ("\\subsubsection{%s}" . "\\subsubsection*{%s}")))))

;; (defun org-cree-pdf ()
;;   (interactive)
;;   (save-buffer)
;;   (org-beamer-export-to-pdf))

(defun my/org-compile ()
  "Compile le fichier org selon la directive #+OUTPUT_TYPE."
  (interactive)
  (save-buffer)
  (let ((output-type (save-excursion
                       (goto-char (point-min))
                       (when (re-search-forward
                              "^#\\+OUTPUT_TYPE:\\s-*\\(.+\\)" nil t)
                         (string-trim (match-string 1))))))
    (pcase output-type
      ("presentation" (org-beamer-export-to-pdf))
      ("document"     (org-latex-export-to-pdf))
      (_              (message "OUTPUT_TYPE non reconnu : %s" output-type)))))

;; ============================================================
;;  3. TAB / SHIFT-TAB DANS ORG
;; ============================================================

(with-eval-after-load 'org
  (define-key org-mode-map (kbd "<tab>") #'org-cycle)
  (define-key org-mode-map (kbd "TAB")   #'org-cycle)
  (define-key org-mode-map [backtab]     #'org-shifttab))

;; ============================================================
;;  4. RACCOURCIS CLAVIER ORG
;; ============================================================

(global-set-key (kbd "C-c c") 'org-capture)

(add-hook 'org-mode-hook
          (lambda ()
            (define-key org-mode-map (kbd "<f5>") #'org-insert-structure-template)
            ;; (define-key org-mode-map (kbd "M-<f8>") #'my/org-compile)
            ;; (define-key org-mode-map (kbd "S-<f8>") #'org-latex-export-to-pdf)
            (define-key org-mode-map (kbd "<f8>") #'my/org-compile)))

;; ============================================================
;;  5. FORMATAGE GRAS / ITALIQUE / SOULIGNÉ / BARRÉ / CODE
;; ============================================================

(defun trim-selection-to-word-boundaries ()
  "Ajuste la sélection pour qu'elle commence et se termine aux limites des mots,
en excluant les espaces au début et à la fin."
  (interactive)
  (if (use-region-p)
      (let* ((beg (region-beginning))
             (end (region-end))
             (text (buffer-substring-no-properties beg end))
             (trimmed (string-trim text))
             (new-beg (progn (goto-char beg)
                             (re-search-forward "[^\s,.:;]" nil t)
                             (backward-char)
                             (point)))
             (new-end (progn (goto-char end)
                             (re-search-backward "[^\s,.:;]" nil t)
                             (forward-char)
                             (point))))
        (goto-char new-beg)
        (set-mark new-end)
        (activate-mark))
    (message "Aucune sélection active.")))

(defun my/org-toggle-wrap-with (delim)
  "Bascule l'encadrement de la région ou du mot/segment autour du point avec DELIM.

Sans région :
- Si le point est entre deux DELIM sur la même ligne, on les enlève
  (sauf cas spécial du gras quand DELIM est \"*\").
- Sinon, on bascule sur le mot au point."
  (let ((len (length delim)))
    (if (use-region-p)
        ;; ----- CAS REGION -----
        (let* ((beg (region-beginning))
               (end (region-end)))
          (save-excursion
            ;; Si la région est déjà exactement entourée par DELIM, on les enlève
            (if (and (<= (+ beg len) end)
                     (string= (buffer-substring-no-properties beg (+ beg len)) delim)
                     (string= (buffer-substring-no-properties (- end len) end) delim))
                (progn
                  (delete-region (- end len) end)
                  (delete-region beg (+ beg len)))
              ;; Sinon, on resserre éventuellement aux mots et on ajoute DELIM
              (when (fboundp 'trim-selection-to-word-boundaries)
                (trim-selection-to-word-boundaries))
              (setq beg (region-beginning)
                    end (region-end))
              (goto-char end)
              (insert delim)
              (goto-char beg)
              (insert delim))))

      ;; ----- CAS SANS REGION -----
      (let* ((pos (point))
             (line-beg (line-beginning-position))
             (line-end (line-end-position))
             ;; délimiteur ouvrant le plus proche avant le point (sur la ligne)
             (open (save-excursion
                     (goto-char pos)
                     (when (search-backward delim line-beg t)
                       (point))))
             ;; délimiteur fermant le plus proche après le point (sur la ligne)
             (close (save-excursion
                      (goto-char pos)
                      (when (search-forward delim line-end t)
                        (- (point) len)))))
        (cond
         ;; 1) On est entre deux DELIM sur la même ligne
         ((and open close (< open pos) (> close pos)
               ;; Cas spécial : si DELIM = "*" et on est dans **...** ou ***...***,
               ;; NE PAS retirer les délimiteurs (laisser l'italique gérer ça).
               (let ((ok t))
                 (when (string= delim "*")
                   (save-excursion
                     (let ((run-left 1)
                           (run-right 1))
                       ;; Longueur de la "course" de * à gauche (run-left)
                       (goto-char open)
                       (while (and (> (point) line-beg)
                                   (eq (char-before) ?*))
                         (setq run-left (1+ run-left))
                         (backward-char))
                       ;; Longueur de la "course" de * à droite (run-right)
                       (goto-char close)
                       (while (and (< (point) line-end)
                                   (eq (char-after (1+ (point))) ?*))
                         (setq run-right (1+ run-right))
                         (forward-char))
                       ;; Si on a plus d'un * de chaque côté (gras ou gras+italique),
                       ;; on ne retire pas ici : on laisse metal-quarto-italic décider.
                       (unless (and (= run-left 1) (= run-right 1))
                         (setq ok nil)))))
                 ok))
          (save-excursion
            (delete-region close (+ close len))   ; fermer
            (delete-region open (+ open len))))   ; ouvrir

         ;; 2) Sinon, on bascule sur le mot au point comme avant
         (t
          (let ((bounds (bounds-of-thing-at-point 'word)))
            (if bounds
                (let ((beg (car bounds))
                      (end (cdr bounds)))
                  (save-excursion
                    (if (and (>= beg len)
                             (<= (+ end len) (point-max))
                             (string=
                              (buffer-substring-no-properties (- beg len) beg) delim)
                             (string=
                              (buffer-substring-no-properties end (+ end len)) delim))
                        ;; DELIM mot DELIM -> on enlève
                        (progn
                          (delete-region end (+ end len))
                          (delete-region (- beg len) beg))
                      ;; Sinon on ajoute
                      (goto-char end)
                      (insert delim)
                      (goto-char beg)
                      (insert delim))))
              (message "Aucun mot trouve.")))))))

    ;; Si on vient de poser les DELIM sans région (cas mot), replacer le point dedans
    (when (and (not (use-region-p))
               (> len 0))
      (backward-char len))))

(defun select-style ()
  "Sélectionne la région si le curseur est sur du texte mis en forme
(gras, italique, souligné, barré ou code).
Si aucun texte mis en forme n'est trouvé, ne sélectionne rien."
  (interactive)
  (let ((bounds nil))
    (cond
     ;; Org-mode
     ((derived-mode-p 'org-mode)
      (let* ((element (org-element-context))
             (type (org-element-type element)))
        (when (memq type '(bold italic underline strike-through verbatim code))
          (setq bounds (cons (org-element-property :begin element)
                             (org-element-property :end element))))))
     ;; Markdown
     ((derived-mode-p 'markdown-mode)
      (setq bounds (markdown-get-enclosing-delimiters)))
     ;; reStructuredText
     ((derived-mode-p 'rst-mode)
      (setq bounds (rst-get-enclosing-delimiters)))
     ;; Texte enrichi (face properties)
     ((or (derived-mode-p 'text-mode) (derived-mode-p 'fundamental-mode))
      (let ((faces '(bold italic underline strike-through font-lock-variable-name-face
                    font-lock-keyword-face font-lock-function-name-face)))
        (when (cl-some (lambda (face) (get-text-property (point) 'face)) faces)
          (setq bounds (bounds-of-thing-at-point 'word))))))
    (if bounds
        (progn
          (goto-char (car bounds))
          (set-mark (cdr bounds))
          (message "Région stylisée sélectionnée"))
      (message "Pas de texte mis en forme trouvé"))))

(defun gras ()
  "Basculer la mise en forme gras (en entourant avec *) en org-mode."
  (interactive)
  (my/org-toggle-wrap-with "*"))

(defun italique ()
  "Basculer la mise en forme italique (en entourant avec /) en org-mode."
  (interactive)
  (my/org-toggle-wrap-with "/"))

(defun souligne ()
  "Basculer la mise en forme souligné (en entourant avec _) en org-mode."
  (interactive)
  (my/org-toggle-wrap-with "_"))

(defun barre ()
  "Basculer la mise en forme barré (en entourant avec +) en org-mode."
  (interactive)
  (my/org-toggle-wrap-with "+"))

(defun code ()
  "Basculer la mise en forme code (en entourant avec ~) en org-mode."
  (interactive)
  (my/org-toggle-wrap-with "~"))

;; Raccourcis formatage
(add-hook 'org-mode-hook (lambda () (local-set-key (kbd "M-g") 'gras)))
(add-hook 'org-mode-hook (lambda () (local-set-key (kbd "M-i") 'italique)))
(add-hook 'org-mode-hook (lambda () (local-set-key (kbd "M-s") 'souligne)))

;; ============================================================
;;  6. EXTRACTION GRAS / ITALIQUE / SOULIGNÉ
;; ============================================================



(defun extraire-gras ()
  "Extraire les mots/expressions en gras (*...*) du buffer courant."
  (interactive)
  (let ((gras-words '())
        (buffer-name "*GRAS*")
        (texte (buffer-substring-no-properties (point-min) (point-max)))
        (pos 0))
    (while (string-match "\\*\\([^*\n]\\{1,300\\}\\)\\*" texte pos)
      (let ((mot (string-trim (match-string 1 texte))))
        (when (and (> (length mot) 0)
                   (string-match-p "[[:alpha:]]" mot))
          (push mot gras-words)))
      (setq pos (match-end 0)))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (dolist (word (reverse gras-words))
        (insert word "\n"))
      (goto-char (point-min))
      (tab-line-mode 1))
    (switch-to-buffer-other-window buffer-name)
    (message "Mots en gras extraits dans le buffer '%s'." buffer-name)))

(defun extraire-italique ()
  "Extraire les mots/expressions en italique (/.../) du buffer courant."
  (interactive)
  (let ((ital-words '())
        (buffer-name "*ITALIQUES*")
        (texte (buffer-substring-no-properties (point-min) (point-max)))
        (pos 0))
    (while (string-match "/\\([^/\n]\\{1,1200\\}\\)/" texte pos)
      (let ((mot (string-trim (match-string 1 texte))))
        (when (and (> (length mot) 0)
                   (string-match-p "[[:alpha:]]" mot))
          (push mot ital-words)))
      (setq pos (match-end 0)))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (dolist (word (reverse ital-words))
        (insert word "\n"))
      (goto-char (point-min))
      (tab-line-mode 1))
    (switch-to-buffer-other-window buffer-name)
    (message "Mots en italique extraits dans le buffer '%s'." buffer-name)))



(defun extraire-souligne ()
  "Extraire les mots/expressions soulignés (_..._) du buffer courant."
  (interactive)
  (let ((soul-words '())
        (buffer-name "*SOULIGNÉS*")
        (texte (buffer-substring-no-properties (point-min) (point-max)))
        (pos 0))
    (while (string-match "_\\([^_\n]\\{1,300\\}\\)_" texte pos)
      (let ((mot (string-trim (match-string 1 texte))))
        (when (and (> (length mot) 0)
                   (string-match-p "[[:alpha:]]" mot))
          (push mot soul-words)))
      (setq pos (match-end 0)))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (dolist (word (reverse soul-words))
        (insert word "\n"))
      (goto-char (point-min))
      (tab-line-mode 1))
    (switch-to-buffer-other-window buffer-name)
    (message "Mots soulignés extraits dans le buffer '%s'." buffer-name)))


(defun extraire-barre ()
  "Extraire les mots/expressions barrés (+...+) du buffer courant."
  (interactive)
  (let ((barre-words '())
        (buffer-name "*BARRÉS*")
        (texte (buffer-substring-no-properties (point-min) (point-max)))
        (pos 0))
    (while (string-match "\\+\\([^+\n]\\{1,300\\}\\)\\+" texte pos)
      (let ((mot (string-trim (match-string 1 texte))))
        (when (and (> (length mot) 0)
                   (string-match-p "[[:alpha:]]" mot))
          (push mot barre-words)))
      (setq pos (match-end 0)))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (dolist (word (reverse barre-words))
        (insert word "\n"))
      (goto-char (point-min))
      (tab-line-mode 1))
    (switch-to-buffer-other-window buffer-name)
    (message "Mots barrés extraits dans le buffer '%s'." buffer-name)))

;; Raccourcis extraction
(add-hook 'org-mode-hook (lambda () (local-set-key (kbd "C-c g") 'extraire-gras)))
(add-hook 'org-mode-hook (lambda () (local-set-key (kbd "C-c i") 'extraire-italique)))
(add-hook 'org-mode-hook (lambda () (local-set-key (kbd "C-c s") 'extraire-souligne)))

;; ============================================================
;;  7. CONVERSION LISTE → TABLE ORG
;; ============================================================


(defun metal-liste-a-table-sep--decouper-cellule (texte largeur)
  "Découpe TEXTE en une liste de chaînes, chacune ≤ LARGEUR caractères.
La coupure se fait à la frontière des mots (après un espace).
Si un mot seul dépasse LARGEUR, il est laissé tel quel sur sa
propre ligne."
  (let ((mots (split-string (string-trim texte) "\\s-+" t))
        (lignes nil)
        (ligne ""))
    (dolist (mot mots)
      (cond
       ;; Premier mot de la ligne : on le pose.
       ((string-empty-p ligne)
        (setq ligne mot))
       ;; Le mot rentre encore dans la ligne courante.
       ((<= (+ (length ligne) 1 (length mot)) largeur)
        (setq ligne (concat ligne " " mot)))
       ;; Le mot ne rentre plus : on ferme la ligne et on
       ;; recommence avec le mot courant.
       (t
        (push ligne lignes)
        (setq ligne mot))))
    (unless (string-empty-p ligne)
      (push ligne lignes))
    (nreverse lignes)))

(defun metal-liste-a-table-sep (beg end separator)
  "Convertit la région en table Org multilignes.

Demande un SEPARATOR (par exemple « , », « ; » ou « \\t »).

Chaque ligne de la région est découpée selon SEPARATOR pour
produire une rangée de la table. La largeur de chaque colonne
est calculée automatiquement à partir de la largeur de la
fenêtre divisée par le nombre de colonnes. Les cellules trop
longues sont **éclatées sur plusieurs lignes physiques** en
respectant la frontière des mots. Les autres cellules de la
même rangée restent vides sur les lignes supplémentaires. Un
séparateur horizontal `|---|` est inséré entre chaque rangée
originale pour distinguer visuellement les rangées.

Si le buffer courant n'est pas en `org-mode` (par exemple un
buffer d'extraction comme `*ITALIQUES*`), la fonction y active
`org-mode` pour que la table soit alignée correctement."
  (interactive "r\nsSéparateur : ")
  (let* ((sep (if (string= separator "\\t") "\t" separator))
         (text  (buffer-substring-no-properties beg end))
         (lignes-source (split-string text "\n" t))
         (ncols (when lignes-source
                  (length (split-string (car lignes-source) sep))))
         ;; Largeur disponible : largeur de la fenêtre moins les
         ;; caractères de séparation entre cellules.
         (window-width (window-body-width))
         (overhead (+ (1+ ncols) (* 2 ncols)))
         (col-width (max 6 (ceiling (- window-width overhead) ncols))))
    (delete-region beg end)
    (goto-char beg)
    (when (and ncols (> ncols 0))
      ;; Séparateur horizontal initial.
      (insert "|" (mapconcat (lambda (_) "--") (number-sequence 1 ncols) "+") "|\n")
      ;; Traiter chaque ligne source : la découper en cellules,
      ;; éclater chaque cellule longue, puis composer les lignes
      ;; physiques de la table.
      (dolist (ligne-source lignes-source)
        (let* ((cellules (split-string ligne-source sep))
               ;; Pour chaque cellule, calculer la liste de ses
               ;; lignes éclatées (1 ou plusieurs selon la
               ;; longueur).
               (cellules-eclatees
                (mapcar (lambda (c)
                          (metal-liste-a-table-sep--decouper-cellule
                           c col-width))
                        cellules))
               ;; Nombre de lignes physiques nécessaires pour
               ;; cette rangée (= max sur toutes les cellules).
               (nb-lignes (apply #'max
                                 (mapcar #'length cellules-eclatees))))
          ;; Émettre les nb-lignes lignes physiques.
          (dotimes (i nb-lignes)
            (insert "|"
                    (mapconcat
                     (lambda (cell-lignes)
                       (let ((contenu (or (nth i cell-lignes) "")))
                         (concat " " contenu " ")))
                     cellules-eclatees
                     "|")
                    "|\n"))
          ;; Séparateur horizontal entre rangées originales.
          (insert "|" (mapconcat (lambda (_) "--") (number-sequence 1 ncols) "+") "|\n"))))
    ;; Si le buffer n'est pas en org-mode (typiquement un buffer
    ;; d'extraction comme *ITALIQUES*), l'activer pour permettre
    ;; l'alignement de la table.
    (unless (derived-mode-p 'org-mode)
      (org-mode))
    ;; Réaligner la table : se positionner DANS la table.
    (save-excursion
      (goto-char beg)
      (forward-line 1)  ; sauter le premier séparateur horizontal
      (when (looking-at "|")
        (org-table-align)))))


(defun metal-liste-a-table-ncol (beg end n)
  "Convert a plain list (one item per line) in region to an N-column Org table."
  (interactive "r\nnColumns: ")
  (let* ((text  (buffer-substring-no-properties beg end))
         (items (split-string text "\n" t))
         (i 0))
    (delete-region beg end)
    (goto-char beg)
    (while items
      (let ((row '()))
        (dotimes (_ n)
          (push (if items (pop items) "") row))
        (insert "|" (mapconcat (lambda (c) (concat " " c " ")) (nreverse row) "|") "|\n")
        (setq i (1+ i))))
    (when (or (derived-mode-p 'org-mode)
              (bound-and-true-p orgtbl-mode))
      (save-excursion (goto-char beg) (org-table-align)))))

;; ============================================================
;;  8. HEADER-LINE / TOOLBAR ORG
;; ============================================================

(require 'metal-toolbar)

(defun my-header-line-menu ()
  "Affiche un menu déroulant pour extraire du contenu mis en forme."
  (interactive)
  (let ((choice (x-popup-menu
                 t
                 '("Choisir une option"
                   ("Options"
                    ("Extraire ce qui est en gras"      . extraire-gras)
                    ("Extraire ce qui est en italique"  . extraire-italique)
                    ("Extraire ce qui est souligné"     . extraire-souligne)
                    ("Extraire ce qui est barré"        . extraire-barre))))))
    (when choice
      (if (fboundp choice)
          (funcall choice)
        (message "Fonction non définie : %s" choice)))))

(defun aide-memoire-org ()
  "Ouvre l'aide-mémoire orgcard.pdf."
  (interactive)
  (find-file "~/.emacs.d/orgcard.pdf"))

(defun metal-org-toolbar-format ()
  "Construit la barre d'outils Org via `metal-toolbar-build'.
Formatage typographique en lettres stylées (G/I/S/B), reste en emoji.
Dans un fichier .sec (séance d'assemblée), greffe aussi le segment
Secrétaire via `:secretaire t' : le bouton 🗒️ apparaît à côté de 🤖, et
bascule vers la barre du secrétaire (qui remplace alors les boutons Org)."
  (let ((sec-p (and buffer-file-name
                    (string-suffix-p ".sec" buffer-file-name))))
    (metal-toolbar-build
     '((:char "G" :style bold      :color "#2c3e50"
              :tooltip "Gras" :command gras)
       (:char "I" :style italic    :color "#2c3e50"
              :tooltip "Italique" :command italique)
       (:char "S" :style underline :color "#2980b9"
              :tooltip "Souligné" :command souligne)
       (:char "B" :style strike    :color "#c0392b"
              :tooltip "Barré" :command barre)
       (:char "</>" :color "#8e44ad"
              :tooltip "Code inline" :command code)
       (:sep)
       (:emoji "📄" :tooltip "Produire le PDF" :command my/org-compile)
       (:emoji "🔎" :tooltip "Extraire (gras / italique / souligné / barré)"
               :command my-header-line-menu)
       (:sep)
       (:emoji "📖" :tooltip "Wiktionnaire" :command search-wiktionary)
       (:emoji "🌐" :tooltip "Wikipédia" :command search-wikipedia)
       (:emoji "❓" :tooltip "Aide-mémoire (orgcard)" :command aide-memoire-org))
     :agent t
     :secretaire sec-p)))

(defun metal-org-header-line ()
  "Active la barre d'outils dans le tampon Org courant."
  (metal-toolbar-setup-header-line-style)
  (setq-local header-line-format
              '(:eval (metal-org-toolbar-format))))

;; Activer la header-line dans org-mode
(add-hook 'org-mode-hook #'metal-org-header-line)

;; ============================================================
;;  9. DRAG & DROP DE LIENS WEB DANS UN FICHIER ORG
;; ============================================================

(defcustom metal-org-signets-dir
  (expand-file-name "~/Documents/MetalEmacs/Signets/")
  "Dossier contenant les fichiers de signets (`.org').
Calque de `metal-dashboard-notes-dir' : plusieurs fichiers thématiques
de signets peuvent coexister dans ce dossier. Placé dans
~/Documents/MetalEmacs/ pour survivre aux mises à jour de MetalEmacs."
  :type 'directory
  :group 'metal-org)

(defvar metal-org-links-file
  (expand-file-name "Signets.org" metal-org-signets-dir)
  "Fichier de signets actif où les liens web sont classés par section.
Pointe par défaut vers `Signets.org' dans `metal-org-signets-dir'.
`metal-org-selectionner-signets' change ce fichier actif.")

;; Cache des sections — évite de relire le fichier à chaque drop
(defvar metal-org--sections-cache nil
  "Cache : (MODTIME . SECTIONS).")

(defun metal-org--migrer-signets-si-besoin ()
  "Déplacer l'ancien `Signets.org' unique vers le nouveau dossier.
Migration unique : l'ancien emplacement était un fichier unique
`~/Documents/MetalEmacs/Signets.org' à côté du nouveau dossier
`Signets/'. Le fichier est déplacé tel quel comme un fichier de
signets parmi d'autres."
  (let* ((ancien (expand-file-name "~/Documents/MetalEmacs/Signets.org"))
         (cible (expand-file-name "Signets.org" metal-org-signets-dir)))
    (when (and (file-exists-p ancien)
               (not (file-exists-p cible)))
      (make-directory metal-org-signets-dir t)
      (rename-file ancien cible)
      (message "🔖 Signets.org déplacé : %s → %s" ancien cible))))

(metal-org--migrer-signets-si-besoin)

(defun metal-org-links-ensure-file ()
  "Crée le dossier et le fichier de signets actif s'ils n'existent pas."
  (let ((dir (file-name-directory metal-org-links-file)))
    (unless (file-exists-p dir)
      (make-directory dir t))
    (unless (file-exists-p metal-org-links-file)
      (with-temp-file metal-org-links-file
        (insert (format "#+TITLE: %s\n\n* Général\n"
                        (file-name-base metal-org-links-file)))))))

(defun metal-org-selectionner-signets (filepath)
  "Définir FILEPATH comme fichier de signets actif.
Invalide le cache des sections pour forcer une relecture."
  (setq metal-org-links-file (expand-file-name filepath))
  (setq metal-org--sections-cache nil))

(defun metal-org--signets-fichiers ()
  "Liste des fichiers de signets (`.org') du dossier, l'actif en tête.
Retourne une liste de chemins absolus. Le fichier actif
`metal-org-links-file' apparaît toujours en premier (dernier utilisé),
suivi des autres fichiers triés par nom."
  (let* ((dir (file-name-directory (expand-file-name metal-org-links-file)))
         (actif (expand-file-name metal-org-links-file))
         (tous (when (file-directory-p dir)
                 (directory-files dir t "\\.org\\'" t)))
         (autres (sort (seq-remove (lambda (f) (file-equal-p f actif)) tous)
                       #'string<)))
    (if (file-exists-p actif)
        (cons actif autres)
      autres)))

;;;###autoload
(defun metal-org-ouvrir-signets ()
  "Ouvre le fichier de signets actif."
  (interactive)
  (metal-org-links-ensure-file)
  (find-file metal-org-links-file))

(defun metal-org-get-sections ()
  "Retourne la liste des sections niveau 1, avec cache par date de modification."
  (when (file-exists-p metal-org-links-file)
    (let ((modtime (file-attribute-modification-time
                    (file-attributes metal-org-links-file))))
      ;; Retourner le cache si le fichier n'a pas changé
      (if (and metal-org--sections-cache
               (equal modtime (car metal-org--sections-cache)))
          (cdr metal-org--sections-cache)
        ;; Sinon, relire (toujours en mode brut, jamais org-mode)
        (let (sections)
          (with-temp-buffer
            (insert-file-contents metal-org-links-file)
            (goto-char (point-min))
            (while (re-search-forward "^\\* \\(.+\\)$" nil t)
              (push (match-string 1) sections)))
          (setq sections (nreverse sections))
          (setq metal-org--sections-cache (cons modtime sections))
          sections)))))

(defun metal-org--insert-link (section title url)
  "Insère le lien URL avec TITLE sous SECTION dans le fichier de signets.
Écriture directe en mode brut — ne charge jamais org-mode."
  (let ((link-line (format "- [[%s][%s]]\n" url title))
        (buf (get-buffer (file-name-nondirectory metal-org-links-file))))
    (if buf
        ;; Buffer déjà ouvert — modifier en place
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-min))
            (if (re-search-forward (format "^\\* %s" (regexp-quote section)) nil t)
                (progn
                  (if (re-search-forward "^\\* " nil t)
                      (forward-line -1)
                    (goto-char (point-max)))
                  (unless (bolp) (insert "\n"))
                  (insert link-line))
              (goto-char (point-max))
              (unless (bolp) (insert "\n"))
              (insert (format "\n* %s\n%s" section link-line)))
            (save-buffer)))
      ;; Buffer pas ouvert — écriture rapide
      (with-temp-buffer
        (insert-file-contents metal-org-links-file)
        (goto-char (point-min))
        (if (re-search-forward (format "^\\* %s" (regexp-quote section)) nil t)
            (progn
              (if (re-search-forward "^\\* " nil t)
                  (forward-line -1)
                (goto-char (point-max)))
              (unless (bolp) (insert "\n"))
              (insert link-line))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (format "\n* %s\n%s" section link-line)))
        (write-region (point-min) (point-max) metal-org-links-file)))
    ;; Invalider le cache
    (setq metal-org--sections-cache nil)
    (message "✓ Lien ajouté sous « %s » : %s" section title)))

(defun metal-org-handle-url-drop (url _action)
  "Intercepte le drop d'une URL instantanément.
Diffère l'affichage du menu via `run-at-time' pour ne pas bloquer le DnD."
  ;; Nettoyer l'URL (enlever newlines, espaces, préfixe file://)
  (let ((clean-url (string-trim (replace-regexp-in-string "[\n\r]" "" url))))
    ;; Retourner immédiatement — le menu s'affiche après
    (run-at-time 0 nil #'metal-org--prompt-and-save clean-url))
  ;; Retourner 'private pour signaler à Emacs que le drop est géré
  'private)

(defun metal-org--prompt-and-save (url)
  "Affiche deux menus popup : d'abord le fichier de signets, puis la section.
Le fichier actif (dernier utilisé) est proposé en premier. Une option
permet de créer un nouveau fichier de signets."
  (metal-org-links-ensure-file)
  ;; --- Étape 1 : choisir le fichier de signets ---------------------------
  (let* ((fichiers (metal-org--signets-fichiers))
         (fichier-items (append
                         (mapcar (lambda (f)
                                   (cons (file-name-nondirectory f) f))
                                 fichiers)
                         '(("---")  ;; séparateur
                           ("✚ Nouveau fichier de signets..." . __new-file__))))
         (choix-fichier (x-popup-menu
                         (list '(300 300) (selected-frame))
                         (list "🔖 Classer dans quel fichier ?"
                               (cons "" fichier-items)))))
    (when choix-fichier
      (let ((fichier
             (if (eq choix-fichier '__new-file__)
                 (let* ((dir (file-name-directory
                              (expand-file-name metal-org-links-file)))
                        (nom (read-string "Nom du nouveau fichier de signets : "))
                        (nom-ext (if (string-suffix-p ".org" nom)
                                     nom
                                   (concat nom ".org"))))
                   (when (string-empty-p nom)
                     (user-error "Nom de fichier vide"))
                   (expand-file-name nom-ext dir))
               choix-fichier)))
        ;; Activer le fichier choisi (crée le fichier au besoin)
        (metal-org-selectionner-signets fichier)
        (metal-org-links-ensure-file)
        ;; --- Étape 2 : choisir la section -------------------------------
        (let* ((sections (metal-org-get-sections))
               (menu-items (append
                            (mapcar (lambda (s) (cons s s)) sections)
                            '(("---")  ;; séparateur
                              ("✚ Nouvelle section..." . __new__))))
               (choix (x-popup-menu
                       (list '(300 300) (selected-frame))
                       (list (format "📎 Section dans %s"
                                     (file-name-nondirectory fichier))
                             (cons "" menu-items)))))
          (when choix
            (let* ((section (if (eq choix '__new__)
                                (read-string "Nom de la nouvelle section : ")
                              choix))
                   (title (read-string "Titre du lien : "
                                       (metal-org--extract-domain url)
                                       nil url)))
              (when (and section (not (string-empty-p section)))
                (metal-org--insert-link section title url)))))))))

(defun metal-org--extract-domain (url)
  "Extrait le nom de domaine d'une URL pour suggestion de titre."
  (if (string-match "https?://\\(?:www\\.\\)?\\([^/]+\\)" url)
      (match-string 1 url)
    url))

;; Enregistrer le handler en TÊTE — court-circuite tout handler par défaut
(setq dnd-protocol-alist
      (cons '("^https?://" . metal-org-handle-url-drop)
            (cons '("^www\\." . metal-org-handle-url-drop)
                  (seq-remove (lambda (e)
                                (and (stringp (car e))
                                     (string-match-p "^\\^https\\|^\\^www" (car e))))
                              dnd-protocol-alist))))

;; ============================================================
;;  10. SYNCHRONISATION iCloud Drive (dossier MetalEmacs)
;; ============================================================
;;
;; Principe :
;;   1. Le fichier .org est DÉPLACÉ vers le dossier MetalEmacs dans iCloud Drive
;;   2. Un lien symbolique est créé à l'emplacement original
;;   3. Emacs suit le symlink → édition transparente
;;   4. iCloud synchronise le vrai fichier → accessible sur iOS
;;      (Plain Org ou toute autre application lisant iCloud Drive)
;;
;; Usage :
;;   - Dans Treemacs : C-c b sur un fichier .org → lier vers iCloud
;;   - Depuis un buffer org : C-c b s
;;   - Délier : C-c b u ou M-x metal-icloud-delier-fichier
;;   - État   : C-c b i ou M-x metal-icloud-afficher-etat

(require 'treemacs nil t)

(defgroup metal-icloud nil
  "Synchronisation bidirectionnelle de fichiers org via iCloud Drive."
  :group 'metal
  :prefix "metal-icloud-")

(defcustom metal-icloud-path
  (expand-file-name
   "~/Library/Mobile Documents/com~apple~CloudDocs/MetalEmacs")
  "Chemin du dossier MetalEmacs dans iCloud Drive.
Créé automatiquement au chargement du module s'il n'existe pas."
  :type 'directory
  :group 'metal-icloud)

(defcustom metal-icloud-sous-dossier nil
  "Sous-dossier optionnel où stocker les fichiers org.
Mettre nil ou \"\" pour utiliser la racine du dossier MetalEmacs."
  :type '(choice (const :tag "Racine (pas de sous-dossier)" nil)
                 string)
  :group 'metal-icloud)

(defcustom metal-icloud-confirm t
  "Si non-nil, demander confirmation avant chaque opération."
  :type 'boolean
  :group 'metal-icloud)

(defun metal-icloud--dossier-destination ()
  "Retourne le chemin complet de destination (avec sous-dossier si configuré)."
  (if (and metal-icloud-sous-dossier
           (not (string-empty-p metal-icloud-sous-dossier)))
      (expand-file-name metal-icloud-sous-dossier metal-icloud-path)
    metal-icloud-path))

(defun metal-icloud--assurer-dossier ()
  "Crée le dossier de destination iCloud s'il n'existe pas.
Retourne le chemin du dossier de destination."
  (let ((dest (metal-icloud--dossier-destination)))
    (unless (file-directory-p dest)
      (make-directory dest t))
    dest))

(defun metal-icloud--disponible-p ()
  "Vérifie si le dossier iCloud Drive existe (le crée au besoin)."
  (condition-case nil
      (file-directory-p (metal-icloud--assurer-dossier))
    (error nil)))

(defun metal-icloud--deja-lie-p (file)
  "Vérifie si FILE est déjà un symlink vers le dossier iCloud."
  (and (file-symlink-p file)
       (string-prefix-p (expand-file-name (metal-icloud--dossier-destination))
                        (file-truename file))))

(defun metal-icloud--lier-fichier (src-file)
  "Déplace SRC-FILE vers iCloud Drive et crée un symlink à sa place.

Opération :
  1. src-file → déplacé vers iCloud Drive/MetalEmacs/
  2. symlink créé : src-file → fichier dans iCloud
  3. Recharge le buffer si le fichier était ouvert"
  (unless (and src-file (file-exists-p src-file))
    (user-error "Fichier introuvable : %s" src-file))
  (unless (string-suffix-p ".org" src-file t)
    (user-error "Seuls les fichiers .org peuvent être liés à iCloud"))
  (unless (metal-icloud--disponible-p)
    (user-error "Dossier iCloud introuvable ou non créable : %s"
                metal-icloud-path))

  (let ((real-src (file-truename src-file)))

    (when (metal-icloud--deja-lie-p src-file)
      (user-error "Déjà lié à iCloud : %s → %s"
                  (abbreviate-file-name src-file)
                  (abbreviate-file-name real-src)))

    (let* ((dest-root (metal-icloud--assurer-dossier))
           (src-name  (file-name-nondirectory src-file))
           (dest-file (expand-file-name src-name dest-root))
           (buf       (find-buffer-visiting src-file)))

      ;; Collision dans le dossier iCloud
      (when (file-exists-p dest-file)
        (unless (y-or-n-p
                 (format "⚠ %s existe déjà dans iCloud. Remplacer ?" src-name))
          (user-error "Opération annulée"))
        (delete-file dest-file))

      ;; Confirmation
      (when metal-icloud-confirm
        (unless (y-or-n-p
                 (format "Lier %s vers iCloud Drive ?" src-name))
          (user-error "Opération annulée")))

      ;; 1. Copier le fichier vers iCloud
      (copy-file real-src dest-file t)

      ;; 2. Supprimer l'original
      (sleep-for 0.5)
      (delete-file real-src)

      ;; 3. Créer le symlink à l'emplacement original
      (sleep-for 0.5)
      (make-symbolic-link dest-file src-file)

      ;; 4. Recharger le buffer si ouvert
      (when buf
        (with-current-buffer buf
          (revert-buffer t t t)))

      (message "✓ %s lié à iCloud Drive" src-name))))

(defun metal-icloud--delier-fichier (src-file)
  "Rapatrie le fichier depuis iCloud et supprime le symlink."
  (unless (file-symlink-p src-file)
    (user-error "Ce fichier n'est pas un lien symbolique : %s" src-file))

  (let* ((target   (file-truename src-file))
         (src-name (file-name-nondirectory src-file))
         (buf      (find-buffer-visiting src-file)))

    (unless (file-exists-p target)
      (user-error "Le fichier cible n'existe plus : %s" target))

    (when metal-icloud-confirm
      (unless (y-or-n-p
               (format "Délier %s d'iCloud ? (rapatrier le fichier)" src-name))
        (user-error "Opération annulée")))

    ;; 1. Supprimer le symlink
    (delete-file src-file)

    ;; 2. Ramener le vrai fichier
    (rename-file target src-file)

    ;; 3. Recharger le buffer si ouvert
    (when buf
      (with-current-buffer buf
        (revert-buffer t t t)))

    (message "✓ %s délié d'iCloud — fichier rapatrié" src-name)))

;; Commandes interactives

(defun metal-icloud--fichier-sous-curseur ()
  "Retourne le fichier sous le curseur (Treemacs ou buffer courant)."
  (or (when (eq major-mode 'treemacs-mode)
        (treemacs--prop-at-point :path))
      (buffer-file-name)
      (read-file-name "Fichier .org : " nil nil t nil
                      (lambda (f) (string-suffix-p ".org" f t)))))

;;;###autoload
(defun metal-icloud-lier-fichier (&optional file)
  "Lie FILE à iCloud Drive (symlink bidirectionnel)."
  (interactive)
  (metal-icloud--lier-fichier (or file (metal-icloud--fichier-sous-curseur))))

;;;###autoload
(defun metal-icloud-delier-fichier (&optional file)
  "Délie FILE d'iCloud : rapatrie le fichier, supprime le symlink."
  (interactive)
  (metal-icloud--delier-fichier (or file (metal-icloud--fichier-sous-curseur))))

;;;###autoload
(defun metal-icloud-lier-depuis-treemacs ()
  "Lie/délie le fichier .org sélectionné dans Treemacs."
  (interactive)
  (let* ((path (treemacs--prop-at-point :path)))
    (cond
     ((not (and path (string-suffix-p ".org" path t)))
      (user-error "Sélectionnez un fichier .org dans Treemacs"))
     ((metal-icloud--deja-lie-p path)
      (when (y-or-n-p (format "%s est déjà lié à iCloud. Délier ?"
                              (file-name-nondirectory path)))
        (metal-icloud--delier-fichier path)))
     (t (metal-icloud--lier-fichier path)))))

;;;###autoload
(defun metal-icloud-afficher-etat ()
  "Affiche l'état de la synchronisation iCloud."
  (interactive)
  (let ((available (metal-icloud--disponible-p)))
    (with-help-window "*iCloud Status*"
      (with-current-buffer "*iCloud Status*"
        (insert "MetalEmacs ↔ iCloud Drive\n")
        (insert (make-string 30 ?─) "\n\n")
        (insert (format "%s iCloud Drive : %s\n"
                        (if available "✓" "✗")
                        (abbreviate-file-name metal-icloud-path)))
        (insert (format "  Sous-dossier  : %s\n\n"
                        (or metal-icloud-sous-dossier "(racine)")))
        (if (not available)
            (insert "⚠ Dossier iCloud introuvable ou non créable.\n")
          (let* ((dest (metal-icloud--dossier-destination))
                 (org-files (and (file-directory-p dest)
                                 (directory-files dest nil "\\.org$"))))
            (if org-files
                (progn
                  (insert (format "Fichiers dans iCloud (%d) :\n" (length org-files)))
                  (dolist (f org-files)
                    (insert (format "  📄 %s\n" f))))
              (insert "Aucun fichier .org dans iCloud.\n"))))))))

;; Création automatique du dossier au chargement du module
(ignore-errors (metal-icloud--assurer-dossier))

;; Intégration Treemacs
(with-eval-after-load 'treemacs
  (define-key treemacs-mode-map (kbd "C-c b") #'metal-icloud-lier-depuis-treemacs)

  (easy-menu-define metal-icloud-treemacs-menu treemacs-mode-map
    "Menu iCloud dans Treemacs."
    '("iCloud"
      ["Lier / Délier" metal-icloud-lier-depuis-treemacs
       :help "Lie ou délie le fichier .org avec iCloud Drive"]
      ["État iCloud" metal-icloud-afficher-etat
       :help "Affiche les fichiers synchronisés avec iCloud"])))

(defun my/org-hide-header ()
  "Cache les lignes #+KEYWORD en début de fichier org."
  (save-excursion
    (goto-char (point-min))
    ;; Sauter les lignes vides éventuelles
    (while (and (not (eobp)) (looking-at "^$"))
      (forward-line 1))
    (let ((start (point))
          (end (point)))
      (while (and (not (eobp)) (looking-at "^#\\+"))
        (forward-line 1)
        (setq end (point)))
      (when (> end start)
        ;; Supprimer un ancien overlay s'il existe
        (dolist (ov (overlays-in (point-min) (point-max)))
          (when (overlay-get ov 'my/org-header)
            (delete-overlay ov)))
        (let ((ov (make-overlay start end)))
          (overlay-put ov 'invisible t)
          (overlay-put ov 'my/org-header t)
          (overlay-put ov 'before-string
                       (propertize "▶ En-tête\n"
                                   'face '(:foreground "#999999" :slant italic)
                                   'mouse-face 'highlight
                                   'pointer 'hand
                                   'keymap (let ((map (make-sparse-keymap)))
                                             (define-key map [mouse-1] #'my/org-toggle-header)
                                             (define-key map (kbd "RET") #'my/org-toggle-header)
                                             map))))))))

(defun my/org-toggle-header ()
  "Affiche/cache l'en-tête org."
  (interactive)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'my/org-header)
      (if (overlay-get ov 'invisible)
          (progn
            (overlay-put ov 'invisible nil)
            (overlay-put ov 'before-string
                         (propertize "▼ En-tête\n"
                                     'face '(:foreground "#999999" :slant italic)
                                     'mouse-face 'highlight
                                     'pointer 'hand
                                     'keymap (let ((map (make-sparse-keymap)))
                                               (define-key map [mouse-1] #'my/org-toggle-header)
                                               (define-key map (kbd "RET") #'my/org-toggle-header)
                                               map))))
        (overlay-put ov 'invisible t)
        (overlay-put ov 'before-string
                     (propertize "▶ En-tête\n"
                                 'face '(:foreground "#999999" :slant italic)
                                 'mouse-face 'highlight
                                 'pointer 'hand
                                 'keymap (let ((map (make-sparse-keymap)))
                                           (define-key map [mouse-1] #'my/org-toggle-header)
                                           (define-key map (kbd "RET") #'my/org-toggle-header)
                                           map)))))))

(add-hook 'find-file-hook
          (lambda ()
            (when (derived-mode-p 'org-mode)
              (run-with-idle-timer 0.1 nil
                (lambda (buf)
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (my/org-hide-header))))
                (current-buffer)))))

;; Raccourcis iCloud
(global-set-key (kbd "C-c b s") #'metal-icloud-lier-fichier)
(global-set-key (kbd "C-c b u") #'metal-icloud-delier-fichier)
(global-set-key (kbd "C-c b i") #'metal-icloud-afficher-etat)

(use-package org-table-wrap-functions
  :straight (:host github :repo "analyticd/org-table-wrap-functions")
  :bind (:map org-mode-map
              ("C-|" . org-table-column-wrap-to-point)))

;; ============================================================
;;  FIN METAL-ORG
;; ============================================================

(provide 'metal-org)
