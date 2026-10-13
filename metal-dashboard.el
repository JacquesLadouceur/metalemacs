;;; metal-dashboard.el --- Tableau de bord MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.2


;;; Commentaires:
;; Ce module fournit le tableau de bord de MetalEmacs :
;; - Affichage des fichiers récents
;; - Création rapide de fichiers (Quarto, Python, Prolog, Org)
;; - Accès au calendrier, notes, etc.

;;; Code:

(require 'recentf)
(require 'cl-lib)
(require 'subr-x)
(require 'ucs-normalize)
(require 'url)
(require 'xml)
(require 'metal-icones nil t)

;; Fournies par `metal-quarto.el'.  Chargement non forcé ici : la création
;; de document teste `fboundp' et retombe sur la front matter complète si
;; le module n'est pas encore chargé.
(declare-function metal-quarto-contexte-dossier "metal-quarto" (dir))
(declare-function metal-quarto--creer-metadata "metal-quarto" (dir))
(declare-function metal-quarto--ajouter-include "metal-quarto" (chapitre))
(declare-function metal-quarto--modele "metal-quarto" (nom))
(declare-function metal-quarto-front-matter-document "metal-quarto" (&optional titre))
(defvar metal-quarto-dossiers-chapitres)

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
  "Fichiers à copier dans le dossier de chaque nouveau document ou présentation Quarto.")

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

;;; ── Capture d'un lien depuis le presse-papiers ─────────────────────

(defun metal-dashboard--signets-utile (chaine)
  "Retourner CHAINE élaguée si elle contient autre chose que du blanc.
Retourne nil sinon.  Indispensable pour chaîner les sources du
presse-papiers avec `or\\=': le port NS de macOS renvoie la chaîne vide
— et non nil — pour un type de sélection qu\\='il ne gère pas, ce qui
arrêterait le `or\\=' sur une valeur inexploitable."
  (when (stringp chaine)
    (let ((elaguee (string-trim chaine)))
      (unless (string-empty-p elaguee) elaguee))))

(defun metal-dashboard--signets-presse-papiers ()
  "Retourner le contenu du presse-papiers système, ou une chaîne vide.
Interroge la sélection CLIPBOARD sous ses deux types (le navigateur doit
être encore ouvert sous X11), puis retombe sur l'anneau de kill d'Emacs.
Chaque source est ignorée si elle est vide ou ne contient que du blanc."
  (or (metal-dashboard--signets-utile
       (ignore-errors (gui-get-selection 'CLIPBOARD 'UTF8_STRING)))
      (metal-dashboard--signets-utile
       (ignore-errors (gui-get-selection 'CLIPBOARD 'STRING)))
      (metal-dashboard--signets-utile
       (ignore-errors (current-kill 0 t)))
      ""))

(defun metal-dashboard--signets-url-p (chaine)
  "Retourner non-nil si CHAINE ressemble à une adresse http(s)."
  (and (stringp chaine)
       (string-match-p "\\`https?://[^[:space:]]+\\'" chaine)))

(defun metal-dashboard--signets-extraire-url (chaine)
  "Retourner la première adresse http(s) contenue dans CHAINE, ou nil.
Tolère ce qui entoure le lien : titre de page copié avec l'adresse,
guillemets, chevrons, parenthèses Markdown, retours de ligne."
  (when (and (stringp chaine)
             (string-match "https?://[^ \t\n\r\f\"<>]+" chaine))
    ;; Retirer la ponctuation ou les délimiteurs collés à la fin du lien.
    (replace-regexp-in-string "[].,;:!?'\")]+\\'" "" (match-string 0 chaine))))

(defun metal-dashboard--signets-titre-extraire ()
  "Retourner le titre HTML du tampon courant, ou nil.
Le tampon contient la réponse brute de `url-retrieve\=' : ses octets ne
sont pas décodés, d'où le `decode-coding-string\=' — sans lui, tout titre
accentué revenait en mojibake."
  (goto-char (point-min))
  (when (re-search-forward "<title[^>]*>\\([^<]*\\)</title>" nil t)
    (let ((titre (string-trim
                  (replace-regexp-in-string
                   "[ \t\n\r]+" " "
                   (xml-substitute-special
                    (decode-coding-string (match-string 1) 'utf-8))))))
      (unless (string-empty-p titre) titre))))

(defun metal-dashboard--signets-titre-async (url)
  "Lancer la récupération du titre de URL ; retourner une cellule résultat.
Le titre est déposé dans le `car\=' de la cellule dès que la page répond.

La requête ne bloque plus Emacs : `url-retrieve-synchronously\=' gelait
tout, et son argument TIMEOUT ne borne que la boucle d'attente — la
résolution DNS et la poignée de main TLS d'`open-network-stream' lui
échappent, et chaque redirection relance le chrono. L'en-tête Range
demande en outre les premiers kilooctets seulement : le titre est dans
la tête du document, inutile de rapatrier la page entière (les serveurs
qui ignorent Range renvoient simplement tout, sans dommage)."
  (let ((cellule (cons nil nil))
        (url-request-extra-headers '(("Range" . "bytes=0-8191"))))
    (ignore-errors
      (url-retrieve
       url
       (lambda (statut cellule)
         (unwind-protect
             (unless (plist-get statut :error)
               (setcar cellule (metal-dashboard--signets-titre-extraire)))
           (kill-buffer (current-buffer))))
       (list cellule) t t))
    cellule))

(defun metal-dashboard--signets-sections (filepath)
  "Retourner la liste des titres de niveau 1 du fichier FILEPATH."
  (when (file-exists-p filepath)
    (with-temp-buffer
      (insert-file-contents filepath)
      (goto-char (point-min))
      (let (titres)
        (while (re-search-forward "^\\* +\\(.*\\)$" nil t)
          (let ((titre (string-trim (match-string 1))))
            (unless (string-empty-p titre)
              (push titre titres))))
        (nreverse titres)))))

(defun metal-dashboard--signets-clef-tri (chaine)
  "Retourner la clef de comparaison de CHAINE : minuscules, sans accents.
La décomposition NFD sépare la lettre de son signe diacritique, qui est
ensuite retiré : « Éducation » et « education » donnent la même clef."
  (replace-regexp-in-string
   "[\u0300-\u036f]" ""
   (ucs-normalize-NFD-string (downcase chaine))))

(defun metal-dashboard--signets-trier-sections (sections)
  "Retourner SECTIONS triées alphabétiquement, casse et accents ignorés."
  (mapcar #'cdr
          (sort (mapcar (lambda (s)
                          (cons (metal-dashboard--signets-clef-tri s) s))
                        sections)
                (lambda (a b) (string-lessp (car a) (car b))))))

(defun metal-dashboard--signets-table (candidats)
  "Retourner une table de complétion préservant l'ordre de CANDIDATS.
Sans cela, les interfaces de complétion (Vertico, Ivy, etc.) réordonnent
la liste selon leur propre tri et défont le tri sans accents."
  (lambda (chaine predicat action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidats chaine predicat))))

(defcustom metal-dashboard-signets-prefixe "- "
  "Préfixe des entrées de signet écrites dans les fichiers .org.
Vaut « - » : les signets sont des éléments de liste sous la section.
Mettre « ** » pour en faire des titres de niveau 2."
  :type 'string
  :group 'metal-dashboard)

(defun metal-dashboard--signets-inserer-ligne (section ligne)
  "Insérer LIGNE à la fin de SECTION dans le tampon courant.
SECTION est créée à la fin du tampon si elle n'existe pas."
  (goto-char (point-min))
  (if (re-search-forward
       (format "^\\* +%s[ \t]*$" (regexp-quote section)) nil t)
      (progn
        (forward-line 1)
        (if (re-search-forward "^\\* " nil t)
            (goto-char (match-beginning 0))
          (goto-char (point-max)))
        (skip-chars-backward " \t\n"))
    (goto-char (point-max))
    (skip-chars-backward " \t\n")
    (insert (format "\n\n* %s" section)))
  (insert "\n" ligne)
  (goto-char (point-max))
  (unless (bolp) (insert "\n")))

(defun metal-dashboard--signets-inserer (filepath section url titre)
  "Insérer le signet URL/TITRE à la fin de SECTION dans FILEPATH.
L'entrée est écrite avec `metal-dashboard-signets-prefixe'.  La section
est créée à la fin du fichier si elle n'existe pas.

Si aucun tampon ne visite FILEPATH, l'écriture passe par un tampon
temporaire : `find-file-noselect' déclencherait l'initialisation
complète d'org-mode — font-lock sur tout le fichier, cache
org-element — pour ajouter une seule ligne."
  (let ((ligne (format "%s[[%s][%s]]"
                       metal-dashboard-signets-prefixe url
                       (if (string-empty-p titre) url titre)))
        (tampon (find-buffer-visiting filepath)))
    (if tampon
        (with-current-buffer tampon
          (save-excursion
            (metal-dashboard--signets-inserer-ligne section ligne))
          (save-buffer))
      (with-temp-buffer
        (when (file-exists-p filepath)
          (insert-file-contents filepath))
        (metal-dashboard--signets-inserer-ligne section ligne)
        (write-region (point-min) (point-max) filepath nil 'silence)))))

(defun metal-dashboard-signets-ajouter-lien ()
  "Ajouter un signet à partir du lien copié dans le presse-papiers.
L'adresse est reprise automatiquement du presse-papiers ; elle n'est
demandée que si celui-ci n'en contient aucune.  Demande ensuite la liste
de destination (si plusieurs existent), la section Org de niveau 1 où
classer le signet, puis le titre — récupéré en arrière-plan depuis la
page distante."
  (interactive)
  (let ((fichiers (mapcar #'car (metal-dashboard--signets-liste-fichiers))))
    (unless fichiers
      (user-error "Aucune liste de signets : créez-en une d'abord"))
    (let* ((fichier
            (if (cdr fichiers)
                (expand-file-name
                 (completing-read "Liste : "
                                  (mapcar #'file-name-nondirectory fichiers)
                                  nil t)
                 (metal-dashboard--signets-dir))
              (car fichiers)))
           (brut (metal-dashboard--signets-presse-papiers))
           ;; L'adresse est prise telle quelle dans le presse-papiers ; on
           ;; ne demande la saisie que s'il n'y a rien d'exploitable.
           (url (or (metal-dashboard--signets-extraire-url brut)
                    (metal-dashboard--signets-extraire-url
                     (read-string "Aucun lien dans le presse-papiers, URL : ")))))
      (unless (metal-dashboard--signets-url-p url)
        (user-error "Adresse invalide : %s" (or url "")))
      ;; La requête réseau est lancée d'abord et l'invite de section — qui
      ;; ne consulte que le disque — passe avant l'invite de titre : le
      ;; temps de choisir la section, la réponse distante est arrivée et
      ;; l'attente devient invisible.
      (let* ((attente (metal-dashboard--signets-titre-async url))
             (sections (metal-dashboard--signets-trier-sections
                        (or (metal-dashboard--signets-sections fichier)
                            '("Général"))))
             (section (completing-read
                       "Section : "
                       (metal-dashboard--signets-table sections)
                       nil nil nil nil (car sections)))
             (titre (read-string "Titre : " (or (car attente) ""))))
        (metal-dashboard--signets-inserer fichier section url titre)
        (message "Signet ajouté dans %s (%s)"
                 (file-name-nondirectory fichier) section)))))

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
              (insert-button (concat (metal-dashboard--icone "📋")
                                     " Ajouter un lien du presse-papiers...")
                             'action (lambda (_b)
                                       (call-interactively
                                        #'metal-dashboard-signets-ajouter-lien))
                             'follow-link t
                             'help-echo "Capturer l'URL copiée dans le navigateur")
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
  (let* ((template (metal-quarto--modele "presentation-quarto.txt")))
    (metal-dashboard--create-new-file
     ".qmd"
     "Présentation Quarto: "
     template)
    ;; Copier les ressources Quarto dans le dossier de la présentation
    (when (and buffer-file-name
               (string-suffix-p ".qmd" buffer-file-name t))
      (metal-dashboard--copier-ressources-quarto
       (file-name-directory buffer-file-name)))))

(defun metal-dashboard-new-qmd-document ()
  "Créer un document Quarto, avec ou sans en-tête selon le contexte du dossier.

Si le dossier fournit déjà la configuration (via `_metadata.yml' complet, ou
via un `_quarto.yml' ancêtre), le document est créé sans front matter et
amorcé par un titre de section.  Sinon il reçoit la front matter complète du
modèle partagé `modeles/quarto-config.txt', via
`metal-quarto-front-matter-document'.

Dans un dossier entièrement vide, le minibuffer propose de basculer en
document réparti sur plusieurs fichiers.  Le squelette écrit alors est :

  _metadata.yml
  maître.qmd
  Chapitres/          (ou Fichiers/, au choix)

Le fichier nommé à l'invite devient le document maître.  Les documents créés
ensuite dans le sous-dossier sont détectés comme chapitres : pas de front
matter, et leur `include' est ajouté au maître.  La question multifichiers
n'est jamais posée si le dossier contient déjà un .qmd."
  (interactive)
  (let* ((dir (metal-dashboard--treemacs-selected-dir))
         (ctx (and (fboundp 'metal-quarto-contexte-dossier)
                   (metal-quarto-contexte-dossier dir)))
         (dossier-chapitres nil))

    (when (and (eq ctx 'vierge)
               (y-or-n-p "Dossier vide — document réparti sur plusieurs fichiers ? "))
      (setq dossier-chapitres
            (completing-read "Nom du sous-dossier des fichiers : "
                             metal-quarto-dossiers-chapitres
                             nil nil
                             (car metal-quarto-dossiers-chapitres)))
      (metal-quarto--creer-metadata dir)
      (make-directory (expand-file-name dossier-chapitres dir) t)
      (setq ctx 'maitre))

    (metal-dashboard--create-new-file
     ".qmd"
     (if (eq ctx 'maitre) "Document maître: " "Document Quarto: ")
     (if (memq ctx '(chapitre metadata maitre))
         ""
       (metal-quarto-front-matter-document)))

    (when (and buffer-file-name
               (string-suffix-p ".qmd" buffer-file-name t))
      (when (= (buffer-size) 0)
        (pcase ctx
          ;; Document maître : titre seul, le reste vient de `_metadata.yml'.
          ('maitre
           (insert "---\n"
                   "title: \"" (file-name-base buffer-file-name) "\"\n"
                   "---\n\n"
                   "<!-- Un include par fichier, dans l'ordre de lecture.\n"
                   "     Les documents créés dans " dossier-chapitres "/ s'ajoutent ici. -->\n\n"))
          ;; Sans front matter : amorcer par un titre de section.
          ((or 'chapitre 'metadata)
           (insert "# " (file-name-base buffer-file-name) "\n\n")))
        (save-buffer))

      ;; Un chapitre s'annonce au maître ; les ressources vivent à la racine.
      (if (eq ctx 'chapitre)
          (metal-quarto--ajouter-include buffer-file-name)
        (metal-dashboard--copier-ressources-quarto
         (file-name-directory buffer-file-name))))))

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
    ":HEADER: \n"
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
    ":END: \n"
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

;;; ── Mise en forme (couleurs, pastilles, boutons) ───────────────────

(defconst metal-dashboard--types
  ;; type  libellé  encre-clair  fond-clair  encre-sombre  fond-sombre
  '((qmd   "QMD" "#2448B0" "#E3E9F8" "#8AA8FF" "#252E45")
    (py    "PY"  "#7A5A00" "#F6EED6" "#E6C16A" "#36311E")
    (pl    "PL"  "#A63E06" "#FBE7DA" "#F0955E" "#3A2A20")
    (org   "ORG" "#5B33B5" "#ECE5FA" "#B79CF7" "#2F2940")
    (pdf   "PDF" "#A42525" "#F8E1E1" "#F07F7F" "#3A2426")
    (el    "EL"  "#16725C" "#DDF0EA" "#6FCFB5" "#1F3531")
    (dia   "DIA" "#16725C" "#DDF0EA" "#6FCFB5" "#1F3531")
    (autre nil   "#4A5260" "#E9EBEE" "#AEB6C1" "#2A2D33"))
  "Libellé et couleurs des pastilles de type de fichier.")

(defconst metal-dashboard--extensions
  '(("qmd" . qmd) ("md" . qmd) ("py" . py) ("pl" . pl) ("pro" . pl)
    ("org" . org) ("pdf" . pdf) ("el" . el) ("drawio" . dia))
  "Correspondance extension → type de pastille.")

(defun metal-dashboard--sombre-p ()
  "Retourner non nil si le thème courant est sombre."
  (if (fboundp 'metal-apparence-sombre-p)
      (metal-apparence-sombre-p)
    (eq (frame-parameter nil 'background-mode) 'dark)))

(defun metal-dashboard--couleur (cle)
  "Retourner la couleur d'interface CLE pour le thème courant."
  (let ((sombre (metal-dashboard--sombre-p)))
    (pcase cle
      ('accent  (if sombre "#8AA8FF" "#2C55C9"))
      ('pilule  (if (fboundp 'metal-apparence-couleur)
                    (metal-apparence-couleur 'bg-dim (if sombre "#1E2126" "#EDEFF2"))
                  (if sombre "#1E2126" "#EDEFF2")))
      ('survol  (if sombre "#2B303A" "#DCE4F7"))
      ('bordure (if (fboundp 'metal-apparence-couleur)
                    (metal-apparence-couleur 'border (if sombre "#3A3F48" "#C9CED6"))
                  (if sombre "#3A3F48" "#C9CED6")))
      (_ nil))))

(defvar metal-dashboard--mono nil
  "Famille monospace utilisée dans le tableau de bord (calculée au rendu).")

(defun metal-dashboard--aller (colonne)
  "Retourner un espace qui aligne la suite à COLONNE."
  (propertize " " 'display `(space :align-to ,colonne)))

(defun metal-dashboard--centrer (texte largeur)
  "Centrer TEXTE dans LARGEUR caractères."
  (let* ((n (max 0 (- largeur (length texte))))
         (g (/ n 2)))
    (concat (make-string g ?\s) texte (make-string (- n g) ?\s))))

(defun metal-dashboard--type-fichier (fichier)
  "Retourner (TYPE . LIBELLÉ) de la pastille pour FICHIER."
  (let* ((ext (downcase (or (file-name-extension fichier) "")))
         (type (or (cdr (assoc ext metal-dashboard--extensions)) 'autre))
         (libelle (or (nth 1 (assq type metal-dashboard--types))
                      (upcase (truncate-string-to-width
                               (if (string-empty-p ext) "—" ext) 3)))))
    (cons type libelle)))

(defun metal-dashboard--pastille (type &optional libelle)
  "Retourner la pastille colorée du TYPE, avec LIBELLE éventuel."
  (let* ((e (assq type metal-dashboard--types))
         (sombre (metal-dashboard--sombre-p))
         (encre (if sombre (nth 4 e) (nth 2 e)))
         (fond  (if sombre (nth 5 e) (nth 3 e))))
    (propertize (metal-dashboard--centrer (or libelle (nth 1 e) "") 3)
                'face `(:family ,metal-dashboard--mono :height 0.8 :weight bold
                        :foreground ,encre :background ,fond
                        :box (:line-width (6 . 3) :color ,fond)))))

(defun metal-dashboard--carre (couleur fond)
  "Petit carré COULEUR sur FOND (SVG ; repli : caractère ■)."
  (if (and (display-graphic-p) (image-type-available-p 'svg))
      (let ((px (max 8 (round (* (frame-char-height) 0.45)))))
        (propertize
         " " 'display
         (create-image
          (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><rect width='%d' height='%d' fill='%s'/><rect width='%d' height='%d' rx='2' fill='%s'/></svg>"
                  px px px px fond px px couleur)
          'svg t :ascent 'center)))
    (propertize "■" 'face `(:foreground ,couleur))))

(defun metal-dashboard--cliquable (texte action aide &optional mouse-face)
  "Rendre TEXTE cliquable (souris et RET) : ACTION, infobulle AIDE."
  (let ((map (make-sparse-keymap))
        (cmd (if (commandp action)
                 action
               (lambda () (interactive) (funcall action)))))
    (define-key map [mouse-1] cmd)
    (define-key map (kbd "RET") cmd)
    (propertize texte
                'mouse-face (or mouse-face 'highlight)
                'help-echo aide
                'pointer 'hand
                'keymap map)))

(defun metal-dashboard--pilule (couleur libelle aide action)
  "Bouton arrondi : carré COULEUR, LIBELLE, infobulle AIDE, ACTION."
  (let* ((fond  (metal-dashboard--couleur 'pilule))
         (survol (metal-dashboard--couleur 'survol))
         (face  `(:background ,fond :weight medium
                  :box (:line-width (12 . 7) :color ,fond)))
         (s (concat (metal-dashboard--carre couleur fond) "  " libelle)))
    (add-face-text-property 0 (length s) face t s)
    (metal-dashboard--cliquable
     s action aide
     `(:background ,survol :box (:line-width (12 . 7) :color ,survol)))))

(defun metal-dashboard--touche (touche)
  "Indication de raccourci clavier TOUCHE."
  (propertize (concat " " touche " ")
              'face `(:family ,metal-dashboard--mono :height 0.8
                      :inherit shadow
                      :box (:line-width 1 :color ,(metal-dashboard--couleur 'bordure)))))

(defun metal-dashboard--titre-section (texte)
  "Titre de section discret, en capitales."
  (propertize (upcase texte) 'face '(:inherit shadow :height 0.8 :weight bold)))

(defun metal-dashboard--lien (texte action aide)
  "Lien textuel couleur d'accent."
  (metal-dashboard--cliquable
   (propertize texte 'face `(:foreground ,(metal-dashboard--couleur 'accent)))
   action aide))

(defun metal-dashboard--prenom ()
  "Prénom de l'accueil, ou nil."
  (and (fboundp 'metal-utilisateur-prenom-affiche)
       (metal-utilisateur-prenom-affiche)))

;;; ── Rendu ──────────────────────────────────────────────────────────

(defun metal-dashboard--inserer-entete (marge largeur)
  "Insérer la date, l'accueil et les boutons de navigation."
  (insert (propertize (metal-dashboard--date-francaise) 'face 'shadow)
          (metal-dashboard--aller (- (+ marge largeur) 15))
          (propertize "MetalEmacs 1.1" 'face 'shadow)
          "\n")
  (let ((prenom (metal-dashboard--prenom)))
    (insert (metal-dashboard--cliquable
             (propertize (if prenom (format "Bonjour, %s" prenom) "Bonjour")
                         'face '(:height 1.8 :weight semi-bold))
             (lambda ()
               (when (fboundp 'metal-utilisateur-definir-prenom)
                 (call-interactively 'metal-utilisateur-definir-prenom)))
             "Modifier le prénom affiché"
             '(:height 1.8 :weight semi-bold))
            "\n\n"))
  (let ((boutons
         (list
          (metal-dashboard--pilule
           "#D9534F" "METAL" "Ouvrir le guide METAL (PDF)"
           (lambda ()
             (find-file (expand-file-name "Metal.pdf" user-emacs-directory))))
          (metal-dashboard--pilule
           "#E0701E" "Calendrier" "Ouvrir le calendrier"
           (lambda ()
             (if (fboundp 'metal-calendrier-ouvrir)
                 (metal-calendrier-ouvrir)
               (calendar))))
          (metal-dashboard--pilule
           "#C9A220" "Notes rapides" "Ouvrir les notes rapides"
           #'metal-dashboard-notes-ouvrir)
          (metal-dashboard--pilule
           "#7B4FDB" "Signets" "Ouvrir les signets web"
           #'metal-dashboard-signets-ouvrir)
          (metal-dashboard--pilule
           "#2C55C9" "Actualités" "Choisir un site d'actualités"
           #'metal-dashboard-actualites-menu)
          (metal-dashboard--pilule
           "#1F9E80" "Assistant" "Ouvrir l'assistant d'installation"
           (lambda ()
             (require 'metal-deps nil t)
             (if (fboundp 'metal-deps-afficher-etat)
                 (metal-deps-afficher-etat)
               (message "metal-deps non disponible")))))))
    (insert (mapconcat #'identity boutons "   "))
    (when (fboundp 'metal-agent-dashboard-buttons)
      (let ((extra (metal-agent-dashboard-buttons)))
        (when (and extra (not (string-empty-p extra)))
          (insert "   " extra))))
    (insert "\n\n\n")))

(defun metal-dashboard--inserer-nouveau (marge largeur)
  "Insérer la grille « Nouveau » (2 rangées de 3 cartes)."
  (insert (metal-dashboard--titre-section "Nouveau") "\n")
  (let* ((cartes
          `(("p" qmd "Présentation" "Quarto · Beamer"
             metal-dashboard-new-qmd "Créer une présentation Quarto")
            ("d" qmd "Document" "Quarto · LuaLaTeX"
             metal-dashboard-new-qmd-document "Créer un document Quarto")
            ("y" py "Python" "Script .py"
             metal-dashboard-new-python "Créer un fichier Python")
            ("r" pl "Prolog" "SWI-Prolog .pl"
             metal-dashboard-new-prolog "Créer un fichier Prolog")
            ("o" org "Document Org" "Notes .org"
             metal-dashboard-new-org-document "Créer un document Org-mode")
            ("g" dia "Diagramme" "draw.io"
             metal-dashboard-new-drawio "Créer un diagramme draw.io")))
         (colw (/ largeur 3)))
    (dolist (rangee (list (seq-take cartes 3) (seq-drop cartes 3)))
      (let ((ligne1 "") (ligne2 "") (i 0))
        (dolist (c rangee)
          (pcase-let* ((`(,touche ,type ,nom ,desc ,action ,aide) c)
                       (x (+ marge (* i colw))))
            (setq ligne1
                  (concat ligne1
                          (metal-dashboard--aller x)
                          (metal-dashboard--cliquable
                           (concat (metal-dashboard--pastille type)
                                   (metal-dashboard--aller (+ x 6))
                                   (propertize nom 'face '(:weight semi-bold)))
                           action aide)
                          (metal-dashboard--aller (+ x colw -6))
                          (metal-dashboard--touche touche))
                  ligne2
                  (concat ligne2
                          (metal-dashboard--aller (+ x 6))
                          (propertize desc 'face '(:inherit shadow :height 0.9))))
            (setq i (1+ i))))
        (insert ligne1 "\n" ligne2 "\n\n"))))
  (insert "\n"))

(defun metal-dashboard--inserer-recents (marge largeur)
  "Insérer la liste numérotée des fichiers récents."
  (insert (metal-dashboard--titre-section "Fichiers récents")
          (metal-dashboard--aller (- (+ marge largeur) 13))
          (metal-dashboard--lien
           "Tout afficher"
           (if (fboundp 'recentf-open) #'recentf-open #'recentf-open-files)
           "Parcourir tous les fichiers récents")
          "\n")
  (let* ((fichiers (seq-take
                    (seq-filter #'metal-dashboard--recentf-acceptable-p
                                recentf-list)
                    9))
         (x-nom (+ marge 6))
         (x-dossier (+ marge (max 34 (round (* largeur 0.6)))))
         (x-num (- (+ marge largeur) 2))
         (n 0))
    (if (null fichiers)
        (insert (propertize "Aucun fichier récent pour l'instant." 'face 'shadow) "\n")
      (dolist (f fichiers)
        (setq n (1+ n))
        (let* ((type (metal-dashboard--type-fichier f))
               (nom (truncate-string-to-width
                     (file-name-nondirectory f) (- x-dossier x-nom 2) nil nil "…"))
               (dossier (truncate-string-to-width
                         (file-name-nondirectory
                          (directory-file-name (file-name-directory f)))
                         (max 8 (- x-num x-dossier 3)) nil nil "…"))
               (chemin f))
          (insert (metal-dashboard--aller marge)
                  (metal-dashboard--cliquable
                   (concat (metal-dashboard--pastille (car type) (cdr type))
                           (metal-dashboard--aller x-nom)
                           (propertize nom 'face `(:family ,metal-dashboard--mono)))
                   (lambda () (find-file chemin))
                   chemin)
                  (metal-dashboard--aller x-dossier)
                  (propertize dossier 'face 'shadow)
                  (metal-dashboard--aller x-num)
                  (propertize (number-to-string n)
                              'face `(:inherit shadow :family ,metal-dashboard--mono))
                  "\n")))))
  (insert "\n\n")
  ;; Retourner la liste affichée pour les raccourcis 1 à 9.
  (seq-take (seq-filter #'metal-dashboard--recentf-acceptable-p recentf-list) 9))

(defun metal-dashboard--inserer-reglages ()
  "Insérer la ligne discrète des réglages d'affichage."
  (let ((sep (propertize "     ·     " 'face 'shadow))
        (police (if (fboundp 'metal-font-height) (metal-font-height) 120))
        (icones (if (fboundp 'metal-toolbar-emoji-size) (metal-toolbar-emoji-size) 120))
        (rafraichir (lambda (f) (lambda () (when (fboundp f) (funcall f) (metal-dashboard-open))))))
    (insert
     (propertize (format "Police %d  " police) 'face 'shadow)
     (metal-dashboard--lien "−" (funcall rafraichir 'metal-font-decrease) "Diminuer la police (touche -)")
     "  "
     (metal-dashboard--lien "+" (funcall rafraichir 'metal-font-increase) "Augmenter la police (touche +)")
     "  "
     (metal-dashboard--lien "réinitialiser" (funcall rafraichir 'metal-font-reset) "Taille par défaut (touche 0)")
     sep
     (propertize (format "Icônes %d  " icones) 'face 'shadow)
     (metal-dashboard--lien "−" (funcall rafraichir 'metal-toolbar-emoji-decrease) "Diminuer les icônes")
     "  "
     (metal-dashboard--lien "+" (funcall rafraichir 'metal-toolbar-emoji-increase) "Augmenter les icônes")
     "  "
     (metal-dashboard--lien "réinitialiser" (funcall rafraichir 'metal-toolbar-emoji-reset) "Taille par défaut")
     sep
     (propertize (format "Thème %s  "
                         (if (fboundp 'metal-apparence-nom-theme)
                             (metal-apparence-nom-theme)
                           "Clair"))
                 'face 'shadow)
     (metal-dashboard--lien "changer"
                            (lambda ()
                              (if (fboundp 'metal-apparence-choisir)
                                  (call-interactively #'metal-apparence-choisir)
                                (message "metal-apparence non chargé")))
                            "Clair, sombre ou système (touche t : basculer)")
     "\n")))

(defun metal-dashboard--clavier (recents)
  "Construire le clavier local ; RECENTS est la liste numérotée."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "p") #'metal-dashboard-new-qmd)
    (define-key map (kbd "d") #'metal-dashboard-new-qmd-document)
    (define-key map (kbd "y") #'metal-dashboard-new-python)
    (define-key map (kbd "r") #'metal-dashboard-new-prolog)
    (define-key map (kbd "o") #'metal-dashboard-new-org-document)
    (define-key map (kbd "g") #'metal-dashboard-new-drawio)
    (define-key map (kbd "G") #'metal-dashboard-open)
    (define-key map (kbd "+") (lambda () (interactive)
                                (when (fboundp 'metal-font-increase)
                                  (metal-font-increase) (metal-dashboard-open))))
    (define-key map (kbd "-") (lambda () (interactive)
                                (when (fboundp 'metal-font-decrease)
                                  (metal-font-decrease) (metal-dashboard-open))))
    (define-key map (kbd "0") (lambda () (interactive)
                                (when (fboundp 'metal-font-reset)
                                  (metal-font-reset) (metal-dashboard-open))))
    (define-key map (kbd "t") (lambda () (interactive)
                                (when (fboundp 'metal-apparence-basculer)
                                  (metal-apparence-basculer))))
    (let ((n 0))
      (dolist (f recents)
        (setq n (1+ n))
        (let ((chemin f))
          (define-key map (kbd (number-to-string n))
            (lambda () (interactive) (find-file chemin))))))
    map))

(defun metal-dashboard-open ()
  "Afficher le tableau de bord MetalEmacs."
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
        ;; Famille monospace lue AVANT le remappage proportionnel.
        (setq metal-dashboard--mono (face-attribute 'default :family nil t))
        (setq-local cursor-type nil
                    line-spacing 0.35
                    truncate-lines t
                    buffer-face-mode-face 'variable-pitch)
        (buffer-face-mode 1)
        (let* ((fenetre (or (get-buffer-window buf) (selected-window)))
               (marge 6)
               (largeur (max 72 (- (window-width fenetre) (* 2 marge) 2)))
               recents)
          (setq-local line-prefix `(space :width ,marge))
          (setq-local wrap-prefix `(space :width ,marge))
          (insert "\n")
          (metal-dashboard--inserer-entete marge largeur)
          (metal-dashboard--inserer-nouveau marge largeur)
          (setq recents (metal-dashboard--inserer-recents marge largeur))
          (metal-dashboard--inserer-reglages)
          (use-local-map (metal-dashboard--clavier recents)))
        (goto-char (point-min))
        (setq buffer-read-only t)))
    (when (called-interactively-p 'any)
      (switch-to-buffer buf))
    buf))

;; Redessiner le tableau de bord quand le thème change.
(add-hook 'metal-apparence-apres-changement-hook
          (lambda ()
            (when (get-buffer metal-dashboard-buffer-name)
              (metal-dashboard-open))))

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
