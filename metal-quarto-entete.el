;;; metal-quarto-entete.el --- Masquer les réglages techniques de l'en-tête Quarto -*- coding: utf-8; lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: quarto, yaml, front matter

;;; Commentary:
;;
;; Dans un .qmd, l'en-tête YAML mêle ce que l'auteur remplit (titre,
;; sous-titre, auteur…) et la mécanique de mise en page (format, filtres,
;; header-includes LaTeX, execute…).  Ce module masque la mécanique et
;; laisse visibles les champs à remplir :
;;
;;   ── En-tête ──
;;   title: "Étape 4 — Groupes de synonymes"
;;   subtitle: "Construire un réseau sémantique"
;;   author: "Jacques Ladouceur"
;;   ─────────────
;;
;; Les réglages se modifient dans le panneau ⚙ (metal-quarto-reglages.el).
;; Ce panneau offre aussi l'option « Afficher l'en-tête YAML » pour
;; l'utilisateur expérimenté qui veut éditer le texte brut lui-même.
;; Le fichier n'est jamais modifié : seul l'affichage change (overlays).
;;
;; Compatible polymode : les overlays sont posés dans le tampon de base ET
;; dans ses tampons indirects (le front matter y est un bloc YAML), puisque
;; chaque tampon a ses propres overlays, et polymode est prié de ne pas
;; les déplacer.

;;; Code:

(require 'cl-lib)

(defgroup metal-quarto-entete nil
  "Masquage des réglages techniques de l'en-tête Quarto."
  :group 'metal-quarto)

(defcustom metal-quarto-masquer-entete t
  "Si non nil, les réglages techniques de l'en-tête sont masqués à l'ouverture."
  :type 'boolean
  :group 'metal-quarto-entete)

(defcustom metal-quarto-entete-cles-visibles
  '("title" "subtitle" "author" "institute" "date" "lang"
    "abstract" "keywords" "description" "bibliography")
  "Clés de premier niveau de l'en-tête qui restent toujours visibles.
Ce sont les champs que l'auteur remplit ; toutes les autres clés
\(format, filters, header-includes, execute…) sont masquées."
  :type '(repeat string)
  :group 'metal-quarto-entete)

(defface metal-quarto-entete-face
  '((((background dark)) :foreground "gray60" :height 0.9)
    (t :foreground "gray45" :height 0.9))
  "Visage des lignes de repère de l'en-tête masqué."
  :group 'metal-quarto-entete)

(defvar-local metal-quarto--entete-masque nil
  "Non nil si les réglages de l'en-tête sont masqués (tampon de base).")

(defvar-local metal-quarto--entete-actif nil
  "Non nil dans le tampon de base d'un .qmd géré par ce module.")

(defvar-local metal-quarto--entete-minuterie nil
  "Minuterie de rafraîchissement différé des overlays.")

;;; ─── Analyse du front matter ────────────────────────────────────────

(defun metal-quarto--entete-analyser ()
  "Analyser le front matter du tampon courant.
Retourne une plist (:ouverture BEG :fermeture BEG :blocs ((CLÉ BEG END)…))
ou nil sans front matter.  Chaque bloc couvre la ligne de la clé, ses
lignes indentées et les lignes vides qui suivent."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (looking-at "---[ \t]*$")
        (let ((ouverture (point))
              (debut-corps (progn (forward-line 1) (point)))
              fermeture blocs)
          (when (re-search-forward "^\\(---\\|\\.\\.\\.\\)[ \t]*$" nil t)
            (setq fermeture (match-beginning 0))
            (goto-char debut-corps)
            (let (cle debut)
              (while (< (point) fermeture)
                (when (looking-at "\\([A-Za-z_][A-Za-z0-9_-]*\\)[ \t]*:")
                  (when cle (push (list cle debut (point)) blocs))
                  (setq cle (match-string-no-properties 1)
                        debut (point)))
                (forward-line 1))
              (when cle (push (list cle debut fermeture) blocs)))
            (list :ouverture ouverture :fermeture fermeture
                  :blocs (nreverse blocs))))))))

;;; ─── Overlays ───────────────────────────────────────────────────────

(defun metal-quarto--entete-base ()
  "Tampon de base du tampon courant (lui-même hors polymode)."
  (or (buffer-base-buffer) (current-buffer)))

(defun metal-quarto--entete-tampons ()
  "Le tampon de base et tous ses tampons indirects vivants."
  (let ((base (metal-quarto--entete-base)))
    (cons base
          (cl-remove-if-not (lambda (b) (eq (buffer-base-buffer b) base))
                            (buffer-list)))))

(defun metal-quarto--entete-effacer (tampon)
  "Retirer les overlays d'en-tête de TAMPON."
  (with-current-buffer tampon
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'metal-quarto-entete t))))

(defun metal-quarto--entete-overlay (tampon beg end &rest props)
  "Créer dans TAMPON un overlay d'en-tête de BEG à END avec PROPS."
  (with-current-buffer tampon
    (let ((ov (make-overlay beg end nil t nil)))
      (overlay-put ov 'metal-quarto-entete t)
      (overlay-put ov 'evaporate t)
      (while props
        (overlay-put ov (pop props) (pop props)))
      ov)))

(defun metal-quarto--entete-poser ()
  "Poser les overlays de masquage dans tous les tampons du document."
  (let* ((base (metal-quarto--entete-base))
         (tampons (metal-quarto--entete-tampons))
         (info (with-current-buffer base (metal-quarto--entete-analyser)))
         (masques (and info
                       (cl-remove-if
                        (lambda (b) (member (car b) metal-quarto-entete-cles-visibles))
                        (plist-get info :blocs)))))
    (mapc #'metal-quarto--entete-effacer tampons)
    (when masques
      (let* ((ouverture (plist-get info :ouverture))
             (fermeture (plist-get info :fermeture))
             (repere-haut (propertize "── En-tête ──"
                                      'face 'metal-quarto-entete-face))
             (repere-bas (propertize "─────────────"
                                     'face 'metal-quarto-entete-face)))
        (dolist (tampon tampons)
          ;; Délimiteurs : remplacés à l'affichage par des repères discrets.
          (metal-quarto--entete-overlay tampon ouverture (+ ouverture 3)
                                        'display repere-haut)
          (metal-quarto--entete-overlay tampon fermeture (+ fermeture 3)
                                        'display repere-bas)
          ;; Blocs techniques : remplacés à l'affichage par une chaîne vide.
          ;; Pas de propriété `invisible' : polymode supprime et recopie
          ;; ces overlays-là à chaque changement de tampon indirect.
          (dolist (b masques)
            (metal-quarto--entete-overlay tampon (nth 1 b) (nth 2 b)
                                          'display "")))))))

(defun metal-quarto--entete-rafraichir (&optional tampon)
  "Recalculer les overlays d'en-tête du document de TAMPON (défaut courant)."
  (with-current-buffer (or tampon (current-buffer))
    (let ((base (metal-quarto--entete-base)))
      (when (buffer-live-p base)
        (with-current-buffer base
          (if metal-quarto--entete-masque
              (metal-quarto--entete-poser)
            (mapc #'metal-quarto--entete-effacer
                  (metal-quarto--entete-tampons))))))))

(defun metal-quarto--entete-apres-modif (&rest _)
  "Planifier un rafraîchissement : la structure de l'en-tête a pu changer."
  (let ((base (metal-quarto--entete-base)))
    (when (and (buffer-live-p base)
               (buffer-local-value 'metal-quarto--entete-actif base))
      (with-current-buffer base
        (when (timerp metal-quarto--entete-minuterie)
          (cancel-timer metal-quarto--entete-minuterie))
        (setq metal-quarto--entete-minuterie
              (run-with-idle-timer 0.4 nil #'metal-quarto--entete-rafraichir base))))))

;;; ─── Commandes ──────────────────────────────────────────────────────

(defun metal-quarto-entete-afficher-yaml (afficher)
  "Afficher l'en-tête YAML complet si AFFICHER est non nil, sinon le masquer."
  (let ((base (metal-quarto--entete-base)))
    (with-current-buffer base
      (setq metal-quarto--entete-masque (not afficher))
      (metal-quarto--entete-rafraichir base))))

(defun metal-quarto-entete-yaml-affiche-p ()
  "Non nil si l'en-tête YAML complet est affiché dans le document courant."
  (not (buffer-local-value 'metal-quarto--entete-masque
                           (metal-quarto--entete-base))))

(defun metal-quarto-entete-basculer ()
  "Afficher ou masquer les réglages techniques de l'en-tête."
  (interactive)
  (let ((base (metal-quarto--entete-base)))
    (with-current-buffer base
      (setq metal-quarto--entete-masque (not metal-quarto--entete-masque))
      (metal-quarto--entete-rafraichir base)
      (message (if metal-quarto--entete-masque
                   "Réglages de l'en-tête masqués (C-c y pour les afficher)"
                 "Réglages de l'en-tête affichés (C-c y pour les masquer)")))))

(defun metal-quarto--entete-activer ()
  "Activer le masquage de l'en-tête dans un .qmd, selon la préférence."
  (when (let ((f (buffer-file-name (metal-quarto--entete-base))))
          (and f (string-match-p "\\.qmd\\'" f)))
    (add-hook 'after-change-functions #'metal-quarto--entete-apres-modif nil t)
    (let ((base (metal-quarto--entete-base)))
      (if (eq base (current-buffer))
          (progn
            (setq metal-quarto--entete-actif t
                  metal-quarto--entete-masque (and metal-quarto-masquer-entete t))
            (metal-quarto--entete-rafraichir))
        ;; Tampon indirect (polymode) créé après le tampon de base : y
        ;; reporter les overlays, différé le temps que polymode l'installe.
        (run-with-idle-timer 0.1 nil #'metal-quarto--entete-rafraichir base)))))

;; Polymode déplace les overlays d'un tampon indirect à l'autre quand le
;; point change de bloc.  Les nôtres sont posés dans chaque tampon : il
;; doit les laisser en place.
(with-eval-after-load 'polymode-core
  (defvar polymode-ignore-overlays-with-these-properties)
  (add-to-list 'polymode-ignore-overlays-with-these-properties
               'metal-quarto-entete))

(defun metal-quarto--entete-apres-changement-tampon (_ancien nouveau)
  "Poser les overlays dans NOUVEAU (tampon polymode) s'il n'en a pas encore."
  (when (and (buffer-live-p nouveau)
             (buffer-local-value 'metal-quarto--entete-actif
                                 (with-current-buffer nouveau
                                   (metal-quarto--entete-base)))
             (with-current-buffer nouveau
               (save-restriction
                 (widen)
                 (not (cl-some (lambda (o) (overlay-get o 'metal-quarto-entete))
                               (overlays-in (point-min) (point-max)))))))
    (metal-quarto--entete-rafraichir nouveau)))

(add-hook 'polymode-after-switch-buffer-hook
          #'metal-quarto--entete-apres-changement-tampon)

(add-hook 'markdown-mode-hook #'metal-quarto--entete-activer)
(add-hook 'yaml-mode-hook #'metal-quarto--entete-activer)
(add-hook 'yaml-ts-mode-hook #'metal-quarto--entete-activer)

(with-eval-after-load 'markdown-mode
  (with-no-warnings
    (define-key markdown-mode-map (kbd "C-c y") #'metal-quarto-entete-basculer)))

(provide 'metal-quarto-entete)
;;; metal-quarto-entete.el ends here
