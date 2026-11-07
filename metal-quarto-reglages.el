;;; metal-quarto-reglages.el --- Panneau des réglages de mise en page Quarto -*- coding: utf-8; lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: quarto, yaml, beamer, pdf

;;; Commentary:
;;
;; Un panneau « *Réglages — X.qmd* » pour modifier la mise en page d'un
;; document ou d'une présentation sans toucher au YAML :
;;
;;   Document PDF   : papier, marges, classe, police, interligne,
;;                    numérotation, table des matières, code…
;;   Présentation   : thème Beamer, format d'écran, police, listes
;;                    progressives, coloration, thème du diaporama HTML.
;;
;; Tout se choisit dans des listes ou des cases à cocher : aucune saisie
;; libre, donc aucune valeur invalide possible.  « Appliquer » écrit les
;; valeurs dans l'en-tête en un seul pas d'annulation (C-/ revient en
;; arrière) ; les clés absentes sont ajoutées à leur place, les autres
;; lignes de l'en-tête ne sont jamais touchées.

;;; Code:

(require 'cl-lib)
(require 'wid-edit)

(declare-function metal-quarto--beamer-p "metal-quarto-barre")
(declare-function metal-quarto--theme-html "metal-quarto-barre")
(declare-function metal-quarto--ecrire-theme-html "metal-quarto-barre")
(declare-function metal-quarto--ecrire-theme-beamer "metal-quarto-barre")
(declare-function metal-quarto-entete-afficher-yaml "metal-quarto-entete")
(declare-function metal-quarto-entete-yaml-affiche-p "metal-quarto-entete")
(defvar metal-quarto-themes-beamer)
(defvar metal-quarto-themes-revealjs)

;;; ─── Lecture et écriture ciblées du YAML ────────────────────────────
;;
;; Pas d'analyseur YAML complet : l'en-tête des modèles MetalEmacs est un
;; arbre de clés indentées de 2 en 2.  On localise un bloc par son chemin
;; de clés (("format" "pdf") …) et on n'édite que la ligne visée.

(defun metal-quarto--fm-bornes ()
  "Bornes (DÉBUT-CORPS . FIN) du front matter, ou nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (looking-at "---[ \t]*$")
        (forward-line 1)
        (let ((debut (point)))
          (when (re-search-forward "^\\(---\\|\\.\\.\\.\\)[ \t]*$" nil t)
            (cons debut (match-beginning 0))))))))

(defun metal-quarto--indentation ()
  "Indentation de la ligne courante, ou nil pour une ligne vide/commentaire."
  (save-excursion
    (beginning-of-line)
    (unless (looking-at "[ \t]*\\(#.*\\)?$")
      (skip-chars-forward " ")
      (current-column))))

(defun metal-quarto--yaml-bloc (chemin)
  "Bornes (EN-TÊTE DÉBUT FIN INDENT-ENFANTS) du bloc désigné par CHEMIN.
EN-TÊTE est la fin de la ligne « clé: » ; DÉBUT…FIN couvre ses lignes
enfants.  Nil si le bloc n'existe pas (ou n'est pas un bloc)."
  (let ((fm (metal-quarto--fm-bornes)))
    (when fm
      (save-excursion
        (let ((debut (car fm)) (fin (cdr fm)) (indent 0) entete)
          (catch 'absent
            (dolist (cle chemin)
              (goto-char debut)
              (unless (re-search-forward
                       (format "^%s%s:[ \t]*$" (make-string indent ?\s)
                               (regexp-quote cle))
                       fin t)
                (throw 'absent nil))
              (setq entete (point))
              (forward-line 1)
              (setq debut (point))
              ;; Le bloc s'étend tant que les lignes sont plus indentées.
              (while (and (< (point) fin)
                          (let ((i (metal-quarto--indentation)))
                            (or (null i) (> i indent))))
                (forward-line 1))
              ;; Ne pas avaler les lignes vides de fin.
              (while (and (> (point) debut)
                          (save-excursion (forward-line -1)
                                          (null (metal-quarto--indentation))))
                (forward-line -1))
              (setq fin (point)
                    indent (+ indent 2)))
            (list entete debut fin indent)))))))

(defun metal-quarto--yaml-lire (chemin cle)
  "Valeur scalaire de CLE dans le bloc CHEMIN (chaîne sans guillemets), ou nil."
  (let ((bloc (metal-quarto--yaml-bloc chemin)))
    (when bloc
      (save-excursion
        (goto-char (nth 1 bloc))
        (when (re-search-forward
               (format "^%s%s:[ \t]*\"?\\([^\"\n#]*?\\)\"?[ \t]*\\(#.*\\)?$"
                       (make-string (nth 3 bloc) ?\s) (regexp-quote cle))
               (nth 2 bloc) t)
          (let ((v (match-string-no-properties 1)))
            (unless (string-empty-p v) v)))))))

(defun metal-quarto--yaml-assurer-bloc (chemin)
  "Créer au besoin le bloc CHEMIN (ex. (\"format\" \"pdf\")) et le retourner."
  (or (metal-quarto--yaml-bloc chemin)
      (let ((parent (butlast chemin))
            (cle (car (last chemin))))
        (if parent
            (let ((bloc (metal-quarto--yaml-assurer-bloc parent)))
              (save-excursion
                (goto-char (nth 0 bloc))
                ;; Forme abrégée « pdf: default » : la convertir en bloc.
                (if (re-search-forward
                     (format "^%s%s:.*$" (make-string (nth 3 bloc) ?\s)
                             (regexp-quote cle))
                     (nth 2 bloc) t)
                    (replace-match (format "%s%s:" (make-string (nth 3 bloc) ?\s)
                                           cle)
                                   t t)
                  (insert "\n" (make-string (nth 3 bloc) ?\s) cle ":"))))
          (let ((fm (metal-quarto--fm-bornes)))
            (save-excursion
              (goto-char (cdr fm))
              (insert cle ":\n"))))
        (metal-quarto--yaml-bloc chemin))))

(defun metal-quarto--yaml-ecrire (chemin cle valeur)
  "Donner VALEUR (chaîne) à CLE dans le bloc CHEMIN, créé au besoin."
  (let* ((bloc (metal-quarto--yaml-assurer-bloc chemin))
         (retrait (make-string (nth 3 bloc) ?\s)))
    (save-excursion
      (goto-char (nth 1 bloc))
      (if (re-search-forward (format "^%s%s:.*$" retrait (regexp-quote cle))
                             (nth 2 bloc) t)
          (replace-match (format "%s%s: %s" retrait cle valeur) t t)
        (goto-char (nth 0 bloc))
        (insert "\n" retrait cle ": " valeur)))))

(defun metal-quarto--marge-lire ()
  "Marge en cm lue dans `geometry' du bloc format/pdf, ou nil."
  (let ((bloc (metal-quarto--yaml-bloc '("format" "pdf"))))
    (when bloc
      (save-excursion
        (goto-char (nth 1 bloc))
        (when (re-search-forward "margin=\\([0-9.]+\\)cm" (nth 2 bloc) t)
          (match-string-no-properties 1))))))

(defun metal-quarto--marge-ecrire (cm)
  "Fixer la marge à CM centimètres (geometry: - margin=CMcm)."
  (let* ((bloc (metal-quarto--yaml-assurer-bloc '("format" "pdf")))
         (retrait (make-string (nth 3 bloc) ?\s)))
    (save-excursion
      (goto-char (nth 1 bloc))
      (if (re-search-forward (format "^%sgeometry:.*$" retrait) (nth 2 bloc) t)
          (let ((debut (match-beginning 0)))
            ;; Remplacer la clé et ses éventuels éléments de liste.
            (forward-line 1)
            (while (and (< (point) (nth 2 bloc))
                        (let ((i (metal-quarto--indentation)))
                          (and i (> i (nth 3 bloc)))))
              (forward-line 1))
            (delete-region debut (point))
            (goto-char debut)
            (insert (format "%sgeometry:\n%s  - margin=%scm\n" retrait retrait cm)))
        (goto-char (nth 0 bloc))
        (insert (format "\n%sgeometry:\n%s  - margin=%scm" retrait retrait cm))))))

;;; ─── Description des réglages ───────────────────────────────────────
;;
;; Chaque réglage : (ÉTIQUETTE CHEMIN CLÉ TYPE CHOIX DÉFAUT)
;;   TYPE : `choix' (liste de (LIBELLÉ . VALEUR)) ou `bool'.

(defconst metal-quarto-reglages-document
  '(("Format du papier"      ("format" "pdf") "papersize" choix
     (("Lettre US" . "letter") ("A4" . "a4")) "letter")
    ("Marges"                ("format" "pdf") marge choix
     (("1 cm" . "1") ("1,25 cm" . "1.25") ("1,5 cm" . "1.5")
      ("1,75 cm" . "1.75") ("2 cm" . "2") ("2,25 cm" . "2.25")
      ("2,5 cm" . "2.5") ("2,75 cm" . "2.75") ("3 cm" . "3")
      ("3,5 cm" . "3.5") ("4 cm" . "4") ("4,5 cm" . "4.5") ("5 cm" . "5"))
     "2")
    ("Type de document"      ("format" "pdf") "documentclass" choix
     (("Article" . "scrartcl") ("Rapport (chapitres)" . "scrreprt")
      ("Livre" . "scrbook"))
     "scrartcl")
    ;; Les classes KOMA (scrartcl, scrreprt, scrbook) acceptent toute taille.
    ("Taille du texte"       ("format" "pdf") "fontsize" choix
     (("9 pt" . "9pt") ("9,5 pt" . "9.5pt") ("10 pt" . "10pt")
      ("10,5 pt" . "10.5pt") ("11 pt" . "11pt") ("11,5 pt" . "11.5pt")
      ("12 pt" . "12pt") ("13 pt" . "13pt") ("14 pt" . "14pt")
      ("16 pt" . "16pt"))
     "11pt")
    ("Interligne"            ("format" "pdf") "linestretch" choix
     (("Simple" . "1") ("1,1" . "1.1") ("1,15" . "1.15") ("1,25" . "1.25")
      ("1,5" . "1.5") ("1,75" . "1.75") ("Double" . "2"))
     "1")
    ("Sections numérotées"   ("format" "pdf") "number-sections" bool nil t)
    ("Table des matières"    ("format" "pdf") "toc" bool nil nil)
    ("Fond gris du code"     ("format" "pdf") "code-block-bg" bool nil t)
    ("Coloration du code"    ("format" "pdf") "highlight-style" choix
     (("GitHub" . "github") ("Tango" . "tango") ("Pygments" . "pygments")
      ("Kate" . "kate") ("Monochrome" . "monochrome"))
     "github")
    ("Exécuter le code"      ("execute") "enabled" bool nil nil))
  "Réglages proposés pour un document PDF.")

(defconst metal-quarto-reglages-presentation
  '(("Thème (PDF)"           ("format" "beamer") theme-beamer choix nil
     "metropolis")
    ("Thème (diaporama HTML)" nil theme-html choix nil "default")
    ("Format d'écran"        ("format" "beamer") "aspectratio" choix
     (("16:9" . "169") ("16:10" . "1610") ("4:3" . "43")) "169")
    ;; Beamer n'accepte que ces tailles (options de la classe).
    ("Taille du texte"       ("format" "beamer") "fontsize" choix
     (("8 pt" . "8pt") ("9 pt" . "9pt") ("10 pt" . "10pt")
      ("11 pt" . "11pt") ("12 pt" . "12pt") ("14 pt" . "14pt")
      ("17 pt" . "17pt") ("20 pt" . "20pt"))
     "10pt")
    ("Listes progressives"   ("format" "beamer") "incremental" bool nil nil)
    ("Coloration du code"    ("format" "beamer") "highlight-style" choix
     (("GitHub" . "github") ("Tango" . "tango") ("Pygments" . "pygments")
      ("Kate" . "kate") ("Monochrome" . "monochrome"))
     "github")
    ("Exécuter le code"      ("execute") "enabled" bool nil nil))
  "Réglages proposés pour une présentation Beamer.")

(defun metal-quarto--reglage-choix (r)
  "Liste (LIBELLÉ . VALEUR) du réglage R (thèmes compris)."
  (pcase (nth 2 r)
    ('theme-beamer (mapcar (lambda (x) (cons x x)) metal-quarto-themes-beamer))
    ('theme-html   (mapcar (lambda (x) (cons x x)) metal-quarto-themes-revealjs))
    (_ (nth 4 r))))

(defun metal-quarto--reglage-lire (r)
  "Valeur actuelle du réglage R dans le tampon courant (défaut sinon)."
  (let* ((cle (nth 2 r))
         (v (pcase cle
              ('marge (metal-quarto--marge-lire))
              ('theme-beamer (metal-quarto--yaml-lire (nth 1 r) "theme"))
              ('theme-html (metal-quarto--theme-html))
              (_ (metal-quarto--yaml-lire (nth 1 r) cle)))))
    (if (eq (nth 3 r) 'bool)
        (if v (and (member v '("true" "yes" "on")) t) (nth 5 r))
      ;; Valeur inconnue des choix : on la montre telle quelle plutôt que
      ;; de l'écraser sans prévenir.
      (or v (nth 5 r)))))

(defun metal-quarto--reglage-ecrire (r valeur)
  "Écrire VALEUR du réglage R dans le tampon courant."
  (let ((cle (nth 2 r)))
    (pcase cle
      ('marge (metal-quarto--marge-ecrire valeur))
      ('theme-beamer (metal-quarto--ecrire-theme-beamer valeur))
      ('theme-html (metal-quarto--ecrire-theme-html valeur))
      (_ (metal-quarto--yaml-ecrire
          (nth 1 r) cle
          (if (eq (nth 3 r) 'bool) (if valeur "true" "false") valeur))))))

;;; ─── Le panneau ─────────────────────────────────────────────────────

(defvar-local metal-quarto--reglages-source nil
  "Tampon .qmd édité par ce panneau.")

(defvar-local metal-quarto--reglages-widgets nil
  "Liste (RÉGLAGE . WIDGET) du panneau.")

(defface metal-quarto-reglages-titre
  '((t :inherit bold :height 1.25))
  "Titre du panneau des réglages."
  :group 'metal-quarto)

(defface metal-quarto-reglages-etiquette
  '((t :inherit default))
  "Étiquette d'un réglage."
  :group 'metal-quarto)

(defun metal-quarto--reglages-liste ()
  "Réglages applicables au document source."
  (if (metal-quarto--beamer-p)
      metal-quarto-reglages-presentation
    metal-quarto-reglages-document))

;;;###autoload
(defun metal-quarto-reglages ()
  "Ouvrir le panneau des réglages de mise en page du document courant."
  (interactive)
  (let ((source (or (buffer-base-buffer) (current-buffer))))
    (unless (with-current-buffer source (metal-quarto--fm-bornes))
      (user-error "Ce document n'a pas d'en-tête : insérez-en un (➕ ▸ En-tête YAML)"))
    (let* ((nom (format "*Réglages — %s*" (buffer-name source)))
           (panneau (get-buffer-create nom))
           (reglages (with-current-buffer source (metal-quarto--reglages-liste)))
           (presentation (with-current-buffer source (metal-quarto--beamer-p))))
      (with-current-buffer panneau
        (let ((inhibit-read-only t))
          (kill-all-local-variables)
          (remove-overlays)
          (erase-buffer))
        (setq metal-quarto--reglages-source source
              metal-quarto--reglages-widgets nil)
        (widget-insert (propertize
                        (if presentation "Réglages de la présentation"
                          "Réglages du document")
                        'face 'metal-quarto-reglages-titre)
                       "\n"
                       (propertize (buffer-name source) 'face 'shadow)
                       "\n\n")
        (let ((largeur (apply #'max (mapcar (lambda (r) (string-width (car r)))
                                            reglages))))
          (dolist (r reglages)
            (let ((valeur (with-current-buffer source
                            (metal-quarto--reglage-lire r))))
              (widget-insert
               "  " (propertize (car r) 'face 'metal-quarto-reglages-etiquette)
               (make-string (- (+ largeur 3) (string-width (car r))) ?\s))
              (push
               (cons r
                     (if (eq (nth 3 r) 'bool)
                         (prog1 (widget-create 'checkbox (and valeur t))
                           (widget-insert "\n"))
                       (let* ((choix (metal-quarto--reglage-choix r))
                              (connu (rassoc valeur choix))
                              (choix (if (or connu (null valeur)) choix
                                       (append choix
                                               (list (cons (format "%s (actuel)" valeur)
                                                           valeur))))))
                         (apply #'widget-create 'menu-choice
                                :tag "" :format "%[%v%]\n"
                                :value valeur
                                (mapcar (lambda (c)
                                          (list 'const :tag (car c) :format "%t" (cdr c)))
                                        choix)))))
               metal-quarto--reglages-widgets))))
        (setq metal-quarto--reglages-widgets
              (nreverse metal-quarto--reglages-widgets))
        (widget-insert "\n  ")
        (widget-create 'push-button
                       :notify (lambda (&rest _) (metal-quarto-reglages-appliquer))
                       " Appliquer ")
        (widget-insert "   ")
        (widget-create 'push-button
                       :notify (lambda (&rest _) (metal-quarto-reglages-fermer))
                       " Fermer ")
        (widget-insert "\n\n"
                       (propertize
                        "  Cliquez sur une valeur pour la changer.  « Appliquer » écrit\n  les réglages dans l'en-tête (C-/ dans le document pour annuler)."
                        'face 'shadow)
                       "\n\n"
                       (propertize "Avancé" 'face 'metal-quarto-reglages-titre)
                       "\n\n  ")
        ;; Effet immédiat, sans « Appliquer » : ne change que l'affichage.
        (widget-create 'checkbox
                       :notify (lambda (w &rest _)
                                 (when (buffer-live-p source)
                                   (with-current-buffer source
                                     (metal-quarto-entete-afficher-yaml
                                      (widget-value w)))))
                       (with-current-buffer source
                         (metal-quarto-entete-yaml-affiche-p)))
        (widget-insert " Afficher l'en-tête YAML complet dans le document\n"
                       (propertize
                        "      Pour l'utilisateur expérimenté qui édite le YAML lui-même,\n      à ses risques : une erreur d'indentation ou de syntaxe peut\n      empêcher la production du document."
                        'face 'shadow)
                       "\n")
        (use-local-map widget-keymap)
        (local-set-key (kbd "q") #'metal-quarto-reglages-fermer)
        (widget-setup)
        (goto-char (point-min))
        (widget-forward 1))
      (pop-to-buffer panneau '((display-buffer-reuse-window
                                display-buffer-below-selected)
                               (window-height . fit-window-to-buffer))))))

(defun metal-quarto-reglages-appliquer ()
  "Écrire les réglages du panneau dans l'en-tête du document."
  (interactive)
  (let ((source metal-quarto--reglages-source)
        (paires (mapcar (lambda (rw) (cons (car rw) (widget-value (cdr rw))))
                        metal-quarto--reglages-widgets))
        (changes 0))
    (unless (buffer-live-p source)
      (user-error "Le document n'est plus ouvert"))
    (with-current-buffer source
      ;; Un seul pas d'annulation pour l'ensemble ; en cas d'erreur, le
      ;; groupe est annulé et l'en-tête revient intact.
      (let ((groupe (prepare-change-group))
            (ok nil))
        (unwind-protect
            (progn
              (activate-change-group groupe)
              (dolist (p paires)
                (unless (equal (metal-quarto--reglage-lire (car p)) (cdr p))
                  (metal-quarto--reglage-ecrire (car p) (cdr p))
                  (cl-incf changes)))
              (setq ok t))
          (if ok
              (progn (accept-change-group groupe)
                     (undo-amalgamate-change-group groupe))
            (cancel-change-group groupe)))))
    (message (if (zerop changes) "Aucun changement"
               (format "%d réglage%s appliqué%s — produisez le document pour voir le résultat"
                       changes (if (> changes 1) "s" "") (if (> changes 1) "s" ""))))))

(defun metal-quarto-reglages-fermer ()
  "Fermer le panneau des réglages."
  (interactive)
  (quit-window t))

(provide 'metal-quarto-reglages)
;;; metal-quarto-reglages.el ends here
