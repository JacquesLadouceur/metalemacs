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
      (delete-file meta t))))

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
                (delete-file source t))
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
      (delete-file chemin t))))

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
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (when (fboundp 'hl-line-mode)
    (hl-line-mode 1)))

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

(defun metal-corbeille--inserer-contenu ()
  "Insérer le contenu de la corbeille dans le buffer courant."
  (let ((fichiers (metal-securite--lister-fichiers-corbeille))
        (inhibit-read-only t))
    (erase-buffer)
    ;; En-tête
    (insert (propertize "🗑️ Corbeille MetalEmacs\n"
                        'face '(:height 1.3 :weight bold)))
    (insert (propertize (format "   Dossier : %s\n"
                                metal-securite-dossier-corbeille)
                        'face 'font-lock-comment-face))
    (insert (propertize (format "   Éléments : %d\n"
                                (length fichiers))
                        'face 'font-lock-comment-face))
    ;; Rappel des raccourcis
    (insert "\n")
    (insert (propertize "   Raccourcis : " 'face '(:weight bold)))
    (insert (propertize "R" 'face '(:foreground "#4488cc" :weight bold)))
    (insert (propertize ":restaurer  " 'face 'font-lock-comment-face))
    (insert (propertize "D" 'face '(:foreground "#cc4444" :weight bold)))
    (insert (propertize ":supprimer  " 'face 'font-lock-comment-face))
    (insert (propertize "V" 'face '(:foreground "#cc4444" :weight bold)))
    (insert (propertize ":vider tout  " 'face 'font-lock-comment-face))
    (insert (propertize "r" 'face 'font-lock-comment-face))
    (insert (propertize ":rafraîchir  " 'face 'font-lock-comment-face))
    (insert (propertize "?" 'face 'font-lock-comment-face))
    (insert (propertize ":aide" 'face 'font-lock-comment-face))
    (insert "\n\n")

    (if (not fichiers)
        ;; Corbeille vide
        (insert (propertize "\n   La corbeille est vide. 🎉\n"
                            'face 'font-lock-comment-face))
      ;; En-tête du tableau
      (insert (propertize (format "     %-20s  %-10s  %-30s  %s\n"
                                  "Date" "Taille" "Élément" "Origine")
                          'face '(:weight bold :underline t)))
      ;; Lignes de données
      (dolist (f fichiers)
        (let* ((attrs (file-attributes f))
               (est-dossier (file-directory-p f))
               (nom-brut (file-name-nondirectory (directory-file-name f)))
               (date (metal-securite--extraire-date-lisible nom-brut))
               (taille (if est-dossier
                           (* (metal-securite--taille-dossier-mo f) 1048576.0)
                         (or (file-attribute-size attrs) 0)))
               (taille-str (metal-securite--formater-taille taille))
               (nom-original (metal-securite--extraire-nom-original nom-brut))
               (icone (if est-dossier "📁" "  "))
               (chemin-origine (metal-securite--lire-meta f))
               (origine-str (if chemin-origine
                                (metal-securite--raccourcir-chemin
                                 (file-name-directory chemin-origine))
                              ""))
               (ligne (format "     %-20s  %-10s  %s %-28s%s\n"
                              date taille-str icone nom-original origine-str))
               (debut (point)))
          (insert ligne)
          (put-text-property debut (point) 'metal-corbeille-chemin f)
          (put-text-property debut (point) 'metal-corbeille-nom nom-original)
          ;; Colorer le chemin d'origine en gris
          (when (and chemin-origine (> (length origine-str) 0))
            (save-excursion
              (goto-char debut)
              (when (search-forward origine-str (line-end-position) t)
                (put-text-property (match-beginning 0) (match-end 0)
                                   'face 'font-lock-comment-face)))))))

    ;; Pied de page
    (insert (propertize "\n─────────────────────────────────────────────────────────────────────────────\n"
                        'face 'font-lock-comment-face))))

(defun metal-corbeille ()
  "Afficher le contenu de la corbeille interne MetalEmacs dans un buffer interactif."
  (interactive)
  (let ((buf (get-buffer-create metal-securite-nom-buffer)))
    (with-current-buffer buf
      (metal-corbeille-mode)
      (metal-corbeille--inserer-contenu)
      (metal-corbeille--aller-premiere-entree)
      (when (fboundp 'tab-line-mode)
        (setq-local tab-line-exclude nil)
        (tab-line-mode 1)))
    ;; Ouvrir dans la fenêtre principale (pas Treemacs)
    (let ((fenetre (or (get-mru-window nil nil t)
                       (selected-window))))
      (select-window fenetre)
      (switch-to-buffer buf))))

(defun metal-corbeille-rafraichir ()
  "Rafraîchir le buffer de la corbeille."
  (interactive)
  (when (string= (buffer-name) metal-securite-nom-buffer)
    (let ((ligne (line-number-at-pos)))
      (metal-corbeille--inserer-contenu)
      (goto-char (point-min))
      (forward-line (1- ligne))
      (unless (metal-corbeille--chemin-a-la-ligne)
        (metal-corbeille--aller-premiere-entree))
      (message "Corbeille rafraîchie."))))

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
        (metal-corbeille-rafraichir)))))

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
        (when (y-or-n-p (format "Supprimer définitivement « %s » ? " nom-original))
          (metal-securite--supprimer-element-corbeille chemin)
          (message "🗑️ Supprimé définitivement : %s" nom-original)
          (metal-corbeille-rafraichir))))))

(defun metal-corbeille-vider-tout ()
  "Vider complètement la corbeille depuis le buffer interactif."
  (interactive)
  (let ((fichiers (metal-securite--lister-fichiers-corbeille)))
    (if (not fichiers)
        (message "🗑️ La corbeille est déjà vide.")
      (when (y-or-n-p (format "Supprimer définitivement les %d éléments de la corbeille ? "
                               (length fichiers)))
        (dolist (f fichiers)
          (metal-securite--supprimer-element-corbeille f))
        (message "🗑️ Corbeille vidée : %d éléments supprimés" (length fichiers))
        (metal-corbeille-rafraichir)))))

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
      (when (y-or-n-p (format "Supprimer définitivement %d élément(s) de la corbeille ? "
                               (length fichiers)))
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
