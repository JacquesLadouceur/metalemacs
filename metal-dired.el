;;; metal-dired.el --- Dired dans le style du tableau de bord -*- lexical-binding: t; -*-

;;; Commentaire:
;;
;; Habillage de Dired aux couleurs de MetalEmacs.  Le tampon reste un
;; vrai Dired : toutes ses commandes (m, u, D, R, C, +, g, ^, wdired…)
;; fonctionnent comme avant.  Seul l'affichage change, par-dessus les
;; lignes produites par Dired :
;;
;;   - fil d'Ariane cliquable dans la ligne d'en-tête, avec le nombre de
;;     dossiers, de fichiers et d'éléments marqués ;
;;   - dossiers d'abord (listage `ls-lisp', identique sur macOS, Windows
;;     et Linux — le `ls' de macOS ignore --group-directories-first) ;
;;   - pastille de type aux couleurs du tableau de bord, date relative,
;;     taille lisible, police proportionnelle ;
;;   - « .. » devient « Dossier parent », « . » disparaît ;
;;   - marques visibles : ✓ sur fond bleu, D barré en rouge ;
;;   - rappel des touches principales au bas de la liste.
;;
;; Touches ajoutées :
;;   (  affichage classique (permissions, dates exactes) — natif Dired ;
;;   .  montrer ou cacher les fichiers commençant par un point.
;;
;; Le thème est celui choisi au tableau de bord : les tampons Dired
;; ouverts se redessinent via `metal-apparence-apres-changement-hook'.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dired-x)
(require 'ls-lisp)

(defgroup metal-dired nil
  "Habillage de Dired dans le style du tableau de bord."
  :group 'dired)

(defcustom metal-dired-cacher-points t
  "Si non nil, cacher par défaut les fichiers commençant par un point.
La touche « . » bascule l'affichage dans le tampon courant."
  :type 'boolean
  :group 'metal-dired)

(defcustom metal-dired-compter-elements t
  "Si non nil, afficher le nombre d'éléments de chaque sous-dossier."
  :type 'boolean
  :group 'metal-dired)

(defcustom metal-dired-compter-max 300
  "Nombre maximal de sous-dossiers dont on compte les éléments.
Compter oblige à lire chaque sous-dossier ; au-delà de ce nombre, le
compte est omis pour garder l'ouverture instantanée."
  :type 'integer
  :group 'metal-dired)

;;; ── Listage : ls-lisp partout, dossiers d'abord ────────────────────

(setq ls-lisp-use-insert-directory-program nil
      ls-lisp-dirs-first t
      ls-lisp-ignore-case t
      ls-lisp-use-localized-time-format nil)

;;; ── Couleurs ───────────────────────────────────────────────────────

(defconst metal-dired--types
  ;; type  libellé  encre-clair  fond-clair  encre-sombre  fond-sombre
  '((dos   "DOS" "#A06A00" "#FBEFD3" "#F0C46A" "#3A3220")
    (qmd   "QMD" "#2448B0" "#E3E9F8" "#8AA8FF" "#252E45")
    (py    "PY"  "#7A5A00" "#F6EED6" "#E6C16A" "#36311E")
    (pl    "PL"  "#A63E06" "#FBE7DA" "#F0955E" "#3A2A20")
    (org   "ORG" "#5B33B5" "#ECE5FA" "#B79CF7" "#2F2940")
    (pdf   "PDF" "#A42525" "#F8E1E1" "#F07F7F" "#3A2426")
    (el    "EL"  "#16725C" "#DDF0EA" "#6FCFB5" "#1F3531")
    (dia   "DIA" "#16725C" "#DDF0EA" "#6FCFB5" "#1F3531")
    (autre nil   "#4A5260" "#E9EBEE" "#AEB6C1" "#2A2D33"))
  "Pastilles de type (mêmes teintes que le tableau de bord).")

(defconst metal-dired--extensions
  '(("qmd" . qmd) ("md" . qmd) ("tex" . qmd) ("bib" . qmd)
    ("py" . py) ("ipynb" . py) ("pl" . pl) ("pro" . pl)
    ("org" . org) ("pdf" . pdf) ("el" . el) ("elc" . el)
    ("drawio" . dia))
  "Correspondance extension → type de pastille.")

(defun metal-dired--sombre-p ()
  "Non nil si le thème courant est sombre."
  (cond ((fboundp 'metal-apparence-sombre-p) (metal-apparence-sombre-p))
        (t (eq (frame-parameter nil 'background-mode) 'dark))))

(defun metal-dired--teinte (cle)
  "Couleur d'interface CLE selon le thème."
  (let ((s (metal-dired--sombre-p)))
    (pcase cle
      ('accent       (if s "#8AA8FF" "#2C55C9"))
      ('rouge        (if s "#F07F7F" "#A42525"))
      ('fond-marque  (if s "#252E45" "#E3E9F8"))
      ('fond-suppr   (if s "#3A2426" "#F8E1E1"))
      ('bordure      (if s "#3A3F48" "#C9CED6")))))

(defvar metal-dired--mono nil
  "Famille monospace (lue avant le remappage proportionnel).")

(defun metal-dired--pastille (type &optional libelle)
  "Pastille du TYPE, avec LIBELLE éventuel (3 caractères au plus)."
  (let* ((e (assq type metal-dired--types))
         (s (metal-dired--sombre-p))
         (encre (if s (nth 4 e) (nth 2 e)))
         (fond  (if s (nth 5 e) (nth 3 e)))
         (texte (or libelle (nth 1 e) "—"))
         (n (max 0 (- 3 (string-width texte))))
         (g (/ n 2)))
    (propertize (concat (make-string g ?\s) texte (make-string (- n g) ?\s))
                'face `(:family ,metal-dired--mono :height 0.8 :weight bold
                        :foreground ,encre :background ,fond
                        :box (:line-width (6 . 2) :color ,fond)))))

;;; ── Marques ───────────────────────────────────────────────────────

(defun metal-dired--mots-cles ()
  "Mots-clés font-lock : ✓ pour la marque *, fond de ligne marqué ou à supprimer.
Passent par font-lock (et non par des overlays) parce que Dired change
le caractère de marque sur place, sans relire le listage."
  `(("^\\(\\*\\)\\(.*\n\\)"
     (1 (list 'face '(:foreground ,(metal-dired--teinte 'accent) :weight bold)
              'display "✓")
        t)
     (2 '(:background ,(metal-dired--teinte 'fond-marque) :extend t
          :foreground ,(face-foreground 'default nil t) :weight normal)
        t))
    ("^\\(D\\)\\(.*\n\\)"
     (1 '(:foreground ,(metal-dired--teinte 'rouge) :weight bold) t)
     (2 '(:background ,(metal-dired--teinte 'fond-suppr) :extend t
          :foreground ,(metal-dired--teinte 'rouge) :weight normal)
        t))))

(defvar-local metal-dired--mots-cles-actifs nil
  "Mots-clés font-lock installés dans ce tampon (pour les retirer).")

(defun metal-dired--installer-mots-cles ()
  "(Ré)installer les mots-clés des marques selon le thème courant."
  (when metal-dired--mots-cles-actifs
    (font-lock-remove-keywords nil metal-dired--mots-cles-actifs))
  (setq metal-dired--mots-cles-actifs (metal-dired--mots-cles))
  (font-lock-add-keywords nil metal-dired--mots-cles-actifs 'append)
  (setq-local font-lock-extra-managed-props
              (cl-adjoin 'display font-lock-extra-managed-props))
  (when font-lock-mode (font-lock-flush)))

;;; ── Tailles et dates ───────────────────────────────────────────────

(defun metal-dired--taille (octets)
  "Taille lisible pour OCTETS : 612, 70 k, 1,8 M, 2,3 G."
  (cond ((< octets 1024) (format "%d" octets))
        ((< octets (* 1024 1024)) (format "%d k" (round (/ octets 1024.0))))
        ((< octets (* 1024 1024 1024))
         (subst-char-in-string ?. ?, (format "%.1f M" (/ octets 1048576.0))))
        (t (subst-char-in-string ?. ?, (format "%.1f G" (/ octets 1073741824.0))))))

(defun metal-dired--date (mtime)
  "Date relative de MTIME (fonction du tableau de bord si présente)."
  (if (fboundp 'metal-dashboard--notes-format-date-relative)
      (metal-dashboard--notes-format-date-relative mtime)
    (format-time-string "%Y-%m-%d %H:%M" mtime)))

(defun metal-dired--nb-elements (dossier)
  "Nombre d'éléments visibles (hors fichiers à point) dans DOSSIER, ou nil."
  (ignore-errors
    (length (directory-files dossier nil "\\`[^.]" t))))

;;; ── Décoration des lignes ──────────────────────────────────────────

(defvar-local metal-dired--titre nil
  "Titre d'un Dired « liste de fichiers » (voir `metal-dired-liste'), sinon nil.")

(defvar-local metal-dired--nb-dossiers 0)
(defvar-local metal-dired--nb-fichiers 0)

(defun metal-dired--ov (debut fin &rest props)
  "Créer un overlay metal-dired de DEBUT à FIN avec PROPS."
  (let ((ov (make-overlay debut fin nil t nil)))
    (overlay-put ov 'metal-dired t)
    (overlay-put ov 'evaporate (/= debut fin))
    (while props
      (overlay-put ov (pop props) (pop props)))
    ov))

(defun metal-dired--type-fichier (nom)
  "Retourner (TYPE . LIBELLÉ) de la pastille pour le fichier NOM."
  (let* ((ext (downcase (or (file-name-extension nom) "")))
         (type (or (cdr (assoc ext metal-dired--extensions)) 'autre)))
    (cons type
          (if (eq type 'autre)
              (if (string-empty-p ext) "—"
                (upcase (truncate-string-to-width ext 3)))
            nil))))

(defun metal-dired--decorer ()
  "Habiller toutes les lignes du tampon Dired courant."
  (save-excursion
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'metal-dired t)
      (setq metal-dired--mono (face-attribute 'default :family nil t))
      ;; Affichage classique (touche « ( ») : on laisse Dired tel quel.
      (when (bound-and-true-p dired-hide-details-mode)
      (let ((details (not (bound-and-true-p dired-hide-details-mode)))
            (dossier-courant nil)
            (encre (face-foreground 'default nil t))
            (nb-dossiers 0) (nb-fichiers 0) (comptes 0)
            (premier-fichier t))
        ;; Ligne d'en-tête du dossier principal : redondante avec le fil
        ;; d'Ariane de la ligne d'en-tête.
        (goto-char (point-min))
        (when (and (not details) (looking-at "^  \\(.*\\):$"))
          (metal-dired--ov (line-beginning-position)
                           (min (point-max) (1+ (line-end-position)))
                           'invisible t))
        (while (not (eobp))
          (let ((debut (dired-move-to-filename)))
            (when debut
              (let* ((fin (or (dired-move-to-end-of-filename t) (line-end-position)))
                     (nom (buffer-substring-no-properties debut fin))
                     (dir (or dossier-courant (dired-current-directory)))
                     (chemin (expand-file-name nom dir))
                     (attrs (file-attributes chemin))
                     (est-dossier (eq t (file-attribute-type attrs)))
                     (parent (string= nom ".."))
                     (cache (and (string-prefix-p "." nom) (not parent))))
                (if (or parent est-dossier)
                    (setq nb-dossiers (+ nb-dossiers (if parent 0 1)))
                  (setq nb-fichiers (1+ nb-fichiers)))
                ;; Espace entre les dossiers et les fichiers.
                (when (and premier-fichier (not est-dossier) (not parent) (not details)
                           (not metal-dired--titre))
                  (setq premier-fichier nil)
                  (unless (= nb-dossiers 0)
                    (metal-dired--ov (line-beginning-position) (line-beginning-position)
                                     'before-string "\n")))
                ;; Pastille avant le nom.
                (let ((pastille
                       (cond (parent (metal-dired--pastille 'dos "↑"))
                             ((file-symlink-p chemin)
                              (metal-dired--pastille (if est-dossier 'dos 'autre) "→"))
                             (est-dossier (metal-dired--pastille 'dos))
                             (t (let ((ty (metal-dired--type-fichier nom)))
                                  (metal-dired--pastille (car ty) (cdr ty)))))))
                  (metal-dired--ov debut debut
                                   'before-string
                                   (concat (propertize " " 'display '(space :align-to 4))
                                           pastille
                                           (propertize "  " 'display '(space :width 1.2)))))
                ;; Nom.
                (cond
                 (metal-dired--titre
                  (metal-dired--ov debut fin
                                   'display (file-name-nondirectory
                                             (directory-file-name chemin))
                                   'face (if est-dossier
                                             `(:weight semi-bold :foreground ,encre)
                                           `(:foreground ,encre))))
                 (parent
                  (metal-dired--ov debut fin
                                   'display (propertize "Dossier parent"
                                                        'face `(:weight semi-bold :foreground ,encre))))
                 (est-dossier
                  (metal-dired--ov debut fin 'face `(:weight semi-bold :foreground ,encre)))
                 (cache
                  (metal-dired--ov debut fin 'face 'shadow)))
                ;; Date et taille, alignées à droite de la fenêtre.
                (when (and (not details) (not parent) attrs)
                  (let* ((date (metal-dired--date (file-attribute-modification-time attrs)))
                         (taille
                          (if est-dossier
                              (when (and metal-dired-compter-elements
                                         (< comptes metal-dired-compter-max))
                                (setq comptes (1+ comptes))
                                (let ((n (metal-dired--nb-elements chemin)))
                                  (and n (format "%d él." n))))
                            (metal-dired--taille (file-attribute-size attrs)))))
                    (metal-dired--ov
                     (line-end-position) (line-end-position)
                     'after-string
                     (concat
                      (if metal-dired--titre
                          (concat
                           (propertize " " 'display '(space :align-to (- right 58)))
                           (propertize (truncate-string-to-width
                                        (abbreviate-file-name
                                         (directory-file-name (file-name-directory chemin)))
                                        26 nil nil "…" )
                                       'face '(:inherit shadow :height 0.92)))
                        "")
                      (propertize " " 'display '(space :align-to (- right 30)))
                      (propertize date 'face '(:inherit shadow :height 0.92))
                      (propertize " " 'display '(space :align-to (- right 9)))
                      (propertize (format "%7s" (or taille ""))
                                  'face `(:inherit shadow :family ,metal-dired--mono
                                          :height 0.85))))))))
            ;; En-têtes de sous-dossiers insérés (touche i).
            (when (and (not debut) (looking-at "^  \\(/.*\\|~.*\\|[A-Za-z]:.*\\):$"))
              (setq dossier-courant (expand-file-name (match-string 1)))))
          (forward-line 1))
        (setq metal-dired--nb-dossiers nb-dossiers
              metal-dired--nb-fichiers nb-fichiers)
        ;; Rappel des touches au bas de la liste.
        (unless details
          (metal-dired--ov (point-max) (point-max)
                           'after-string (metal-dired--pied))))))))

(defun metal-dired--touche (touche)
  "Indication de raccourci TOUCHE."
  (propertize (concat " " touche " ")
              'face `(:family ,metal-dired--mono :height 0.8 :inherit shadow
                      :box (:line-width 1 :color ,(metal-dired--teinte 'bordure)))))

(defun metal-dired--pied ()
  "Chaîne du rappel des touches."
  (concat
   "\n"
   (mapconcat (lambda (k)
                (concat (metal-dired--touche (car k)) " "
                        (propertize (cdr k) 'face '(:inherit shadow :height 0.92))))
              (if metal-dired--titre
                  '(("RET" . "ouvrir") ("g" . "rafraîchir") ("(" . "détails"))
                '(("RET" . "ouvrir") ("^" . "dossier parent") ("+" . "nouveau dossier")
                  ("(" . "détails") ("." . "fichiers cachés")))
              "    ")
   "\n\n"
   (mapconcat (lambda (k)
                (concat (metal-dired--touche (car k)) " "
                        (propertize (cdr k) 'face '(:inherit shadow :height 0.92))))
              '(("m" . "marquer") ("u" . "démarquer") ("D" . "supprimer")
                ("x" . "exécuter les suppressions") ("R" . "renommer") ("C" . "copier"))
              "    ")
   "\n"))

;;; ── Ligne d'en-tête : fil d'Ariane et comptes ──────────────────────

(defun metal-dired--fil ()
  "Fil d'Ariane cliquable du dossier du tampon."
  (let* ((dir (abbreviate-file-name
               (directory-file-name (expand-file-name default-directory))))
         (parties (split-string dir "/"))
         (racine (if (string-empty-p (car parties)) "/" nil))
         (cumul "")
         (segments nil))
    (when racine (setq parties (cdr parties) cumul ""))
    (when racine (push (cons "/" "/") segments))
    (dolist (p parties)
      (unless (string-empty-p p)
        (setq cumul (if (or (string-empty-p cumul) (string= cumul "/"))
                        (concat (if racine "/" "") p)
                      (concat cumul "/" p)))
        (push (cons p cumul) segments)))
    (setq segments (nreverse segments))
    (let ((dernier (car (last segments))))
      (mapconcat
       (lambda (s)
         (if (eq s dernier)
             (propertize (car s) 'face '(:weight semi-bold))
           (let ((map (make-sparse-keymap))
                 (cible (cdr s)))
             (define-key map [header-line mouse-1]
                         (lambda () (interactive) (dired cible)))
             (propertize (car s)
                         'face `(:foreground ,(metal-dired--teinte 'accent))
                         'mouse-face 'highlight
                         'help-echo (format "Ouvrir %s" cible)
                         'local-map map))))
       segments
       (propertize "  ›  " 'face 'shadow)))))

(defun metal-dired--comptes ()
  "Comptes affichés à droite de la ligne d'en-tête."
  (let* ((marques (save-excursion
                    (save-restriction
                      (widen)
                      (how-many "^\\*" (point-min) (point-max)))))
         (pl (lambda (n mot) (format "%d %s%s" n mot (if (> n 1) "s" "")))))
    (concat (if (and metal-dired--titre (= metal-dired--nb-dossiers 0))
                ""
              (concat (funcall pl metal-dired--nb-dossiers "dossier") "  ·  "))
            (funcall pl metal-dired--nb-fichiers "fichier")
            (if (> marques 0)
                (concat "  ·  " (funcall pl marques "marqué"))
              ""))))

(defun metal-dired--en-tete ()
  "Contenu de la ligne d'en-tête."
  (let ((droite (metal-dired--comptes)))
    (concat "   " (if metal-dired--titre
                      (propertize metal-dired--titre 'face '(:weight semi-bold))
                    (metal-dired--fil))
            (propertize " " 'display `(space :align-to (- right ,(+ 3 (string-width droite)))))
            (propertize droite 'face '(:inherit shadow :height 0.92)))))

;;; ── Fichiers cachés ────────────────────────────────────────────────

(defconst metal-dired--omettre-points "\\`\\.\\(?:[^.]\\|\\'\\)"
  "Omettre « . » et les fichiers à point, garder « .. ».")

(defconst metal-dired--omettre-point-seul "\\`\\.\\'"
  "Omettre seulement « . ».")

(defvar-local metal-dired--points-caches nil)

(defun metal-dired--regler-omission ()
  "Régler `dired-omit-mode' pour ce tampon."
  (setq-local dired-omit-files (if metal-dired--points-caches
                                   metal-dired--omettre-points
                                 metal-dired--omettre-point-seul))
  ;; Ne rien omettre d'autre (dired-x cache sinon .elc, ~, etc.).
  (setq-local dired-omit-extensions nil)
  (setq-local dired-omit-verbose nil)
  (dired-omit-mode 1))

(defun metal-dired-basculer-caches ()
  "Montrer ou cacher les fichiers commençant par un point."
  (interactive)
  (setq metal-dired--points-caches (not metal-dired--points-caches))
  (metal-dired--regler-omission)
  (revert-buffer)
  (message (if metal-dired--points-caches
               "Fichiers commençant par un point : cachés"
             "Fichiers commençant par un point : affichés")))

;;; ── Dired d'une liste de fichiers ──────────────────────────────────

(defun metal-dired-liste (titre fichiers)
  "Ouvrir dans un onglet nommé TITRE un Dired des FICHIERS, dans l'ordre donné.
FICHIERS sont des chemins (absolus ou avec ~) pouvant venir de dossiers
différents.  Le tampon est un vrai Dired : marquer, renommer, copier,
supprimer fonctionnent ; g relit la même liste."
  (let ((fichiers (cl-remove-if-not #'file-exists-p
                                    (mapcar #'expand-file-name fichiers))))
    (unless fichiers
      (user-error "Aucun fichier à afficher"))
    (when (get-buffer titre)
      (kill-buffer titre))
    ;; -U : pas de tri, l'ordre de la liste est conservé (ls-lisp).
    (let ((buf (dired-noselect (cons (expand-file-name "~/") fichiers) "-alU")))
      (with-current-buffer buf
        (rename-buffer titre t)
        (setq metal-dired--titre titre)
        (metal-dired--decorer))
      (switch-to-buffer buf))))

;;; ── Activation ─────────────────────────────────────────────────────

(defvar-local metal-dired--minuterie nil)

(defun metal-dired--planifier ()
  "Redécorer après la fin du listage (et de l'omission de dired-x).
`dired-after-readin-hook' s'exécute sur la portion insérée seulement ;
on redécore donc tout le tampon un instant plus tard."
  (let ((buf (current-buffer)))
    (unless metal-dired--minuterie
      (setq metal-dired--minuterie
            (run-at-time 0 nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq metal-dired--minuterie nil)
                               (metal-dired--decorer)))))))))

(defun metal-dired--police ()
  "Police proportionnelle quand les détails sont cachés, sinon monospace."
  (setq-local buffer-face-mode-face 'variable-pitch)
  (buffer-face-mode (if (bound-and-true-p dired-hide-details-mode) 1 -1)))

(defun metal-dired--apres-details ()
  "Après la touche « ( » : police et décoration."
  (when (derived-mode-p 'dired-mode)
    (metal-dired--police)
    (metal-dired--decorer)))

(defun metal-dired--activer ()
  "Habiller le tampon Dired courant."
  (setq metal-dired--points-caches metal-dired-cacher-points)
  (metal-dired--regler-omission)
  (setq-local line-spacing (if (boundp 'metal-dashboard-interligne)
                               metal-dashboard-interligne
                             0.25))
  (setq-local dired-hide-details-hide-symlink-targets t)
  (dired-hide-details-mode 1)
  (metal-dired--police)
  (metal-dired--installer-mots-cles)
  (setq-local header-line-format '(:eval (metal-dired--en-tete)))
  (face-remap-add-relative 'header-line '(:inherit variable-pitch))
  (add-hook 'dired-after-readin-hook #'metal-dired--planifier 90 t)
  (add-hook 'dired-hide-details-mode-hook #'metal-dired--apres-details nil t)
  (metal-dired--planifier))

(add-hook 'dired-mode-hook #'metal-dired--activer)

(define-key dired-mode-map (kbd ".") #'metal-dired-basculer-caches)

;; Thème choisi au tableau de bord : redessiner les Dired ouverts.
(add-hook 'metal-apparence-apres-changement-hook
          (lambda ()
            (dolist (b (buffer-list))
              (with-current-buffer b
                (when (derived-mode-p 'dired-mode)
                  (ignore-errors
                    (metal-dired--installer-mots-cles)
                    (metal-dired--decorer)))))))

(provide 'metal-dired)
;;; metal-dired.el ends here
