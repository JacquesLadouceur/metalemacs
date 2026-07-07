;;; metal-nettoyer.el --- Nettoyage des caractères spéciaux et reflow -*- lexical-binding: t; -*-

;; Auteur : Jacques Ladouceur
;; Description : Deux outils complémentaires de nettoyage de tampon.
;;
;;   1. `metal-nettoyer-buffer' — suppression des caractères invisibles ou
;;      problématiques (espaces insécables, espaces de largeur nulle, NUL,
;;      BOM, séparateurs de ligne exotiques).  N'altère PAS le fil dur des
;;      paragraphes : opération purement caractère par caractère.
;;
;;   2. `metal-nettoyer' — reflow des paragraphes : fusionne les lignes
;;      brisées d'un paragraphe en une seule ligne logique et normalise les
;;      espaces insécables, en préservant les structures du document (blocs
;;      de code, listes, titres, tables, callouts).  S'adapte au format du
;;      document (Quarto/Markdown, Org, texte brut) et produit un rapport.

;;; Commentary:

;; Ces deux fonctions répondent à des besoins distincts :
;;
;; - `metal-nettoyer-buffer' corrige les caractères qui cassent la recherche
;;   incrémentale, `consult-line', la compilation Quarto/LaTeX ou l'affichage,
;;   SANS toucher au fil dur des paragraphes.
;;
;; - `metal-nettoyer' réécrit au contraire la mise en forme : il aplatit les
;;   paragraphes à fil dur en lignes logiques uniques (pour qui préfère le
;;   `visual-line-mode' au retour à la ligne fixe), tout en respectant la
;;   syntaxe du format courant.  À utiliser exprès, sur région ou buffer.

;;; Code:

(require 'cl-lib)

(defgroup metal-nettoyer nil
  "Nettoyage des caractères spéciaux et reflow des paragraphes."
  :group 'metal
  :prefix "metal-nettoyer-")


;;; ----------------------------------------------------------------------
;;; Partie 1 : suppression des caractères invisibles (sans reflow)
;;; ----------------------------------------------------------------------

(defcustom metal-nettoyer-remplacer-insecables t
  "Si non-nil, remplacer les espaces insécables par des espaces ordinaires.
Concerne U+00A0 (espace insécable) et U+202F (espace fine insécable).
Mettre à nil pour conserver la typographie française posée volontairement
(espaces insécables avant « : ; ? ! » ou dans les guillemets)."
  :type 'boolean
  :group 'metal-nettoyer)

(defconst metal-nettoyer--table-suppression
  '((?\x0000 . "caractère NUL")
    (?\xFEFF . "marque d'ordre des octets (BOM)")
    (?\x200B . "espace de largeur nulle")
    (?\x200C . "antiliant de largeur nulle")
    (?\x200D . "liant de largeur nulle")
    (?\x00AD . "trait d'union conditionnel")
    (?\x2060 . "liant insécable de largeur nulle"))
  "Caractères invisibles à supprimer purement et simplement.
Liste d'éléments (CARACTÈRE . DESCRIPTION).")

(defconst metal-nettoyer--table-remplacement-ligne
  '((?\x2028 . "séparateur de ligne Unicode")
    (?\x0085 . "saut de ligne suivant (NEL)"))
  "Séparateurs de ligne exotiques à remplacer par un saut de ligne ordinaire.")

(defun metal-nettoyer--compter-et-remplacer (cible remplacement)
  "Remplacer toutes les occurrences de CIBLE par REMPLACEMENT dans le tampon.
CIBLE est un caractère ; REMPLACEMENT une chaîne (éventuellement vide).
Retourne le nombre d'occurrences traitées."
  (let ((n 0))
    (save-excursion
      (goto-char (point-min))
      (while (search-forward (char-to-string cible) nil t)
        (replace-match remplacement nil t)
        (setq n (1+ n))))
    n))

(defun metal-nettoyer-caracteres ()
  "Nettoyer les caractères invisibles ou problématiques du tampon.
Supprime NUL, BOM, espaces de largeur nulle, traits d'union conditionnels ;
normalise les séparateurs de ligne exotiques en saut de ligne ordinaire ;
remplace optionnellement les espaces insécables (voir
`metal-nettoyer-remplacer-insecables').  Ne fusionne PAS les paragraphes :
le fil dur et la mise en forme restent intacts.  Préserve le point et
respecte `undo'."
  (interactive)
  (when buffer-read-only
    (user-error "Le tampon est en lecture seule"))
  (let ((total 0)
        (details '()))
    ;; Suppression pure.
    (dolist (entree metal-nettoyer--table-suppression)
      (let ((n (metal-nettoyer--compter-et-remplacer (car entree) "")))
        (when (> n 0)
          (setq total (+ total n))
          (push (format "%d %s" n (cdr entree)) details))))
    ;; Séparateurs de ligne exotiques → saut de ligne ordinaire.
    (dolist (entree metal-nettoyer--table-remplacement-ligne)
      (let ((n (metal-nettoyer--compter-et-remplacer (car entree) "\n")))
        (when (> n 0)
          (setq total (+ total n))
          (push (format "%d %s" n (cdr entree)) details))))
    ;; Espaces insécables → espace ordinaire (optionnel).
    (when metal-nettoyer-remplacer-insecables
      (dolist (car-insec '((?\x00A0 . "espace insécable")
                           (?\x202F . "espace fine insécable")))
        (let ((n (metal-nettoyer--compter-et-remplacer (car car-insec) " ")))
          (when (> n 0)
            (setq total (+ total n))
            (push (format "%d %s" n (cdr car-insec)) details)))))
    (if (= total 0)
        (message "Aucun caractère spécial à nettoyer.")
      (message "Nettoyage : %d caractère(s) traité(s) — %s."
               total
               (mapconcat #'identity (nreverse details) ", ")))))


;;; ----------------------------------------------------------------------
;;; Partie 2 : reflow des paragraphes (paramétré par format, avec rapport)
;;; ----------------------------------------------------------------------

;; Chaque format déclare comment reconnaître ses structures à préserver.
;; Un « style » est un plist :
;;   :nom            chaîne lisible pour le rapport
;;   :code-bascules  fonction (bloc) -> entier : nombre de délimiteurs de
;;                   bloc de code (en tête de ligne) dans BLOC.  Un nombre
;;                   IMPAIR bascule l'état « dans bloc de code ».  Compter
;;                   (plutôt que renvoyer un booléen) gère le cas d'un bloc
;;                   de code contenant des lignes vides, scindé en plusieurs
;;                   morceaux par `split-string' : le morceau portant le
;;                   délimiteur ouvrant OU fermant a un compte impair et
;;                   bascule ; un morceau purement interne a un compte de 0.
;;   :structure-p    fonction (tête-de-bloc) -> non-nil si bloc structurel
;;                   (liste, titre, table, callout…) à préserver intact.
;;
;; tête-de-bloc = le bloc avec ses espaces de gauche retirés.

(defun metal-nettoyer--compter-delimiteurs (bloc delim)
  "Nombre de lignes de BLOC débutant par DELIM (espaces de gauche tolérés).
Un délimiteur de bloc de code (``` ou #+begin/#+end) n'est valide qu'en
tête de ligne ; on évite ainsi de compter un ``` apparaissant en milieu
de prose."
  (let ((n 0)
        (re (concat "^[[:space:]]*" (regexp-quote delim))))
    (dolist (ligne (split-string bloc "\n"))
      (when (string-match-p re ligne)
        (setq n (1+ n))))
    n))

(defun metal-nettoyer--style-quarto ()
  "Style de préservation pour Quarto / Markdown.
Blocs de code délimités par ``` ; structures = - * + # | : (callouts :::)."
  (list
   :nom "Quarto/Markdown"
   :code-bascules
   (lambda (bloc) (metal-nettoyer--compter-delimiteurs bloc "```"))
   :structure-p
   (lambda (tete) (string-match-p "\\`[-*+#|:]" tete))))

(defun metal-nettoyer--style-org ()
  "Style de préservation pour Org.
Blocs délimités par #+begin_… / #+end_… ; structures = * - + | et #+….
Chaque ligne #+begin_… ou #+end_… compte comme un délimiteur ; un bloc
en contenant un nombre impair bascule l'état « dans bloc de code »."
  (list
   :nom "Org"
   :code-bascules
   (lambda (bloc)
     (+ (metal-nettoyer--compter-delimiteurs bloc "#+begin")
        (metal-nettoyer--compter-delimiteurs bloc "#+BEGIN")
        (metal-nettoyer--compter-delimiteurs bloc "#+end")
        (metal-nettoyer--compter-delimiteurs bloc "#+END")))
   :structure-p
   (lambda (tete)
     ;; Titres (*), listes (- + et * en début), tables (|), mots-clés (#+),
     ;; drawers (:NOM:).
     (string-match-p "\\`\\([*+|-]\\|#\\+\\|:[A-Za-z]\\)" tete))))

(defun metal-nettoyer--style-texte ()
  "Style de préservation pour texte brut.
Aucun bloc de code ; les listes à puces (- * +) sont préservées pour
éviter d'agglomérer des éléments distincts."
  (list
   :nom "Texte brut"
   :code-bascules
   (lambda (_bloc) 0)
   :structure-p
   (lambda (tete) (string-match-p "\\`[-*+]" tete))))

(defun metal-nettoyer--detecter-style ()
  "Retourner le style de préservation adapté au `major-mode' courant."
  (cond
   ((derived-mode-p 'org-mode)
    (metal-nettoyer--style-org))
   ((derived-mode-p 'markdown-mode 'gfm-mode)
    (metal-nettoyer--style-quarto))
   ;; poly-markdown / markdown-ts ne dérivent pas toujours de markdown-mode :
   ;; on se rabat sur le nom de mode et l'extension .qmd / .md.
   ((or (and (symbolp major-mode)
             (string-match-p "markdown" (symbol-name major-mode)))
        (and buffer-file-name
             (string-match-p "\\.\\(qmd\\|md\\|markdown\\)\\'"
                             buffer-file-name)))
    (metal-nettoyer--style-quarto))
   (t
    (metal-nettoyer--style-texte))))

(defun metal-reformer-paragraphes (&optional debut fin)
  "Reflow des paragraphes du buffer, ou de la région si elle est active.
Remplace les espaces insécables par des espaces ordinaires et fusionne les
lignes brisées des paragraphes de texte ordinaire en une seule ligne
logique.  Les structures du document (blocs de code, listes, titres, tables,
callouts) sont préservées intactes ; leur reconnaissance s'adapte au format
courant (Quarto/Markdown, Org, texte brut).

Produit un rapport détaillé dans le tampon *Rapport nettoyage MetalEmacs*.

À distinguer de `metal-nettoyer-buffer', qui ne touche pas au fil dur."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (list (point-min) (point-max))))
  (when buffer-read-only
    (user-error "Le tampon est en lecture seule"))
  (let* ((sur-region (use-region-p))
         (debut (or debut (point-min)))
         (fin (or fin (point-max)))
         (style (metal-nettoyer--detecter-style))
         (nom-style (plist-get style :nom))
         (code-bascules (plist-get style :code-bascules))
         (structure-p (plist-get style :structure-p))
         (texte-orig (buffer-substring-no-properties debut fin))
         ;; Compteurs pour le rapport.
         (n-insecables (cl-count ?\u00a0 texte-orig))
         (n-fines (cl-count ?\u202f texte-orig))
         (n-blocs 0)
         (n-paragraphes-fusionnes 0)
         (n-lignes-eliminees 0)
         (n-code 0)
         (n-structure 0)
         ;; Normalisation des insécables (U+00A0 et U+202F).
         (texte (replace-regexp-in-string "[\u00a0\u202f]" " " texte-orig))
         (blocs (split-string texte "\n[[:space:]]*\n"))
         (dans-bloc-code nil)
         (resultat '()))
    (dolist (bloc blocs)
      (setq n-blocs (1+ n-blocs))
      (let* ((tete (string-trim-left bloc))
             (bascules (funcall code-bascules bloc)))
        (cond
         ;; Bloc portant un nombre impair de délimiteurs : bascule l'état.
         ;; On préserve le bloc tel quel (il contient une frontière de code).
         ((cl-oddp bascules)
          (setq dans-bloc-code (not dans-bloc-code))
          (setq n-code (1+ n-code))
          (push bloc resultat))
         ;; À l'intérieur d'un bloc de code : intact.
         (dans-bloc-code
          (setq n-code (1+ n-code))
          (push bloc resultat))
         ;; Bloc autonome contenant ouverture ET fermeture (compte pair > 0)
         ;; alors qu'on est hors code : on le préserve intact aussi.
         ((> bascules 0)
          (setq n-code (1+ n-code))
          (push bloc resultat))
         ;; Structure du document (liste, titre, table, callout) : intacte.
         ((funcall structure-p tete)
          (setq n-structure (1+ n-structure))
          (push bloc resultat))
         ;; Paragraphe ordinaire : fusion des lignes brisées.
         (t
          (let* ((lignes (split-string bloc "\n"))
                 (nb (length lignes)))
            (when (> nb 1)
              (setq n-paragraphes-fusionnes (1+ n-paragraphes-fusionnes))
              (setq n-lignes-eliminees (+ n-lignes-eliminees (1- nb))))
            (push (mapconcat #'string-trim lignes " ") resultat))))))
    ;; Réécriture du texte nettoyé.
    (let ((texte-propre (mapconcat #'identity (nreverse resultat) "\n\n")))
      (save-excursion
        (delete-region debut fin)
        (goto-char debut)
        (insert texte-propre)))
    ;; Rapport.
    (let ((total-insec (+ n-insecables n-fines)))
      (with-current-buffer (get-buffer-create "*Rapport nettoyage MetalEmacs*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Rapport de nettoyage — reflow des paragraphes\n")
          (insert "=============================================\n\n")
          (insert (format "Format détecté    : %s\n" nom-style))
          (insert (format "Portée            : %s\n"
                          (if sur-region "région sélectionnée" "buffer entier")))
          (insert (format "Blocs analysés    : %d\n\n" n-blocs))
          (insert "Modifications\n")
          (insert "-------------\n")
          (insert (format "Espaces insécables remplacées       : %d"
                          total-insec))
          (when (> total-insec 0)
            (insert (format "  (dont %d fines U+202F)" n-fines)))
          (insert "\n")
          (insert (format "Paragraphes fusionnés               : %d\n"
                          n-paragraphes-fusionnes))
          (insert (format "Lignes brisées éliminées            : %d\n\n"
                          n-lignes-eliminees))
          (insert "Préservés (intacts)\n")
          (insert "-------------------\n")
          (insert (format "Blocs de code                       : %d\n" n-code))
          (insert (format "Listes / titres / tables / callouts : %d\n"
                          n-structure))
          (goto-char (point-min))
          (special-mode)))
      (display-buffer "*Rapport nettoyage MetalEmacs*")
      (message "Reflow terminé (%s) : %d insécable(s), %d paragraphe(s) fusionné(s)."
               nom-style total-insec n-paragraphes-fusionnes))))

(provide 'metal-nettoyer)

;;; metal-nettoyer.el ends here
