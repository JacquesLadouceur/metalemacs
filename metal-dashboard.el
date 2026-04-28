;;; metal-dashboard.el --- Tableau de bord MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1


;;; Commentaires:
;; Ce module fournit le tableau de bord de MetalEmacs :
;; - Affichage des fichiers récents
;; - Création rapide de fichiers (Quarto, Python, Prolog, Org)
;; - Accès au calendrier, notes, etc.

;;; Code:

(require 'recentf)
(require 'cl-lib)

;;; ═══════════════════════════════════════════════════════════════════
;;; Variables
;;; ═══════════════════════════════════════════════════════════════════

(defvar metal-dashboard-buffer-name "*Tableau-de-bord*"
  "Nom du buffer du tableau de bord.")

(defvar metal-dashboard-quarto-ressources
  '("metal-boites.lua" "metal-tcolorbox.sty")
  "Fichiers à copier dans le dossier de chaque nouvelle présentation Quarto.")

(defvar metal-dashboard-quarto-ressources-dir
  (expand-file-name "quarto/" user-emacs-directory)
  "Dossier source contenant les ressources Quarto.")

(defcustom metal-dashboard-notes-file
  (expand-file-name "~/Documents/MetalEmacs/notes.org")
  "Fichier des notes rapides ouvert par le bouton « Notes » du tableau de bord.

Placé dans ~/Documents/MetalEmacs/ plutôt que dans `user-emacs-directory'
pour survivre aux mises à jour de MetalEmacs (le dossier .emacs.d peut
être écrasé par la distribution, effaçant son contenu utilisateur)."
  :type 'file
  :group 'metal-dashboard)

(defun metal-dashboard--migrer-notes-si-besoin ()
  "Déplacer `notes.org' de ~/.emacs.d/ vers `metal-dashboard-notes-file'.
Migration unique pour les utilisateurs qui avaient l'ancien emplacement.
Si le nouveau fichier existe déjà, ne fait rien (pour éviter d'écraser)."
  (let ((ancien (expand-file-name "notes.org" user-emacs-directory))
        (nouveau metal-dashboard-notes-file))
    (when (and (file-exists-p ancien)
               (not (file-exists-p nouveau)))
      (make-directory (file-name-directory nouveau) t)
      (rename-file ancien nouveau)
      (message "📝 notes.org déplacé : %s → %s" ancien nouveau))))

;; Exécuter la migration au chargement du module
(metal-dashboard--migrer-notes-si-besoin)

;;; ═══════════════════════════════════════════════════════════════════
;;; Fonctions auxiliaires
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-dashboard--copier-ressources-quarto (dossier-cible)
  "Copier les ressources Quarto dans DOSSIER-CIBLE si absentes."
  (dolist (fichier metal-dashboard-quarto-ressources)
    (let ((source (expand-file-name fichier metal-dashboard-quarto-ressources-dir))
          (cible  (expand-file-name fichier dossier-cible)))
      (when (and (file-exists-p source)
                 (not (file-exists-p cible)))
        (copy-file source cible)
        (message "📋 %s → %s" fichier (abbreviate-file-name dossier-cible))))))

(defun metal-dashboard--insert-clickable (text action &optional help-text)
  "Insérer TEXT comme bouton cliquable avec ACTION."
  (let ((start (point)))
    (insert text)
    (make-text-button start (point)
                      'face '(:foreground "#0066cc" :underline nil)
                      'mouse-face 'highlight
                      'help-echo (or help-text "")
                      'action (lambda (_btn) 
                                (if (commandp action)
                                    (call-interactively action)
                                  (funcall action)))
                      'follow-link t
                      'pointer 'hand)))

(defun metal-dashboard--separator (&optional width)
  "Retourner un séparateur élégant bordeaux de largeur WIDTH."
  (let ((w (or width 80)))
    (propertize (concat (make-string w ?━) "\n")
                'face '(:foreground "#8B0000"))))

(defun metal-dashboard--format-recent-file (file)
  "Formater un fichier récent : nom + dossier parent."
  (let* ((name (file-name-nondirectory file))
         (dir (file-name-nondirectory
               (directory-file-name (file-name-directory file)))))
    (format "%s  (%s)" name dir)))

(defun metal-dashboard--recentf-acceptable-p (file)
  "Retourne t si FILE doit apparaître dans les fichiers récents."
  (and (file-exists-p file)
       ;; Exclure les fichiers temporaires
       (not (string-match-p "^/tmp" file))
       (not (string-match-p "/tmp/" file))
       ;; Exclure les fichiers compilés et de sauvegarde
       (not (string-match-p "\\.elc$" file))
       (not (string-match-p (regexp-quote temporary-file-directory) file))
       (not (string-match-p "recentf$" file))
       (not (string-match-p "#" file))
       (not (string-match-p "~$" file))
       ;; Exclure les fichiers de cache et configuration Emacs
       (not (string-match-p "\\.cache" file))
       (not (string-match-p "treemacs-persist" file))
       (not (string-match-p "calendrier.org" file))
       (not (string-match-p "eln-cache" file))
       (not (string-match-p "/straight/" file))
       (not (string-match-p "bookmarks$" file))
       (not (string-match-p "places$" file))
       (not (string-match-p "savehist$" file))
       (not (string-match-p "\\.newsrc" file))
       (not (string-match-p "ido\\.last$" file))
       (not (string-match-p "tramp$" file))
       (not (string-match-p "org-id-locations$" file))
       (not (string-match-p "projectile-bookmarks" file))
       (not (string-match-p "\\.gpg$" file))
       ;; Exclure les fichiers auto-save
       (not (string-match-p "^\\." (file-name-nondirectory file)))))

(defvar metal-dashboard-actualites-file
  (expand-file-name "metal-news.org" user-emacs-directory)
  "Fichier org contenant les liens d'actualités.")

(defun metal-dashboard--parse-actualites ()
  "Parser le fichier metal-news.org et retourner une liste de (nom . url)."
  (let ((file metal-dashboard-actualites-file)
        (sites nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^\\*\\* \\(.+\\)$" nil t)
          (let ((name (match-string 1)))
            (forward-line 1)
            (when (looking-at "^https?://[^ \t\n]+")
              (push (cons name (match-string 0)) sites))))))
    (nreverse sites)))

(defun metal-dashboard-actualites-menu ()
  "Afficher un menu pour choisir un site d'actualités."
  (interactive)
  (let ((sites (metal-dashboard--parse-actualites)))
    (if (null sites)
        (progn
          (message "Aucun site trouvé dans %s" metal-dashboard-actualites-file)
          (when (y-or-n-p "Créer le fichier metal-news.org ? ")
            (find-file metal-dashboard-actualites-file)))
      (let* ((choices (mapcar #'car sites))
             (choice (completing-read "Actualités: " choices nil t)))
        (when choice
          (browse-url (cdr (assoc choice sites))))))))

(defun metal-dashboard--make-action-button (label help-text action)
  "Créer un bouton cliquable avec LABEL, HELP-TEXT et ACTION."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] action)
    (define-key map (kbd "RET") action)
    (propertize label
                'mouse-face 'highlight
                'help-echo help-text
                'keymap map)))

(defun metal-dashboard--make-file-link (filepath &optional display-name)
  "Créer un lien cliquable vers FILEPATH avec DISPLAY-NAME optionnel."
  (let ((name (or display-name filepath)))
    (propertize name
                'face '(:foreground "#0066cc")
                'mouse-face 'highlight
                'help-echo filepath
                'keymap (let ((map (make-sparse-keymap)))
                          (define-key map [mouse-1]
                            (lambda () (interactive) (find-file filepath)))
                          (define-key map (kbd "RET")
                            (lambda () (interactive) (find-file filepath)))
                          map))))

(defun metal-dashboard--header-buttons ()
  "Créer la barre de boutons d'en-tête."
  (let* ((icon-folder (if (fboundp 'nerd-icons-faicon)
                          (nerd-icons-faicon "nf-fa-folder_open" :face '(:foreground "#8B4513"))
                        "📁"))
         (icon-calendar (if (fboundp 'nerd-icons-faicon)
                            (nerd-icons-faicon "nf-fa-calendar" :face '(:foreground "#006400"))
                          "📅"))
         (icon-notes (if (fboundp 'nerd-icons-faicon)
                         (nerd-icons-faicon "nf-fa-sticky_note" :face '(:foreground "#DAA520"))
                       "📝"))
         (icon-signets (if (fboundp 'nerd-icons-faicon)
                           (nerd-icons-faicon "nf-fa-bookmark" :face '(:foreground "#B22222"))
                         "🔖"))
         (icon-news (if (fboundp 'nerd-icons-faicon)
                        (nerd-icons-faicon "nf-fa-newspaper_o" :face '(:foreground "#4169E1"))
                      "📰"))
         (icon-assistant (if (fboundp 'nerd-icons-faicon)
                             (nerd-icons-faicon "nf-fa-wrench" :face '(:foreground "#FF6600"))
                           "🔧"))
         (text-face '(:foreground "#0066cc" :weight bold)))
    (concat
     (metal-dashboard--make-action-button
      (concat icon-folder " " (propertize "METAL" 'face text-face))
      "Ouvrir le guide METAL (PDF)"
      (lambda () (interactive) 
        (find-file (expand-file-name "Metal.pdf" user-emacs-directory))))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-calendar " " (propertize "Calendrier" 'face text-face))
      "Ouvrir le calendrier"
      (lambda () (interactive) 
        (if (fboundp 'metal-calendrier-ouvrir)
            (metal-calendrier-ouvrir)
          (calendar))))
     "  "
     ;; (metal-dashboard--make-action-button
     ;;  (concat icon-notes " " (propertize "Notes" 'face text-face))
     ;;  "Ouvrir les notes rapides"
     ;;  (lambda () (interactive) 
     ;;    (find-file (expand-file-name "notes.org" user-emacs-directory))))
     (metal-dashboard--make-action-button
      (concat icon-notes " " (propertize "Notes" 'face text-face))
      "Ouvrir les notes rapides"
      (lambda () (interactive)
       (let ((filepath metal-dashboard-notes-file))
        ;; S'assurer que le dossier parent existe (créé au premier usage)
        (make-directory (file-name-directory filepath) t)
        (find-file filepath)
       (when (= (buffer-size) 0)
       (insert "#+TITLE: Notes\n"
               "#+OPTIONS: toc:nil num:nil date:nil author:nil\n"
               "#+OUTPUT_TYPE: document\n"
               "#+LATEX_CLASS: article\n"
               "#+LATEX_HEADER: \\usepackage[margin=1in]{geometry}\n\n")
       (save-buffer)))))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-signets " " (propertize "Signets" 'face text-face))
      "Ouvrir les signets web"
      (lambda () (interactive)
        (if (fboundp 'metal-org-ouvrir-signets)
            (metal-org-ouvrir-signets)
          (find-file (expand-file-name "~/Documents/MetalEmacs/Signets.org")))))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-news " " (propertize "Actualités" 'face text-face))
      "Choisir un site d'actualités"
      #'metal-dashboard-actualites-menu)
     "  "
     (metal-dashboard--make-action-button
      (concat icon-assistant " " (propertize "Assistant" 'face text-face))
      "Ouvrir l'assistant d'installation"
      (lambda () (interactive) 
        (require 'metal-deps nil t)
        (if (fboundp 'metal-deps-afficher-etat)
            (metal-deps-afficher-etat)
          (message "metal-deps non disponible - vérifiez que le fichier existe")))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Fonctions de création de fichiers
;;; ═══════════════════════════════════════════════════════════════════

;; (defun metal-dashboard--create-new-file (extension prompt &optional template)
;;   "Créer un nouveau fichier avec EXTENSION, PROMPT et TEMPLATE optionnel.
;; Utilise le dossier sélectionné dans Treemacs comme dossier par défaut."
;;   (cl-block metal-dashboard--create-new-file
;;     (let* ((treemacs-dir (ignore-errors
;;                            (when (and (fboundp 'treemacs-get-local-buffer)
;;                                       (treemacs-get-local-buffer))
;;                              (with-current-buffer (treemacs-get-local-buffer)
;;                                (let* ((btn (treemacs-current-button))
;;                                       (path (when btn (treemacs-button-get btn :path))))
;;                                  (when path
;;                                    (if (file-directory-p path)
;;                                        path
;;                                      (file-name-directory path))))))))
;;            (default-dir (or treemacs-dir "~/Documents/"))
;;            (dir (read-directory-name "Dans quel dossier ? " default-dir))
;;            (name (read-string prompt))
;;            (filepath (expand-file-name (concat name extension) dir))
;;            (replace nil))
;;       ;; Si le fichier existe, demander quoi faire
;;       (when (file-exists-p filepath)
;;         (let ((choice (read-char-choice
;;                        (format "« %s » existe déjà : [r]emplacer, [o]uvrir, [a]nnuler ? "
;;                                (file-name-nondirectory filepath))
;;                        '(?r ?o ?a))))
;;           (pcase choice
;;             (?r (setq replace t))
;;             (?o (find-file filepath)
;;                 (cl-return-from metal-dashboard--create-new-file))
;;             (?a (message "Annulé.")
;;                 (cl-return-from metal-dashboard--create-new-file)))))
;;       (find-file filepath)
;;       (when (or (= (buffer-size) 0) replace)
;;         (erase-buffer)
;;         (when template
;;           (insert template)))
;;       (save-buffer))))


(defun metal-dashboard--create-new-file (extension prompt &optional template)
  "Créer un nouveau fichier avec EXTENSION, PROMPT et TEMPLATE optionnel.
Utilise le dossier sélectionné dans Treemacs comme dossier par défaut."
  (cl-block metal-dashboard--create-new-file
    (let* ((treemacs-dir (ignore-errors
                           (when (and (fboundp 'treemacs-get-local-buffer)
                                      (treemacs-get-local-buffer))
                             (with-current-buffer (treemacs-get-local-buffer)
                               (let* ((btn (treemacs-current-button))
                                      (path (when btn (treemacs-button-get btn :path))))
                                 (when path
                                   (if (file-directory-p path)
                                       path
                                     (file-name-directory path))))))))
           (default-dir (or treemacs-dir "~/Documents/"))
           ;; Un seul dialogue graphique pour dossier + nom de fichier
           (filepath (read-file-name prompt default-dir nil nil
                                     (concat "nouveau" extension)))
           ;; Ajouter l'extension si l'utilisateur ne l'a pas tapée
           (filepath (if (string-suffix-p extension filepath)
                         filepath
                       (concat filepath extension)))
           (replace nil))
      ;; Si le fichier existe, demander quoi faire
      (when (file-exists-p filepath)
        (let ((choice (read-char-choice
                       (format "« %s » existe déjà : [r]emplacer, [o]uvrir, [a]nnuler ? "
                               (file-name-nondirectory filepath))
                       '(?r ?o ?a))))
          (pcase choice
            (?r (setq replace t))
            (?o (find-file filepath)
                (cl-return-from metal-dashboard--create-new-file))
            (?a (message "Annulé.")
                (cl-return-from metal-dashboard--create-new-file)))))
      (find-file filepath)
      (when (or (= (buffer-size) 0) replace)
        (erase-buffer)
        (when template
          (insert template)))
      (save-buffer))))

;; (defun metal-dashboard-new-qmd ()
;;   "Créer une présentation Quarto."
;;   (interactive)
;;   (let* ((template-file (expand-file-name "Modèles/Modèle-Présentation.txt" user-emacs-directory))
;;          (template (if (file-exists-p template-file)
;;                        (with-temp-buffer
;;                          (insert-file-contents template-file)
;;                          (buffer-string))
;;                      "---\ntitle: \"Titre\"\nformat:\n  beamer: default\nlang: fr\n---\n\n")))
;;     (metal-dashboard--create-new-file
;;      ".qmd"
;;      "Nom de la présentation (sans extension) : "
;;      template)
;;     ;; Copier les ressources Quarto dans le dossier de la présentation
;;     (when buffer-file-name
;;       (metal-dashboard--copier-ressources-quarto
;;        (file-name-directory buffer-file-name)))))

(defun metal-dashboard-new-qmd ()
  "Créer une présentation Quarto."
  (interactive)
  (let* ((template-file (expand-file-name "modeles/presentation-quarto.txt" user-emacs-directory))
         (template (if (file-exists-p template-file)
                       (with-temp-buffer
                         (insert-file-contents template-file)
                         (buffer-string))
                     "---\ntitle: \"Titre\"\nformat:\n  beamer:\n    theme: metropolis\nlang: fr\n---\n\n")))
    (metal-dashboard--create-new-file
     ".qmd"
     "Nom de la présentation (sans extension) : "
     template)
    ;; Copier les ressources Quarto dans le dossier de la présentation
    (when buffer-file-name
      (metal-dashboard--copier-ressources-quarto
       (file-name-directory buffer-file-name)))))

(defun metal-dashboard-new-qmd-document ()
  "Créer un document Quarto."
  (interactive)
  (let* ((template-file (expand-file-name "Modèles/Modèle-Document.txt" user-emacs-directory))
         (template (if (file-exists-p template-file)
                       (with-temp-buffer
                         (insert-file-contents template-file)
                         (buffer-string))
                     "---\ntitle: \"Titre\"\nformat:\n  pdf: default\nlang: fr\n---\n\n")))
    (metal-dashboard--create-new-file
     ".qmd"
     "Nom du document Quarto (sans extension) : "
     template)))

(defun metal-dashboard-new-python ()
  "Créer un fichier Python."
  (interactive)
  (metal-dashboard--create-new-file
   ".py"
   "Nom du fichier Python (sans extension) : "
   "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n\n"))

(defun metal-dashboard-new-prolog ()
  "Créer un fichier Prolog."
  (interactive)
  (metal-dashboard--create-new-file
   ".pl"
   "Nom du fichier Prolog (sans extension) : "
   "% -*- mode: prolog -*-\n\n"))

(defun metal-dashboard-new-org-document ()
  "Créer un document Org-mode."
  (interactive)
  (metal-dashboard--create-new-file
   ".org"
   "Nom du document Org (sans extension) : "
   (concat
    "#+TITLE: \n"
    "#+SUBTITLE: \n"
    "#+AUTHOR: \n"
    "#+DATE: \n"
    "#+OPTIONS: toc:nil num:t date:nil\n"
    "#+OUTPUT_TYPE: document\n"
    "#+LATEX_CLASS: article\n"
    "#+LATEX_HEADER: \\usepackage[margin=1in]{geometry}\n"
    "#+LATEX_HEADER: \\usepackage{listings}\n"
    "#+LATEX_HEADER: \\lstset{basicstyle=\\ttfamily\\small, breaklines=true, frame=single, columns=fullflexible, keepspaces=true, showstringspaces=false}\n"
    "\n")))

(defun metal-dashboard-new-drawio ()
  "Créer un diagramme draw.io et l'ouvrir dans draw.io (Desktop ou web)."
  (interactive)
  (cl-block metal-dashboard-new-drawio
    (let* ((treemacs-dir (ignore-errors
                           (when (and (fboundp 'treemacs-get-local-buffer)
                                      (treemacs-get-local-buffer))
                             (with-current-buffer (treemacs-get-local-buffer)
                               (let* ((btn (treemacs-current-button))
                                      (path (when btn (treemacs-button-get btn :path))))
                                 (when path
                                   (if (file-directory-p path)
                                       path
                                     (file-name-directory path))))))))
           (default-dir (or treemacs-dir "~/Documents/"))
           ;; Un seul dialogue graphique pour dossier + nom
           (filepath (read-file-name "Nouveau diagramme : " default-dir nil nil
                                     "nouveau.drawio"))
           ;; S'assurer que l'extension est présente
           (filepath (if (string-suffix-p ".drawio" filepath)
                         filepath
                       (concat filepath ".drawio"))))
      ;; Vérifier si le fichier existe
      (when (file-exists-p filepath)
        (let ((choice (read-char-choice
                       (format "« %s » existe déjà : [o]uvrir, [r]emplacer, [a]nnuler ? "
                               (file-name-nondirectory filepath))
                       '(?o ?r ?a))))
          (pcase choice
            (?o (metal-dashboard--open-in-drawio filepath)
                (cl-return-from metal-dashboard-new-drawio))
            (?a (message "Annulé.")
                (cl-return-from metal-dashboard-new-drawio))
            (?r nil))))
      ;; Écrire le template draw.io (XML minimal)
      (with-temp-file filepath
        (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                "<mxfile host=\"app.diagrams.net\" modified=\""
                (format-time-string "%Y-%m-%dT%H:%M:%S")
                "\" type=\"device\">\n"
                "  <diagram id=\"diag1\" name=\"Page-1\">\n"
                "    <mxGraphModel dx=\"1024\" dy=\"768\" grid=\"1\" "
                "gridSize=\"10\" guides=\"1\" tooltips=\"1\" connect=\"1\" "
                "arrows=\"1\" fold=\"1\" page=\"1\" pageScale=\"1\" "
                "pageWidth=\"1169\" pageHeight=\"827\" math=\"0\" shadow=\"0\">\n"
                "      <root>\n"
                "        <mxCell id=\"0\"/>\n"
                "        <mxCell id=\"1\" parent=\"0\"/>\n"
                "      </root>\n"
                "    </mxGraphModel>\n"
                "  </diagram>\n"
                "</mxfile>\n"))
      (message "📊 Ouverture de %s dans draw.io..." (file-name-nondirectory filepath))
      (metal-dashboard--open-in-drawio filepath))))


(defun metal-dashboard--open-in-drawio (filepath)
  "Ouvre FILEPATH dans draw.io Desktop ou la version web sur Linux."
  (let ((filepath (expand-file-name filepath)))
    (pcase system-type
      ('darwin
       (start-process "drawio" nil "open" "-a" "draw.io" filepath))
      ('windows-nt
       (let ((drawio-exe
              (or (executable-find "drawio")
                  (expand-file-name
                   "scoop/apps/draw.io/current/draw.io.exe"
                   (or (getenv "HOME") (getenv "USERPROFILE"))))))
         (if (and drawio-exe (file-exists-p drawio-exe))
             (start-process "drawio" nil drawio-exe filepath)
           (start-process "drawio" nil "cmd" "/c" "start" "" filepath))))
      ('gnu/linux
       (let ((drawio-exe (or (executable-find "drawio")
                             (and (file-exists-p "/usr/bin/drawio") "/usr/bin/drawio"))))
         (if drawio-exe
             (start-process "drawio" nil drawio-exe filepath)
           ;; Pas de draw.io Desktop — ouvrir la version web
           (browse-url "https://app.diagrams.net/")
           (message "draw.io web ouvert — utilisez Fichier > Ouvrir pour charger %s"
                    (file-name-nondirectory filepath))))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Fonction principale du dashboard
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-dashboard--date-francaise ()
  "Retourne la date en français, indépendamment de la locale."
  (let* ((jours '("Dimanche" "Lundi" "Mardi" "Mercredi" "Jeudi" "Vendredi" "Samedi"))
         (mois '("janvier" "février" "mars" "avril" "mai" "juin"
                 "juillet" "août" "septembre" "octobre" "novembre" "décembre"))
         (maintenant (decode-time))
         (jour-semaine (nth (nth 6 maintenant) jours))
         (jour (nth 3 maintenant))
         (nom-mois (nth (1- (nth 4 maintenant)) mois))
         (annee (nth 5 maintenant)))
    (format "%s %d %s %d" jour-semaine jour nom-mois annee)))

(defun metal-dashboard-open ()
  "Afficher le tableau de bord MetalEmacs dans un buffer lisible et joli."
  (interactive)

  ;; S'assurer que recentf est actif et à jour
  (recentf-mode 1)
  (ignore-errors (recentf-save-list))
  (ignore-errors (recentf-load-list))
  
  (let ((buf (get-buffer-create metal-dashboard-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
      (erase-buffer)
      (fundamental-mode)
      ;; Réglages d'affichage
      (setq-local cursor-type nil
                  line-spacing 0.3
                  truncate-lines t
                  buffer-read-only nil)

      ;; Largeur dynamique basée sur la fenêtre qui affiche ce buffer
      (let* ((dash-window (or (get-buffer-window buf)
                              (selected-window)))
             (avail-width (max 60 (- (window-width dash-window) 4))))

      ;; --------------------------------------------------
      ;;  Titre encadré
      ;; --------------------------------------------------
      (let* ((title "🤖 - MetalEmacs 1.1 – Tableau de bord ")
             (line-len (max (length title) avail-width))
             (line     (make-string line-len ?═))
             (pad-left (/ (- line-len (length title)) 2))
             (pad-right (- line-len pad-left (length title) 1 )))
        (insert "╔" line "╗\n")
        (insert "║"
                (make-string pad-left ? )
                title
                (make-string pad-right ? )
                "║\n")
        (insert "╚" line "╝\n\n"))

      ;; --------------------------------------------------
      ;;  Barre d'icônes principale
      ;; --------------------------------------------------
      (insert "  " (metal-dashboard--header-buttons) "\n")

      ;; Petite ligne de séparation
      (insert (make-string avail-width ?─) "\n\n")
      
      ;; --------------------------------------------------
      ;;  Section : Nouveaux fichiers (grille 2x2)
      ;; --------------------------------------------------
      (insert "◼ Nouveaux fichiers\n")

      (let* ((icon-presentation (if (fboundp 'nerd-icons-faicon)
                              (nerd-icons-faicon "nf-fa-file_powerpoint_o" :face '(:foreground "#8B0000"))
                            "📊"))
       (icon-document (if (fboundp 'nerd-icons-faicon)
                          (nerd-icons-faicon "nf-fa-file_text_o" :face '(:foreground "#8B0000"))
                        "📄"))
       (icon-python (if (fboundp 'nerd-icons-devicon)
                        (nerd-icons-devicon "nf-dev-python" :face '(:foreground "#3776AB"))
                      "🐍"))
       
       (icon-prolog (propertize "[]" 'face '(:foreground "#000000")))
       (icon-org (if (fboundp 'nerd-icons-sucicon)
                     (nerd-icons-sucicon "nf-custom-orgmode" :face '(:foreground "#77AA99"))
                   "📓"))
       (icon-drawio (if (fboundp 'nerd-icons-faicon)
                        (nerd-icons-faicon "nf-fa-sitemap" :face '(:foreground "#F08705"))
                      "📊"))
       (col2-start (max 30 (/ avail-width 2))))

        ;; Ligne 1 : Présentation et Document
        (let ((start (point)))
          (insert (format "   [p] %s " icon-presentation))
          (metal-dashboard--insert-clickable "Présentation QMD" #'metal-dashboard-new-qmd "Créer une présentation Quarto Markdown")
          (insert (make-string (max 1 (- col2-start (- (point) start))) ? )))
        (insert (format "[d] %s " icon-document))
        (metal-dashboard--insert-clickable "Document QMD" #'metal-dashboard-new-qmd-document "Créer un document Quarto Markdown")
        (insert "\n")

        ;; Ligne 2 : Python et Prolog
        (let ((start (point)))
          (insert (format "   [y] %s " icon-python))
          (metal-dashboard--insert-clickable "Python" #'metal-dashboard-new-python "Créer un fichier Python")
          (insert (make-string (max 1 (- col2-start (- (point) start))) ? )))
        (insert (format "[r] %s " icon-prolog))
        (metal-dashboard--insert-clickable "Prolog" #'metal-dashboard-new-prolog "Créer un fichier Prolog")
        (insert "\n")

        ;; Ligne 3 : Document Org et Diagramme draw.io
        (let ((start (point)))
          (insert (format "   [o] %s " icon-org))
          (metal-dashboard--insert-clickable "Document ORG" #'metal-dashboard-new-org-document "Créer un document Org-mode")
          (insert (make-string (max 1 (- col2-start (- (point) start))) ? )))
        (insert (format "[g] %s " icon-drawio))
        (metal-dashboard--insert-clickable "Diagramme" #'metal-dashboard-new-drawio "Créer un diagramme draw.io")
        (insert "\n\n"))
      (insert (metal-dashboard--separator avail-width))

      (insert "\n")
      

      ;; --------------------------------------------------
      ;;  Section : Derniers fichiers
      ;; --------------------------------------------------
      (insert "◼ Fichiers récents\n")
      (recentf-load-list)
      (dolist (f (seq-take
                  (seq-filter #'metal-dashboard--recentf-acceptable-p
                              recentf-list)
                  10))
        (let* ((name (file-name-nondirectory f))
               (dir (file-name-nondirectory
                     (directory-file-name (file-name-directory f))))
               (filepath f))
          (insert "   • ")
          (insert-text-button name
                              'face '(:foreground "#0066cc" :underline nil)
                              'mouse-face 'highlight
                              'help-echo filepath
                              'action `(lambda (_btn) (find-file ,filepath))
                              'follow-link t
                              'pointer 'hand)
          (insert (propertize (format "  (%s)" dir) 'face '(:foreground "#666666")))
          (insert "\n")))
      (insert "\n")
      (insert (metal-dashboard--separator avail-width))

      ;; --------------------------------------------------
      ;;  Section : Taille des polices
      ;; --------------------------------------------------
      (insert "\n◼ Taille des polices\n")
      (insert "   ")
      (insert-text-button "[ - ]"
                          'face '(:foreground "#cc0000" :weight bold)
                          'mouse-face 'highlight
                          'help-echo "Diminuer la taille des polices (C--)"
                          'action (lambda (_btn) 
                                    (when (fboundp 'metal-font-decrease)
                                      (metal-font-decrease)
                                      (metal-dashboard-open)))
                          'follow-link t
                          'pointer 'hand)
      (insert "  ")
      (let ((current-size (if (fboundp 'metal-font-height) 
                              (metal-font-height) 
                            130)))
        (insert (propertize (format " %d " current-size) 
                            'face '(:foreground "#333333" :weight bold))))
      (insert "  ")
      (insert-text-button "[ + ]"
                          'face '(:foreground "#006600" :weight bold)
                          'mouse-face 'highlight
                          'help-echo "Augmenter la taille des polices (C-+)"
                          'action (lambda (_btn) 
                                    (when (fboundp 'metal-font-increase)
                                      (metal-font-increase)
                                      (metal-dashboard-open)))
                          'follow-link t
                          'pointer 'hand)
      (insert "   ")
      (insert-text-button "[Réinitialiser]"
                          'face '(:foreground "#666666")
                          'mouse-face 'highlight
                          'help-echo "Réinitialiser la taille des polices (C-0)"
                          'action (lambda (_btn) 
                                    (when (fboundp 'metal-font-reset)
                                      (metal-font-reset)
                                      (metal-dashboard-open)))
                          'follow-link t
                          'pointer 'hand)
      (insert "\n\n")
      (insert (metal-dashboard--separator avail-width))

      ;; Raccourcis clavier locaux
      (local-set-key (kbd "p") #'metal-dashboard-new-qmd)
      (local-set-key (kbd "d") #'metal-dashboard-new-qmd-document)
      (local-set-key (kbd "y") #'metal-dashboard-new-python)
      (local-set-key (kbd "r") #'metal-dashboard-new-prolog)
      (local-set-key (kbd "o") #'metal-dashboard-new-org-document)
      (local-set-key (kbd "g") #'metal-dashboard-new-drawio)
      (local-set-key (kbd "G") #'metal-dashboard-open)  ; rafraîchir (déplacé de g à G)
      (local-set-key (kbd "+") #'metal-font-increase)
      (local-set-key (kbd "-") #'metal-font-decrease)
      (local-set-key (kbd "0") #'metal-font-reset)

      ;; Mise en forme finale
      (goto-char (point-min))
      (forward-line 4)
      (setq buffer-read-only t))))
    ;; Afficher le buffer si appelé interactivement
    (when (called-interactively-p 'any)
      (switch-to-buffer buf))
    buf))

;;; ═══════════════════════════════════════════════════════════════════
;;; Démarrage automatique
;;; ═══════════════════════════════════════════════════════════════════

;; Ne pas utiliser initial-buffer-choice car il cause des problèmes
;; Utiliser window-setup-hook à la place
;; (setq initial-buffer-choice t)  ;; Utilise *scratch* temporairement

(setq initial-buffer-choice
      (lambda ()
        (or (get-buffer "*Tableau-de-bord*")
            (metal-dashboard-open))))

(add-hook 'window-setup-hook
          (lambda ()
            ;; Ouvrir treemacs
            (ignore-errors
              (when (fboundp 'treemacs)
                (unless (treemacs-current-visibility)
                  (treemacs))))
            ;; Ouvrir le dashboard
            (metal-dashboard-open)))

(setq inhibit-startup-buffer-menu t
      inhibit-startup-message t)

;; Rafraîchir le dashboard quand la fenêtre est redimensionnée
(add-hook 'window-size-change-functions
          (lambda (_frame)
            (when-let ((buf (get-buffer "*Tableau-de-bord*")))
              (when (get-buffer-window buf)
                ;; Éviter de rafraîchir en boucle avec un timer
                (run-with-idle-timer 0.3 nil
                  (lambda ()
                    (when (get-buffer-window buf)
                      (metal-dashboard-open))))))))

(add-hook 'window-setup-hook
          (lambda ()
            (when (get-buffer "*Messages*")
              (delete-windows-on "*Messages*"))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Ouverture automatique des .drawio dans draw.io (Desktop ou web)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-dashboard--drawio-find-file-handler ()
  "Si le fichier ouvert est un .drawio, l'ouvrir dans draw.io
et tuer le buffer Emacs correspondant."
  (when (and buffer-file-name
             (string-match-p "\\.drawio$" buffer-file-name))
    (let ((filepath buffer-file-name))
      (message "📊 Ouverture dans draw.io...")
      (metal-dashboard--open-in-drawio filepath)
      ;; Tuer le buffer XML (inutile dans Emacs)
      (run-with-timer 0.5 nil
                      (lambda (buf)
                        (when (buffer-live-p buf)
                          (kill-buffer buf)))
                      (current-buffer)))))

(add-hook 'find-file-hook #'metal-dashboard--drawio-find-file-handler)

(provide 'metal-dashboard)

;;; metal-dashboard.el ends here
