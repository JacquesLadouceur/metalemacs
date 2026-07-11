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
(require 'metal-icones nil t)

;;; ═══════════════════════════════════════════════════════════════════
;;; Icônes : rendu SVG couleur délégué à `metal-icones.el'
;;; ═══════════════════════════════════════════════════════════════════
;;
;; La logique de rendu (dérivation du codepoint, téléchargement paresseux,
;; cache, repli sur emoji Unicode) est centralisée dans `metal-icones.el',
;; partagé avec `metal-toolbar.el' pour que TOUTES les barres d'outils et
;; le tableau de bord affichent des icônes couleur identiques sur macOS et
;; Windows.  Les fonctions ci-dessous ne sont plus que de fines enveloppes
;; conservées pour compatibilité avec les appels existants du module.

(defun metal-dashboard--icone-taille-px ()
  "Retourner la taille en pixels des icônes, dérivée des préférences.
Suit `metal-toolbar-emoji-size' (échelle ~160 = 100 %) si disponible,
sinon la valeur par défaut du module d'icônes."
  (if (fboundp 'metal-toolbar-emoji-size)
      (max 14 (round (* (metal-toolbar-emoji-size) 0.125)))
    (if (boundp 'metal-icones-taille-defaut) metal-icones-taille-defaut 20)))

(defun metal-dashboard--icone (emoji &optional taille-px)
  "Retourner EMOJI rendu comme icône SVG couleur (repli : emoji Unicode).
Enveloppe autour de `metal-icone' utilisant la taille du dashboard par
défaut."
  (if (fboundp 'metal-icone)
      (metal-icone emoji (or taille-px (metal-dashboard--icone-taille-px)))
    emoji))

(defun metal-dashboard--mdicon (emoji color &optional height fallback v-adjust)
  "Retourner EMOJI comme icône SVG couleur, dimensionnée par HEIGHT.
Signature conservée pour compatibilité (COLOR et FALLBACK ignorés).
HEIGHT est un multiplicateur (défaut 1.2) appliqué à la taille de base ;
V-ADJUST décale verticalement le repli texte le cas échéant."
  (ignore color fallback)
  (let* ((echelle (or height 1.2))
         (px (round (* (metal-dashboard--icone-taille-px) echelle)))
         (image (and (fboundp 'metal-icones-image)
                     (metal-icones-image emoji px))))
    (if image
        (propertize emoji 'display image 'rear-nonsticky t)
      ;; Repli : emoji Unicode dimensionné par :height (comportement d'origine).
      (let ((s (propertize emoji 'face `(:height ,echelle))))
        (if v-adjust
            (propertize s 'display `((raise ,(- v-adjust))))
          s)))))

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

(defcustom metal-dashboard-notes-dir
  (expand-file-name "~/Documents/MetalEmacs/Notes/")
  "Dossier des notes rapides ouvert par le bouton « Notes rapides » du tableau de bord.

Placé dans ~/Documents/MetalEmacs/ plutôt que dans `user-emacs-directory'
pour survivre aux mises à jour de MetalEmacs (le dossier .emacs.d peut
être écrasé par la distribution, effaçant son contenu utilisateur)."
  :type 'directory
  :group 'metal-dashboard)

(defcustom metal-dashboard-notes-tri 'date
  "Critère de tri par défaut dans le buffer « Notes rapides ».
Valeurs possibles :
  - `date' : par date de modification, plus récente en premier
  - `nom'  : par ordre alphabétique du nom de fichier"
  :type '(choice (const :tag "Par date" date)
                 (const :tag "Par nom" nom))
  :group 'metal-dashboard)

(defun metal-dashboard--migrer-notes-si-besoin ()
  "Déplacer l'ancien `notes.org' vers le nouveau dossier `metal-dashboard-notes-dir'.
Migration unique pour les utilisateurs qui avaient l'ancien emplacement
(fichier unique). Le fichier est déplacé tel quel comme une note parmi
d'autres."
  (let* ((ancien-emacs-d (expand-file-name "notes.org" user-emacs-directory))
         (ancien-documents (expand-file-name "~/Documents/MetalEmacs/notes.org"))
         (nouveau-dir metal-dashboard-notes-dir)
         (cible (expand-file-name "notes.org" nouveau-dir)))
    ;; Migrer depuis ~/.emacs.d/notes.org
    (when (and (file-exists-p ancien-emacs-d)
               (not (file-exists-p cible)))
      (make-directory nouveau-dir t)
      (rename-file ancien-emacs-d cible)
      (message "📝 notes.org déplacé : %s → %s" ancien-emacs-d cible))
    ;; Migrer depuis ~/Documents/MetalEmacs/notes.org (fichier unique
    ;; à côté du nouveau dossier)
    (when (and (file-exists-p ancien-documents)
               (not (file-equal-p ancien-documents cible))
               (not (file-exists-p cible)))
      (make-directory nouveau-dir t)
      (rename-file ancien-documents cible)
      (message "📝 notes.org déplacé : %s → %s" ancien-documents cible))))

;; Exécuter la migration au chargement du module
(metal-dashboard--migrer-notes-si-besoin)

;;; ═══════════════════════════════════════════════════════════════════
;;; Notes rapides : buffer dédié pour gérer plusieurs notes
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-dashboard--notes-format-date-relative (mtime)
  "Convertir un temps de modification MTIME en chaîne relative en français.
Renvoie par exemple « il y a 2 heures », « hier », « il y a 3 jours »."
  (let* ((maintenant (float-time))
         (diff (- maintenant (float-time mtime)))
         (minutes (/ diff 60))
         (heures (/ minutes 60))
         (jours (/ heures 24)))
    (cond
     ((< diff 60)
      "à l'instant")
     ((< minutes 60)
      (format "il y a %d minute%s"
              (floor minutes)
              (if (>= minutes 2) "s" "")))
     ((< heures 2)
      "il y a une heure")
     ((< heures 24)
      (format "il y a %d heures" (floor heures)))
     ((< jours 2)
      "hier")
     ((< jours 7)
      (format "il y a %d jours" (floor jours)))
     ((< jours 30)
      (format "il y a %d semaines" (floor (/ jours 7))))
     ((< jours 365)
      (format "il y a %d mois" (floor (/ jours 30))))
     (t
      (format "il y a %d ans" (floor (/ jours 365)))))))

(defun metal-dashboard--notes-creer-template (filepath)
  "Insérer un en-tête Org standard dans le fichier FILEPATH nouvellement créé.
Le titre est dérivé du nom de fichier (sans extension)."
  (let ((titre (file-name-base filepath)))
    (insert (format "#+TITLE: %s\n" titre)
            "#+OPTIONS: toc:nil num:nil date:nil author:nil\n"
            "#+OUTPUT_TYPE: document\n"
            "#+LATEX_CLASS: article\n"
            "#+LATEX_HEADER: \\usepackage[margin=1in]{geometry}\n\n")))

(defun metal-dashboard--notes-creer-nouvelle ()
  "Demander un nom de note et la créer dans `metal-dashboard-notes-dir'.
Si l'utilisateur n'a pas tapé l'extension .org, elle est ajoutée
automatiquement. Si le fichier existe déjà, il est simplement ouvert."
  (interactive)
  (let* ((nom (read-string "Nom de la nouvelle note : "))
         (nom-avec-ext (if (string-suffix-p ".org" nom)
                           nom
                         (concat nom ".org")))
         (filepath (expand-file-name nom-avec-ext
                                     metal-dashboard-notes-dir))
         (nouveau (not (file-exists-p filepath))))
    (when (string-empty-p nom)
      (user-error "Nom de note vide"))
    (find-file filepath)
    (when (and nouveau (= (buffer-size) 0))
      (metal-dashboard--notes-creer-template filepath)
      (save-buffer))))

(defun metal-dashboard--notes-liste-fichiers ()
  "Retourner la liste des fichiers .org du dossier des notes rapides.
Chaque élément est un cons (FILEPATH . MTIME) où MTIME est le
moment de la dernière modification."
  (let ((dir metal-dashboard-notes-dir))
    (when (file-directory-p dir)
      (mapcar (lambda (f)
                (cons f (file-attribute-modification-time
                         (file-attributes f))))
              (directory-files dir t "\\.org\\'" t)))))

(defun metal-dashboard--notes-trier (fichiers critere)
  "Trier la liste FICHIERS selon CRITERE (`date' ou `nom').
Pour `date', les plus récents apparaissent en premier."
  (cond
   ((eq critere 'nom)
    (sort fichiers (lambda (a b)
                     (string< (file-name-nondirectory (car a))
                              (file-name-nondirectory (car b))))))
   (t  ; date par défaut
    (sort fichiers (lambda (a b)
                     (time-less-p (cdr b) (cdr a)))))))

(defun metal-dashboard--notes-bouton-ouvrir (filepath)
  "Construire l'action qui ouvre FILEPATH en remplaçant le buffer courant."
  (lambda (_button)
    (let ((buffer-notes (current-buffer)))
      (find-file filepath)
      (kill-buffer buffer-notes))))

(defun metal-dashboard--notes-bouton-creer ()
  "Construire l'action qui crée une nouvelle note et remplace le buffer."
  (lambda (_button)
    (let ((buffer-notes (current-buffer)))
      (call-interactively #'metal-dashboard--notes-creer-nouvelle)
      (when (buffer-live-p buffer-notes)
        (kill-buffer buffer-notes)))))

(defun metal-dashboard--notes-changer-tri ()
  "Basculer le critère de tri entre date et nom, puis rafraîchir le buffer."
  (interactive)
  (setq metal-dashboard-notes-tri
        (if (eq metal-dashboard-notes-tri 'date) 'nom 'date))
  (metal-dashboard-notes-ouvrir))

(defun metal-dashboard-notes-ouvrir ()
  "Ouvrir le buffer `*Notes rapides*' listant les notes du dossier.
Si le dossier n'existe pas, le créer. Si aucune note n'existe,
demander immédiatement un nom pour créer la première."
  (interactive)
  (make-directory metal-dashboard-notes-dir t)
  (let ((fichiers (metal-dashboard--notes-liste-fichiers)))
    (if (null fichiers)
        ;; Aucune note : on demande directement un nom.
        (call-interactively #'metal-dashboard--notes-creer-nouvelle)
      ;; Au moins une note : afficher le buffer dédié.
      (let ((buffer (get-buffer-create "*Notes rapides*"))
            (fichiers-tries (metal-dashboard--notes-trier
                             fichiers metal-dashboard-notes-tri)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            ;; En-tête
            (insert (propertize "Notes rapides\n"
                                'face '(:height 1.5 :weight bold)))
            (insert "\n")
            ;; Indication de tri + bouton de bascule
            (insert (format "Tri : %s  "
                            (if (eq metal-dashboard-notes-tri 'date)
                                "par date"
                              "par nom")))
            (insert-button "[changer le tri]"
                           'action (lambda (_b)
                                     (metal-dashboard--notes-changer-tri))
                           'follow-link t)
            (insert "\n\n")
            (insert "Notes existantes :\n\n")
            ;; Liste des notes
            (dolist (entree fichiers-tries)
              (let* ((filepath (car entree))
                     (mtime (cdr entree))
                     (nom (file-name-nondirectory filepath))
                     (date-relative
                      (metal-dashboard--notes-format-date-relative mtime)))
                (insert "  ")
                (insert-button (concat (metal-dashboard--icone "📝") " " nom)
                               'action (metal-dashboard--notes-bouton-ouvrir filepath)
                               'follow-link t
                               'help-echo (format "Ouvrir %s" filepath))
                (insert (format "    %s\n" date-relative))))
            (insert "\n  ")
            (insert-button (concat (metal-dashboard--icone "➕")
                                   " Créer une nouvelle note...")
                           'action (metal-dashboard--notes-bouton-creer)
                           'follow-link t
                           'help-echo "Demander un nom et créer une note")
            (insert "\n\n")
            (insert (format "Dossier : %s\n"
                            (abbreviate-file-name
                             metal-dashboard-notes-dir))))
          (setq buffer-read-only t)
          (setq-local tab-line-exclude nil)
          (tab-line-mode 1)
          (goto-char (point-min)))
        (switch-to-buffer buffer)))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Signets : buffer dédié pour gérer plusieurs fichiers de signets
;;; ═══════════════════════════════════════════════════════════════════

(defcustom metal-dashboard-signets-tri 'date
  "Critère de tri par défaut dans le buffer « Signets ».
Valeurs possibles :
  - `date' : par date de modification, plus récente en premier
  - `nom'  : par ordre alphabétique du nom de fichier"
  :type '(choice (const :tag "Par date" date)
                 (const :tag "Par nom" nom))
  :group 'metal-dashboard)

(defun metal-dashboard--signets-dir ()
  "Retourne le dossier des signets défini dans `metal-org.el'.
Fournit une valeur de repli si le module n'est pas encore chargé."
  (if (boundp 'metal-org-signets-dir)
      metal-org-signets-dir
    (expand-file-name "~/Documents/MetalEmacs/Signets/")))

(defun metal-dashboard--signets-creer-template (filepath)
  "Insérer un en-tête Org standard dans le fichier de signets FILEPATH.
Le titre est dérivé du nom de fichier (sans extension) et une première
section « Général » est ajoutée."
  (let ((titre (file-name-base filepath)))
    (insert (format "#+TITLE: %s\n\n* Général\n" titre))))

(defun metal-dashboard--signets-creer-nouvelle ()
  "Demander un nom de fichier de signets et le créer dans le dossier.
Si l'utilisateur n'a pas tapé l'extension .org, elle est ajoutée
automatiquement. Le fichier créé devient le fichier de signets actif."
  (interactive)
  (let* ((dir (metal-dashboard--signets-dir))
         (nom (read-string "Nom de la nouvelle liste de signets : "))
         (nom-avec-ext (if (string-suffix-p ".org" nom)
                           nom
                         (concat nom ".org")))
         (filepath (expand-file-name nom-avec-ext dir))
         (nouveau (not (file-exists-p filepath))))
    (when (string-empty-p nom)
      (user-error "Nom de fichier de signets vide"))
    (make-directory dir t)
    (when (fboundp 'metal-org-selectionner-signets)
      (metal-org-selectionner-signets filepath))
    (find-file filepath)
    (when (and nouveau (= (buffer-size) 0))
      (metal-dashboard--signets-creer-template filepath)
      (save-buffer))))

(defun metal-dashboard--signets-liste-fichiers ()
  "Retourner la liste des fichiers .org du dossier des signets.
Chaque élément est un cons (FILEPATH . MTIME) où MTIME est le
moment de la dernière modification."
  (let ((dir (metal-dashboard--signets-dir)))
    (when (file-directory-p dir)
      (mapcar (lambda (f)
                (cons f (file-attribute-modification-time
                         (file-attributes f))))
              (directory-files dir t "\\.org\\'" t)))))

(defun metal-dashboard--signets-trier (fichiers critere)
  "Trier la liste FICHIERS selon CRITERE (`date' ou `nom').
Pour `date', les plus récents apparaissent en premier."
  (cond
   ((eq critere 'nom)
    (sort fichiers (lambda (a b)
                     (string< (file-name-nondirectory (car a))
                              (file-name-nondirectory (car b))))))
   (t  ; date par défaut
    (sort fichiers (lambda (a b)
                     (time-less-p (cdr b) (cdr a)))))))

(defun metal-dashboard--signets-bouton-ouvrir (filepath)
  "Construire l'action qui ouvre FILEPATH comme fichier de signets actif.
Remplace le buffer de sélection courant."
  (lambda (_button)
    (let ((buffer-signets (current-buffer)))
      (when (fboundp 'metal-org-selectionner-signets)
        (metal-org-selectionner-signets filepath))
      (find-file filepath)
      (kill-buffer buffer-signets))))

(defun metal-dashboard--signets-bouton-creer ()
  "Construire l'action qui crée un nouveau fichier de signets."
  (lambda (_button)
    (let ((buffer-signets (current-buffer)))
      (call-interactively #'metal-dashboard--signets-creer-nouvelle)
      (when (buffer-live-p buffer-signets)
        (kill-buffer buffer-signets)))))

(defun metal-dashboard--signets-changer-tri ()
  "Basculer le critère de tri entre date et nom, puis rafraîchir le buffer."
  (interactive)
  (setq metal-dashboard-signets-tri
        (if (eq metal-dashboard-signets-tri 'date) 'nom 'date))
  (metal-dashboard-signets-ouvrir))

(defun metal-dashboard-signets-ouvrir ()
  "Ouvrir le buffer `*Signets*' listant les fichiers de signets du dossier.
Si le dossier n'existe pas, le créer. Si aucun fichier n'existe,
demander immédiatement un nom pour créer le premier."
  (interactive)
  (let ((dir (metal-dashboard--signets-dir)))
    (make-directory dir t)
    (let ((fichiers (metal-dashboard--signets-liste-fichiers)))
      (if (null fichiers)
          ;; Aucun fichier : on demande directement un nom.
          (call-interactively #'metal-dashboard--signets-creer-nouvelle)
        ;; Au moins un fichier : afficher le buffer dédié.
        (let ((buffer (get-buffer-create "*Signets*"))
              (fichiers-tries (metal-dashboard--signets-trier
                               fichiers metal-dashboard-signets-tri)))
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)
              ;; En-tête
              (insert (propertize "Signets\n"
                                  'face '(:height 1.5 :weight bold)))
              (insert "\n")
              ;; Indication de tri + bouton de bascule
              (insert (format "Tri : %s  "
                              (if (eq metal-dashboard-signets-tri 'date)
                                  "par date"
                                "par nom")))
              (insert-button "[changer le tri]"
                             'action (lambda (_b)
                                       (metal-dashboard--signets-changer-tri))
                             'follow-link t)
              (insert "\n\n")
              (insert "Listes de signets existantes :\n\n")
              ;; Liste des fichiers de signets
              (dolist (entree fichiers-tries)
                (let* ((filepath (car entree))
                       (mtime (cdr entree))
                       (nom (file-name-nondirectory filepath))
                       (date-relative
                        (metal-dashboard--notes-format-date-relative mtime)))
                  (insert "  ")
                  (insert-button (concat (metal-dashboard--icone "🔖") " " nom)
                                 'action (metal-dashboard--signets-bouton-ouvrir filepath)
                                 'follow-link t
                                 'help-echo (format "Ouvrir %s" filepath))
                  (insert (format "    %s\n" date-relative))))
              (insert "\n  ")
              (insert-button (concat (metal-dashboard--icone "➕")
                                     " Créer une nouvelle liste de signets...")
                             'action (metal-dashboard--signets-bouton-creer)
                             'follow-link t
                             'help-echo "Demander un nom et créer une liste de signets")
              (insert "\n\n")
              (insert (format "Dossier : %s\n"
                              (abbreviate-file-name
                               (metal-dashboard--signets-dir)))))
            (setq buffer-read-only t)
            (setq-local tab-line-exclude nil)
            (tab-line-mode 1)
            (goto-char (point-min)))
          (switch-to-buffer buffer))))))

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

(defun metal-dashboard--insert-to-column (column)
  "Insérer des espaces jusqu'à COLUMN.
Cette méthode utilise les colonnes texte Emacs plutôt que des pixels.
Elle est plus stable entre macOS et Windows pour ce dashboard."
  (let ((column (max 0 column)))
    (when (> column (current-column))
      (insert (make-string (- column (current-column)) ? )))))

(defun metal-dashboard--insert-new-file-entry (key icon label action help key-column)
  "Insérer une entrée de création de fichier à KEY-COLUMN."
  (metal-dashboard--insert-to-column key-column)
  (insert (format "[%s] " key))
  (insert icon)
  (insert " ")
  (metal-dashboard--insert-clickable label action help))

(defun metal-dashboard--insert-new-file-row
    (left-key left-icon left-label left-action left-help
              right-key right-icon right-label right-action right-help
              left-key-column right-key-column)
  "Insérer une ligne à deux colonnes pour la section Nouveaux fichiers."
  (metal-dashboard--insert-new-file-entry
   left-key left-icon left-label left-action left-help
   left-key-column)
  (metal-dashboard--insert-to-column right-key-column)
  (metal-dashboard--insert-new-file-entry
   right-key right-icon right-label right-action right-help
   right-key-column)
  (insert "\n"))

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
  (let* ((px (metal-dashboard--icone-taille-px))
         (icon-folder    (metal-dashboard--icone "❓" (round (* px 1.6))))
         (icon-calendar  (metal-dashboard--icone "📅" (round (* px 1.5))))
         (icon-notes     (metal-dashboard--icone "📝" (round (* px 1.5))))
         (icon-signets   (metal-dashboard--icone "🔖" (round (* px 1.4))))
         (icon-news      (metal-dashboard--icone "📰" (round (* px 1.5))))
         (icon-assistant (metal-dashboard--icone "🔧" (round (* px 1.5))))

         (text-face '(:foreground "#0066cc" :weight bold)))
    (concat
     (metal-dashboard--make-action-button
      (concat icon-folder " " (propertize "METAL" 'face text-face))
      "Ouvrir le guide METAL (PDF)"
      (lambda ()
        (interactive)
        (find-file (expand-file-name "Metal.pdf" user-emacs-directory))))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-calendar " " (propertize "Calendrier" 'face text-face))
      "Ouvrir le calendrier"
      (lambda ()
        (interactive)
        (if (fboundp 'metal-calendrier-ouvrir)
            (metal-calendrier-ouvrir)
          (calendar))))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-notes " " (propertize "Notes rapides" 'face text-face))
      "Ouvrir les notes rapides"
      (lambda ()
        (interactive)
        (metal-dashboard-notes-ouvrir)))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-signets " " (propertize "Signets" 'face text-face))
      "Ouvrir les signets web"
      (lambda ()
        (interactive)
        (metal-dashboard-signets-ouvrir)))
     "  "
     (metal-dashboard--make-action-button
      (concat icon-news " " (propertize "Actualités" 'face text-face))
      "Choisir un site d'actualités"
      #'metal-dashboard-actualites-menu)
     "  "
     (metal-dashboard--make-action-button
      (concat icon-assistant " " (propertize "Assistant" 'face text-face))
      "Ouvrir l'assistant d'installation"
      (lambda ()
        (interactive)
        (require 'metal-deps nil t)
        (if (fboundp 'metal-deps-afficher-etat)
            (metal-deps-afficher-etat)
          (message "metal-deps non disponible - vérifiez que le fichier existe"))))
     "  "
     (if (fboundp 'metal-agent-dashboard-buttons)
          (or (metal-agent-dashboard-buttons) "")
       ""))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Fonctions de création de fichiers
;;; ═══════════════════════════════════════════════════════════════════
(defun metal-dashboard--treemacs-selected-dir ()
  "Retourne le dossier sélectionné dans Treemacs.
Si un fichier est sélectionné, retourne son dossier parent.
Sinon, affiche un message d'erreur."
  (let* ((buf (and (fboundp 'treemacs-get-local-buffer)
                   (treemacs-get-local-buffer)))
         (win (and (buffer-live-p buf)
                   (get-buffer-window buf t)))
         (pos (and win (window-point win)))
         (path (and pos
                    (with-current-buffer buf
                      (get-text-property pos :path)))))
    (cond
     ;; Cas 1 : dossier
     ((and path (file-directory-p path))
      (file-name-as-directory path))

     ;; Cas 2 : fichier
     ((and path (file-regular-p path))
      (file-name-directory path))

     ;; Cas 3 : autre chemin existant
     ((and path (file-exists-p path))
      (file-name-directory path))

     ;; Cas 4 : rien → message utilisateur
     (t
      (user-error "Veuillez sélectionner un dossier ou un fichier dans Treemacs")))))

(defun metal-dashboard--create-new-file (extension prompt &optional template)
  "Créer un nouveau fichier dans le dossier sélectionné dans Treemacs."
  (cl-block metal-dashboard--create-new-file
    (let* ((dir (metal-dashboard--treemacs-selected-dir))
           (name (string-trim (read-string prompt)))
           (replace nil))

      (unless dir
        (user-error "Aucun dossier Treemacs sélectionné"))

      (when (string-empty-p name)
        (user-error "Nom de fichier vide"))

      (when (string-match-p "[/\\]" name)
        (user-error "Le nom ne doit pas contenir / ou \\"))

      ;; Évite test.qmd.qmd
      (when (string-suffix-p extension name t)
        (setq name (substring name 0 (- (length name) (length extension)))))

      (let ((filepath (expand-file-name (concat name extension) dir)))

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

        ;; Crée seulement le dossier parent, jamais le fichier comme dossier.
        (make-directory (file-name-directory filepath) t)

        (find-file filepath)
        (when (or (= (buffer-size) 0) replace)
          (erase-buffer)
          (when template
            (insert template)))
        (save-buffer)
        (message "Fichier créé : %s" filepath)))))

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
     "Présentation Quarto: "
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
     "Document Quarto: "
     template)))

(defun metal-dashboard-new-python ()
  "Créer un fichier Python."
  (interactive)
  (metal-dashboard--create-new-file
   ".py"
   "Fichier Python: "
   "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n\n"))

(defun metal-dashboard-new-prolog ()
  "Créer un fichier Prolog."
  (interactive)
  (metal-dashboard--create-new-file
   ".pl"
   "Fichier Prolog: "
   "% -*- mode: prolog -*-\n\n"))

(defun metal-dashboard-new-org-document ()
  "Créer un document Org-mode."
  (interactive)
  (metal-dashboard--create-new-file
   ".org"
   "Document Org-mode: "
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
  "Créer un diagramme draw.io et l'ouvrir dans draw.io."
  (interactive)
  (let* ((dir (metal-dashboard--treemacs-selected-dir))
         (name (string-trim (read-string "Diagramme draw.io: ")))
         (filepath nil)
         (replace nil))
    (when (string-empty-p name)
      (user-error "Nom de fichier vide"))
    (when (string-match-p "[/\\]" name)
      (user-error "Le nom ne doit pas contenir / ou \\"))
    (when (string-suffix-p ".drawio" name t)
      (setq name (substring name 0 (- (length name) (length ".drawio")))))
    (setq filepath (expand-file-name (concat name ".drawio") dir))

    (when (file-exists-p filepath)
      (let ((choice (read-char-choice
                     (format "« %s » existe déjà : [r]emplacer, [o]uvrir, [a]nnuler ? "
                             (file-name-nondirectory filepath))
                     '(?r ?o ?a))))
        (pcase choice
          (?r (setq replace t))
          (?o (metal-dashboard--open-in-drawio filepath)
              (cl-return-from metal-dashboard-new-drawio))
          (?a (message "Annulé.")
              (cl-return-from metal-dashboard-new-drawio)))))

    (when (or replace (not (file-exists-p filepath)))
      (with-temp-file filepath
        (insert
         "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
         "<mxfile host=\"app.diagrams.net\" type=\"device\">\n"
         "  <diagram id=\"diag1\" name=\"Page-1\">\n"
         "    <mxGraphModel dx=\"1024\" dy=\"768\" grid=\"1\" gridSize=\"10\" guides=\"1\" tooltips=\"1\" connect=\"1\" arrows=\"1\" fold=\"1\" page=\"1\" pageScale=\"1\" pageWidth=\"1169\" pageHeight=\"827\" math=\"0\" shadow=\"0\">\n"
         "      <root>\n"
         "        <mxCell id=\"0\"/>\n"
         "        <mxCell id=\"1\" parent=\"0\"/>\n"
         "      </root>\n"
         "    </mxGraphModel>\n"
         "  </diagram>\n"
         "</mxfile>\n")))

    (message "Ouverture de %s dans draw.io..."
             (file-name-nondirectory filepath))
    (metal-dashboard--open-in-drawio filepath)))

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

  ;; Précharger les icônes SVG couleur du tableau de bord (silencieux ;
  ;; téléchargées si absentes, repli sur emoji Unicode si hors-ligne).
  (when (fboundp 'metal-icones-precharger)
    (metal-icones-precharger
     '("👤" "❓" "📅" "📝" "🔖" "📰" "🔧"
       "📊" "📄" "🐍" "🦉" "📋" "🗂" "➕")
     (metal-dashboard--icone-taille-px)))

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
      (let* ((title (concat (metal-dashboard--icone "👤")
                            " - MetalEmacs 1.1 – Tableau de bord "))
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

      (let* ((icon-presentation
              (metal-dashboard--mdicon "📊" nil 1.2))
             (icon-document
              (metal-dashboard--mdicon "📄" nil 1.2))
             (icon-python
              (metal-dashboard--mdicon "🐍" nil 1.2))
             (icon-prolog
              (metal-dashboard--mdicon "🦉" nil 1.2))
             (icon-org
              (metal-dashboard--mdicon "📋" nil 1.2))
             (icon-drawio
              (if (fboundp 'metal-icone-locale)
                  (let ((s (metal-icone-locale
                            "organigramme"
                            (round (* (metal-dashboard--icone-taille-px) 1.2)))))
                    (if (and s (> (length s) 0))
                        s
                      (metal-dashboard--mdicon "🗂️" nil 1.2)))
                (metal-dashboard--mdicon "🗂️" nil 1.2)))
             (left-key-column 3)
             (right-key-column 42))
        (metal-dashboard--insert-new-file-row
         "p" icon-presentation "Présentation QMD"
         #'metal-dashboard-new-qmd
         "Créer une présentation Quarto Markdown"
         "d" icon-document "Document QMD"
         #'metal-dashboard-new-qmd-document
         "Créer un document Quarto Markdown"
         left-key-column right-key-column)
        (metal-dashboard--insert-new-file-row
         "y" icon-python "Python"
         #'metal-dashboard-new-python
         "Créer un fichier Python"
         "r" icon-prolog "Prolog"
         #'metal-dashboard-new-prolog
         "Créer un fichier Prolog"
         left-key-column right-key-column)
        (metal-dashboard--insert-new-file-row
         "o" icon-org "Document ORG"
         #'metal-dashboard-new-org-document
         "Créer un document Org-mode"
         "g" icon-drawio "Diagramme"
         #'metal-dashboard-new-drawio
         "Créer un diagramme draw.io"
         left-key-column right-key-column)
        (insert "\n"))
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

      ;; --------------------------------------------------
      ;;  Section : Taille des icônes
      ;; --------------------------------------------------
      (insert "◼ Taille des icônes\n")
      (insert "   ")
      (insert-text-button "[ - ]"
                          'face '(:foreground "#cc0000" :weight bold)
                          'mouse-face 'highlight
                          'help-echo "Diminuer la taille des icônes des barres d'outils"
                          'action (lambda (_btn)
                                    (when (fboundp 'metal-toolbar-emoji-decrease)
                                      (metal-toolbar-emoji-decrease)
                                      (metal-dashboard-open)))
                          'follow-link t
                          'pointer 'hand)
      (insert "  ")
      (let ((current (if (fboundp 'metal-toolbar-emoji-size)
                         (metal-toolbar-emoji-size)
                       160)))
        (insert (propertize (format " %d " current)
                            'face '(:foreground "#333333" :weight bold))))
      (insert "  ")
      (insert-text-button "[ + ]"
                          'face '(:foreground "#006600" :weight bold)
                          'mouse-face 'highlight
                          'help-echo "Augmenter la taille des icônes des barres d'outils"
                          'action (lambda (_btn)
                                    (when (fboundp 'metal-toolbar-emoji-increase)
                                      (metal-toolbar-emoji-increase)
                                      (metal-dashboard-open)))
                          'follow-link t
                          'pointer 'hand)
      (insert "   ")
      (insert-text-button "[Réinitialiser]"
                          'face '(:foreground "#666666")
                          'mouse-face 'highlight
                          'help-echo "Réinitialiser la taille des icônes"
                          'action (lambda (_btn)
                                    (when (fboundp 'metal-toolbar-emoji-reset)
                                      (metal-toolbar-emoji-reset)
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
