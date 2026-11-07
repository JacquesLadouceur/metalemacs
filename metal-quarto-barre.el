;;; metal-quarto-barre.el --- Barre d'outils Quarto (.qmd / .md) -*- coding: utf-8; lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, header-line, quarto, markdown

;;; Commentary:
;;
;; Barre d'outils des tampons Markdown/Quarto, organisée en groupes :
;;
;;   T2▾ │ G I S B </> 🎨▾ │ ➕▾ 🟦▾ 🔗 ▣▾ │ ⚙ PDF▾ HTML▾ │ 📚▾ │ 👤
;;
;;   T2▾   Titres : niveau 1 à 4, texte normal, monter/descendre, plan.
;;         L'indicateur affiche le niveau de la ligne courante (T1…T6,
;;         « T· » hors texte de titre).  En Beamer, les libellés deviennent
;;         Section / Diapositive / Bloc (slide-level 2).
;;   🎨▾   Couleur du texte (\textcolor) sur la région ou le mot.
;;   ➕▾   Insérer : code, colonnes, figure, tableau, lien, en-têtes YAML.
;;   🟦▾   Encadrés MetalEmacs (tcolorbox) et callouts Quarto.
;;   ▣▾   Outils de diapositive — affiché seulement en Beamer.
;;   📚▾   Aide et dictionnaires (regroupe les quatre anciens boutons).
;;
;; Les entrées des menus réutilisent les modèles YASnippet de
;; snippets/markdown-mode, appelés par leur nom (`# name:').  Un modèle
;; absent rend son entrée inactive au lieu de provoquer une erreur.
;;
;; Raccourcis : C-c 1 … C-c 4 (niveau de titre), C-c 0 (texte normal).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'easymenu)
(require 'metal-toolbar)
(require 'metal-quarto-entete)
(require 'metal-quarto-reglages)

(declare-function yas-lookup-snippet "yasnippet")
(defvar yas-selected-text)
(defvar yas--condition-cache-timestamp)
(declare-function yas-expand-snippet "yasnippet")
(declare-function markdown-code-block-at-point-p "markdown-mode")
(declare-function metal-quarto--detect-output-format "metal-quarto")
(declare-function metal-quarto-produire-document "metal-quarto")

;;; ─── Modèles YASnippet par nom ──────────────────────────────────────

(defun metal-quarto--snippet (nom)
  "Retourner le modèle YASnippet NOM de `markdown-mode', ou nil."
  (and (require 'yasnippet nil t)
       ;; Un modèle peut porter `# condition: yas-selected-text' : la
       ;; recherche doit voir la région comme le fera le développement.
       (let ((yas-selected-text
              (and (use-region-p)
                   (buffer-substring-no-properties (region-beginning)
                                                   (region-end)))))
         ;; Tables chargées à l'activation du mode mineur (chargement
         ;; différé) ; conditions réévaluées (cache horodaté de YASnippet).
         (unless (bound-and-true-p yas-minor-mode) (yas-minor-mode 1))
         (setq yas--condition-cache-timestamp (current-time))
         (ignore-errors (yas-lookup-snippet nom 'markdown-mode t)))))

(defun metal-quarto-inserer-snippet (nom)
  "Développer le modèle YASnippet NOM au point.
Une région active devient le texte sélectionné du modèle
\(`yas-selected-text'), comme avec \\[yas-insert-snippet]."
  (let ((modele (metal-quarto--snippet nom)))
    (unless modele
      (user-error "Modèle introuvable : « %s »" nom))
    (yas-expand-snippet modele)))

(defun metal-quarto--entree-snippet (libelle nom &rest proprietes)
  "Entrée de menu LIBELLE qui développe le modèle NOM.
PROPRIETES s'ajoutent au vecteur easy-menu (:help, :active…).  Sans
:active explicite, l'entrée n'est active que si le modèle existe."
  (vconcat (list libelle `(metal-quarto-inserer-snippet ,nom))
           (if (plist-member proprietes :active)
               proprietes
             (append (list :active (and (metal-quarto--snippet nom) t))
                     proprietes))))

(defun metal-quarto--popup (titre items)
  "Afficher le menu TITRE composé d'ITEMS (format easy-menu)."
  (popup-menu (cons titre items)))

;;; ─── Format de sortie (mis en cache) ────────────────────────────────

(defvar-local metal-quarto--format-cache nil
  "Cache (TICK . FORMAT) du format de sortie du tampon.")

(defun metal-quarto--format ()
  "Format de sortie du document (beamer, pdf, html ou nil), mis en cache.
La barre est réévaluée à chaque redisplay : on ne relit le front matter
que lorsque le tampon a changé."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eql (car metal-quarto--format-cache) tick)
      (setq metal-quarto--format-cache
            (cons tick (and (fboundp 'metal-quarto--detect-output-format)
                            (ignore-errors
                              (metal-quarto--detect-output-format))))))
    (cdr metal-quarto--format-cache)))

(defun metal-quarto--beamer-p ()
  "Non nil si le document courant est une présentation Beamer."
  (eq (metal-quarto--format) 'beamer))

;;; ─── Titres ─────────────────────────────────────────────────────────

(defun metal-quarto--niveau-titre ()
  "Niveau du titre Markdown de la ligne courante, ou nil.
Une ligne commençant par `#' dans un bloc de code n'est pas un titre."
  (save-excursion
    (beginning-of-line)
    (and (looking-at "\\(#\\{1,6\\}\\)[ \t]")
         (not (and (fboundp 'markdown-code-block-at-point-p)
                   (ignore-errors (markdown-code-block-at-point-p))))
         (length (match-string 1)))))

(defun metal-quarto-titre (niveau)
  "Donner le NIVEAU de titre à la ligne courante (0 = texte normal).
Le texte et les attributs de la ligne sont conservés.  Redemander le
niveau déjà en place retire le titre (bascule)."
  (interactive "p")
  (let* ((actuel (metal-quarto--niveau-titre))
         (cible  (if (eql actuel niveau) 0 niveau))
         (debut  (line-beginning-position))
         (col    (- (point) debut))
         (ancien 0))
    (save-excursion
      (goto-char debut)
      (when (looking-at "#\\{1,6\\}[ \t]+")
        (setq ancien (- (match-end 0) (match-beginning 0)))
        (delete-region (match-beginning 0) (match-end 0)))
      (when (> cible 0)
        (insert (make-string cible ?#) " ")))
    ;; Garder le point à la même place dans le texte du titre.
    (let ((nouveau (if (> cible 0) (1+ cible) 0)))
      (goto-char (+ debut (max nouveau (+ nouveau (- col ancien))))))
    (message (if (> cible 0) "Titre de niveau %d" "Texte normal")
             cible)))

(defmacro metal-quarto--def-titre (n)
  "Définir la commande `metal-quarto-titre-N'."
  `(defun ,(intern (format "metal-quarto-titre-%d" n)) ()
     ,(if (zerop n)
          "Retirer le titre de la ligne courante (texte normal)."
        (format "Titre de niveau %d sur la ligne courante (bascule)." n))
     (interactive)
     (metal-quarto-titre ,n)))

(metal-quarto--def-titre 0)
(metal-quarto--def-titre 1)
(metal-quarto--def-titre 2)
(metal-quarto--def-titre 3)
(metal-quarto--def-titre 4)

(defun metal-quarto--libelles-titres ()
  "Libellés des niveaux 1 à 4 selon le format du document."
  (if (metal-quarto--beamer-p)
      '("Section" "Diapositive" "Bloc" "Sous-bloc")
    '("Titre 1" "Titre 2" "Titre 3" "Titre 4")))

(defun metal-quarto-menu-titres ()
  "Menu des titres et niveaux."
  (interactive)
  (let* ((libelles (metal-quarto--libelles-titres))
         (actuel   (metal-quarto--niveau-titre))
         (entree   (lambda (n)
                     (vector (format "%-14s %s" (nth (1- n) libelles)
                                     (make-string n ?#))
                             (intern (format "metal-quarto-titre-%d" n))
                             :style 'radio
                             :selected (eql actuel n)))))
    (metal-quarto--popup
     "Titres"
     (append
      (mapcar entree '(1 2 3 4))
      (list ["Texte normal" metal-quarto-titre-0
             :style radio :selected (null actuel)]
            "---"
            ["Monter d'un niveau"     markdown-promote :active actuel]
            ["Descendre d'un niveau"  markdown-demote  :active actuel]
            "---"
            ["Aller à un titre…"      imenu])))))

(defun metal-quarto--indicateur-titre ()
  "Libellé du bouton Titres : niveau de la ligne courante."
  (let ((n (metal-quarto--niveau-titre)))
    (if n (format "T%d" n) "T·")))

(defun metal-quarto--couleur-titre ()
  "Couleur du bouton Titres : accentuée sur une ligne de titre."
  (if (metal-quarto--niveau-titre) "#2471a3" "#5d6d7e"))

;;; ─── Couleur du texte ───────────────────────────────────────────────

(defconst metal-quarto-couleurs
  '(("Rouge" . "red") ("Bleu" . "blue") ("Vert" . "green!50!black")
    ("Orange" . "orange") ("Violet" . "violet") ("Gris" . "gray"))
  "Couleurs proposées : (LIBELLÉ . COULEUR xcolor).")

(defun metal-quarto-couleur (couleur)
  "Mettre la région (ou le mot au point) en COULEUR via \\textcolor.
Sans région ni mot, insère un \\textcolor vide, le point à l'intérieur."
  (interactive
   (list (cdr (assoc (completing-read "Couleur : " metal-quarto-couleurs nil t)
                     metal-quarto-couleurs))))
  (let ((bornes (cond ((use-region-p) (cons (region-beginning) (region-end)))
                      ((bounds-of-thing-at-point 'word)))))
    (if bornes
        (let ((texte (buffer-substring-no-properties (car bornes) (cdr bornes))))
          (delete-region (car bornes) (cdr bornes))
          (goto-char (car bornes))
          (insert (format "\\textcolor{%s}{%s}" couleur texte)))
      (insert (format "\\textcolor{%s}{}" couleur))
      (backward-char 1))))

(defun metal-quarto-menu-couleur ()
  "Menu des couleurs de texte."
  (interactive)
  (metal-quarto--popup
   "Couleur"
   (mapcar (lambda (c) (vector (car c) `(metal-quarto-couleur ,(cdr c))))
           metal-quarto-couleurs)))

;;; ─── Insérer ────────────────────────────────────────────────────────

(defun metal-quarto--sans-front-matter-p ()
  "Non nil si le tampon ne commence pas par un front matter YAML."
  (save-excursion
    (goto-char (point-min))
    (not (looking-at "---[ \t]*$"))))

(defun metal-quarto-menu-inserer ()
  "Menu d'insertion d'éléments structurés."
  (interactive)
  (let ((region (use-region-p))
        (vierge (metal-quarto--sans-front-matter-p)))
    (metal-quarto--popup
     "Insérer"
     (list
      ["Bloc de code…" metal-quarto-code-block]
      (metal-quarto--entree-snippet "Bloc de code avec titre" "Code")
      (metal-quarto--entree-snippet "Code d'un fichier inclus" "Code - Fichier inclus")
      "---"
      (metal-quarto--entree-snippet "Deux colonnes" "Colonnes")
      (metal-quarto--entree-snippet "Figure (légende + renvoi)"
                                   "Figure - Image avec légende et référence")
      (metal-quarto--entree-snippet "Image du fichier sélectionné" "Image"
                                   :active region
                                   :help "Sélectionner d'abord le nom du fichier")
      (metal-quarto--entree-snippet "Attributs d'image" "Image - Attributs")
      "---"
      (metal-quarto--entree-snippet "Tableau (tblr)" "Table LaTeX (tblr)")
      (metal-quarto--entree-snippet "Lien vers le fichier sélectionné"
                                   "Document - Lien fichier"
                                   :active region
                                   :help "Sélectionner d'abord le chemin du fichier")
      "---"
      (metal-quarto--entree-snippet "Texte centré" "Centrer")
      (metal-quarto--entree-snippet "Espacement vertical" "Espacement vertical")
      (metal-quarto--entree-snippet "Taille de police précise" "Police - Taille précise")
      "---"
      (list "En-tête YAML"
            (vector "Document PDF" 'metal-quarto-entete-document :active vierge)
            (vector "Présentation Beamer" 'metal-quarto-entete-presentation
                    :active vierge))))))

(declare-function metal-quarto--modele "metal-quarto")
(declare-function metal-quarto-front-matter-document "metal-quarto")

(defun metal-quarto-entete-document ()
  "Insérer en tête de fichier la front matter du modèle de document.
Même source que le tableau de bord : `modeles/quarto-config.txt'."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (insert (metal-quarto-front-matter-document))))

(defun metal-quarto-entete-presentation ()
  "Insérer en tête de fichier la front matter du modèle de présentation.
Même source que le tableau de bord : `modeles/presentation-quarto.txt',
dont seule la front matter (jusqu'au second `---') est reprise."
  (interactive)
  (let* ((modele (metal-quarto--modele "presentation-quarto.txt"))
         (fin (and (string-match "\\`---[ \t]*\n" modele)
                   (string-match "^---[ \t]*$" modele (match-end 0)))))
    (save-excursion
      (goto-char (point-min))
      (insert (if fin (concat (substring modele 0 (match-end 0)) "\n\n")
                modele)))))

;;; ─── Encadrés ───────────────────────────────────────────────────────

(defun metal-quarto-menu-encadres ()
  "Menu des encadrés : boîtes MetalEmacs et callouts Quarto."
  (interactive)
  (metal-quarto--popup
   "Encadrés"
   (list
    (metal-quarto--entree-snippet "ℹ  Remarque"  "Encadré - Remarque")
    (metal-quarto--entree-snippet "✔  Astuce"    "Encadré - Astuce")
    (metal-quarto--entree-snippet "⚠  Attention" "Encadré - Attention")
    (metal-quarto--entree-snippet "❗ Important"  "Encadré - Important")
    "---"
    (list "Callouts Quarto"
          ["Note"      metal-quarto-callout-note]
          ["Conseil"   metal-quarto-callout-tip]
          ["Mise en garde" metal-quarto-callout-warning]
          ["Important" metal-quarto-callout-important]
          ["Précaution" metal-quarto-callout-caution]))))

;;; ─── Diapositives (Beamer) ──────────────────────────────────────────

(defun metal-quarto-diapo-shrink ()
  "Basculer l'attribut {.shrink} sur le titre de la diapositive courante.
La diapositive est le titre `## ' (slide-level 2) qui précède le point.
Un bloc d'attributs déjà présent ({#id .classe}) est complété."
  (interactive)
  (save-excursion
    (end-of-line)
    (unless (re-search-backward "^##[ \t]" nil t)
      (user-error "Aucun titre de diapositive (##) avant le point"))
    (let ((fin (line-end-position)))
      (cond
       ((re-search-forward "[ \t]*\\.shrink\\b" fin t)
        (replace-match "")
        ;; Bloc devenu vide : le retirer.
        (goto-char (line-beginning-position))
        (when (re-search-forward "[ \t]*{[ \t]*}[ \t]*$" fin t)
          (replace-match ""))
        (message "Réduction automatique retirée"))
       ((re-search-forward "{\\([^}]*\\)}[ \t]*$" fin t)
        (goto-char (match-end 1))
        (insert " .shrink")
        (message "Réduction automatique activée"))
       (t
        (end-of-line)
        (skip-chars-backward " \t")
        (insert " {.shrink}")
        (message "Réduction automatique activée"))))))

(defun metal-quarto-menu-diapo ()
  "Menu des outils de diapositive Beamer."
  (interactive)
  (metal-quarto--popup
   "Diapositive"
   (list
    ["Nouvelle diapositive" metal-quarto-titre-2]
    (metal-quarto--entree-snippet "Renvoi à la diapositive suivante" "Diapo suivante")
    ["Réduire si le contenu déborde {.shrink}" metal-quarto-diapo-shrink]
    "---"
    (metal-quarto--entree-snippet "Code en petite police (\\tiny)" "Code - Police (\\tiny)")
    (metal-quarto--entree-snippet "Taille de police précise" "Police - Taille précise")
    (metal-quarto--entree-snippet "Espacement vertical" "Espacement vertical")
    (metal-quarto--entree-snippet "Deux colonnes" "Colonnes")
    "---"
    (metal-quarto--entree-snippet "Flèche Prolog (swiarrow)" "SwiArrow"))))

;;; ─── Aide ───────────────────────────────────────────────────────────

(defun metal-quarto-menu-aide ()
  "Menu d'aide : dictionnaires et documentation."
  (interactive)
  (metal-quarto--popup
   "Aide"
   (list
    ["Wiktionnaire (mot au point)" search-wiktionary]
    ["Wikipédia (mot au point)"    search-wikipedia]
    "---"
    ["Documentation Quarto"        metal-quarto-doc-buffer]
    ["Aide-mémoire QMD"            metal-quarto-open-cheatsheet])))

;;; ─── Production HTML ─────────────────────────────────────────────────

(defvar metal-dashboard-quarto-ressources-dir)

(defconst metal-quarto--marque-filtre-html "quarto.Callout"
  "Chaîne présente dans un `metal-boites.lua' qui gère la sortie HTML.")

(defun metal-quarto--filtre-a-jour (dir)
  "S'assurer que `metal-boites.lua' de DIR sait produire du HTML.
Les copies faites par le tableau de bord avant cette version ne gèrent
que LaTeX : en HTML, les encadrés y perdent cadre et titre.  On propose
alors de remplacer la copie locale par celle de la distribution."
  (let* ((source (expand-file-name
                  "metal-boites.lua"
                  (if (boundp 'metal-dashboard-quarto-ressources-dir)
                      metal-dashboard-quarto-ressources-dir
                    (expand-file-name "quarto/" user-emacs-directory))))
         (cible (expand-file-name "metal-boites.lua" dir)))
    (when (and (file-exists-p source) (file-exists-p cible)
               (not (with-temp-buffer
                      (insert-file-contents cible)
                      (search-forward metal-quarto--marque-filtre-html nil t)))
               (y-or-n-p "metal-boites.lua de ce dossier ne gère pas le HTML. \
Le mettre à jour ? "))
      (copy-file source cible t)
      (message "📋 metal-boites.lua mis à jour"))))

;;; ─── Thèmes des présentations ───────────────────────────────────────

(defconst metal-quarto-themes-beamer
  '("metropolis" "Madrid" "Boadilla" "CambridgeUS" "Copenhagen"
    "Warsaw" "Singapore" "Berlin" "default")
  "Thèmes Beamer proposés au menu PDF (tous livrés avec TeX Live).")

(defconst metal-quarto-themes-revealjs
  '("default" "simple" "serif" "sky" "solarized" "beige"
    "moon" "night" "dark" "league" "blood")
  "Thèmes reveal.js natifs de Quarto proposés au menu HTML.")

(defconst metal-quarto-cle-theme-html "metal-theme-html"
  "Clé de l'en-tête où est rangé le thème du diaporama HTML.
Quarto ignore cette clé : la ranger sous `format: revealjs:' ferait de
revealjs un format déclaré, ce qui changerait le rendu par défaut (F8).")

(defun metal-quarto--fin-front-matter ()
  "Position du début de la ligne `---' qui ferme le front matter, ou nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (looking-at "---[ \t]*$")
        (forward-line 1)
        (when (re-search-forward "^\\(---\\|\\.\\.\\.\\)[ \t]*$" nil t)
          (match-beginning 0))))))

(defun metal-quarto--bloc-beamer ()
  "Bornes (DÉBUT . FIN) du bloc `  beamer:' du front matter, ou nil.
DÉBUT est la fin de la ligne `beamer:' ; FIN, le début de la première
ligne moins indentée qui suit."
  (let ((fin-fm (metal-quarto--fin-front-matter)))
    (when fin-fm
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^\\( +\\)beamer:[ \t]*$" fin-fm t)
          (let ((retrait (length (match-string 1)))
                (debut (point)))
            (forward-line 1)
            (while (and (< (point) fin-fm)
                        (or (looking-at "[ \t]*$")
                            (and (looking-at "\\( *\\)")
                                 (> (length (match-string 1)) retrait))))
              (forward-line 1))
            (cons debut (point))))))))

(defun metal-quarto--theme-beamer ()
  "Thème Beamer déclaré dans l'en-tête, ou nil (thème par défaut)."
  (let ((bloc (metal-quarto--bloc-beamer)))
    (when bloc
      (save-excursion
        (goto-char (car bloc))
        (when (re-search-forward "^ +theme:[ \t]*\"?\\([^\"\n]+?\\)\"?[ \t]*$"
                                 (cdr bloc) t)
          (match-string-no-properties 1))))))

(defun metal-quarto--theme-html ()
  "Thème reveal.js retenu dans l'en-tête, ou \"default\"."
  (let ((fin-fm (metal-quarto--fin-front-matter)))
    (or (and fin-fm
             (save-excursion
               (goto-char (point-min))
               (when (re-search-forward
                      (concat "^" metal-quarto-cle-theme-html
                              ":[ \t]*\"?\\([^\"\n]+?\\)\"?[ \t]*$")
                      fin-fm t)
                 (match-string-no-properties 1))))
        "default")))

(defun metal-quarto--ecrire-theme-beamer (theme)
  "Écrire THEME comme thème Beamer dans l'en-tête.
La couleur de lien `mDarkTeal' n'existe qu'avec metropolis : en quittant
ce thème, elle devient `teal' (standard) ; en y revenant, l'inverse."
  (let ((bloc (metal-quarto--bloc-beamer)))
    (unless bloc
      (user-error "Aucune section « beamer: » dans l'en-tête"))
    (save-excursion
      (goto-char (car bloc))
      (if (re-search-forward "^\\( +\\)theme:.*$" (cdr bloc) t)
          (replace-match (concat "\\1theme: " theme) t)
        (goto-char (car bloc))
        (insert "\n    theme: " theme))
      (let ((bloc (metal-quarto--bloc-beamer))
            (de (if (equal theme "metropolis") "teal" "mDarkTeal"))
            (vers (if (equal theme "metropolis") "mDarkTeal" "teal")))
        (goto-char (car bloc))
        (when (re-search-forward (concat "^\\( +linkcolor:[ \t]*\\)" de "[ \t]*$")
                                 (cdr bloc) t)
          (replace-match (concat "\\1" vers) t))))))

(defun metal-quarto--ecrire-theme-html (theme)
  "Ranger THEME comme thème du diaporama HTML dans l'en-tête."
  (let ((fin-fm (metal-quarto--fin-front-matter)))
    (unless fin-fm
      (user-error "Ce document n'a pas d'en-tête YAML"))
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward (concat "^" metal-quarto-cle-theme-html ":.*$")
                             fin-fm t)
          (replace-match (concat metal-quarto-cle-theme-html ": " theme) t t)
        (goto-char fin-fm)
        (insert metal-quarto-cle-theme-html ": " theme "\n")))))

(defconst metal-quarto--extensions-auxiliaires
  '("aux" "nav" "snm" "toc" "out" "vrb" "log")
  "Fichiers intermédiaires LaTeX/Beamer laissés à côté du document.
Ils sont relus au rendu suivant : produits sous un autre thème, ils
peuvent faire échouer la compilation.")

(defun metal-quarto--nettoyer-auxiliaires ()
  "Supprimer les fichiers intermédiaires LaTeX du document courant."
  (when buffer-file-name
    (let ((base (file-name-sans-extension buffer-file-name)))
      (dolist (ext metal-quarto--extensions-auxiliaires)
        (let ((f (concat base "." ext)))
          (when (file-exists-p f)
            (ignore-errors (delete-file f))))))))

(defun metal-quarto--production-en-cours-p ()
  "Non nil si un rendu Quarto lancé par MetalEmacs tourne encore."
  (seq-some (lambda (p)
              (and (process-live-p p)
                   (string-prefix-p "quarto-render" (process-name p))))
            (process-list)))

(defun metal-quarto-theme-pdf (theme)
  "Choisir THEME pour le PDF Beamer, puis produire le PDF.
Les fichiers intermédiaires de la compilation précédente (.nav, .snm,
.toc…) sont d'abord supprimés : produits sous l'ancien thème, ils font
échouer le premier rendu sous le nouveau."
  (interactive (list (completing-read "Thème Beamer : "
                                      metal-quarto-themes-beamer nil t)))
  (when (metal-quarto--production-en-cours-p)
    (user-error "Une production est déjà en cours — attendez qu'elle se termine"))
  (metal-quarto--ecrire-theme-beamer theme)
  (metal-quarto--nettoyer-auxiliaires)
  (metal-quarto-produire-document))

(defun metal-quarto-theme-html (theme)
  "Choisir THEME pour le diaporama HTML, puis le produire."
  (interactive (list (completing-read "Thème reveal.js : "
                                      metal-quarto-themes-revealjs nil t)))
  (when (metal-quarto--production-en-cours-p)
    (user-error "Une production est déjà en cours — attendez qu'elle se termine"))
  (metal-quarto--ecrire-theme-html theme)
  (metal-quarto-produire-html))

(defun metal-quarto-menu-pdf ()
  "Menu du bouton PDF d'une présentation : produire, ou changer de thème."
  (interactive)
  (let ((actuel (or (metal-quarto--theme-beamer) "default")))
    (metal-quarto--popup
     "PDF"
     (append
      (list (vector (format "Produire le PDF (%s)" actuel)
                    'metal-quarto-produire-document)
            "---")
      (mapcar (lambda (th)
                (vector th `(metal-quarto-theme-pdf ,th)
                        :style 'radio :selected (equal th actuel)))
              metal-quarto-themes-beamer)))))

(defun metal-quarto-menu-html ()
  "Menu du bouton HTML d'une présentation : produire, ou changer de thème."
  (interactive)
  (let ((actuel (metal-quarto--theme-html)))
    (metal-quarto--popup
     "HTML"
     (append
      (list (vector (format "Produire le diaporama (%s)" actuel)
                    'metal-quarto-produire-html)
            "---")
      (mapcar (lambda (th)
                (vector th `(metal-quarto-theme-html ,th)
                        :style 'radio :selected (equal th actuel)))
              metal-quarto-themes-revealjs)))))

(defun metal-quarto--options-diaporama ()
  "Écrire un fichier de métadonnées temporaire pour le diaporama reveal.js.
Retourne son chemin.  Le thème doit passer par `format: revealjs:' :
`-M theme:' n'est que de la métadonnée Pandoc.  Un en-tête qui déclare
lui-même `format: revealjs:' garde la priorité (les métadonnées d'un
--metadata-file passent après celles du document)."
  (let ((theme (metal-quarto--theme-html))
        (fichier (make-temp-file "metal-revealjs-" nil ".yml")))
    (with-temp-file fichier
      (insert "format:\n  revealjs:\n"
              "    theme: " theme "\n"
              "    slide-number: true\n"
              "    format-links: false\n"))
    fichier))

(defun metal-quarto-produire-html ()
  "Produire la version HTML du fichier Quarto courant, puis l'ouvrir.
Une présentation (en-tête `beamer') devient un diaporama reveal.js ; tout
autre document, une page web (`--to html').  Dans les deux cas, les options
propres au PDF ou à Beamer sont ignorées, les encadrés deviennent des
callouts Quarto et le LaTeX de `header-includes' est écarté (voir
`metal-boites.lua').  Ne dépend pas de TinyTeX.

Le diaporama prend le thème reveal.js natif choisi au menu HTML (clé
`metal-theme-html' de l'en-tête), « default » à défaut.
Dans le diaporama : flèches ou Espace pour avancer, F plein écran,
Échap vue d'ensemble, S vue présentateur (notes `::: {.notes}').

Le rendu est asynchrone.  En cas de succès, la page s'ouvre dans le
navigateur ; en cas d'échec, le buffer `*Quarto Render*' reste visible."
  (interactive)
  (unless buffer-file-name
    (user-error "Ce tampon n'est associé à aucun fichier"))
  (save-buffer)
  (let* ((file       buffer-file-name)
         (dir        (file-name-directory file))
         (name       (file-name-nondirectory file))
         (html       (concat (file-name-sans-extension file) ".html"))
         (diaporama  (metal-quarto--beamer-p))
         (cible      (if diaporama "revealjs" "html"))
         (quoi       (if diaporama
                         (format "diaporama HTML (%s)" (metal-quarto--theme-html))
                       "page HTML"))
         (options    (and diaporama (metal-quarto--options-diaporama)))
         (default-directory dir)
         (output-buf (get-buffer-create "*Quarto Render*")))
    (metal-quarto--filtre-a-jour dir)
    (with-current-buffer output-buf
      (let ((inhibit-read-only t)) (erase-buffer)))
    (message "Quarto: rendu du %s de %s..." quoi name)
    (make-process
     :name "quarto-render-html"
     :buffer output-buf
     ;; format-links:false : sans lui, Quarto ajoute à la page un encadré
     ;; « Autres formats » pointant vers le PDF déclaré dans l'en-tête,
     ;; même si ce PDF n'a jamais été produit (lien mort).
     :command (append (list "quarto" "render" name "--to" cible
                            "-M" "format-links:false")
                      (and options (list "--metadata-file" options)))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when (and options (file-exists-p options))
           (delete-file options))
         (let ((code (process-exit-status proc)))
           (if (zerop code)
               (progn
                 (when (buffer-live-p output-buf)
                   (kill-buffer output-buf))
                 (when (fboundp 'metal-quarto--rafraichir-treemacs)
                   (metal-quarto--rafraichir-treemacs))
                 (if (file-exists-p html)
                     (progn (browse-url-of-file html)
                            (message "Quarto: %s ouvert (%s)%s" quoi
                                     (file-name-nondirectory html)
                                     (if diaporama
                                         " — F plein écran, S présentateur"
                                       "")))
                   (message "Quarto: rendu HTML terminé pour %s" name)))
             (message "Quarto: ERREUR (code %d) pour %s" code name)
             (when (buffer-live-p output-buf)
               (display-buffer output-buf)))))))))

;;; ─── La barre ───────────────────────────────────────────────────────

(defconst metal-quarto-icone-diapositive
  (concat
   "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 36 36'>"
   "<rect x='2' y='6' width='32' height='22' rx='2.5' fill='#E1E8ED'"
   " stroke='#66757F' stroke-width='1.5'/>"
   "<rect x='2.75' y='6.75' width='30.5' height='6' rx='1.8' fill='#2B6C8F'/>"
   "<rect x='7' y='16' width='15' height='2.4' rx='1.2' fill='#8899A6'/>"
   "<rect x='7' y='21' width='11' height='2.4' rx='1.2' fill='#8899A6'/>"
   "<circle cx='27' cy='20.5' r='3.6' fill='#F4900C'/>"
   "</svg>")
  "Pictogramme « diapositive » du bouton Beamer (aucun emoji ne convient).
Style et couleurs de Twemoji, pour s'accorder aux autres icônes.")

(defun metal-quarto-toolbar-format ()
  "Construire la barre d'outils Quarto via `metal-toolbar-build'.
Les boutons marqués :menu ouvrent un menu (indiqués par ▾)."
  (metal-toolbar-build
   (append
    '((:char metal-quarto--indicateur-titre :style bold
             :color metal-quarto--couleur-titre :menu t
             :tooltip "Titres et niveaux (C-c 1…4, C-c 0)"
             :command metal-quarto-menu-titres)
      (:sep)
      (:char "G" :style bold      :color "#2c3e50"
             :tooltip "Gras" :command metal-quarto-bold)
      (:char "I" :style italic    :color "#2c3e50"
             :tooltip "Italique" :command metal-quarto-italic)
      (:char "S" :style underline :color "#2980b9"
             :tooltip "Souligné" :command metal-quarto-underline)
      (:char "B" :style strike    :color "#c0392b"
             :tooltip "Barré" :command metal-quarto-strike)
      (:char "</>" :color "#8e44ad"
             :tooltip "Code en ligne" :command metal-quarto-code)
      (:emoji "🎨" :menu t :tooltip "Couleur du texte"
              :command metal-quarto-menu-couleur)
      (:sep)
      (:emoji "➕" :menu t
              :tooltip "Insérer : code, colonnes, figure, tableau…"
              :command metal-quarto-menu-inserer)
      (:emoji "🟦" :scale 0.78 :menu t :tooltip "Encadrés (remarque, astuce, attention, important)"
              :command metal-quarto-menu-encadres)
      (:emoji "🔗" :tooltip "Références (note, citation, image, renvoi)"
              :command metal-quarto-references))
    (when (metal-quarto--beamer-p)
      `((:svg ,metal-quarto-icone-diapositive :repli "🖥" :menu t
              :tooltip "Diapositive (Beamer)"
              :command metal-quarto-menu-diapo)))
    '((:sep)
      (:emoji "⚙️" :tooltip "Réglages de mise en page (papier, marges, thème…)"
              :command metal-quarto-reglages))
    ;; Présentation : PDF et HTML deviennent des menus (produire / thème).
    (if (metal-quarto--beamer-p)
        '((:char "PDF" :style bold :color "#c0392b" :scale 0.7 :menu t
                 :tooltip "PDF Beamer : produire ou changer de thème"
                 :command metal-quarto-menu-pdf)
          (:char "HTML" :style bold :color "#1f6f9f" :scale 0.7 :menu t
                 :tooltip "Diaporama HTML : produire ou changer de thème"
                 :command metal-quarto-menu-html))
      '((:char "PDF" :style bold :color "#c0392b" :scale 0.7
               :tooltip "Produire le PDF (F8)"
               :command metal-quarto-produire-document)
        (:char "HTML" :style bold :color "#1f6f9f" :scale 0.7
               :tooltip "Produire la page HTML et l'ouvrir"
               :command metal-quarto-produire-html)))
    '((:sep)
      (:emoji "📚" :menu t :tooltip "Aide et dictionnaires"
              :command metal-quarto-menu-aide)))
   :agent t
   :snippets nil))

;;; ─── Raccourcis ─────────────────────────────────────────────────────

(with-eval-after-load 'markdown-mode
  (with-no-warnings
    (define-key markdown-mode-map (kbd "C-c 0") #'metal-quarto-titre-0)
    (define-key markdown-mode-map (kbd "C-c 1") #'metal-quarto-titre-1)
    (define-key markdown-mode-map (kbd "C-c 2") #'metal-quarto-titre-2)
    (define-key markdown-mode-map (kbd "C-c 3") #'metal-quarto-titre-3)
    (define-key markdown-mode-map (kbd "C-c 4") #'metal-quarto-titre-4)))

(provide 'metal-quarto-barre)
;;; metal-quarto-barre.el ends here
