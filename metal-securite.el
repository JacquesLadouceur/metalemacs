;;; metal-securite.el --- Protection et récupération de fichiers pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;;; Commentaires:
;;
;; Ce module ajoute un filet de sécurité pour éviter la perte de fichiers
;; dans MetalEmacs :
;;
;;   - Corbeille interne MetalEmacs (~/.emacs.d/corbeille/)
;;     Copie automatique avant suppression dans Treemacs (uniquement)
;;     Chemin d'origine mémorisé (fichier .meta) pour restauration directe
;;     Nettoyage automatique des éléments de plus de 30 jours
;;
;;   - Buffer interactif « Corbeille MetalEmacs »
;;     R   : restaurer l'élément à son emplacement d'origine
;;     D   : supprimer définitivement l'élément sous le curseur
;;     V   : vider toute la corbeille
;;     r   : rafraîchir l'affichage
;;     RET : prévisualiser le fichier
;;     n/p : naviguer (bas/haut)
;;     ?   : aide
;;     q   : fermer le buffer
;;
;;   - Commandes
;;     M-x metal-corbeille              : ouvrir le buffer interactif
;;     M-x metal-securite-restaurer     : restaurer via completing-read
;;     M-x metal-vider-corbeille        : nettoyer (par âge)
;;     M-x metal-vider-corbeille-tout   : vider complètement
;;
;; Installation :
;;   Ajouter dans init.el :
;;     (require 'metal-securite)
;;
;; Bouton dashboard :
;;   Dans metal-dashboard--header-buttons, ajouter :
;;     (metal-securite--dashboard-bouton)

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; ============================================================================
;; Configuration
;; ============================================================================

(defgroup metal-securite nil
  "Protection et récupération de fichiers pour MetalEmacs."
  :group 'files
  :prefix "metal-securite-")

(defcustom metal-securite-dossier-corbeille
  (expand-file-name "corbeille" user-emacs-directory)
  "Répertoire de la corbeille interne MetalEmacs."
  :type 'directory
  :group 'metal-securite)

(defcustom metal-securite-jours-retention 30
  "Nombre de jours de rétention dans la corbeille interne."
  :type 'integer
  :group 'metal-securite)

(defcustom metal-securite-taille-max-mo 50
  "Taille maximale (en Mo) d'un fichier à copier dans la corbeille interne.
Les fichiers plus gros sont ignorés (ils iront dans la corbeille système)."
  :type 'integer
  :group 'metal-securite)

(defcustom metal-securite-taille-max-dossier-mo 300
  "Taille maximale (en Mo) d'un dossier à copier dans la corbeille interne.
Les dossiers plus gros sont ignorés."
  :type 'integer
  :group 'metal-securite)

(defvar metal-securite-inhiber nil
  "Si non-nil, désactive toute interception de suppression.
Utilisé par les opérations internes (mise à jour, distribution).")

(defconst metal-securite-nom-buffer "Corbeille MetalEmacs"
  "Nom du buffer de la corbeille (sans astérisques pour tab-line).")

;; ============================================================================
;; Initialisation
;; ============================================================================

(defun metal-securite--init-dossiers ()
  "Créer le répertoire corbeille s'il n'existe pas."
  (unless (file-exists-p metal-securite-dossier-corbeille)
    (make-directory metal-securite-dossier-corbeille t)))

(metal-securite--init-dossiers)

;; ============================================================================
;; Filtrage minimal
;; ============================================================================

(defun metal-securite--fichier-a-ignorer-p (chemin)
  "Retourne t si CHEMIN ne devrait pas être copié dans la corbeille.
Seuls les cas extrêmes sont filtrés (la corbeille elle-même, taille zéro)."
  (when chemin
    (let ((chemin-abs (expand-file-name chemin)))
      (or
       ;; Fichiers dans la corbeille elle-même (éviter la boucle infinie)
       (string-prefix-p (expand-file-name metal-securite-dossier-corbeille) chemin-abs)
       ;; Fichiers de taille zéro (pas de contenu à sauvegarder)
       (and (file-exists-p chemin)
            (not (file-directory-p chemin))
            (zerop (or (file-attribute-size (file-attributes chemin)) 0)))))))

;; ============================================================================
;; Fichiers .meta — mémoriser le chemin d'origine
;; ============================================================================

(defun metal-securite--chemin-meta (chemin-corbeille)
  "Retourner le chemin du fichier .meta associé à CHEMIN-CORBEILLE."
  (concat (directory-file-name chemin-corbeille) ".meta"))

(defun metal-securite--ecrire-meta (chemin-corbeille chemin-original)
  "Écrire CHEMIN-ORIGINAL dans le fichier .meta de CHEMIN-CORBEILLE."
  (condition-case nil
      (with-temp-file (metal-securite--chemin-meta chemin-corbeille)
        (insert (expand-file-name chemin-original)))
    (error nil)))

(defun metal-securite--lire-meta (chemin-corbeille)
  "Lire et retourner le chemin d'origine depuis le .meta de CHEMIN-CORBEILLE.
Retourne nil si le fichier .meta n'existe pas."
  (let ((meta (metal-securite--chemin-meta chemin-corbeille)))
    (when (file-exists-p meta)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents meta)
            (string-trim (buffer-string)))
        (error nil)))))

(defun metal-securite--supprimer-meta (chemin-corbeille)
  "Supprimer le fichier .meta associé à CHEMIN-CORBEILLE, s'il existe."
  (let ((meta (metal-securite--chemin-meta chemin-corbeille)))
    (when (file-exists-p meta)
      ;; Effacement réel : sans quoi, avec `delete-by-moving-to-trash',
      ;; les .meta s'accumulent dans la corbeille du système.
      (delete-file meta))))

;; ============================================================================
;; Corbeille interne MetalEmacs
;; ============================================================================

(defun metal-securite--horodatage ()
  "Retourner un horodatage pour nommer les fichiers."
  (format-time-string "%Y%m%d-%H%M%S"))

(defun metal-securite--copier-vers-corbeille (chemin)
  "Copier CHEMIN dans la corbeille interne MetalEmacs.
Crée aussi un fichier .meta avec le chemin d'origine.
Retourne le chemin de la copie, ou nil si le fichier est ignoré."
  (when (and chemin
             (file-exists-p chemin)
             (not (file-directory-p chemin))
             (not (metal-securite--fichier-a-ignorer-p chemin)))
    (let ((taille-mo (/ (file-attribute-size (file-attributes chemin))
                        1048576.0)))
      (if (> taille-mo metal-securite-taille-max-mo)
          (progn
            (message "⚠️ Fichier trop gros (%.1f Mo) pour la corbeille interne : %s"
                     taille-mo (file-name-nondirectory chemin))
            nil)
        (let* ((nom (file-name-nondirectory chemin))
               (destination (expand-file-name
                             (format "%s_%s" (metal-securite--horodatage) nom)
                             metal-securite-dossier-corbeille)))
          (condition-case err
              (progn
                (copy-file chemin destination)
                (metal-securite--ecrire-meta destination chemin)
                (message "🗑️ Copie de sécurité : %s" (file-name-nondirectory destination))
                destination)
            (error
             (message "❌ Erreur copie de sécurité : %s" (error-message-string err))
             nil)))))))

(defun metal-securite--taille-dossier-mo (chemin)
  "Retourner la taille approximative de CHEMIN en Mo (pur Elisp, pas de shell)."
  (let ((total 0))
    (dolist (f (directory-files-recursively chemin "." t))
      (let ((attrs (file-attributes f)))
        (when (and attrs (not (eq t (file-attribute-type attrs))))
          (cl-incf total (or (file-attribute-size attrs) 0)))))
    (/ total 1048576.0)))

(defun metal-securite--copier-dossier-vers-corbeille (chemin)
  "Copier le dossier CHEMIN en entier dans la corbeille interne.
Crée aussi un fichier .meta avec le chemin d'origine.
Retourne le chemin de la copie."
  (when (and chemin
             (file-directory-p chemin)
             (not (metal-securite--fichier-a-ignorer-p chemin)))
    (let* ((taille-mo (metal-securite--taille-dossier-mo chemin))
           (nom (file-name-nondirectory (directory-file-name chemin)))
           (destination (expand-file-name
                         (format "%s_%s" (metal-securite--horodatage) nom)
                         metal-securite-dossier-corbeille)))
      (if (> taille-mo metal-securite-taille-max-dossier-mo)
          (progn
            (message "⚠️ Dossier trop gros (%.1f Mo) pour la corbeille interne : %s"
                     taille-mo nom)
            nil)
        (condition-case err
            (progn
              (copy-directory chemin destination t t t)
              (metal-securite--ecrire-meta destination chemin)
              (message "🗑️ Copie de sécurité (dossier) : %s" nom)
              destination)
          (error
           (message "❌ Erreur copie de sécurité dossier : %s" (error-message-string err))
           nil))))))

;; ============================================================================
;; Interception des suppressions Treemacs uniquement
;; ============================================================================

(defun metal-securite--avant-suppression-treemacs (&rest _args)
  "Advice exécuté avant une suppression dans Treemacs.
Copie le fichier ou dossier sélectionné dans la corbeille interne.
Ne s'active que si la commande est appelée interactivement par
l'utilisateur (pas par un timer, hook, ou code automatique)."
  (condition-case nil
      (when (and (not metal-securite-inhiber)
                 (called-interactively-p 'interactive))
        (let* ((node (treemacs-current-button))
               (chemin (when node (treemacs-safe-button-get node :path))))
          (when chemin
            (if (file-directory-p chemin)
                (metal-securite--copier-dossier-vers-corbeille chemin)
              (metal-securite--copier-vers-corbeille chemin)))))
    (error nil)))

(with-eval-after-load 'treemacs
  (when (fboundp 'treemacs-delete-file)
    (advice-add 'treemacs-delete-file :before
                #'metal-securite--avant-suppression-treemacs))
  (when (fboundp 'treemacs-delete)
    (advice-add 'treemacs-delete :before
                #'metal-securite--avant-suppression-treemacs))
  (setq delete-by-moving-to-trash t)
  (when (boundp 'treemacs-confirm-delete)
    (setq treemacs-confirm-delete t)))

;; ============================================================================
;; Utilitaires de la corbeille
;; ============================================================================

(defun metal-securite--lister-fichiers-corbeille ()
  "Retourner la liste des fichiers et dossiers dans la corbeille interne, triés par date.
Les fichiers .meta sont exclus de la liste."
  (when (file-exists-p metal-securite-dossier-corbeille)
    (let ((entrees (directory-files metal-securite-dossier-corbeille t "^[^.]")))
      ;; Exclure les fichiers .meta
      (setq entrees (cl-remove-if
                     (lambda (f) (string-match-p "\\.meta$" f))
                     entrees))
      (sort entrees
            (lambda (a b)
              (time-less-p
               (file-attribute-modification-time (file-attributes b))
               (file-attribute-modification-time (file-attributes a))))))))

(defun metal-securite--extraire-nom-original (nom-brut)
  "Extraire le nom original depuis NOM-BRUT (sans le préfixe horodatage)."
  (if (string-match "^[0-9]\\{8\\}-[0-9]\\{6\\}_\\(.*\\)" nom-brut)
      (match-string 1 nom-brut)
    nom-brut))

(defun metal-securite--extraire-date-lisible (nom-brut)
  "Extraire une date lisible depuis le préfixe horodatage de NOM-BRUT."
  (if (string-match "^\\([0-9]\\{8\\}\\)-\\([0-9]\\{6\\}\\)_" nom-brut)
      (let ((d (match-string 1 nom-brut))
            (h (match-string 2 nom-brut)))
        (format "%s-%s-%s %s:%s:%s"
                (substring d 0 4) (substring d 4 6) (substring d 6 8)
                (substring h 0 2) (substring h 2 4) (substring h 4 6)))
    ""))

(defun metal-securite--formater-taille (taille)
  "Formater TAILLE (en octets) en chaîne lisible."
  (cond
   ((> taille 1048576)
    (format "%.1f Mo" (/ taille 1048576.0)))
   ((> taille 1024)
    (format "%.1f Ko" (/ taille 1024.0)))
   (t (format "%d o" (truncate taille)))))

(defun metal-securite--raccourcir-chemin (chemin)
  "Raccourcir CHEMIN en remplaçant le home par ~."
  (if chemin
      (abbreviate-file-name chemin)
    ""))

;; ============================================================================
;; Sélecteur de dossier graphique (multiplateforme)
;; ============================================================================

(defun metal-securite--choisir-dossier (titre dossier-initial)
  "Ouvrir un dialogue graphique pour choisir un dossier.
TITRE est le titre du dialogue, DOSSIER-INITIAL le point de départ.
Sur macOS, utilise un NSSavePanel (avec bouton Nouveau dossier).
Sur les autres plateformes, utilise le dialogue natif."
  (cond
   ;; macOS : ns-read-file-name en mode Save → NSSavePanel avec « Nouveau dossier »
   ((and (eq system-type 'darwin)
         (fboundp 'ns-read-file-name))
    (let* ((dir (file-name-as-directory dossier-initial))
           ;; Pré-remplir avec un nom indicatif pour que Save soit cliquable
           (choix (ns-read-file-name titre dir nil "choisir-ce-dossier" nil)))
      (when (and choix (not (string-empty-p choix)))
        ;; On prend le dossier parent (le nom de fichier est ignoré)
        (file-name-directory choix))))
   ;; Windows / Linux : dialogue natif via read-directory-name
   (t
    (let ((last-nonmenu-event nil)
          (use-dialog-box t)
          (use-file-dialog t))
      (read-directory-name (format "%s : " titre) dossier-initial nil nil)))))

;; ============================================================================
;; Restauration commune (avec chemin d'origine)
;; ============================================================================

(defun metal-securite--restaurer-depuis-corbeille (source)
  "Restaurer SOURCE depuis la corbeille vers son emplacement d'origine.
Propose deux options : restaurer à l'emplacement d'origine, ou choisir
un autre dossier de destination.
Retourne t si la restauration a réussi, nil sinon."
  (let* ((nom-brut (file-name-nondirectory (directory-file-name source)))
         (est-dossier (file-directory-p source))
         (nom-original (metal-securite--extraire-nom-original nom-brut))
         (chemin-origine (metal-securite--lire-meta source))
         (origine-court (when chemin-origine
                          (abbreviate-file-name chemin-origine)))
         ;; Construire les choix
         (choix-origine (if origine-court
                            (format "↩ Emplacement d'origine : %s" origine-court)
                          nil))
         (choix-autre   "📂 Choisir un autre emplacement…")
         (options (if choix-origine
                     (list choix-origine choix-autre)
                   (list choix-autre)))
         ;; Demander à l'utilisateur
         (selection (if (and choix-origine (= (length options) 2))
                        (completing-read
                         (format "Restaurer « %s » : " nom-original)
                         options nil t nil nil choix-origine)
                      choix-autre))
         ;; Déterminer la destination
         (destination
          (cond
           ;; Choix : emplacement d'origine
           ((and choix-origine (string= selection choix-origine))
            (expand-file-name chemin-origine))
           ;; Choix : autre emplacement → dialogue graphique natif
           (t
            (let* ((dir-depart (if chemin-origine
                                   (file-name-directory chemin-origine)
                                 default-directory))
                   (dossier (metal-securite--choisir-dossier
                             (format "Destination pour « %s »" nom-original)
                             dir-depart)))
              (when (and dossier (not (string-empty-p dossier)))
                ;; Créer le dossier s'il n'existe pas
                (unless (file-exists-p dossier)
                  (make-directory dossier t)
                  (message "📁 Dossier créé : %s" (abbreviate-file-name dossier)))
                (expand-file-name nom-original dossier)))))))
    (when destination
      (if (and (file-exists-p destination)
               (not (y-or-n-p (format "« %s » existe déjà. Écraser ? "
                                      (file-name-nondirectory
                                       (directory-file-name destination))))))
          (progn (message "Restauration annulée.") nil)
        (condition-case err
            (let ((metal-securite-inhiber t))
              ;; Créer le répertoire parent si nécessaire
              (let ((dir-parent (file-name-directory destination)))
                (unless (file-exists-p dir-parent)
                  (make-directory dir-parent t)))
              (if est-dossier
                  (progn
                    (when (file-exists-p destination)
                      (delete-directory destination t))
                    (copy-directory source destination t t t))
                (copy-file source destination t))
              ;; Supprimer de la corbeille après restauration réussie
              (metal-securite--supprimer-meta source)
              (if est-dossier
                  (delete-directory source t)
                (delete-file source))
              (message "✅ Restauré : %s" (abbreviate-file-name destination))
              t)
          (error
           (message "❌ Erreur de restauration : %s"
                    (error-message-string err))
           nil))))))

;; ============================================================================
;; Suppression commune (avec .meta)
;; ============================================================================

(defun metal-securite--supprimer-element-corbeille (chemin)
  "Supprimer définitivement CHEMIN de la corbeille (et son .meta)."
  (let ((metal-securite-inhiber t))
    (metal-securite--supprimer-meta chemin)
    (if (file-directory-p chemin)
        (delete-directory chemin t)
      (delete-file chemin))))

;; ============================================================================
;; Mode majeur pour le buffer corbeille
;; ============================================================================

(defvar metal-corbeille-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "R")   #'metal-corbeille-restaurer-element)
    (define-key map (kbd "RET") #'metal-corbeille-previsualiser)
    (define-key map (kbd "D")   #'metal-corbeille-supprimer-element)
    (define-key map (kbd "V")   #'metal-corbeille-vider-tout)
    (define-key map (kbd "r")   #'metal-corbeille-rafraichir)
    (define-key map (kbd "s")   #'metal-corbeille-changer-tri)
    (define-key map (kbd "q")   #'metal-corbeille-quitter)
    (define-key map (kbd "n")   #'metal-corbeille-ligne-suivante)
    (define-key map (kbd "p")   #'metal-corbeille-ligne-precedente)
    (define-key map (kbd "?")   #'metal-corbeille-aide)
    map)
  "Keymap pour le mode corbeille MetalEmacs.")

(define-derived-mode metal-corbeille-mode special-mode "Corbeille"
  "Mode majeur pour le buffer interactif de la corbeille MetalEmacs.

Raccourcis clavier :
\\{metal-corbeille-mode-map}"
  :group 'metal-securite
  (setq buffer-read-only t)
  (metal-corbeille--sans-enroulement)
  (metal-corbeille--activer-presentation)
  (when (fboundp 'hl-line-mode)
    (hl-line-mode 1)))

(defun metal-corbeille--sans-enroulement ()
  "Couper l'enroulement des lignes dans le tampon de la corbeille.
Le `global-visual-line-mode' de MetalEmacs l'emporte sinon sur
`truncate-lines' et casse l'alignement des colonnes."
  (setq-local truncate-lines t)
  (setq-local truncate-partial-width-windows nil)
  (setq-local word-wrap nil)
  (when (bound-and-true-p visual-line-mode)
    (visual-line-mode -1)))

;; ============================================================================
;; Propriétés textuelles et navigation
;; ============================================================================

(defun metal-corbeille--prop-sur-ligne (prop)
  "Retourner la valeur de PROP sur la ligne courante.
Scanne les premières positions de la ligne pour trouver la propriété."
  (let ((debut (line-beginning-position))
        (fin (min (+ (line-beginning-position) 10) (line-end-position))))
    (cl-loop for pos from debut below fin
             for val = (get-text-property pos prop)
             when val return val)))

(defun metal-corbeille--chemin-a-la-ligne ()
  "Retourner le chemin de l'élément à la ligne courante, ou nil."
  (metal-corbeille--prop-sur-ligne 'metal-corbeille-chemin))

(defun metal-corbeille--nom-a-la-ligne ()
  "Retourner le nom original de l'élément à la ligne courante, ou nil."
  (metal-corbeille--prop-sur-ligne 'metal-corbeille-nom))

(defun metal-corbeille--aller-premiere-entree ()
  "Placer le curseur sur la première entrée de la corbeille."
  (goto-char (point-min))
  (while (and (not (eobp))
              (not (metal-corbeille--chemin-a-la-ligne)))
    (forward-line 1)))

(defun metal-corbeille-ligne-suivante ()
  "Descendre à la prochaine entrée de la corbeille."
  (interactive)
  (let ((depart (line-beginning-position)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (metal-corbeille--chemin-a-la-ligne)))
      (forward-line 1))
    (when (and (eobp) (not (metal-corbeille--chemin-a-la-ligne)))
      (goto-char depart))))

(defun metal-corbeille-ligne-precedente ()
  "Monter à l'entrée précédente de la corbeille."
  (interactive)
  (let ((depart (line-beginning-position)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (metal-corbeille--chemin-a-la-ligne)))
      (forward-line -1))
    (when (not (metal-corbeille--chemin-a-la-ligne))
      (goto-char depart))))

;; ============================================================================
;; Affichage du buffer corbeille
;; ============================================================================

;; ---------------------------------------------------------------------------
;; Présentation en liste, à la manière du Finder
;; ---------------------------------------------------------------------------

(defconst metal-corbeille--mois-abreges
  ["janv." "févr." "mars" "avr." "mai" "juin" "juil."
   "août" "sept." "oct." "nov." "déc."]
  "Mois abrégés, indépendants de la locale du système.")

(defconst metal-corbeille--types
  ;; extensions                         icône   libellé du type
  '((("png")                             "🖼️" "Image PNG")
    (("jpg" "jpeg")                      "🖼️" "Image JPEG")
    (("gif" "webp" "heic")               "🖼️" "Image")
    (("svg")                             "🖼️" "Image SVG")
    (("pdf")                             "📕" "Document PDF")
    (("org")                             "📝" "Document Org")
    (("qmd")                             "📝" "Document Quarto")
    (("md")                              "📝" "Document Markdown")
    (("txt")                             "📝" "Texte")
    (("tex" "sty" "cls")                 "📜" "Document LaTeX")
    (("bib")                             "📜" "Bibliographie")
    (("pl" "pro")                        "🦉" "Programme Prolog")
    (("py")                              "🐍" "Script Python")
    (("ipynb")                           "🐍" "Carnet Jupyter")
    (("pptx" "ppt" "key")                "📊" "Présentation")
    (("xlsx" "xls")                      "📈" "Classeur")
    (("csv" "tsv")                       "📈" "Données CSV")
    (("docx" "doc")                      "📘" "Document Word")
    (("el")                              "⚙️" "Lisp Emacs")
    (("zip" "gz" "tar" "7z")             "📦" "Archive"))
  "Icône et libellé de type pour chaque famille d'extensions.")

(defvar-local metal-corbeille--entrees-cache nil
  "Entrées de la corbeille lues au dernier rafraîchissement.")

(defvar-local metal-corbeille--tri '(:date . t)
  "Clé de tri (:nom, :date, :taille, :type ou :origine) et ordre décroissant.")

(defvar-local metal-corbeille--largeur nil
  "Largeur de fenêtre utilisée au dernier rendu.")

(defun metal-corbeille--sombre-p ()
  "Non nil si le thème courant est sombre."
  (if (fboundp 'metal-apparence-sombre-p)
      (metal-apparence-sombre-p)
    (eq (frame-parameter nil 'background-mode) 'dark)))

(defun metal-corbeille--couleur (role)
  "Couleur de ROLE, accordée au thème clair ou sombre du tableau de bord."
  (let ((s (metal-corbeille--sombre-p)))
    (pcase role
      ('accent  (if s "#8AA8FF" "#2C55C9"))
      ('danger  (if s "#F07F7F" "#A42525"))
      ('bande   (if s "#23262C" "#F4F5F7"))
      ('bouton  (if s "#2B303A" "#ECEDF0"))
      ('filet   (if s "#3A3F48" "#D5D9DF")))))

(defun metal-corbeille--mono ()
  "Famille de la police à chasse fixe par défaut (pour les tailles)."
  (face-attribute 'default :family nil t))

(defun metal-corbeille--type (nom est-dossier)
  "Retourner (ICÔNE . LIBELLÉ) pour l'élément NOM."
  (if est-dossier
      (cons "📁" "Dossier")
    (let* ((ext (downcase (or (file-name-extension nom) "")))
           (e (cl-find-if (lambda (e) (member ext (car e)))
                          metal-corbeille--types)))
      (if e
          (cons (nth 1 e) (nth 2 e))
        (cons "📄" (if (string-empty-p ext)
                      "Document"
                    (format "Fichier %s" (upcase ext))))))))

(defun metal-corbeille--heure-suppression (nom-brut)
  "Moment de la suppression, lu dans le préfixe horodaté de NOM-BRUT."
  (when (string-match (concat "^\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)"
                              "-\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)_")
                      nom-brut)
    (let ((n (lambda (i) (string-to-number (match-string i nom-brut)))))
      (encode-time (list (funcall n 6) (funcall n 5) (funcall n 4)
                         (funcall n 3) (funcall n 2) (funcall n 1)
                         nil -1 nil)))))

(defun metal-corbeille--date (temps)
  "TEMPS à la manière du Finder : « aujourd'hui à 20:26 », « 16 oct. 2026 à 16:41 »."
  (if (null temps)
      "—"
    (let ((ecart (- (time-to-days (current-time)) (time-to-days temps)))
          (heure (format-time-string "%H:%M" temps))
          (d (decode-time temps)))
      (pcase ecart
        (0 (concat "aujourd’hui à " heure))
        (1 (concat "hier à " heure))
        (_ (format "%d %s %d à %s"
                   (decoded-time-day d)
                   (aref metal-corbeille--mois-abreges (1- (decoded-time-month d)))
                   (decoded-time-year d)
                   heure))))))

(defun metal-corbeille--taille (octets est-dossier)
  "Taille lisible, à la manière du Finder (« -- » pour un dossier vide)."
  (cond
   ((and est-dossier (< octets 1)) "--")
   ((< octets 1000) (format "%d octet%s" octets (if (> octets 1) "s" "")))
   ((< octets 1000000) (format "%d ko" (round octets 1000)))
   ((< octets 1000000000) (format "%.1f Mo" (/ octets 1e6)))
   (t (format "%.1f Go" (/ octets 1e9)))))

(defun metal-corbeille--lire-entrees ()
  "Lire la corbeille et décrire chaque élément sous forme de pliste."
  (mapcar
   (lambda (f)
     (let* ((est-dossier (file-directory-p f))
            (nom-brut (file-name-nondirectory (directory-file-name f)))
            (nom (metal-securite--extraire-nom-original nom-brut))
            (origine (metal-securite--lire-meta f))
            (type (metal-corbeille--type nom est-dossier)))
       (list :chemin f
             :dossier est-dossier
             :nom nom
             :temps (or (metal-corbeille--heure-suppression nom-brut)
                        (file-attribute-modification-time (file-attributes f)))
             :taille (round
                      (if est-dossier
                          (* (metal-securite--taille-dossier-mo f) 1048576.0)
                        (or (file-attribute-size (file-attributes f)) 0)))
             :icone (car type)
             :type (cdr type)
             :origine (and origine
                           (abbreviate-file-name
                            (directory-file-name (file-name-directory origine)))))))
   (metal-securite--lister-fichiers-corbeille)))

(defun metal-corbeille--trier (entrees)
  "Trier ENTREES selon `metal-corbeille--tri'."
  (let* ((cle (car metal-corbeille--tri))
         (desc (cdr metal-corbeille--tri))
         (avant
          (pcase cle
            (:date (lambda (a b) (time-less-p (plist-get a :temps)
                                              (plist-get b :temps))))
            (:taille (lambda (a b) (< (plist-get a :taille)
                                      (plist-get b :taille))))
            (_ (lambda (a b) (string-collate-lessp
                              (or (plist-get a cle) "") (or (plist-get b cle) "")
                              nil t))))))
    (sort (copy-sequence entrees)
          (if desc (lambda (a b) (funcall avant b a)) avant))))

(defun metal-corbeille--tronquer-debut (texte largeur)
  "Raccourcir le chemin TEXTE par le début pour qu'il tienne en LARGEUR colonnes.
On retire des dossiers entiers à gauche (« …/Cours 08 ») : c'est la fin
du chemin, le dossier lui-même, qui est utile.  Si le dernier dossier
seul est trop long, il est coupé par la fin."
  (if (<= (string-width texte) largeur)
      texte
    (let* ((parties (reverse (split-string texte "/" t)))
           (garde (list (car parties))))
      ;; Ajouter des dossiers depuis la fin, tant qu'ils tiennent
      (cl-loop for p in (cdr parties)
               while (<= (+ (string-width (string-join (cons p garde) "/")) 2)
                         largeur)
               do (push p garde))
      (let ((res (concat "…/" (string-join garde "/"))))
        (if (<= (string-width res) largeur)
            res
          (truncate-string-to-width res largeur nil nil "…"))))))

(defun metal-corbeille--a (colonne)
  "Espace qui aligne le texte suivant sur COLONNE (spécification :align-to)."
  (propertize " " 'display `(space :align-to ,colonne)))

(defun metal-corbeille--colonnes ()
  "Positions des colonnes : nom, origine, date, fin de la taille, type."
  (let* ((l (max 60 (window-width)))
         (droite 58)                     ; date + taille + type, ancrés à droite
         (libre (- l droite 6))
         (c-origine (+ 6 (max 18 (round (* libre 0.55))))))
    (list :nom 6
          :larg-nom (- c-origine 6 2)
          :origine c-origine
          :larg-origine (max 8 (- l droite c-origine 2))
          :date '(- right 56)
          :taille '(- right 24)
          :larg-taille 10
          :type '(- right 21))))

(defun metal-corbeille-trier-par (cle)
  "Trier la corbeille selon CLE ; un second appel inverse l'ordre."
  (setq metal-corbeille--tri
        (if (eq (car metal-corbeille--tri) cle)
            (cons cle (not (cdr metal-corbeille--tri)))
          (cons cle (memq cle '(:date :taille)))))
  (metal-corbeille--redessiner))

(defun metal-corbeille-changer-tri ()
  "Passer à la clé de tri suivante (nom, date, taille, type)."
  (interactive)
  (let* ((cles '(:nom :date :taille :type :origine))
         (suiv (or (cadr (memq (car metal-corbeille--tri) cles)) (car cles))))
    (metal-corbeille-trier-par suiv)
    (message "Tri par %s" (substring (symbol-name suiv) 1))))

(defun metal-corbeille--titre-colonne (libelle cle)
  "Titre de colonne cliquable LIBELLE, qui trie selon CLE."
  (let* ((actif (eq (car metal-corbeille--tri) cle))
         (map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda () (interactive) (metal-corbeille-trier-par cle)))
    (propertize (concat libelle
                        (if actif (if (cdr metal-corbeille--tri) "  ▾" "  ▴") ""))
                'face (if actif '(:weight bold) 'shadow)
                'mouse-face 'highlight
                'help-echo (format "Trier par %s" (downcase libelle))
                'local-map map)))

(defun metal-corbeille--en-tete ()
  "Ligne d'en-tête : titres des colonnes, cliquables pour trier."
  (let ((c (metal-corbeille--colonnes)))
    (concat
     (metal-corbeille--a (plist-get c :nom))
     (metal-corbeille--titre-colonne "Nom" :nom)
     (metal-corbeille--a (plist-get c :origine))
     (metal-corbeille--titre-colonne "Emplacement d’origine" :origine)
     (metal-corbeille--a (plist-get c :date))
     (metal-corbeille--titre-colonne "Date de suppression" :date)
     (metal-corbeille--a '(- right 30))
     (metal-corbeille--titre-colonne "Taille" :taille)
     (metal-corbeille--a (plist-get c :type))
     (metal-corbeille--titre-colonne "Type" :type))))

(defun metal-corbeille--bouton (libelle action aide &optional danger)
  "Bouton cliquable LIBELLE qui appelle ACTION."
  (let ((map (make-sparse-keymap))
        (fond (metal-corbeille--couleur 'bouton)))
    (define-key map [mouse-1] action)
    (define-key map (kbd "RET") action)
    (propertize (concat " " libelle " ")
                'face `(:background ,fond
                        :foreground ,(if danger (metal-corbeille--couleur 'danger)
                                       (face-foreground 'default nil t))
                        :height 0.9
                        :box (:line-width (8 . 3) :color ,fond))
                'mouse-face 'highlight
                'help-echo aide
                'keymap map)))

(defun metal-corbeille--touche (touche libelle)
  "Rappel de raccourci : TOUCHE en encadré, puis LIBELLE."
  (concat
   (propertize (concat " " touche " ")
               'face `(:family ,(metal-corbeille--mono) :height 0.8 :inherit shadow
                       :box (:line-width 1 :color ,(metal-corbeille--couleur 'filet))))
   " "
   (propertize libelle 'face '(:inherit shadow :height 0.92))))

(defun metal-corbeille--inserer-contenu (&optional relire)
  "Dessiner la corbeille dans le tampon courant.
Avec RELIRE non nil (ou au premier rendu), relire le dossier de la corbeille."
  (metal-corbeille--sans-enroulement)
  (when (or relire (null metal-corbeille--entrees-cache))
    (setq metal-corbeille--entrees-cache (metal-corbeille--lire-entrees)))
  (setq metal-corbeille--largeur (window-width))
  (let* ((inhibit-read-only t)
         (entrees (metal-corbeille--trier metal-corbeille--entrees-cache))
         (total (apply #'+ 0 (mapcar (lambda (e) (plist-get e :taille)) entrees)))
         (c (metal-corbeille--colonnes))
         (mono (metal-corbeille--mono))
         (impaire nil))
    (erase-buffer)

    ;; ── Barre de titre ─────────────────────────────────────────────
    (insert "\n   "
            (propertize "Corbeille" 'face '(:height 1.25 :weight bold))
            (propertize
             (if entrees
                 (format "    %d élément%s  ·  %s"
                         (length entrees) (if (> (length entrees) 1) "s" "")
                         (metal-corbeille--taille total nil))
               "    vide")
             'face '(:inherit shadow :height 0.92))
            (metal-corbeille--a '(- right 12))
            (if entrees
                (metal-corbeille--bouton "Vider" #'metal-corbeille-vider-tout
                                         "Supprimer définitivement tout le contenu"
                                         t)
              "")
            "\n\n")

    ;; ── Rappel des touches, sous le titre ─────────────────────────
    (when entrees
      (insert "   "
              (mapconcat (lambda (k) (metal-corbeille--touche (car k) (cdr k)))
                         '(("R" . "restaurer") ("RET" . "aperçu")
                           ("D" . "supprimer") ("V" . "vider")
                           ("s" . "trier") ("r" . "rafraîchir") ("?" . "aide"))
                         "    ")
              "\n\n"))

    (if (null entrees)
        (insert (propertize "\n\n      La corbeille est vide.\n"
                            'face 'shadow))
      ;; ── Lignes ───────────────────────────────────────────────────
      (dolist (e entrees)
        (let* ((debut (point))
               (nom (plist-get e :nom))
               (origine (plist-get e :origine))
               (taille (metal-corbeille--taille (plist-get e :taille)
                                                (plist-get e :dossier))))
          (insert
           (metal-corbeille--a 2)
           (if (fboundp 'metal-icone)
               (metal-icone (plist-get e :icone))
             (plist-get e :icone))
           (metal-corbeille--a (plist-get c :nom))
           (propertize (truncate-string-to-width nom (plist-get c :larg-nom)
                                                 nil nil "…")
                       'face (and (plist-get e :dossier) '(:weight semi-bold)))
           (metal-corbeille--a (plist-get c :origine))
           (propertize (metal-corbeille--tronquer-debut (or origine "—")
                                                        (plist-get c :larg-origine))
                       'face 'shadow)
           (metal-corbeille--a (plist-get c :date))
           (propertize (metal-corbeille--date (plist-get e :temps)) 'face 'shadow)
           ;; Taille alignée à droite, en chasse fixe
           (let ((tx (propertize taille 'face `(:inherit shadow :family ,mono
                                                         :height 0.85))))
             (concat (metal-corbeille--a
                      (if (and (fboundp 'string-pixel-width) (display-graphic-p))
                          `(- right 24 (,(string-pixel-width tx)))
                        `(- right ,(+ 24 (string-width taille)))))
                     tx))
           (metal-corbeille--a (plist-get c :type))
           (propertize (plist-get e :type) 'face 'shadow)
           "\n")
          (add-text-properties
           debut (point)
           (list 'metal-corbeille-chemin (plist-get e :chemin)
                 'metal-corbeille-nom nom
                 'help-echo (if origine
                                (format "%s\nOrigine : %s" nom origine)
                              nom)))
          ;; Bandes alternées, comme dans le Finder
          (when impaire
            (add-face-text-property
             debut (point)
             `(:background ,(metal-corbeille--couleur 'bande) :extend t)
             t))
          (setq impaire (not impaire))))

      (insert "\n"))))

(defun metal-corbeille--redessiner ()
  "Redessiner sans relire le disque, en gardant l'élément courant."
  (let ((chemin (metal-corbeille--chemin-a-la-ligne)))
    (metal-corbeille--inserer-contenu)
    (metal-corbeille--aller-a chemin)))

(defun metal-corbeille--aller-a (chemin)
  "Placer le curseur sur la ligne de CHEMIN, ou sur la première entrée."
  (goto-char (point-min))
  (let ((trouve nil))
    (when chemin
      (while (and (not trouve) (not (eobp)))
        (if (equal (metal-corbeille--chemin-a-la-ligne) chemin)
            (setq trouve t)
          (forward-line 1))))
    (unless trouve
      (metal-corbeille--aller-premiere-entree))))

(defun metal-corbeille--taille-fenetre (fenetre)
  "Redessiner si la largeur de FENETRE a changé."
  (let ((buf (window-buffer fenetre)))
    (with-current-buffer buf
      (when (and (derived-mode-p 'metal-corbeille-mode)
                 (not (eql (window-width fenetre) metal-corbeille--largeur)))
        (with-selected-window fenetre
          (metal-corbeille--redessiner))))))

(defun metal-corbeille--activer-presentation ()
  "Police, interligne et ligne d'en-tête de la corbeille."
  (setq-local line-spacing (if (boundp 'metal-dashboard-interligne)
                               metal-dashboard-interligne
                             0.3))
  (setq-local buffer-face-mode-face 'variable-pitch)
  (buffer-face-mode 1)
  (setq-local header-line-format '(:eval (metal-corbeille--en-tete)))
  (face-remap-add-relative 'header-line
                           `(:inherit variable-pitch :weight normal
                             :background ,(face-background 'default nil t)
                             :box nil
                             :underline (:color ,(metal-corbeille--couleur 'filet)
                                         :position t)))
  (add-hook 'window-size-change-functions #'metal-corbeille--taille-fenetre nil t))

;; Thème choisi au tableau de bord : redessiner la corbeille si elle est ouverte.
(add-hook 'metal-apparence-apres-changement-hook
          (lambda ()
            (let ((b (get-buffer metal-securite-nom-buffer)))
              (when (buffer-live-p b)
                (with-current-buffer b
                  (ignore-errors (metal-corbeille--redessiner)))))))

(defun metal-corbeille ()
  "Afficher le contenu de la corbeille interne MetalEmacs dans un buffer interactif."
  (interactive)
  (let ((buf (get-buffer-create metal-securite-nom-buffer)))
    (with-current-buffer buf
      (metal-corbeille-mode)
      (when (fboundp 'tab-line-mode)
        (setq-local tab-line-exclude nil)
        (tab-line-mode 1)))
    ;; Ouvrir dans la fenêtre principale (pas Treemacs), puis dessiner :
    ;; les colonnes dépendent de la largeur de cette fenêtre.
    (let ((fenetre (or (get-mru-window nil nil t)
                       (selected-window))))
      (select-window fenetre)
      (switch-to-buffer buf)
      (metal-corbeille--inserer-contenu t)
      (metal-corbeille--aller-premiere-entree))))

(defun metal-corbeille-rafraichir (&optional silencieux)
  "Rafraîchir le buffer de la corbeille.
Avec SILENCIEUX non nil, ne rien afficher dans la zone d'écho (pour
laisser visible le message de l'action qui vient d'avoir lieu)."
  (interactive)
  (when (string= (buffer-name) metal-securite-nom-buffer)
    (let ((ligne (line-number-at-pos)))
      (metal-corbeille--inserer-contenu t)
      (goto-char (point-min))
      (forward-line (1- ligne))
      (unless (metal-corbeille--chemin-a-la-ligne)
        (metal-corbeille--aller-premiere-entree))
      (unless silencieux
        (message "Corbeille rafraîchie.")))))

(defun metal-corbeille-quitter ()
  "Fermer le buffer de la corbeille."
  (interactive)
  (quit-window t))

;; ============================================================================
;; Actions interactives dans le buffer corbeille
;; ============================================================================

(defun metal-corbeille-restaurer-element ()
  "Restaurer l'élément sous le curseur vers son emplacement d'origine."
  (interactive)
  (let ((chemin (metal-corbeille--chemin-a-la-ligne)))
    (if (not chemin)
        (message "Placez le curseur sur un élément de la corbeille.")
      (when (metal-securite--restaurer-depuis-corbeille chemin)
        (metal-corbeille-rafraichir t)))))

(defun metal-corbeille-previsualiser ()
  "Prévisualiser le fichier sous le curseur (lecture seule).
Pour un dossier, ouvre dired."
  (interactive)
  (let ((chemin (metal-corbeille--chemin-a-la-ligne)))
    (if (not chemin)
        (message "Placez le curseur sur un élément de la corbeille.")
      (if (file-directory-p chemin)
          (dired chemin)
        (let ((buf (find-file-noselect chemin t)))
          (with-current-buffer buf
            (read-only-mode 1))
          (display-buffer buf '(display-buffer-pop-up-window)))))))

(defun metal-corbeille-supprimer-element ()
  "Supprimer définitivement l'élément sous le curseur."
  (interactive)
  (let ((chemin (metal-corbeille--chemin-a-la-ligne)))
    (if (not chemin)
        (message "Placez le curseur sur un élément de la corbeille.")
      (let ((nom-original (metal-corbeille--nom-a-la-ligne)))
        (if (not (y-or-n-p (format "Supprimer définitivement « %s » ? "
                                   nom-original)))
            ;; Effacer la question restée dans la zone d'écho
            (message "Suppression annulée.")
          (metal-securite--supprimer-element-corbeille chemin)
          (metal-corbeille-rafraichir t)
          (message "🗑️ Supprimé définitivement : %s" nom-original))))))

(defun metal-corbeille-vider-tout ()
  "Vider complètement la corbeille depuis le buffer interactif."
  (interactive)
  (let ((fichiers (metal-securite--lister-fichiers-corbeille)))
    (if (not fichiers)
        (message "🗑️ La corbeille est déjà vide.")
      (if (not (y-or-n-p (format "Supprimer définitivement les %d éléments de la corbeille ? "
                                 (length fichiers))))
          ;; Effacer la question restée dans la zone d'écho
          (message "Corbeille conservée.")
        (dolist (f fichiers)
          (metal-securite--supprimer-element-corbeille f))
        (metal-corbeille-rafraichir t)
        (message "🗑️ Corbeille vidée : %d éléments supprimés" (length fichiers))))))

;; ============================================================================
;; Aide
;; ============================================================================

(defun metal-corbeille-aide ()
  "Afficher l'aide du buffer corbeille."
  (interactive)
  (message (concat
            "Corbeille MetalEmacs — Raccourcis :\n"
            "  R     Restaurer à l'emplacement d'origine\n"
            "  D     Supprimer définitivement\n"
            "  V     Vider toute la corbeille\n"
            "  r     Rafraîchir\n"
            "  s     Changer le tri (ou cliquer un titre de colonne)\n"
            "  RET   Prévisualiser le fichier\n"
            "  n/p   Naviguer (bas/haut)\n"
            "  q     Fermer")))

;; ============================================================================
;; Commande de restauration via completing-read (conservée)
;; ============================================================================

(defun metal-securite-restaurer ()
  "Restaurer un fichier ou dossier depuis la corbeille interne MetalEmacs.
Version completing-read (alternative au buffer interactif)."
  (interactive)
  (let ((fichiers (metal-securite--lister-fichiers-corbeille)))
    (if (not fichiers)
        (message "🗑️ La corbeille MetalEmacs est vide.")
      (let* ((choix (mapcar
                     (lambda (f)
                       (let* ((nom-brut (file-name-nondirectory (directory-file-name f)))
                              (est-dossier (file-directory-p f))
                              (nom-original (metal-securite--extraire-nom-original nom-brut))
                              (date (metal-securite--extraire-date-lisible nom-brut))
                              (origine (metal-securite--lire-meta f))
                              (origine-str (if origine
                                               (format " → %s"
                                                       (metal-securite--raccourcir-chemin
                                                        (file-name-directory origine)))
                                             ""))
                              (nom-affiche (format "%s%s  ←  %s%s"
                                                   (if est-dossier "📁 " "")
                                                   nom-original date origine-str)))
                         (cons nom-affiche f)))
                     fichiers))
             (selection (completing-read "Restaurer : " choix nil t))
             (source (cdr (assoc selection choix))))
        (when source
          (metal-securite--restaurer-depuis-corbeille source))))))

;; ============================================================================
;; Nettoyage de la corbeille interne
;; ============================================================================

(defun metal-vider-corbeille (&optional jours)
  "Supprimer les éléments de la corbeille plus vieux que JOURS jours.
Par défaut, utilise `metal-securite-jours-retention' (30 jours)."
  (interactive
   (list (when current-prefix-arg
           (read-number "Supprimer les éléments plus vieux que (jours) : "
                        metal-securite-jours-retention))))
  (let* ((max-age (* (or jours metal-securite-jours-retention) 86400))
         (now (float-time))
         (fichiers (metal-securite--lister-fichiers-corbeille))
         (count 0))
    (if (not fichiers)
        (message "🗑️ La corbeille MetalEmacs est déjà vide.")
      (dolist (f fichiers)
        (let ((age (- now (float-time
                          (file-attribute-modification-time
                           (file-attributes f))))))
          (when (> age max-age)
            (metal-securite--supprimer-element-corbeille f)
            (cl-incf count))))
      (if (zerop count)
          (message "🗑️ Aucun élément de plus de %d jours dans la corbeille."
                   (or jours metal-securite-jours-retention))
        (message "🗑️ Corbeille : %d élément(s) supprimé(s)" count)))))

(defun metal-vider-corbeille-tout ()
  "Vider complètement la corbeille interne MetalEmacs."
  (interactive)
  (let ((fichiers (metal-securite--lister-fichiers-corbeille)))
    (if (not fichiers)
        (message "🗑️ La corbeille MetalEmacs est déjà vide.")
      (if (not (y-or-n-p (format "Supprimer définitivement %d élément(s) de la corbeille ? "
                                 (length fichiers))))
          (message "Corbeille conservée.")
        (dolist (f fichiers)
          (metal-securite--supprimer-element-corbeille f))
        (message "🗑️ Corbeille vidée : %d élément(s) supprimés"
                 (length fichiers))))))

;; ============================================================================
;; Nettoyage automatique au démarrage
;; ============================================================================

(defun metal-securite--nettoyage-silencieux ()
  "Nettoyage silencieux de la corbeille au démarrage d'Emacs.
Supprime les éléments de plus de 30 jours (voir `metal-securite-jours-retention')."
  (let ((inhibit-message t))
    (metal-vider-corbeille)))

(run-with-idle-timer 30 nil #'metal-securite--nettoyage-silencieux)

;; ============================================================================
;; Bouton pour le Dashboard
;; ============================================================================

(defun metal-securite--dashboard-bouton ()
  "Retourner un bouton cliquable pour le dashboard MetalEmacs.
Ajouter dans metal-dashboard--header-buttons avec concat."
  (let* ((icon-trash (if (fboundp 'nerd-icons-faicon)
                         (nerd-icons-faicon "nf-fa-trash" :face '(:foreground "#CC3333"))
                       "🗑️"))
         (text-face '(:foreground "#0066cc" :weight bold)))
    (if (fboundp 'metal-dashboard--make-action-button)
        (metal-dashboard--make-action-button
         (concat icon-trash " " (propertize "Corbeille" 'face text-face))
         "Ouvrir la corbeille MetalEmacs"
         (lambda () (interactive)
           (metal-corbeille)))
      "")))

;; ============================================================================
;; Informations
;; ============================================================================

(defun metal-securite-info ()
  "Afficher les informations de configuration du module de sécurité."
  (interactive)
  (let* ((fichiers (metal-securite--lister-fichiers-corbeille))
         (nb (length fichiers))
         (taille (apply #'+ (mapcar (lambda (f)
                                      (or (file-attribute-size
                                           (file-attributes f))
                                          0))
                                    fichiers))))
    (message (concat "🛡️ MetalEmacs Sécurité\n"
                     "   Corbeille : %s (%d fichier(s), %.1f Mo)\n"
                     "   Rétention : %d jours\n"
                     "   Max taille: %d Mo")
             metal-securite-dossier-corbeille nb (/ taille 1048576.0)
             metal-securite-jours-retention
             metal-securite-taille-max-mo)))

;; ============================================================================

(provide 'metal-securite)

;;; metal-securite.el ends here
