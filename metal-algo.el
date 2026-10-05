;;; metal-algo.el --- Programmation algorithmique via metal-agent  -*- lexical-binding: t; -*-

;; Auteur : Jacques Ladouceur
;; Fait partie de MetalEmacs.

;;; Commentary:
;;
;; Depuis un script Python, le bouton 🧭 de la barre agent ouvre un
;; tampon dédié où l'on rédige l'ALGORITHME (en Org) qui sert de prompt.
;; Le tampon a sa propre barre de boutons :
;;
;;   🛠️  Produire            run 1 : l'agent produit le programme
;;   ⏩  Produire et exécuter double run
;;   ▶️  Exécuter            run 2 (C-u : vérifier les exemples)
;;   📄  Script              revenir au script Python
;;   🔎  Aperçu              consigne exacte envoyée à l'agent
;;
;; La production passe par la mécanique de metal-agent : agent choisi
;; dans l'assistant, profil du script (ex. Python TAL) avec ses options
;; et instructions libres, marqueurs sentinelles, diagnostic d'échec,
;; garde-fou anti-effondrement et révision Ediff quand le script n'est
;; pas vide.
;;
;; L'algorithme est enregistré à côté du script : tri.py → tri.algo.org.
;; Le tampon s'appelle « *Algorithme — tri.py* » : son nom commençant
;; par « * », l'auto-sélection de profil l'ignore et le profil du script
;; reste actif.
;;
;; Structure d'un algorithme :
;;
;;   #+TITLE: Fréquence des mots
;;   * Données
;;   - Entrée : [[file:corpus/romans.txt]]   (lien Org ou simple nom,
;;   - Sortie : frequences.tsv                relatif au dossier du script)
;;   * Procédure
;;   1. Lire le fichier ligne par ligne.     → Étape 1
;;   2. Pour chaque ligne :                  → Étape 2
;;      1. normaliser en NFC ;               → Étape 2.1
;;      2. découper en mots.                 → Étape 2.2
;;   3. Écrire les fréquences triées.        → Étape 3
;;   * Exemples                              (facultatif, forme libre)
;;
;; La numérotation hiérarchique est calculée d'après l'imbrication des
;; listes ; Org renumérote lui-même les éléments (M-RET, M-<flèches>).

;;; Code:

(require 'org)
(require 'comint)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'metal-agent)

;;;; Réglages

(defgroup metal-algo nil
  "Programmation algorithmique via metal-agent."
  :group 'metal-agent
  :prefix "metal-algo-")

(defcustom metal-algo-python nil
  "Interpréteur Python pour l'exécution.
Si nil : `python-shell-interpreter', puis python3, puis python."
  :type '(choice (const nil) file))

(defcustom metal-algo-fonction-execution nil
  "Fonction d'exécution (FICHIER EXEMPLES-P) remplaçant l'exécution intégrée.
Permet de déléguer au lanceur Python de MetalEmacs.  Si nil, le script
est lancé dans un tampon comint."
  :type '(choice (const nil) function))

(defcustom metal-algo-regles
  "1. Respecte la procédure à la lettre : aucune étape ajoutée ou omise,
   aucun changement de stratégie.
2. Précède le code de chaque étape d'un commentaire « # Étape N », où N
   est le numéro indiqué dans la procédure (ex. « # Étape 2.1 »).
3. Les contraintes du profil régissent le STYLE du code ; elles ne
   t'autorisent pas à modifier la stratégie de la procédure.  En cas de
   conflit, la procédure prime.
4. Ce que la procédure ne précise pas, tu le décides toi-même, comme un
   programmeur expérimenté, en suivant les consignes du profil.  Ne
   bloque jamais sur un détail : produis toujours le programme.
5. Les noms de fichiers mentionnés sont des chemins relatifs au dossier
   du script, qui sera le dossier courant à l'exécution.  N'exécute
   aucune commande et n'ouvre aucun fichier : les premières lignes des
   fichiers de données existants sont fournies plus bas.  Pour un
   fichier sans aperçu, appuie-toi sur son en-tête (noms de colonnes)
   plutôt que sur des positions supposées."
  "Règles de traduction ajoutées à la consigne de production."
  :type 'string)

(defconst metal-algo--regle-exemples
  "6. Ajoute une fonction _verifier_exemples() qui teste chacun des
   exemples fournis et affiche OK ou ÉCHEC pour chacun ; quand le
   programme est lancé avec l'argument --exemples, appelle-la au lieu du
   programme principal.")

(defconst metal-algo--marqueur-ambiguites "===METAL-ALGO-CHOIX===")

;;;; État

(defvar-local metal-algo--script nil
  "Tampon du script Python associé au tampon d'algorithme.")
(defvar-local metal-algo--profil nil
  "Profil metal-agent capturé à l'ouverture (celui du script).")
(defvar-local metal-algo--tick-production nil
  "`buffer-chars-modified-tick' de l'algorithme à la dernière production.")
(defvar-local metal-algo--exec-script nil)
(defvar-local metal-algo--exec-algo nil)

(defvar metal-algo--avis-revision nil
  "Advice ponctuel posé sur la fin d'Ediff pour le double run.")

;;;; Lecture de la procédure (tampon courant)

(defconst metal-algo--noms-procedure '("Procédure" "Procedure"))

(defconst metal-algo--re-item "^\\([ \t]*\\)[0-9]+[.)][ \t]+\\(.*\\)$"
  "Élément de liste numérotée Org : « 1. texte » ou « 1) texte ».")

(defconst metal-algo--re-lien-fichier
  "\\[\\[file:\\([^]]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]"
  "Lien Org vers un fichier : [[file:chemin]] ou [[file:chemin][description]].")

(defun metal-algo--mot-cle (cle)
  (when-let ((v (cadr (assoc cle (org-collect-keywords (list cle))))))
    (string-trim v)))

(defun metal-algo--section (noms)
  "Position du titre de niveau 1 dont le texte est dans NOMS, ou nil."
  (org-with-wide-buffer
   (goto-char (point-min))
   (catch 'trouve
     (while (re-search-forward "^\\* " nil t)
       (when (member-ignore-case (org-get-heading t t t t) noms)
         (throw 'trouve (line-beginning-position))))
     nil)))

(defun metal-algo--texte-section (noms)
  (when-let ((pos (metal-algo--section noms)))
    (org-with-wide-buffer
     (goto-char pos)
     (let* ((fin (save-excursion (org-end-of-subtree t t) (point)))
            (deb (progn (org-end-of-meta-data t) (min (point) fin)))
            (txt (string-trim (buffer-substring-no-properties deb fin))))
       (unless (string-empty-p txt) txt)))))

(defun metal-algo--clore-etape (e)
  "Finaliser l'étape E : le corps accumulé est remis dans l'ordre."
  (let ((lignes (seq-remove #'string-empty-p
                            (mapcar #'string-trim (reverse (nth 2 e))))))
    (list (nth 0 e) (nth 1 e) (string-join lignes "\n") (nth 3 e) (nth 4 e))))

(defun metal-algo--analyser-procedure ()
  "Analyser la section « Procédure ».
Retourne (INTRO ETAPES DEBUT FIN), où ETAPES est une liste ordonnée de
\(NUMERO TEXTE CORPS POSITION NIVEAU).  La numérotation hiérarchique
\(1, 2, 2.1, 2.2…) est calculée d'après l'imbrication des listes
numérotées ; les numéros saisis ne servent qu'à repérer les éléments."
  (when-let ((debut (metal-algo--section metal-algo--noms-procedure)))
    (org-with-wide-buffer
     (goto-char debut)
     (let ((fin (save-excursion (org-end-of-subtree t t) (point)))
           pile intro etapes courante)
       (forward-line 1)
       (while (< (point) fin)
         (let ((ligne (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
           (cond
            ((string-match metal-algo--re-item ligne)
             (let ((ind (string-width (match-string 1 ligne)))
                   (texte (string-trim (match-string 2 ligne))))
               (while (and pile (> (caar pile) ind)) (pop pile))
               (if (and pile (= (caar pile) ind))
                   (setcdr (car pile) (1+ (cdar pile)))
                 (push (cons ind 1) pile))
               (when courante (push (metal-algo--clore-etape courante) etapes))
               (setq courante
                     (list (mapconcat (lambda (c) (number-to-string (cdr c)))
                                      (reverse pile) ".")
                           texte nil (line-beginning-position) (length pile)))))
            (courante (push ligne (nth 2 courante)))
            (t (push ligne intro))))
         (forward-line 1))
       (when courante (push (metal-algo--clore-etape courante) etapes))
       (list (string-trim (string-join (nreverse intro) "\n"))
             (nreverse etapes) debut fin)))))

(defun metal-algo--etapes ()
  (nth 1 (metal-algo--analyser-procedure)))

(defun metal-algo--formater-etape (e)
  (pcase-let* ((`(,num ,texte ,corps ,_pos ,niv) e)
               (ind (make-string (* 2 (1- niv)) ?\s)))
    (concat ind "Étape " num " : " texte
            (unless (string-empty-p corps)
              (concat "\n" (mapconcat (lambda (l) (concat ind "    " l))
                                      (split-string corps "\n") "\n"))))))

(defun metal-algo--texte-procedure ()
  (pcase-let ((`(,intro ,etapes . ,_) (metal-algo--analyser-procedure)))
    (string-trim
     (concat (or intro "")
             (unless (or (null intro) (string-empty-p intro)) "\n")
             (mapconcat #'metal-algo--formater-etape etapes "\n")))))

(defun metal-algo--liens-en-chemins (texte)
  "Remplacer les liens Org vers des fichiers par leur simple chemin."
  (replace-regexp-in-string metal-algo--re-lien-fichier "\\1" texte))

(defcustom metal-algo-apercu-lignes 6
  "Nombre de lignes de chaque fichier de données montrées à l'agent."
  :type 'integer)

(defconst metal-algo--re-nom-fichier
  "\\(?:^\\|[[:space:]:(«]\\)\\([^][:space:]()«»\"]+\\.\\(?:tsv\\|csv\\|txt\\|jsonl?\\|conllu?\\|xml\\)\\)"
  "Nom de fichier de données écrit en clair dans « Données ».")

(defun metal-algo--fichiers-donnees ()
  "Fichiers de « Données » (liens Org ou noms en clair), sans doublons."
  (let ((txt (or (metal-algo--texte-section '("Données" "Donnees")) ""))
        fichiers)
    ;; Les liens d'abord, puis les noms en clair une fois les liens
    ;; réduits à leur chemin (sinon « [[file:x » serait pris pour un nom).
    (dolist (re (list metal-algo--re-lien-fichier metal-algo--re-nom-fichier))
      (let ((pos 0))
        (while (string-match re txt pos)
          (push (match-string 1 txt) fichiers)
          (setq pos (match-end 1))))
      (setq txt (metal-algo--liens-en-chemins txt)))
    (seq-uniq (nreverse fichiers))))

(defun metal-algo--premieres-lignes (chemin n)
  "Les N premières lignes complètes de CHEMIN (UTF-8), tronquées à 300 caractères."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents chemin nil 0 (* 600 n)))
    (goto-char (point-min))
    (let (lignes)
      (while (and (< (length lignes) n) (search-forward "\n" nil t))
        (push (truncate-string-to-width
               (buffer-substring-no-properties (line-beginning-position 0)
                                               (line-end-position 0))
               300 nil nil "…")
              lignes))
      (nreverse lignes))))

(defun metal-algo--apercu-donnees ()
  "Bloc d'aperçu des fichiers de données existants, ou chaîne vide."
  (let ((dossier (file-name-directory (metal-algo--chemin-script)))
        blocs)
    (dolist (f (metal-algo--fichiers-donnees))
      (let ((chemin (expand-file-name f dossier)))
        (when-let ((lignes (and (file-regular-p chemin)
                                (file-readable-p chemin)
                                (metal-algo--premieres-lignes
                                 chemin metal-algo-apercu-lignes))))
          (push (format "--- %s (premières lignes) ---\n%s"
                        f (string-join lignes "\n"))
                blocs))))
    (if blocs
        (concat "\nAperçu des fichiers de données :\n"
                (string-join (nreverse blocs) "\n") "\n")
      "")))

(defun metal-algo--fichiers-manquants ()
  "Fichiers liés dans « Données » qui n'existent pas (relatifs au script)."
  (let ((txt (or (metal-algo--texte-section '("Données" "Donnees")) ""))
        (dossier (file-name-directory (metal-algo--chemin-script)))
        (pos 0) manquants)
    (while (string-match metal-algo--re-lien-fichier txt pos)
      (let ((f (match-string 1 txt)))
        (unless (file-exists-p (expand-file-name f dossier))
          (push f manquants)))
      (setq pos (match-end 0)))
    (nreverse manquants)))

(defun metal-algo--exemples-utiles-p (texte)
  "Vrai si TEXTE contient au moins un exemple rempli."
  (when texte
    (let ((rangees (seq-filter (lambda (l) (string-prefix-p "|" (string-trim l)))
                               (split-string texte "\n"))))
      (if (null rangees)
          t                               ; exemples rédigés en prose
        (> (cl-count-if (lambda (l)
                          (and (not (string-match-p "\\`[ \t]*|[-+]" l))
                               (string-match-p "[^|[:space:]]" l)))
                        rangees)
           1)))))                         ; plus que l'en-tête

(defun metal-algo--texte-complet ()
  "Retourne (TEXTE . EXEMPLES-P) : l'algorithme tel que transmis."
  (let* ((titre (or (metal-algo--mot-cle "TITLE") "Sans titre"))
         (donnees (metal-algo--texte-section '("Données" "Donnees")))
         (exemples (metal-algo--texte-section '("Exemples")))
         (ex-p (metal-algo--exemples-utiles-p exemples))
         (procedure (metal-algo--texte-procedure)))
    (when (string-empty-p procedure)
      (user-error "La section « Procédure » est vide ou absente"))
    (cons (metal-algo--liens-en-chemins
           (concat "Titre : " titre "\n\n"
                   (when donnees (concat "Données :\n" donnees "\n\n"))
                   "Procédure :\n" procedure
                   (when ex-p (concat "\n\nExemples :\n" exemples))))
          ex-p)))

;;;; Script associé et profil

(defun metal-algo--chemin-algo (py)
  (concat (file-name-sans-extension py) ".algo.org"))

(defun metal-algo--nom-tampon (py)
  (format "*Algorithme — %s*" (file-name-nondirectory py)))

(defun metal-algo--chemin-script ()
  "Chemin du script Python associé au tampon d'algorithme courant."
  (or (and (buffer-live-p metal-algo--script)
           (buffer-file-name metal-algo--script))
      (and buffer-file-name
           (concat (replace-regexp-in-string "\\.algo\\.org\\'" "" buffer-file-name)
                   ".py"))
      (user-error "Aucun script associé à cet algorithme")))

(defun metal-algo--tampon-script ()
  (unless (buffer-live-p metal-algo--script)
    (setq metal-algo--script (find-file-noselect (metal-algo--chemin-script))))
  metal-algo--script)

(defun metal-algo--profil-effectif ()
  (or metal-algo--profil
      (setq metal-algo--profil
            (metal-agent--profil-defaut-pour-mode 'python-mode))))

(defun metal-algo--en-cours-p ()
  (and metal-agent--process-courant
       (process-live-p metal-agent--process-courant)))

;;;; Consigne

(defun metal-algo--consigne (texte exemples-p)
  "Consigne complète, construite avec le profil du script."
  (let* ((fragments (metal-agent--fragments-actifs))
         (libre (string-trim (or metal-agent--instructions-libres ""))))
    (format
     "%s%s
Tâche :
Traduis fidèlement la PROCÉDURE ci-dessous en un programme Python complet
et exécutable, qui remplacera intégralement le fichier %s.

Règles de traduction :
%s
%s
Contraintes obligatoires :
- Ne modifie AUCUN fichier sur le disque. Ne demande PAS la permission
  d'écrire un fichier. RETOURNE le programme comme texte dans ta réponse.
- Ne donne aucune explication, aucun préambule, aucune question.
- Encadre le programme STRICTEMENT entre les deux marqueurs suivants,
  seuls sur leur ligne :
%s
(le programme ici)
%s
- N'utilise PAS de bloc Markdown ``` pour encadrer le programme.
- Après le marqueur de fin, écris le marqueur %s seul sur sa ligne,
  puis, au plus trois lignes, les choix que tu as faits et qui changent
  le résultat, sous la forme « Étape N : choix retenu », ou « Aucun ».
  Rien d'autre.
%s%s%s
%s"
     (metal-agent--context-header)
     (metal-agent--blindage-anti-agentique)
     (file-name-nondirectory (metal-algo--chemin-script))
     metal-algo-regles
     (if exemples-p (concat metal-algo--regle-exemples "\n") "")
     metal-agent--marqueur-debut
     metal-agent--marqueur-fin
     metal-algo--marqueur-ambiguites
     (if fragments
         (concat "\nContraintes du profil (style) :\n"
                 (mapconcat (lambda (f) (concat "- " f)) fragments "\n")
                 "\n")
       "")
     (if (string-empty-p libre) ""
       (concat "\nInstructions supplémentaires :\n" libre "\n"))
     (metal-algo--apercu-donnees)
     texte)))

(defmacro metal-algo--avec-contexte (&rest corps)
  "Exécuter CORPS avec le script comme source et le profil capturé."
  (declare (indent 0))
  `(let ((metal-agent-profil-actif (metal-algo--profil-effectif)))
     (setq metal-agent--source-buffer (metal-algo--tampon-script))
     ,@corps))

;;;; Run 1 — production

(defun metal-algo--ambiguites (raw)
  "Lignes d'ambiguïtés trouvées après le marqueur dédié de RAW."
  (when-let ((d (string-search metal-algo--marqueur-ambiguites raw)))
    (seq-remove
     (lambda (l) (or (string-empty-p l)
                     (string-match-p "\\`aucune?\\.?\\'" (downcase l))
                     (string-prefix-p "===" l)))
     (mapcar #'string-trim
             (split-string (substring raw (+ d (length metal-algo--marqueur-ambiguites)))
                           "\n")))))

(defun metal-algo--afficher-ambiguites (algo lignes)
  (let ((nom "*Choix de l'agent*"))
    (if (null lignes)
        (when-let ((b (get-buffer nom))) (quit-windows-on b))
      (with-current-buffer (get-buffer-create nom)
        (special-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Programme produit.  Choix faits par l'agent là où la "
                  "procédure ne précisait rien.\nSi un choix ne vous convient "
                  "pas, précisez l'étape et produisez de nouveau.\n\n")
          (dolist (l lignes)
            (insert "• ")
            (if (string-match "Étape \\([0-9]+\\(?:\\.[0-9]+\\)*\\)" l)
                (let ((num (match-string 1 l)))
                  (insert-text-button
                   l 'follow-link t
                   'action (lambda (_) (metal-algo--aller-etape algo num))))
              (insert l))
            (insert "\n")))
        (goto-char (point-min)))
      (display-buffer nom))))

(defun metal-algo--armer-execution-apres-revision (script original exemples)
  "Exécuter SCRIPT à la fin d'Ediff, si des changements ont été appliqués."
  (when metal-algo--avis-revision
    (advice-remove 'metal-agent--ediff-quit-hook metal-algo--avis-revision))
  (setq metal-algo--avis-revision
        (lambda (&optional appliquer _texte)
          (advice-remove 'metal-agent--ediff-quit-hook metal-algo--avis-revision)
          (setq metal-algo--avis-revision nil)
          (when (and appliquer (buffer-live-p script)
                     (not (string= (with-current-buffer script
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                                   original)))
            (run-at-time 0.5 nil #'metal-algo--executer-script script exemples))))
  (advice-add 'metal-agent--ediff-quit-hook :after metal-algo--avis-revision))

(defun metal-algo--recevoir (algo executer code raw)
  "Traiter la réponse de l'agent pour l'algorithme ALGO."
  (let ((programme (and (= code 0) (metal-agent--extract-code-block raw))))
    (if (or (null programme) (string-empty-p (string-trim programme)))
        ;; Erreur, authentification, réponse vide/tronquée : diagnostic standard.
        (metal-agent--handle-codex-code-response code raw)
      (let* ((script metal-agent--last-target-buffer)
             (original metal-agent--last-original)
             (nouveau (concat (string-trim programme) "\n"))
             (exemples (eq executer 'exemples)))
        (when-let ((status (get-buffer metal-agent-status-buffer-name)))
          (when-let ((win (get-buffer-window status t)))
            (ignore-errors (delete-window win))))
        (metal-algo--afficher-ambiguites algo (metal-algo--ambiguites raw))
        (cond
         ;; Script vide : le programme est écrit directement.
         ((string-empty-p (string-trim original))
          (with-current-buffer script
            (erase-buffer)
            (insert nouveau)
            (save-buffer))
          (message "🧭 Programme produit dans %s%s"
                   (buffer-name script) (metal-agent--suffixe-duree))
          (when executer (metal-algo--executer-script script exemples)))
         ;; Rien ne change.
         ((string= (string-trim nouveau) (string-trim original))
          (message "🧭 Le programme produit est identique au script actuel.")
          (when executer (metal-algo--executer-script script exemples)))
         ;; Sinon : révision Ediff, avec le garde-fou anti-effondrement.
         (t
          (let ((ratio (metal-agent--revision-effondree-p original nouveau)))
            (when (or (null ratio)
                      (metal-agent--confirmer-revision-suspecte raw ratio))
              (setq metal-agent--last-proposed nouveau)
              (when executer
                (metal-algo--armer-execution-apres-revision script original exemples))
              (metal-agent--reviser-via-ediff original nouveau)))))))))

(defun metal-algo-produire (&optional executer)
  "Run 1 : produire le programme à partir de l'algorithme.
EXECUTER : t pour exécuter ensuite, `exemples' pour vérifier les exemples."
  (interactive)
  (unless (derived-mode-p 'metal-algo-mode)
    (user-error "À lancer depuis un tampon d'algorithme"))
  (when (metal-algo--en-cours-p)
    (user-error "Une requête agent est déjà en cours"))
  (when buffer-file-name (save-buffer))
  (when-let ((manquants (metal-algo--fichiers-manquants)))
    (message "⚠ Fichier(s) introuvable(s) dans « Données » : %s"
             (string-join manquants ", "))
    (sit-for 1.5))
  (let* ((algo (current-buffer))
         (complet (metal-algo--texte-complet)))
    (setq metal-algo--tick-production (buffer-chars-modified-tick))
    (metal-algo--avec-contexte
      (let ((original (with-current-buffer metal-agent--source-buffer
                        (buffer-substring-no-properties (point-min) (point-max)))))
        (metal-agent--store-target 'buffer original)
        (metal-agent--run-codex
         (metal-algo--consigne (car complet) (cdr complet))
         "production du programme"
         (lambda (code raw) (metal-algo--recevoir algo executer code raw))
         "Production du programme à partir de l'algorithme")))))

(defun metal-algo-produire-et-executer (&optional exemples)
  "Double run : produire le programme, puis l'exécuter.
Si une révision Ediff est nécessaire, l'exécution suit sa validation."
  (interactive "P")
  (metal-algo-produire (if exemples 'exemples t)))

;;;; Run 2 — exécution

(defvar metal-algo-execution-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<f8>") #'metal-algo-erreur-vers-etape)
    m))

(define-minor-mode metal-algo-execution-mode
  "Tampon d'exécution d'un programme issu d'un algorithme.
\\<metal-algo-execution-mode-map>\\[metal-algo-erreur-vers-etape] : ramener l'erreur à l'étape fautive."
  :lighter " Algo")

(defun metal-algo--interpreteur ()
  (or metal-algo-python
      (and (boundp 'python-shell-interpreter)
           (stringp python-shell-interpreter)
           (executable-find python-shell-interpreter))
      (executable-find "python3")
      (executable-find "python")
      (user-error "Interpréteur Python introuvable")))

(defun metal-algo--executer-script (script exemples)
  "Enregistrer puis exécuter le tampon SCRIPT."
  (let ((fichier (buffer-file-name script))
        (algo (get-buffer (metal-algo--nom-tampon (buffer-file-name script)))))
    (with-current-buffer script
      (when (buffer-modified-p) (save-buffer)))
    (if metal-algo-fonction-execution
        (funcall metal-algo-fonction-execution fichier exemples)
      (let* ((tampon (get-buffer-create
                      (format "*Exécution — %s*" (file-name-nondirectory fichier))))
             (default-directory (file-name-directory fichier))
             (process-environment (append '("PYTHONUTF8=1" "PYTHONIOENCODING=utf-8")
                                          process-environment)))
        (when-let ((p (get-buffer-process tampon))) (delete-process p))
        (with-current-buffer tampon
          (let ((inhibit-read-only t)) (erase-buffer)))
        (apply #'make-comint-in-buffer "metal-algo-exec" tampon
               (metal-algo--interpreteur) nil
               "-u" (file-name-nondirectory fichier)
               (when exemples '("--exemples")))
        (with-current-buffer tampon
          (set-process-coding-system (get-buffer-process tampon) 'utf-8 'utf-8)
          (setq metal-algo--exec-script fichier
                metal-algo--exec-algo algo)
          (metal-algo-execution-mode 1))
        (display-buffer tampon)))))

(defun metal-algo-executer (&optional exemples)
  "Run 2 : exécuter le programme.  Avec \\[universal-argument], vérifier les exemples."
  (interactive "P")
  (let ((script (metal-algo--tampon-script)))
    (cond
     ((string-empty-p (string-trim (with-current-buffer script (buffer-string))))
      (when (y-or-n-p "Le script est vide.  Produire puis exécuter ? ")
        (metal-algo-produire (if exemples 'exemples t))))
     ((and (not (eql metal-algo--tick-production (buffer-chars-modified-tick)))
           (y-or-n-p "L'algorithme a changé depuis la dernière production.  Produire d'abord ? "))
      (metal-algo-produire (if exemples 'exemples t)))
     (t (metal-algo--executer-script script exemples)))))

;;;; Navigation étape ↔ code

(defun metal-algo--aller-etape (algo num)
  "Afficher l'étape NUM dans le tampon d'algorithme ALGO."
  (unless (buffer-live-p algo)
    (user-error "Le tampon d'algorithme n'est plus ouvert"))
  (pop-to-buffer algo)
  (if-let ((e (seq-find (lambda (e) (equal (car e) num)) (metal-algo--etapes))))
      (progn (goto-char (nth 3 e))
             (org-fold-show-context)
             (org-fold-show-entry))
    (message "Étape %s introuvable dans la procédure" num)))

(defun metal-algo--etape-au-point ()
  "Numéro de l'étape de la procédure qui contient le point."
  (pcase-let ((`(,_intro ,etapes ,debut ,fin) (metal-algo--analyser-procedure))
              (pos (line-beginning-position)))
    (or (and debut (> pos debut) (< pos fin)
             (car (car (last (seq-filter (lambda (e) (<= (nth 3 e) pos))
                                         etapes)))))
        (user-error "Le point n'est dans aucune étape de la « Procédure »"))))

(defun metal-algo--etape-au-point-py ()
  (save-excursion
    (end-of-line)
    (when (re-search-backward
           "#[ \t]*Étape[ \t]+\\([0-9]+\\(?:\\.[0-9]+\\)*\\)" nil t)
      (match-string-no-properties 1))))

(defun metal-algo-aller-au-code ()
  "Depuis une étape de l'algorithme, afficher le code correspondant."
  (interactive)
  (let ((num (metal-algo--etape-au-point))
        (script (metal-algo--tampon-script)))
    (pop-to-buffer script)
    (goto-char (point-min))
    (if (re-search-forward
         (format "#[ \t]*Étape[ \t]+%s\\(?:[^.0-9]\\|$\\)" (regexp-quote num)) nil t)
        (beginning-of-line)
      (message "L'étape %s n'apparaît pas dans le programme" num))))

(defun metal-algo-erreur-vers-etape ()
  "Ramener la dernière erreur d'exécution à l'étape fautive de l'algorithme."
  (interactive)
  (let ((fichier (or metal-algo--exec-script
                     (user-error "Pas un tampon d'exécution d'algorithme")))
        (algo metal-algo--exec-algo)
        ligne)
    (save-excursion
      (goto-char (point-max))
      (when (re-search-backward
             (format "File \"[^\"]*%s\", line \\([0-9]+\\)"
                     (regexp-quote (file-name-nondirectory fichier)))
             nil t)
        (setq ligne (string-to-number (match-string 1)))))
    (unless ligne (user-error "Aucune erreur trouvée dans la sortie"))
    (let ((num (with-current-buffer (find-file-noselect fichier)
                 (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- ligne))
                   (metal-algo--etape-au-point-py)))))
      (unless num (user-error "La ligne %d n'appartient à aucune étape" ligne))
      (message "Erreur à la ligne %d du programme → étape %s" ligne num)
      (metal-algo--aller-etape algo num))))

;;;; Autres commandes du tampon

(defun metal-algo-aller-au-script ()
  "Revenir au script Python."
  (interactive)
  (pop-to-buffer (metal-algo--tampon-script)))

(defun metal-algo-apercu ()
  "Afficher la consigne exacte qui serait envoyée à l'agent."
  (interactive)
  (let ((texte (metal-algo--avec-contexte
                 (let ((complet (metal-algo--texte-complet)))
                   (metal-algo--consigne (car complet) (cdr complet)))))
        (buf (get-buffer-create "*Aperçu — consigne de l'algorithme*")))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert texte)
        (goto-char (point-min))))
    (display-buffer buf)))

;;;; Barre de boutons

(defun metal-algo--bouton (label action aide)
  (metal-agent--toolbar-button label action aide))

(defun metal-algo--barre ()
  "Header-line du tampon d'algorithme."
  (concat
   (metal-agent--padding)
   (metal-algo--bouton (metal-toolbar-emoji "🛠️") #'metal-algo-produire
                       "Produire le programme à partir de l'algorithme (F6)")
   "   "
   (metal-algo--bouton (metal-toolbar-emoji "⏩") #'metal-algo-produire-et-executer
                       "Produire puis exécuter le programme (F5)")
   "   "
   (metal-algo--bouton (metal-toolbar-emoji "▶️") #'metal-algo-executer
                       "Exécuter le programme (F7 ; C-u F7 : vérifier les exemples)")
   "   "
   (metal-algo--bouton (metal-toolbar-emoji "📄") #'metal-algo-aller-au-script
                       "Revenir au script Python")
   "   "
   (metal-algo--bouton (metal-toolbar-emoji "🔎") #'metal-algo-apercu
                       "Aperçu de la consigne envoyée à l'agent")
   (if (metal-algo--en-cours-p)
       (concat "   "
               (metal-algo--bouton (metal-toolbar-emoji "❌") #'metal-agent-interrompre
                                   "Interrompre la production"))
     "")
   (metal-toolbar-separator)
   (propertize (format "Profil : %s · %s "
                       (or (metal-agent--profil-prop :nom (metal-algo--profil-effectif)) "?")
                       (or (metal-agent--current-label) "agent"))
               'face 'metal-agent-profil-indicateur-face
               'help-echo "Profil du script et agent sélectionné dans l'assistant")
   (metal-agent--padding)))

(defun metal-algo--poser-barre ()
  (setq-local header-line-format '(:eval (metal-algo--barre))))

;;;; Mode du tampon d'algorithme

(defvar metal-algo-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<f5>") #'metal-algo-produire-et-executer)
    (define-key m (kbd "<f6>") #'metal-algo-produire)
    (define-key m (kbd "<f7>") #'metal-algo-executer)
    (define-key m (kbd "<f8>") #'metal-algo-aller-au-code)
    m))

(define-derived-mode metal-algo-mode org-mode "Algorithme"
  "Rédaction d'un algorithme destiné à produire un programme Python.
\\{metal-algo-mode-map}"
  (when buffer-file-name
    (rename-buffer (metal-algo--nom-tampon (metal-algo--chemin-script)) t)))

;; Posée en dernier (après les hooks d'org-mode, qui peuvent installer
;; leur propre barre).
(add-hook 'metal-algo-mode-hook #'metal-algo--poser-barre)

(add-to-list 'auto-mode-alist '("\\.algo\\.org\\'" . metal-algo-mode))

(defun metal-algo--squelette (py)
  (insert "#+TITLE: "
          (capitalize (replace-regexp-in-string "[-_]" " " (file-name-base py)))
          "\n\n* Données\n- Entrée : \n- Sortie : \n"
          "\n* Procédure\n1. \n"
          "\n* Exemples\n")
  (goto-char (point-min))
  (search-forward "Entrée : " nil t))

;;;###autoload
(defun metal-algo-ouvrir ()
  "Ouvrir le tampon d'algorithme du script Python courant."
  (interactive)
  (unless (derived-mode-p 'python-mode 'python-ts-mode 'python-base-mode)
    (user-error "À lancer depuis un script Python"))
  (unless buffer-file-name
    (user-error "Enregistrez d'abord le script"))
  (let* ((script (current-buffer))
         (profil metal-agent-profil-actif)
         (py buffer-file-name)
         (fichier (metal-algo--chemin-algo py))
         (buf (or (get-buffer (metal-algo--nom-tampon py))
                  ;; Verrou temporaire : pendant `find-file-noselect', le
                  ;; tampon porte encore le nom « tri.algo.org » (sans « * »)
                  ;; et passe par `fundamental-mode' puis Org ; l'auto-
                  ;; sélection basculerait alors le profil vers Tronc commun.
                  (let* ((nouveau (not (file-exists-p fichier)))
                         (b (let ((metal-agent--profil-verrouille t))
                              (find-file-noselect fichier))))
                    (with-current-buffer b
                      (unless (derived-mode-p 'metal-algo-mode) (metal-algo-mode))
                      (when (and nouveau (= (buffer-size) 0))
                        (metal-algo--squelette py)))
                    b))))
    (with-current-buffer buf
      (setq metal-algo--script script
            metal-algo--profil profil))
    (pop-to-buffer buf)))

(provide 'metal-algo)
;;; metal-algo.el ends here
