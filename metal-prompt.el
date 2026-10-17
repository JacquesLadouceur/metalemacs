;;; metal-prompt.el --- Prompt structuré lié à un programme Prolog  -*- lexical-binding: t; -*-

;; Auteur : Jacques Ladouceur
;; Fait partie de MetalEmacs.

;;; Commentary:
;;
;; Depuis un fichier Prolog, le bouton 📝 de la barre agent ouvre un
;; tampon dédié où l'on rédige un PROMPT STRUCTURÉ (en Org), lié au
;; programme.  Contrairement à la programmation algorithmique (metal-algo),
;; le programme n'est pas produit à partir du prompt : il reste le document
;; maître.  Le prompt est une demande de modification qui lui est attachée ;
;; l'agent ajoute ou modifie des clauses selon les consignes, et le résultat
;; passe toujours par la révision Ediff (metal-revision), bloc par bloc.
;; Les clauses écrites à la main ne peuvent donc jamais disparaître sans que
;; l'utilisateur le voie.
;;
;; Le tampon a sa propre barre de boutons :
;;
;;   🛠️  Appliquer   l'agent modifie le programme, puis révision Ediff (F6)
;;   ▶️  Tester      consulte le programme et lance les Exemples (F7)
;;   📄  Programme   revenir au fichier Prolog
;;   🔎  Aperçu      consigne exacte envoyée à l'agent
;;
;; Le prompt est enregistré à côté du programme :
;; conjugueur.pl → conjugueur.prompt.org, dans le tampon
;; « *Prompt — conjugueur.pl* » (le « * » initial tient l'auto-sélection
;; de profil à l'écart : le profil du programme reste actif).
;;
;; Structure d'un prompt :
;;
;;   #+TITLE: Exceptions du conjugueur
;;   * Contexte                     (prédicats à exploiter, fichiers liés)
;;   - Prédicats : conjuguer/5, radical/3
;;   - Terminaisons : [[file:terminaisons.pl]]   (contenu transmis à l'agent)
;;   * Consignes
;;   1. Traiter les verbes en -eler/-eter sur le modèle de mener.
;;   2. Ajouter le futur simple.
;;      1. sans toucher au présent.
;;   * Exemples
;;   ?- conjuguer(appeler, present, 1, sg, F).
;;   F = appelle.
;;   ?- conjuguer(V, T, P, N, mènes).
;;   V = mener, T = present, P = 2, N = sg.
;;
;; Un exemple est une requête « ?- … . » suivie, facultativement, du
;; résultat attendu (plusieurs solutions séparées par « ; », « false »
;; pour un échec).  Le bouton Tester les exécute dans un SWI-Prolog
;; séparé et affiche OK ou ÉCHEC pour chacun.
;;
;; Toute ligne commentée (« # » en tête, syntaxe Org) est ignorée : ni
;; transmise à l'agent, ni testée.  Une consigne commentée garde son
;; numéro et entraîne ses sous-consignes ; F9 met en commentaire ou
;; réactive la consigne au point (ou la ligne, ou la région).

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'metal-agent)
(require 'metal-algo)   ; lecture des sections Org et aperçus de fichiers

(declare-function metal-prolog--detecter-swipl "metal-prolog" ())

;;;; Réglages

(defgroup metal-prompt nil
  "Prompt structuré lié à un programme Prolog."
  :group 'metal-agent
  :prefix "metal-prompt-")

(defcustom metal-prompt-marquer-consignes t
  "Si non-nil, l'agent précède chaque ajout d'un commentaire « % Consigne N ».
Ces commentaires permettent de passer d'une consigne au code qui la
traite (F8).  Ils restent visibles dans la révision Ediff, où l'on peut
les refuser comme n'importe quel bloc."
  :type 'boolean)

(defcustom metal-prompt-taille-max-fichier 30000
  "Nombre maximal de caractères transmis pour un fichier Prolog lié."
  :type 'integer)

(defcustom metal-prompt-delai-tests 60
  "Délai maximal (secondes) accordé à l'exécution des Exemples."
  :type 'integer)

(defcustom metal-prompt-regles
  "1. Le programme actuel est la référence.  Conserve à l'identique tout
   ce que les consignes ne visent pas : clauses, faits, commentaires,
   directives, ordre des clauses et mise en page.
2. Ajoute les clauses et les faits demandés à l'endroit logique, à côté
   de ceux de même nature.  Ne modifie une clause existante que si une
   consigne l'exige ; ne supprime rien sans demande explicite.
3. Applique les consignes dans l'ordre et n'en ajoute aucune de ton cru.
   Ce qu'elles ne précisent pas, règle-le selon les consignes du profil.
4. Une consigne déjà satisfaite par le programme (code marqué
   « % Consigne N », ou clauses qui produisent déjà l'effet demandé)
   n'est pas retraitée : laisse ce code tel quel.  N'ajoute jamais un
   fait ou une clause déjà présent, même sous une autre mise en page.
   Si toutes les consignes sont satisfaites, retourne le programme
   inchangé.
5. Le code doit satisfaire les Exemples fournis.
6. N'exécute aucune commande et n'ouvre aucun fichier : le contenu des
   fichiers liés est fourni plus bas."
  "Règles de modification ajoutées à la consigne envoyée à l'agent."
  :type 'string)

(defconst metal-prompt--regle-marquage
  "7. Précède chaque groupe de clauses ou de faits que tu ajoutes ou
   modifies d'un commentaire « % Consigne N », où N est le numéro de la
   consigne traitée (ex. « % Consigne 2.1 »).  Ne touche pas aux
   commentaires « % Consigne » déjà présents.")

(defconst metal-prompt--marqueur-notes "===METAL-PROMPT-NOTES===")

(defconst metal-prompt--noms-contexte '("Contexte"))
(defconst metal-prompt--noms-consignes '("Consignes" "Consigne"))
(defconst metal-prompt--noms-exemples '("Exemples" "Exemple"))

(defconst metal-prompt--re-fichier-prolog
  "\\(?:^\\|[[:space:]:(«]\\)\\([^][:space:]()«»\"]+\\.\\(?:pl\\|pro\\)\\)\\b"
  "Nom de fichier Prolog écrit en clair dans « Contexte ».")

;;;; État

(defvar-local metal-prompt--programme nil
  "Tampon du programme Prolog associé au tampon de prompt.")
(defvar-local metal-prompt--profil nil
  "Profil metal-agent capturé à l'ouverture (celui du programme).")

;;;; Fichiers et tampons associés

(defun metal-prompt--chemin-prompt (pl)
  (concat (file-name-sans-extension pl) ".prompt.org"))

(defun metal-prompt--nom-tampon (pl)
  (format "*Prompt — %s*" (file-name-nondirectory pl)))

(defun metal-prompt--chemin-programme ()
  "Chemin du programme Prolog associé au tampon de prompt courant."
  (or (and (buffer-live-p metal-prompt--programme)
           (buffer-file-name metal-prompt--programme))
      (and buffer-file-name
           (concat (replace-regexp-in-string "\\.prompt\\.org\\'" ""
                                             buffer-file-name)
                   ".pl"))
      (user-error "Aucun programme associé à ce prompt")))

(defun metal-prompt--tampon-programme ()
  (unless (buffer-live-p metal-prompt--programme)
    (setq metal-prompt--programme
          (find-file-noselect (metal-prompt--chemin-programme))))
  metal-prompt--programme)

(defun metal-prompt--profil-effectif ()
  (or metal-prompt--profil
      (setq metal-prompt--profil
            (metal-agent--profil-defaut-pour-mode 'prolog-mode))))

(defun metal-prompt--en-cours-p ()
  (and metal-agent--process-courant
       (process-live-p metal-agent--process-courant)))

;;;; Lecture des consignes (listes numérotées hiérarchiques)

(defconst metal-prompt--re-commentaire "^[ \t]*#\\(?:[ \t]\\|$\\)"
  "Ligne de commentaire Org : « # » en tête (après d'éventuels blancs).
Ne reconnaît pas les mots-clés « #+… ».")

(defconst metal-prompt--re-item-commente
  "^\\([ \t]*\\)# ?\\([ \t]*\\)[0-9]+[.)][ \t]+\\(.*\\)$"
  "Élément de liste numérotée mis en commentaire : « # 2. texte ».")

(defun metal-prompt--sans-commentaires (texte)
  "TEXTE privé de ses lignes de commentaire Org, ou nil s'il devient vide."
  (when texte
    (let ((r (string-trim
              (mapconcat #'identity
                         (seq-remove (lambda (l) (string-match-p
                                                  metal-prompt--re-commentaire l))
                                     (split-string texte "\n"))
                         "\n"))))
      (unless (string-empty-p r) r))))

(defun metal-prompt--section (noms)
  "Texte de la section NOMS, sans les lignes commentées."
  (metal-prompt--sans-commentaires (metal-algo--texte-section noms)))

(defun metal-prompt--analyser-consignes ()
  "Analyser la section « Consignes ».
Retourne (INTRO CONSIGNES DEBUT FIN DESACTIVEES), où CONSIGNES est une
liste ordonnée de (NUMERO TEXTE CORPS POSITION NIVEAU) et DESACTIVEES la
liste des numéros des consignes mises en commentaire.

La numérotation hiérarchique (1, 2, 2.1…) est calculée d'après
l'imbrication des listes ; les numéros saisis ne servent qu'à repérer
les éléments.  Une consigne commentée (« # 2. … ») garde son numéro,
pour que les autres ne changent pas de numéro — et leurs marques
« % Consigne N » dans le code restent justes.  Ses sous-consignes, même
non commentées, sont désactivées avec elle ; les autres lignes
commentées sont ignorées."
  (when-let ((debut (metal-algo--section metal-prompt--noms-consignes)))
    (org-with-wide-buffer
     (goto-char debut)
     (let ((fin (save-excursion (org-end-of-subtree t t) (point)))
           pile intro items courant desactivees saut)
       (forward-line 1)
       (while (< (point) fin)
         (let* ((ligne (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
                (ind-ligne (progn (string-match "^[ \t]*" ligne)
                                  (string-width (match-string 0 ligne))))
                (vide (string-blank-p ligne)))
           ;; Fin du bloc d'une consigne désactivée : ligne non vide qui
           ;; n'est pas plus indentée que la consigne.
           (when (and saut (not vide)
                      (<= (if (string-match metal-prompt--re-item-commente ligne)
                              (string-width (concat (match-string 1 ligne)
                                                    (match-string 2 ligne)))
                            ind-ligne)
                          saut))
             (setq saut nil))
           (cond
            (saut nil)
            ((or (string-match metal-algo--re-item ligne)
                 (string-match metal-prompt--re-item-commente ligne))
             (let* ((commente (string-match-p metal-prompt--re-commentaire ligne))
                    (ind (if commente
                             (progn (string-match metal-prompt--re-item-commente ligne)
                                    (string-width (concat (match-string 1 ligne)
                                                          (match-string 2 ligne))))
                           (string-width (match-string 1 ligne))))
                    (texte (string-trim (match-string (if commente 3 2) ligne))))
               (while (and pile (> (caar pile) ind)) (pop pile))
               (if (and pile (= (caar pile) ind))
                   (setcdr (car pile) (1+ (cdar pile)))
                 (push (cons ind 1) pile))
               (when courant (push (metal-algo--clore-etape courant) items))
               (let ((num (mapconcat (lambda (c) (number-to-string (cdr c)))
                                     (reverse pile) ".")))
                 (if commente
                     (setq courant nil
                           saut ind)
                   (setq courant (list num texte nil (line-beginning-position)
                                       (length pile))))
                 (when commente (push num desactivees)))))
            ((string-match-p metal-prompt--re-commentaire ligne) nil)
            (courant (push ligne (nth 2 courant)))
            (t (push ligne intro))))
         (forward-line 1))
       (when courant (push (metal-algo--clore-etape courant) items))
       (list (string-trim (string-join (nreverse intro) "\n"))
             (nreverse items) debut fin (nreverse desactivees))))))

(defun metal-prompt--consignes-desactivees ()
  (nth 4 (metal-prompt--analyser-consignes)))

(defun metal-prompt--formater-consigne (c)
  (pcase-let* ((`(,num ,texte ,corps ,_pos ,niv) c)
               (ind (make-string (* 2 (1- niv)) ?\s)))
    (concat ind "Consigne " num " : " texte
            (unless (string-empty-p corps)
              (concat "\n" (mapconcat (lambda (l) (concat ind "    " l))
                                      (split-string corps "\n") "\n"))))))

(defun metal-prompt--texte-consignes ()
  (pcase-let ((`(,intro ,items . ,_) (metal-prompt--analyser-consignes)))
    (string-trim
     (concat (or intro "")
             (unless (or (null intro) (string-empty-p intro)) "\n")
             (mapconcat #'metal-prompt--formater-consigne items "\n")))))

;;;; Exemples

(defconst metal-prompt--re-but-nu
  "\\`[a-z][a-zA-Z0-9_]*([^?]*)[ \t]*\\.\\'"
  "But Prolog complet écrit sans « ?- » : « pred(args). » sur une ligne.")

(defun metal-prompt--exemples ()
  "Liste des exemples de la section « Exemples » : ((REQUÊTE . ATTENDU) …).
REQUÊTE est le but sans « ?- » ni point final ; ATTENDU est le résultat
attendu (chaîne, éventuellement vide).  Une requête peut s'étendre sur
plusieurs lignes, jusqu'à la ligne qui se termine par un point.

Une ligne qui a la forme d'un but complet sans « ?- », comme
« conjuguer(manger, pi, [mange, …]). », est aussi un exemple : sans
ligne de résultat sous elle, elle doit simplement réussir (« true. »)."
  (let ((texte (or (metal-prompt--section metal-prompt--noms-exemples) ""))
        exemples requete attendu en-requete nu)
    (cl-flet ((clore ()
                (when requete
                  (let ((att (string-trim (string-join (nreverse attendu) " "))))
                    (push (cons (string-trim
                                 (replace-regexp-in-string
                                  "\\.[ \t]*\\'" "" (string-join (nreverse requete) " ")))
                                (if (and nu (string-empty-p att)) "true." att))
                          exemples)))
                (setq requete nil attendu nil nu nil)))
      (dolist (l (split-string texte "\n"))
        (let ((l (string-trim l)))
          (cond
           ((string-prefix-p "?-" l)
            (clore)
            (setq requete (list (string-trim (substring l 2)))
                  en-requete (not (string-suffix-p "." l))))
           ((and (not en-requete)
                 (string-match-p metal-prompt--re-but-nu l))
            (clore)
            (setq requete (list l) nu t))
           (en-requete
            (push l requete)
            (setq en-requete (not (string-suffix-p "." l))))
           ((and requete (not (string-empty-p l))
                 (not (string-prefix-p "#" l)))
            (push l attendu)))))
      (clore))
    (nreverse exemples)))

;;;; Fichiers liés

(defun metal-prompt--fichiers-lies ()
  "Fichiers de « Contexte » (liens Org ou noms en clair), sans doublons."
  (let ((txt (or (metal-prompt--section metal-prompt--noms-contexte) ""))
        fichiers)
    (dolist (re (list metal-algo--re-lien-fichier
                      metal-prompt--re-fichier-prolog
                      metal-algo--re-nom-fichier))
      (let ((pos 0))
        (while (string-match re txt pos)
          (push (match-string 1 txt) fichiers)
          (setq pos (match-end 1))))
      (setq txt (metal-algo--liens-en-chemins txt)))
    (seq-uniq (nreverse fichiers))))

(defun metal-prompt--prolog-p (f)
  (string-match-p "\\.\\(pl\\|pro\\)\\'" f))

(defun metal-prompt--bloc-fichiers ()
  "Contenu des fichiers Prolog liés et aperçu des fichiers de données."
  (let* ((programme (metal-prompt--chemin-programme))
         (dossier (file-name-directory programme))
         blocs)
    (dolist (f (metal-prompt--fichiers-lies))
      (let ((chemin (expand-file-name f dossier)))
        (when (and (file-regular-p chemin) (file-readable-p chemin)
                   (not (file-equal-p chemin programme)))
          (push
           (if (metal-prompt--prolog-p f)
               (format "--- %s (fichier Prolog lié, à ne PAS reproduire) ---\n%s"
                       f
                       (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8))
                           (insert-file-contents chemin))
                         (let ((s (buffer-string)))
                           (if (> (length s) metal-prompt-taille-max-fichier)
                               (concat (substring s 0 metal-prompt-taille-max-fichier)
                                       "\n% … (tronqué)")
                             s))))
             (format "--- %s (premières lignes) ---\n%s"
                     f (string-join (metal-algo--premieres-lignes
                                     chemin metal-algo-apercu-lignes)
                                    "\n")))
           blocs))))
    (if blocs
        (concat "\nFichiers liés :\n" (string-join (nreverse blocs) "\n") "\n")
      "")))

(defun metal-prompt--fichiers-manquants ()
  (let ((dossier (file-name-directory (metal-prompt--chemin-programme))))
    (seq-remove (lambda (f) (file-exists-p (expand-file-name f dossier)))
                (metal-prompt--fichiers-lies))))

;;;; Consigne envoyée à l'agent

(defun metal-prompt--texte-complet ()
  "Le prompt tel que transmis : titre, contexte, consignes, exemples."
  (let* ((titre (or (metal-algo--mot-cle "TITLE") "Sans titre"))
         (contexte (metal-prompt--section metal-prompt--noms-contexte))
         (consignes (metal-prompt--texte-consignes))
         (exemples (metal-prompt--section metal-prompt--noms-exemples)))
    (when (string-empty-p consignes)
      (user-error (if (metal-prompt--consignes-desactivees)
                      "Toutes les consignes sont en commentaire"
                    "La section « Consignes » est vide ou absente")))
    (metal-algo--liens-en-chemins
     (concat "Titre : " titre "\n\n"
             (when contexte (concat "Contexte :\n" contexte "\n\n"))
             "Consignes :\n" consignes
             (when exemples
               (concat "\n\nExemples (requêtes au toplevel et résultat attendu) :\n"
                       exemples))))))

(defun metal-prompt--consigne (texte programme)
  "Consigne complète pour le prompt TEXTE et le PROGRAMME actuel."
  (let* ((fragments (metal-agent--fragments-actifs))
         (libre (string-trim (or metal-agent--instructions-libres "")))
         (nom (file-name-nondirectory (metal-prompt--chemin-programme))))
    (format
     "%s%s
Tâche :
Modifie le programme Prolog %s selon les CONSIGNES du prompt ci-dessous,
puis retourne le fichier COMPLET ainsi modifié.

Règles de modification :
%s
%s
Contraintes obligatoires :
- Ne modifie AUCUN fichier sur le disque. Ne demande PAS la permission
  d'écrire un fichier. RETOURNE le programme comme texte dans ta réponse.
- Retourne le fichier ENTIER, y compris tout ce qui n'a pas changé.
- Ne donne aucune explication, aucun préambule, aucune question.
- Encadre le programme STRICTEMENT entre les deux marqueurs suivants,
  seuls sur leur ligne :
%s
(le programme complet ici)
%s
- N'utilise PAS de bloc Markdown ``` pour encadrer le programme.
- Après le marqueur de fin, écris le marqueur %s seul sur sa ligne,
  puis, au plus cinq lignes, sous la forme « Consigne N : note », ce que
  l'utilisateur doit savoir : prédicat existant introuvable, nouveau
  prédicat créé, clause existante modifiée, choix qui change le
  résultat, consigne déjà en place (« Consigne N : déjà en place »).
  Ou « Aucune ».  Rien d'autre.
%s%s%s
Prompt :
%s

Programme actuel (%s) :
%s
%s
%s"
     (metal-agent--context-header)
     (metal-agent--blindage-anti-agentique)
     nom
     metal-prompt-regles
     (if metal-prompt-marquer-consignes
         (concat metal-prompt--regle-marquage "\n")
       "")
     metal-agent--marqueur-debut
     metal-agent--marqueur-fin
     metal-prompt--marqueur-notes
     (if fragments
         (concat "\nContraintes du profil :\n"
                 (mapconcat (lambda (f) (concat "- " f)) fragments "\n")
                 "\n")
       "")
     (if (string-empty-p libre) ""
       (concat "\nInstructions supplémentaires :\n" libre "\n"))
     (metal-prompt--bloc-fichiers)
     texte
     nom
     metal-agent--marqueur-debut
     programme
     metal-agent--marqueur-fin)))

(defmacro metal-prompt--avec-contexte (&rest corps)
  "Exécuter CORPS avec le programme comme source et le profil capturé."
  (declare (indent 0))
  `(let ((metal-agent-profil-actif (metal-prompt--profil-effectif)))
     (setq metal-agent--source-buffer (metal-prompt--tampon-programme))
     ,@corps))

;;;; Application

(defun metal-prompt--notes (raw)
  "Lignes de notes trouvées après le marqueur dédié de RAW."
  (when-let ((d (string-search metal-prompt--marqueur-notes raw)))
    (seq-remove
     (lambda (l) (or (string-empty-p l)
                     (string-match-p "\\`aucune?\\.?\\'" (downcase l))
                     (string-prefix-p "===" l)))
     (mapcar #'string-trim
             (split-string (substring raw (+ d (length metal-prompt--marqueur-notes)))
                           "\n")))))

(defvar-local metal-prompt--notes-prompt nil
  "Tampon de prompt dont proviennent les notes affichées.")
(defvar-local metal-prompt--notes-propose nil
  "Programme proposé par l'agent, auquel se rapportent les notes.")

(defvar metal-prompt-notes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "?") #'metal-prompt-preciser-note)
    m))

(defface metal-prompt-notes-consigne-face
  '((t :inherit bold))
  "Titre d'un groupe de notes : numéro et texte de la consigne.")

(defface metal-prompt-notes-texte-face
  '((t :inherit default))
  "Texte d'une note de l'agent.")

(defconst metal-prompt--notes-retrait "      "
  "Retrait des notes sous leur consigne, repris sur les lignes repliées.")

(define-derived-mode metal-prompt-notes-mode special-mode "Notes"
  "Notes de l'agent sur les modifications proposées.
\\{metal-prompt-notes-mode-map}"
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (setq-local header-line-format
              (concat " Clic sur une consigne : y revenir   ·   "
                      "❓ ou « ? » sur une note : demander une précision")))

(defun metal-prompt--grouper-notes (lignes)
  "Grouper LIGNES par consigne : ((NUM . (TEXTE…)) …), dans l'ordre d'arrivée.
NUM est nil pour une note qui ne nomme aucune consigne.  Le préfixe
« Consigne N : » est retiré du texte."
  (let (groupes)
    (dolist (l lignes)
      (let* ((num (and (string-match
                        "\\`[ \t]*Consigne[ \t]+\\([0-9]+\\(?:\\.[0-9]+\\)*\\)[ \t]*:?[ \t]*"
                        l)
                       (match-string 1 l)))
             (texte (string-trim (if num (substring l (match-end 0)) l)))
             (texte (if (string-empty-p texte) l
                      (concat (upcase (substring texte 0 1)) (substring texte 1))))
             (groupe (assoc num groupes)))
        (if groupe
            (setcdr groupe (append (cdr groupe) (list texte)))
          (setq groupes (append groupes (list (list num texte)))))))
    groupes))

(defun metal-prompt--texte-consigne (prompt num)
  "Texte de la consigne NUM du tampon PROMPT, ou nil."
  (when (buffer-live-p prompt)
    (with-current-buffer prompt
      (nth 1 (seq-find (lambda (c) (equal (car c) num))
                       (nth 1 (ignore-errors (metal-prompt--analyser-consignes))))))))

(defun metal-prompt--afficher-notes (prompt lignes &optional propose)
  "Afficher les notes LIGNES, groupées par consigne.
PROPOSE est le programme qu'elles commentent."
  (let ((nom "*Notes de l'agent*"))
    (if (null lignes)
        (when-let ((b (get-buffer nom))) (quit-windows-on b))
      (with-current-buffer (get-buffer-create nom)
        (metal-prompt-notes-mode)
        (setq metal-prompt--notes-prompt prompt
              metal-prompt--notes-propose propose)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "\n")
          (dolist (groupe (metal-prompt--grouper-notes lignes))
            (let* ((num (car groupe))
                   (titre (if num
                              (let ((txt (metal-prompt--texte-consigne prompt num)))
                                (concat "Consigne " num (if txt (concat " — " txt) "")))
                            "Remarques générales")))
              (insert " ")
              (if num
                  (insert-text-button
                   titre 'follow-link t
                   'face 'metal-prompt-notes-consigne-face
                   'mouse-face 'highlight
                   'help-echo "Revenir à cette consigne dans le prompt"
                   'action (lambda (_) (metal-prompt--aller-consigne prompt num)))
                (insert (propertize titre 'face 'metal-prompt-notes-consigne-face)))
              (insert "\n")
              (dolist (texte (cdr groupe))
                (let ((note (if num (format "Consigne %s : %s" num texte) texte))
                      (debut (point)))
                  (insert "   ")
                  (insert-text-button
                   "❓" 'follow-link t
                   'face 'default
                   'mouse-face 'highlight
                   'help-echo "Demander à l'agent de préciser cette note"
                   'action (lambda (_) (metal-prompt-preciser-note note)))
                  (insert " " (propertize texte 'face 'metal-prompt-notes-texte-face))
                  (put-text-property debut (point) 'metal-prompt-note note)
                  (put-text-property debut (point) 'wrap-prefix
                                     metal-prompt--notes-retrait)
                  (insert "\n")))
              (insert "\n"))))
        (goto-char (point-min))
        (forward-line 1))
      (display-buffer nom))))

;;;; Préciser une note

(defun metal-prompt--note-au-point ()
  (or (get-text-property (line-beginning-position) 'metal-prompt-note)
      (get-text-property (point) 'metal-prompt-note)
      (user-error "Placer le curseur sur une note")))

(defun metal-prompt--consigne-precision (note question programme propose texte)
  "Consigne d'analyse pour préciser NOTE (sans modifier le programme)."
  (format
   "%s%s
Tâche :
Lors d'une modification du programme Prolog selon le prompt ci-dessous,
tu as émis la note suivante :

  %s

Précise cette note pour l'utilisateur.%s
N'apporte aucune modification au programme ; il s'agit d'une analyse.

Contenu attendu :
1. Ce que la note veut dire concrètement : quelles clauses sont en cause
   (nom/arité et lignes) et pourquoi.
2. Un exemple au toplevel qui montre le problème : la requête, les
   solutions obtenues et celles qu'on attendrait.
3. Conseils pour la suite : les options possibles, avec leurs avantages
   et leurs inconvénients (réversibilité, coût, lisibilité), et ta
   recommandation.
4. Pour l'option recommandée : la consigne à ajouter au prompt, rédigée
   comme un élément de la section « Consignes » (une ligne, à l'impératif),
   et l'exemple « ?- … . » avec son résultat attendu à ajouter à la
   section « Exemples ».

Format de la réponse (IMPORTANT) — elle sera lue dans un tampon Emacs
en texte brut, étroit :
- Réponds en français.
- N'utilise AUCUN tableau Markdown.
- Garde les lignes sous ~78 caractères.
- Cite le code Prolog en blocs ```prolog.
%s%s
Prompt :
%s

Programme proposé (celui que commente la note) :
```prolog
%s
```
%s"
   (metal-agent--context-header)
   (metal-agent--blindage-anti-agentique)
   note
   (if (string-empty-p question) ""
     (concat "\nQuestion de l'utilisateur : " question))
   (metal-agent--bloc-instructions-libres)
   (let ((fragments (metal-agent--fragments-actifs)))
     (if fragments
         (concat "\nConsignes du profil (pour juger les options) :\n"
                 (mapconcat (lambda (f) (concat "- " f)) fragments "\n") "\n")
       ""))
   texte
   (or propose programme)
   (if (and propose (not (string= (string-trim propose) (string-trim programme))))
       (concat "\nProgramme actuel (après révision ; peut différer) :\n"
               "```prolog\n" programme "\n```\n")
     "")))

(defun metal-prompt-preciser-note (&optional note)
  "Demander à l'agent de préciser NOTE (par défaut, celle du point).
La réponse — explication, exemple, options et consigne à ajouter — est
affichée en lecture seule ; le programme n'est pas modifié."
  (interactive)
  (let* ((note (or note (metal-prompt--note-au-point)))
         (notes (get-buffer "*Notes de l'agent*"))
         (prompt (and notes (buffer-local-value 'metal-prompt--notes-prompt notes)))
         (propose (and notes (buffer-local-value 'metal-prompt--notes-propose notes))))
    (unless (buffer-live-p prompt)
      (user-error "Le tampon de prompt n'est plus ouvert"))
    (when (metal-prompt--en-cours-p)
      (user-error "Une requête agent est déjà en cours"))
    (let ((question (string-trim
                     (read-string "Question (vide : explication et conseils) : "))))
      (with-current-buffer prompt
        (let ((texte (metal-prompt--texte-complet)))
          (metal-prompt--avec-contexte
            (let ((programme (with-current-buffer metal-agent--source-buffer
                               (save-restriction
                                 (widen)
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))))
              (metal-agent--run-codex
               (metal-prompt--consigne-precision note question programme
                                                 propose texte)
               "précision d'une note"
               (lambda (code raw) (metal-prompt--afficher-precision note code raw))
               "Précision de la note"))))))))

(defun metal-prompt--afficher-precision (note code raw)
  (when-let ((status (get-buffer metal-agent-status-buffer-name)))
    (when-let ((win (get-buffer-window status t)))
      (ignore-errors (delete-window win))))
  (if (or (/= code 0) (null raw) (string-empty-p (string-trim raw)))
      (metal-agent--handle-codex-code-response code raw)
    (let ((buf (get-buffer-create "*Précision de l'agent*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Note : " note "\n\n" (string-trim raw) "\n")
          (goto-char (point-min)))
        (if (fboundp 'markdown-view-mode) (markdown-view-mode) (special-mode)))
      (display-buffer buf)
      (message "📝 Précision reçue%s" (metal-agent--suffixe-duree)))))

(defun metal-prompt--recevoir (prompt code raw)
  "Traiter la réponse de l'agent pour le tampon de prompt PROMPT."
  (let ((nouveau (and (= code 0) (metal-agent--extract-code-block raw))))
    (if (or (null nouveau) (string-empty-p (string-trim nouveau)))
        ;; Erreur, authentification, réponse vide/tronquée : diagnostic standard.
        (metal-agent--handle-codex-code-response code raw)
      (let* ((programme metal-agent--last-target-buffer)
             (original metal-agent--last-original)
             (nouveau (concat (string-trim-right nouveau) "\n")))
        (when-let ((status (get-buffer metal-agent-status-buffer-name)))
          (when-let ((win (get-buffer-window status t)))
            (ignore-errors (delete-window win))))
        (metal-prompt--afficher-notes prompt (metal-prompt--notes raw) nouveau)
        (cond
         ;; Programme vide : rien à protéger, le résultat est écrit directement.
         ((string-empty-p (string-trim original))
          (with-current-buffer programme
            (erase-buffer)
            (insert nouveau)
            (save-buffer))
          (message "📝 Programme écrit dans %s%s"
                   (buffer-name programme) (metal-agent--suffixe-duree)))
         ((string= (string-trim nouveau) (string-trim original))
          (message "📝 L'agent n'a proposé aucune modification.%s"
                   (metal-agent--suffixe-duree)))
         ;; Sinon : révision Ediff, avec le garde-fou anti-effondrement.
         (t
          (let ((ratio (metal-agent--revision-effondree-p original nouveau)))
            (when (or (null ratio)
                      (metal-agent--confirmer-revision-suspecte raw ratio))
              (setq metal-agent--last-proposed nouveau)
              (metal-revision-lancer
               original nouveau
               :cible programme
               :etiquettes (cons (concat "PROGRAMME — "
                                         (file-name-nondirectory
                                          (buffer-file-name programme)))
                                 "MODIFICATIONS PROPOSÉES")
               :apres (lambda (appliquer resultat)
                        (metal-agent--close-ui-buffers)
                        (when (and appliquer resultat)
                          (message "📝 Blocs acceptés appliqués à %s (non enregistré)."
                                   (buffer-name programme)))))))))))))

(defun metal-prompt-appliquer ()
  "Envoyer le prompt à l'agent ; ses modifications passent par Ediff."
  (interactive)
  (unless (derived-mode-p 'metal-prompt-mode)
    (user-error "À lancer depuis un tampon de prompt"))
  (when (metal-prompt--en-cours-p)
    (user-error "Une requête agent est déjà en cours"))
  (when (metal-revision-active-p)
    (user-error "Une révision est déjà ouverte — terminez-la d'abord"))
  (when buffer-file-name (save-buffer))
  (when-let ((manquants (metal-prompt--fichiers-manquants)))
    (message "⚠ Fichier(s) introuvable(s) dans « Contexte » : %s"
             (string-join manquants ", "))
    (sit-for 1.5))
  (when-let ((off (metal-prompt--consignes-desactivees)))
    (message "📝 Consigne(s) en commentaire, non transmise(s) : %s"
             (string-join off ", "))
    (sit-for 1))
  (let ((prompt (current-buffer))
        (texte (metal-prompt--texte-complet)))
    (metal-prompt--avec-contexte
      (let ((original (with-current-buffer metal-agent--source-buffer
                        (save-restriction
                          (widen)
                          (buffer-substring-no-properties (point-min) (point-max))))))
        (metal-agent--store-target 'buffer original)
        (metal-agent--run-codex
         (metal-prompt--consigne texte original)
         "prompt structuré"
         (lambda (code raw) (metal-prompt--recevoir prompt code raw))
         "Application du prompt au programme")))))

;;;; Tests (Exemples)

(defun metal-prompt--atome (s)
  "S en atome Prolog entre apostrophes."
  (concat "'"
          (replace-regexp-in-string
           "'" "\\\\'" (replace-regexp-in-string "\\\\" "\\\\\\\\" s))
          "'"))

(defconst metal-prompt--script-tests
  ":- set_prolog_flag(verbose, silent).
:- initialization(metal_tests_main, main).

metal_norm(S0, S) :-
    split_string(S0, \"\", \" \\t\\n.\", [S1]),
    split_string(S1, \" \\t\\n\", \" \\t\\n\", Ms),
    atomic_list_concat(Ms, '', A),
    atom_string(A, S).

metal_sol(Vs, S) :-
    exclude([N=_]>>sub_atom(N, 0, 1, _, '_'), Vs, Vs1),
    (   Vs1 == []
    ->  S = \"true\"
    ;   maplist([N=V, T]>>format(string(T), \"~w = ~q\", [N, V]), Vs1, Ts),
        atomic_list_concat(Ts, ', ', A),
        atom_string(A, S)
    ).

% Solutions obtenues plus d'une fois : signe d'un fait ou d'une clause
% en double, que list_to_set masquerait.
metal_repetees(Ss0, Reps) :-
    exclude(==(\"true\"), Ss0, Ss),   % but sans variable : plusieurs preuves, pas un doublon
    msort(Ss, Tri),
    findall(S, (nextto(S, S, Tri)), Rs0),
    list_to_set(Rs0, Reps).

metal_test(Q, Att, R) :-
    format(\"~n?- ~w.~n\", [Q]),
    catch(( term_string(T, Q, [variable_names(Vs)]),
            findall(S, (call(T), metal_sol(Vs, S)), Ss0),
            list_to_set(Ss0, Ss),
            ( Ss == [] -> Obt = [\"false\"] ; Obt = Ss ),
            (   Ss0 == [] -> Aff = [\"false\"]
            ;   Ss == [\"true\"] -> Aff = [\"true\"]
            ;   Aff = Ss0
            ),
            forall(member(O, Aff), format(\"   ~w~n\", [O])),
            metal_repetees(Ss0, Reps),
            (   Reps \\== []
            ->  R = echec,
                atomic_list_concat(Reps, ' ; ', RepA),
                format(\"   ÉCHEC — solution répétée (clause ou fait en double ?) : ~w~n\", [RepA])
            ;   Att == \"\"
            ->  R = sans, format(\"   (aucun résultat attendu)~n\")
            ;   split_string(Att, \";\", \" \", As),
                maplist(metal_norm, As, An0), msort(An0, An),
                maplist(metal_norm, Obt, On0), msort(On0, On),
                (   An == On
                ->  R = ok, format(\"   OK~n\")
                ;   R = echec, format(\"   ÉCHEC — attendu : ~w~n\", [Att])
                )
            ) ),
          E,
          ( R = erreur, format(\"   ERREUR : ~p~n\", [E]) )).

metal_tests_main :-
    set_stream(user_output, encoding(utf8)),
    set_stream(user_error, encoding(utf8)),
    metal_tests(Ts),
    metal_programme(P),
    catch(load_files(P, [encoding(utf8)]), E, print_message(error, E)),
    findall(R, (member(Q-A, Ts), metal_test(Q, A, R)), Rs),
    include(==(ok), Rs, Ok), length(Ok, NOk),
    include(==(echec), Rs, Ec), length(Ec, NEc),
    include(==(erreur), Rs, Er), length(Er, NEr),
    length(Rs, N),
    format(\"~nBilan : ~d exemple(s), ~d OK, ~d échec(s), ~d erreur(s).~n\",
           [N, NOk, NEc, NEr]).
"
  "Script SWI-Prolog qui consulte le programme et exécute les Exemples.
Chaque requête est exécutée avec `findall' : toutes les solutions sont
affichées, sans interaction, répétitions comprises.  Une solution obtenue
plus d'une fois (fait ou clause en double) fait échouer l'exemple.  Sinon,
le résultat attendu est comparé à l'ensemble des solutions, espaces et
point final ignorés.")

(defun metal-prompt--swipl ()
  (or (and (fboundp 'metal-prolog--detecter-swipl)
           (metal-prolog--detecter-swipl))
      (executable-find "swipl")
      (user-error "SWI-Prolog introuvable — l'installer depuis l'Assistant MetalEmacs")))

(defun metal-prompt-tester ()
  "Consulter le programme et exécuter les Exemples du prompt."
  (interactive)
  (let* ((exemples (metal-prompt--exemples))
         (programme (metal-prompt--tampon-programme))
         (fichier (buffer-file-name programme))
         (swipl (metal-prompt--swipl)))
    (unless exemples
      (user-error "Aucun exemple dans la section « Exemples » : écrire « ?- requête. » puis le résultat attendu, ou un but complet comme « conjuguer(parler, pi, [parle, …]). »"))
    (with-current-buffer programme
      (when (buffer-modified-p) (save-buffer)))
    (let* ((script (make-temp-file "metal-prompt-tests-" nil ".pl"))
           (tampon (get-buffer-create
                    (format "*Tests — %s*" (file-name-nondirectory fichier))))
           (default-directory (file-name-directory fichier))
           (proc nil))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file script
          (insert ":- encoding(utf8).\n"
                  "metal_programme(" (metal-prompt--atome fichier) ").\n"
                  "metal_tests([\n"
                  (mapconcat (lambda (e)
                               (concat "    " (metal-prompt--atome (car e))
                                       "-\"" (replace-regexp-in-string
                                              "\"" "\\\\\""
                                              (replace-regexp-in-string
                                               "\\\\" "\\\\\\\\" (cdr e)))
                                       "\""))
                             exemples ",\n")
                  "\n]).\n\n"
                  metal-prompt--script-tests)))
      (when-let ((p (get-buffer-process tampon))) (delete-process p))
      (with-current-buffer tampon
        (special-mode)
        (setq-local metal-agent--buffer-sortie-p t)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Exemples de %s\n" (file-name-nondirectory fichier)))))
      (setq proc
            (make-process
             :name "metal-prompt-tests"
             :buffer tampon
             :command (list swipl "-q" script)
             :coding 'utf-8
             :noquery t
             :connection-type 'pipe
             :filter
             (lambda (p chaine)
               (when (buffer-live-p (process-buffer p))
                 (with-current-buffer (process-buffer p)
                   (let ((inhibit-read-only t))
                     (save-excursion
                       (goto-char (point-max))
                       (insert chaine))))))
             :sentinel
             (lambda (p _evt)
               (when (memq (process-status p) '(exit signal))
                 (ignore-errors (delete-file script))
                 (when (buffer-live-p (process-buffer p))
                   (with-current-buffer (process-buffer p)
                     (metal-prompt--colorer-tests)
                     (goto-char (point-max))
                     (let ((bilan (and (re-search-backward "^Bilan : .*$" nil t)
                                       (match-string 0))))
                       (message "📝 %s"
                                (or bilan
                                    (format "Tests interrompus (code %d) — voir %s"
                                            (process-exit-status p)
                                            (buffer-name)))))))))))
      (process-send-eof proc)
      (run-at-time metal-prompt-delai-tests nil
                   (lambda ()
                     (when (process-live-p proc)
                       (delete-process proc)
                       (message "📝 Tests arrêtés après %d s (boucle infinie ?)"
                                metal-prompt-delai-tests))))
      (display-buffer tampon))))

(defun metal-prompt--colorer-tests ()
  "Colorer OK / ÉCHEC / ERREUR dans le tampon de tests courant."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^   \\(OK\\|ÉCHEC\\|ERREUR\\)" nil t)
        (put-text-property (match-beginning 1) (match-end 1) 'face
                           (if (equal (match-string 1) "OK") 'success 'error))))))

;;;; Navigation consigne ↔ code

(defun metal-prompt--aller-consigne (prompt num)
  "Afficher la consigne NUM dans le tampon de prompt PROMPT."
  (unless (buffer-live-p prompt)
    (user-error "Le tampon de prompt n'est plus ouvert"))
  (pop-to-buffer prompt)
  (if-let ((c (seq-find (lambda (c) (equal (car c) num))
                        (nth 1 (metal-prompt--analyser-consignes)))))
      (progn (goto-char (nth 3 c))
             (org-fold-show-context)
             (org-fold-show-entry))
    (message "Consigne %s introuvable" num)))

(defun metal-prompt--consigne-au-point ()
  (pcase-let ((`(,_intro ,items ,debut ,fin) (metal-prompt--analyser-consignes))
              (pos (line-beginning-position)))
    (or (and debut (> pos debut) (< pos fin)
             (car (car (last (seq-filter (lambda (c) (<= (nth 3 c) pos))
                                         items)))))
        (user-error "Le point n'est dans aucune consigne"))))

(defun metal-prompt-aller-au-code ()
  "Depuis une consigne, afficher le code marqué « % Consigne N »."
  (interactive)
  (let ((num (metal-prompt--consigne-au-point))
        (programme (metal-prompt--tampon-programme)))
    (pop-to-buffer programme)
    (goto-char (point-min))
    (if (re-search-forward
         (format "%%+[ \t]*Consigne[ \t]+%s\\(?:[^.0-9]\\|$\\)" (regexp-quote num))
         nil t)
        (beginning-of-line)
      (message "La consigne %s n'est marquée nulle part dans le programme" num))))

;;;; Activer / désactiver une consigne

(defun metal-prompt--bloc-item ()
  "Bornes (DÉBUT . FIN) de l'élément de liste au point et de ses sous-éléments.
L'élément peut être commenté.  Retourne nil hors d'un élément numéroté."
  (save-excursion
    (beginning-of-line)
    (let ((ligne (buffer-substring-no-properties (point) (line-end-position)))
          ind)
      (cond
       ((string-match metal-prompt--re-item-commente ligne)
        (setq ind (string-width (concat (match-string 1 ligne) (match-string 2 ligne)))))
       ((string-match metal-algo--re-item ligne)
        (setq ind (string-width (match-string 1 ligne)))))
      (when ind
        (let ((debut (point)) (fin (line-end-position)))
          (forward-line 1)
          (while (and (not (eobp))
                      (let ((l (buffer-substring-no-properties
                                (point) (line-end-position))))
                        (and (not (string-match-p "^\\*" l))
                             (or (string-blank-p l)
                                 (> (if (string-match metal-prompt--re-item-commente l)
                                        (string-width (concat (match-string 1 l)
                                                              (match-string 2 l)))
                                      (progn (string-match "^[ \t]*" l)
                                             (string-width (match-string 0 l))))
                                    ind)))))
            (unless (string-blank-p (buffer-substring (point) (line-end-position)))
              (setq fin (line-end-position)))
            (forward-line 1))
          (cons debut fin))))))

(defun metal-prompt-basculer-consigne ()
  "Mettre en commentaire la consigne au point, ou la réactiver.
Les sous-consignes suivent.  Une consigne commentée n'est pas transmise
à l'agent mais garde son numéro.  Ailleurs que sur un élément numéroté,
commente ou décommente la ligne (ou la région)."
  (interactive)
  (let* ((bloc (and (not (use-region-p)) (metal-prompt--bloc-item)))
         (debut (cond (bloc (car bloc))
                      ((use-region-p) (save-excursion (goto-char (region-beginning))
                                                      (line-beginning-position)))
                      (t (line-beginning-position))))
         (fin (cond (bloc (cdr bloc))
                    ((use-region-p) (region-end))
                    (t (line-end-position))))
         (commenter (not (save-excursion
                           (goto-char debut)
                           (looking-at metal-prompt--re-commentaire)))))
    (save-excursion
      (goto-char debut)
      (while (< (point) fin)
        (let ((l (buffer-substring-no-properties (point) (line-end-position))))
          (unless (string-blank-p l)
            (if commenter
                (unless (string-match-p metal-prompt--re-commentaire l)
                  (skip-chars-forward " \t")
                  (insert "# ")
                  (setq fin (+ fin 2)))
              (when (looking-at "\\([ \t]*\\)# ?")
                (let ((n (- (match-end 0) (match-end 1))))
                  (replace-match "\\1")
                  (setq fin (- fin n)))))))
        (forward-line 1)))
    (deactivate-mark)
    (message (if commenter "Désactivé (en commentaire)" "Réactivé"))))

;;;; Autres commandes du tampon

(defun metal-prompt-aller-au-programme ()
  "Revenir au programme Prolog."
  (interactive)
  (pop-to-buffer (metal-prompt--tampon-programme)))

(defun metal-prompt-apercu ()
  "Afficher la consigne exacte qui serait envoyée à l'agent."
  (interactive)
  (let* ((texte (metal-prompt--texte-complet))
         (consigne (metal-prompt--avec-contexte
                     (metal-prompt--consigne
                      texte
                      (with-current-buffer metal-agent--source-buffer
                        (save-restriction
                          (widen)
                          (buffer-substring-no-properties (point-min) (point-max)))))))
         (buf (get-buffer-create "*Aperçu — consigne du prompt*")))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert consigne)
        (goto-char (point-min))))
    (display-buffer buf)))

;;;; Barre de boutons

(defun metal-prompt--bouton (label action aide)
  (metal-agent--toolbar-button label action aide))

(defun metal-prompt--barre ()
  "Header-line du tampon de prompt."
  (concat
   (metal-agent--padding)
   (metal-prompt--bouton (metal-toolbar-emoji "🛠️") #'metal-prompt-appliquer
                         "Appliquer le prompt au programme, puis réviser les modifications (F6)")
   "   "
   (metal-prompt--bouton (metal-toolbar-emoji "▶️") #'metal-prompt-tester
                         "Vérifier les Exemples (F7)")
   "   "
   (metal-prompt--bouton (metal-toolbar-emoji "📄") #'metal-prompt-aller-au-programme
                         "Revenir au programme Prolog")
   "   "
   (metal-prompt--bouton (metal-toolbar-emoji "🔎") #'metal-prompt-apercu
                         "Aperçu de la consigne envoyée à l'agent")
   (if (metal-prompt--en-cours-p)
       (concat "   "
               (metal-prompt--bouton (metal-toolbar-emoji "❌") #'metal-agent-interrompre
                                     "Interrompre l'agent"))
     "")
   (metal-toolbar-separator)
   (propertize (format "Profil : %s · %s "
                       (or (metal-agent--profil-prop :nom (metal-prompt--profil-effectif)) "?")
                       (or (metal-agent--current-label) "agent"))
               'face 'metal-agent-profil-indicateur-face
               'help-echo "Profil du programme et agent sélectionné dans l'assistant")
   (metal-agent--padding)))

(defun metal-prompt--poser-barre ()
  (setq-local header-line-format '(:eval (metal-prompt--barre))))

;;;; Mode du tampon de prompt

(defvar metal-prompt-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<f6>") #'metal-prompt-appliquer)
    (define-key m (kbd "<f7>") #'metal-prompt-tester)
    (define-key m (kbd "<f8>") #'metal-prompt-aller-au-code)
    (define-key m (kbd "<f9>") #'metal-prompt-basculer-consigne)
    m))

(define-derived-mode metal-prompt-mode org-mode "Prompt"
  "Rédaction d'un prompt structuré lié à un programme Prolog.
\\{metal-prompt-mode-map}"
  (when buffer-file-name
    (rename-buffer (metal-prompt--nom-tampon (metal-prompt--chemin-programme)) t)))

;; Posée en dernier (après les hooks d'org-mode).
(add-hook 'metal-prompt-mode-hook #'metal-prompt--poser-barre)

(add-to-list 'auto-mode-alist '("\\.prompt\\.org\\'" . metal-prompt-mode))

(defun metal-prompt--squelette (pl)
  (insert "#+TITLE: "
          (capitalize (replace-regexp-in-string "[-_]" " " (file-name-base pl)))
          "\n\n* Contexte\n- Prédicats à exploiter : \n"
          "\n* Consignes\n1. \n"
          "\n* Exemples\n")
  (goto-char (point-min))
  (search-forward "Prédicats à exploiter : " nil t))

;;;###autoload
(defun metal-prompt-ouvrir ()
  "Ouvrir le prompt structuré du programme Prolog courant."
  (interactive)
  (unless (derived-mode-p 'prolog-mode)
    (user-error "À lancer depuis un fichier Prolog"))
  (unless buffer-file-name
    (user-error "Enregistrez d'abord le programme"))
  (let* ((programme (current-buffer))
         (profil metal-agent-profil-actif)
         (pl buffer-file-name)
         (fichier (metal-prompt--chemin-prompt pl))
         (buf (or (get-buffer (metal-prompt--nom-tampon pl))
                  ;; Verrou temporaire : voir `metal-algo-ouvrir'.
                  (let* ((nouveau (not (file-exists-p fichier)))
                         (b (let ((metal-agent--profil-verrouille t))
                              (find-file-noselect fichier))))
                    (with-current-buffer b
                      (unless (derived-mode-p 'metal-prompt-mode) (metal-prompt-mode))
                      (when (and nouveau (= (buffer-size) 0))
                        (metal-prompt--squelette pl)))
                    b))))
    (with-current-buffer buf
      (setq metal-prompt--programme programme
            metal-prompt--profil profil))
    (pop-to-buffer buf)))

(provide 'metal-prompt)
;;; metal-prompt.el ends here
