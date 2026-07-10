;;; metal-agents-formulaire.el --- Formulaire-widget d'ajout d'agent  -*- lexical-binding: t; -*-
;;
;; COMPLÉMENT à `metal-agents-catalogue-externe.el'.
;;
;; But : remplacer la saisie « gabarit texte » par un formulaire interactif
;; COMPACT (buffer widget.el natif).  Design A + B :
;;   A — l'aide de chaque champ ne s'affiche PAS en permanence ; elle
;;       apparaît dans l'echo area au focus clavier ET au survol souris
;;       (:help-echo).  Le corps reste dense : une ligne par champ.
;;   B — sections repliables.  « Identité » et « Invocation » ouvertes ;
;;       « Authentification » et « Installation » repliées par défaut
;;       (optionnelles).  Un clic sur l'en-tête ▸/▾ plie/déplie.
;;
;; À la sauvegarde : écrit dans `catalogue-agents.el' et recharge à chaud
;; (aucun redémarrage requis).
;;
;; INSTALLATION
;; ------------
;;     (with-eval-after-load 'metal-agents-catalogue-externe
;;       (require 'metal-agents-formulaire))
;;
;; Redéfinit `metal-deps--ajouter-agent-personnalise' : « Saisir les
;; paramètres… » ouvre ce formulaire.  Ne PAS charger en même temps
;; `metal-agents-catalogue-gabarit.el' (les deux redéfinissent la même
;; fonction ; le dernier chargé gagne).

(require 'metal-deps)
(require 'metal-agents-catalogue-externe)
(require 'widget)
(require 'wid-edit)
(require 'cl-lib)

;;; ──────────────────────────────────────────────────────────────────
;;;  Documentation par champ (affichée à la demande, pas en permanence)
;;; ──────────────────────────────────────────────────────────────────

(defconst metal-deps--form-aide
  '((:id            . "Symbole interne unique, sans espace (ex: copilot). Ne plus le changer ensuite : il sert de clé partout.")
    (:nom           . "Nom affiché dans la toolbar et les menus (ex: GitHub Copilot).")
    (:description   . "Texte court affiché à côté de l'agent dans l'Assistant.")
    (:couleur       . "Couleur hex de l'icône robot (ex: #4285F4). À choisir distincte des autres agents.")
    (:format        . "Comment extraire la réponse. claude-style : dernier bloc Markdown. codex-style : idem après avoir sauté l'en-tête de session. Chercher « <cli> non-interactive output format ».")
    (:args          . "Arguments du mode UNE REQUÊTE non interactif, séparés par des espaces. Doit contenir -p / --print / --prompt / exec. Ex Claude: -p --output-format text. Chercher « <cli> non-interactive -p prompt ».")
    (:via-process   . "Coché : lancé via make-process (recommandé, robuste). Décoché : via un shell.")
    (:isoler-fichier . "Coché pour un agent AUTONOME qui explore le disque / exécute des outils (type agy, Copilot). Le lance dans un dossier temporaire vide + préambule anti-agentique. À ÉVITER pour la révision de prose (court-circuite le harnais Ediff).")
    (:dernier-message . "Coché si le CLI est verbeux mais sait écrire sa réponse finale seule via un drapeau type --output-last-message. Chercher « <cli> output last message / --output-format json ».")
    (:auth-mode-externe . "Coché : auth gérée hors CLI (app, navigateur, trousseau), non vérifiable → statut neutre. Laisser décoché si un mécanisme ci-dessous vérifie l'auth.")
    (:auth-verifier . "Nom d'une fonction Lisp sans argument retournant t si authentifié (ex: metal-deps--claude-authentifie-p). Avancé.")
    (:auth-commande . "Commande dont le code de sortie 0 signifie « authentifié », séparée par espaces (ex: gh auth status). Chercher « <cli> auth status exit code ».")
    (:auth-fichiers . "Chemins de fichiers de credentials, séparés par espaces ; un seul présent suffit. Penser aux 3 OS. Ex: ~/.codex/auth.json. Chercher « <cli> credentials file location ».")
    (:auth-env      . "Variables d'environnement de clé API, séparées par espaces ; une seule définie suffit (ex: ANTHROPIC_API_KEY). Chercher « <cli> API key environment variable ».")
    (:auth-args     . "Arguments ajoutés pour lancer le flux d'auth interactif (ex: login, ou auth login). Chercher « <cli> login command ».")
    (:auth-aide     . "Instructions affichées à l'utilisateur pendant l'auth interactive (quoi choisir, où aller).")
    (:paquet-npm    . "Nom du paquet npm pour installation auto (ex: @anthropic-ai/claude-code).")
    (:paquet-brew   . "Nom de la formule Homebrew (ex: claude-code).")
    (:paquet-pipx   . "Nom du paquet pipx/pip."))
  "Aide courte par champ, montrée à la demande (echo area / survol).")

;;; ──────────────────────────────────────────────────────────────────
;;;  État local du formulaire
;;; ──────────────────────────────────────────────────────────────────

(defvar-local metal-deps--form-widgets nil
  "Alist (CLÉ . widget) des champs éditables du formulaire courant.")

(defvar-local metal-deps--form-valeurs nil
  "Alist (CLÉ . VALEUR) persistante des saisies, survivant aux re-rendus.
Mise à jour depuis les widgets avant chaque reconstruction, puis relue
comme valeur initiale à la re-création des widgets.  Évite le recours à
`widget-value-set' après coup (source d'« Overlapping fields »).")

(defvar-local metal-deps--form-sections-ouvertes nil
  "Alist (SECTION . BOOL) : état plié/déplié de chaque section.")

(defvar-local metal-deps--form-derniere-section nil
  "Identifiant de la dernière section basculée, pour repositionner le point.")

(defconst metal-deps--form-buffer-nom "*MetalEmacs — Nouvel agent*"
  "Nom du buffer du formulaire d'ajout d'agent.")

;; Description des sections : (clé titre ouverte-par-défaut (champs…))
;; Chaque champ : (clé étiquette type . extra)
;;   type = texte | menu | checkbox
(defconst metal-deps--form-sections
  '((identite   "Identité"        t
     ((:id          "ID *"         texte)
      (:nom         "Nom *"        texte)
      (:description "Description"   texte)
      (:couleur    "Couleur"       texte)))
    (invocation "Invocation"      t
     ((:commande   "Commande *"    texte)
      (:format     "Format"        menu ("claude-style" "codex-style"))
      (:args       "Arguments"     texte)
      (:via-process "via-process"   checkbox t)
      (:isoler-fichier "isoler-fichier" checkbox nil)
      (:dernier-message "dernier-message" checkbox nil)))
    (auth       "Authentification (optionnel)" nil
     ((:auth-mode-externe "auth-mode externe" checkbox nil)
      (:auth-verifier "auth-verifier" texte)
      (:auth-commande "auth-commande" texte)
      (:auth-fichiers "auth-fichiers" texte)
      (:auth-env      "auth-env"      texte)
      (:auth-args     "auth-args"     texte)
      (:auth-aide     "auth-aide"     texte)))
    (install    "Installation auto (optionnel)" nil
     ((:paquet-npm  "paquet-npm"   texte)
      (:paquet-brew "paquet-brew"  texte)
      (:paquet-pipx "paquet-pipx"  texte))))
  "Structure déclarative du formulaire, par sections repliables.")

;;; ──────────────────────────────────────────────────────────────────
;;;  Aide à la demande : echo area au focus clavier + survol souris
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-aide-de (cle)
  "Texte d'aide pour CLE."
  (or (cdr (assq cle metal-deps--form-aide)) ""))

(defun metal-deps--form-echo-aide ()
  "Affiche dans l'echo area l'aide du champ sous le point, s'il y en a.
Destiné à `post-command-hook' : suit la navigation clavier."
  (let* ((w (widget-at (point)))
         (cle (and w (widget-get w :metal-cle))))
    (when cle
      (let ((msg (metal-deps--form-aide-de cle)))
        (unless (string-empty-p msg)
          ;; message sans journalisation dans *Messages*
          (let ((message-log-max nil))
            (message "%s" msg)))))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Construction des champs (compacts : une ligne, aide à la demande)
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-champ (spec)
  "Insère un champ compact décrit par SPEC = (CLE ÉTIQUETTE TYPE . EXTRA).
L'aide est portée par :help-echo (souris) et :metal-cle (echo clavier).
La valeur initiale provient de `metal-deps--form-valeurs' si présente,
sinon du défaut déclaré dans SPEC."
  (let* ((cle (nth 0 spec))
         (etiquette (nth 1 spec))
         (type (nth 2 spec))
         (extra (nthcdr 3 spec))
         (aide (metal-deps--form-aide-de cle))
         (memo (assq cle metal-deps--form-valeurs))
         w)
    (pcase type
      ('checkbox
       (let ((val (if memo (cdr memo) (and (car extra) t))))
         (setq w (widget-create 'checkbox
                                :help-echo aide
                                val)))
       (widget-put w :metal-cle cle)
       (widget-insert (format " %s\n" etiquette)))
      ('menu
       (widget-insert (format "%-14s" etiquette))
       (let ((val (if memo (cdr memo) (car (car extra)))))
         (setq w (apply #'widget-create 'menu-choice
                        :help-echo aide
                        :value val
                        :format "%v"
                        (mapcar (lambda (c) `(item :tag ,c :value ,c))
                                (car extra)))))
       (widget-put w :metal-cle cle)
       (widget-insert "\n"))
      (_ ; texte
       (widget-insert (format "%-14s" etiquette))
       (let ((val (if memo (cdr memo) "")))
         (setq w (widget-create 'editable-field
                                :size 38 :format "%v"
                                :help-echo aide
                                (or val ""))))
       (widget-put w :metal-cle cle)
       (widget-insert "\n")))
    (push (cons cle w) metal-deps--form-widgets)))

;;; ──────────────────────────────────────────────────────────────────
;;;  Sections repliables
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-section-ouverte-p (id)
  "État déplié de la section ID."
  (cdr (assq id metal-deps--form-sections-ouvertes)))

(defun metal-deps--form-titre-de (id)
  "Titre affiché de la section ID."
  (nth 1 (assq id metal-deps--form-sections)))

(defun metal-deps--form-basculer-section (id)
  "Plie/déplie la section ID et reconstruit le formulaire.
Le re-rendu est DIFFÉRÉ via `run-at-time' 0 : on ne peut pas effacer le
buffer depuis le :notify d'un widget encore en cours d'actionnement (cela
détruit le widget sous ses propres pieds et fait tout disparaître).  On
laisse donc le clic se terminer, puis on reconstruit dans le bon buffer."
  (setf (alist-get id metal-deps--form-sections-ouvertes)
        (not (metal-deps--form-section-ouverte-p id)))
  (setq metal-deps--form-derniere-section id)
  (let ((buf (current-buffer)))
    (run-at-time
     0 nil
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (metal-deps--form-rendre)))))))

(defun metal-deps--form-inserer-section (section)
  "Insère l'en-tête pliable de SECTION et, si ouverte, ses champs."
  (let* ((id (nth 0 section))
         (titre (nth 1 section))
         (champs (nth 3 section))
         (ouverte (metal-deps--form-section-ouverte-p id))
         (fleche (if ouverte "▾" "▸")))
    (widget-create 'push-button
                   :notify (lambda (&rest _)
                             (metal-deps--form-basculer-section id))
                   :button-face 'bold
                   :help-echo "Cliquer pour plier/déplier cette section"
                   (format " %s  %s " fleche titre))
    (widget-insert "\n\n")
    (when ouverte
      (dolist (champ champs)
        (metal-deps--form-champ champ))
      (widget-insert "\n"))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Lecture / validation / construction de la plist
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-capturer-valeurs ()
  "Met à jour `metal-deps--form-valeurs' depuis les widgets vivants.
Ne lit que les widgets encore présents (sections ouvertes) ; les valeurs
des sections repliées restent celles déjà mémorisées."
  (dolist (p metal-deps--form-widgets)
    (let ((v (ignore-errors (widget-value (cdr p)))))
      (setf (alist-get (car p) metal-deps--form-valeurs) v))))

(defun metal-deps--form-val (cle)
  "Valeur de CLE : widget vivant si présent, sinon valeur mémorisée.
Permet de lire les champs des sections repliées (sans widget vivant) à
partir de `metal-deps--form-valeurs'."
  (let ((w (cdr (assq cle metal-deps--form-widgets))))
    (if w
        (widget-value w)
      (cdr (assq cle metal-deps--form-valeurs)))))

(defun metal-deps--form-val-str (cle)
  "Valeur texte nettoyée du widget CLE, ou nil si vide/absent."
  (let ((v (metal-deps--form-val cle)))
    (and (stringp v)
         (let ((s (string-trim v)))
           (and (not (string-empty-p s)) s)))))

(defun metal-deps--form-liste-de (cle)
  "Lit CLE comme une liste de chaînes séparées par espaces, ou nil."
  (let ((s (metal-deps--form-val-str cle)))
    (and s (split-string-and-unquote s))))

(defun metal-deps--form-assurer-print (args)
  "Garantit un drapeau non interactif dans ARGS."
  (if (fboundp 'metal-deps--assurer-print)
      (metal-deps--assurer-print args)
    (if (or (member "-p" args) (member "--print" args)
            (member "--prompt" args) (member "exec" args))
        args
      (cons "-p" args))))

(defun metal-deps--form-construire-spec ()
  "Construit (ID . PLIST) depuis les champs, ou signale une erreur.
Les clés absentes/décochées ne sont pas incluses.  Les valeurs des
sections repliées sont lues depuis `metal-deps--form-valeurs' : une
section n'a donc pas besoin d'être dépliée pour que sa saisie compte."
  ;; Synchroniser les widgets vivants (sections ouvertes) vers le stockage
  ;; persistant, pour que `metal-deps--form-val' voie tout.
  (metal-deps--form-capturer-valeurs)
  (let* ((id-str (metal-deps--form-val-str :id))
         (id (and id-str (intern id-str)))
         (nom (metal-deps--form-val-str :nom))
         (commande (metal-deps--form-val-str :commande))
         (format-str (metal-deps--form-val :format))
         (args (metal-deps--form-assurer-print
                (metal-deps--form-liste-de :args)))
         spec)
    (unless id (user-error "Le champ « ID » est requis (section Identité)"))
    ;; En mode ÉDITION, l'ID existe forcément : ne pas le rejeter comme
    ;; doublon (l'enregistrement fera un remplacement en place).
    (when (and (assq id metal-deps-agents-catalogue)
               (not (eq metal-deps--form-mode-edition id)))
      (user-error "L'ID « %s » existe déjà dans le catalogue" id-str))
    (unless nom (user-error "Le champ « Nom » est requis (section Identité)"))
    (unless commande (user-error "Le champ « Commande » est requis (section Invocation)"))
    (setq spec (list :nom nom :commande commande
                     :format (intern (or format-str "claude-style"))
                     :args args))
    (dolist (paire '((:description . :description)
                     (:couleur     . :couleur)
                     (:auth-aide   . :auth-aide)
                     (:paquet-npm  . :paquet-npm)
                     (:paquet-brew . :paquet-brew)
                     (:paquet-pipx . :paquet-pipx)))
      (let ((v (metal-deps--form-val-str (car paire))))
        (when v (setq spec (plist-put spec (cdr paire) v)))))
    (dolist (paire '((:auth-args     . :auth-args)
                     (:auth-fichiers . :auth-fichiers)
                     (:auth-env      . :auth-env)
                     (:auth-commande . :auth-commande)))
      (let ((v (metal-deps--form-liste-de (car paire))))
        (when v (setq spec (plist-put spec (cdr paire) v)))))
    (let ((v (metal-deps--form-val-str :auth-verifier)))
      (when v (setq spec (plist-put spec :auth-verifier (intern v)))))
    (when (metal-deps--form-val :auth-mode-externe)
      (setq spec (plist-put spec :auth-mode 'externe)))
    (when (metal-deps--form-val :via-process)
      (setq spec (plist-put spec :via-process t)))
    (when (metal-deps--form-val :isoler-fichier)
      (setq spec (plist-put spec :isoler-fichier t)))
    (when (metal-deps--form-val :dernier-message)
      (setq spec (plist-put spec :dernier-message t)))
    (cons id spec)))

;;; ──────────────────────────────────────────────────────────────────
;;;  Actions
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-enregistrer (&rest _)
  "Valide, écrit dans le catalogue, recharge à chaud."
  (let* ((entry (metal-deps--form-construire-spec))
         (nom (plist-get (cdr entry) :nom))
         (commande (plist-get (cdr entry) :commande)))
    (unless (executable-find commande)
      (unless (yes-or-no-p
               (format "« %s » introuvable dans le PATH.  Ajouter quand même ? "
                       commande))
        (user-error "Annulé")))
    (metal-deps--charger-catalogue)
    ;; Upsert par ID : si un agent de même ID existe déjà (cas édition),
    ;; on REMPLACE son entrée en place ; sinon (cas ajout) on l'ajoute à
    ;; la fin.  Cela permet au même formulaire de servir à créer ET à
    ;; éditer un agent, sans dupliquer les entrées.
    (let* ((id (car entry))
           (existe (assq id metal-deps-agents-catalogue)))
      (if existe
          (setq metal-deps-agents-catalogue
                (mapcar (lambda (e)
                          (if (eq (car e) id) entry e))
                        metal-deps-agents-catalogue))
        (setq metal-deps-agents-catalogue
              (append metal-deps-agents-catalogue (list entry)))))
    (metal-deps--sauver-catalogue)
    (metal-deps-recharger-catalogue)
    (let ((buf (get-buffer metal-deps--form-buffer-nom))
          (assistant (get-buffer metal-deps--assistant-buffer-nom)))
      (when buf (kill-buffer buf))
      ;; Revenir à l'Assistant dans la même fenêtre avant son re-rendu.
      (when (buffer-live-p assistant)
        (switch-to-buffer assistant)))
    (message "Agent « %s » enregistré et catalogue rechargé. Aucun redémarrage requis."
             nom)
    (when (fboundp 'metal-deps-afficher-etat)
      (run-with-timer 0.2 nil #'metal-deps-afficher-etat))))

(defun metal-deps--form-annuler (&rest _)
  "Ferme le formulaire sans enregistrer et revient à l'onglet Assistant."
  (let ((buf (get-buffer metal-deps--form-buffer-nom))
        (assistant (get-buffer metal-deps--assistant-buffer-nom)))
    (when buf (kill-buffer buf))
    ;; Revenir à l'Assistant dans la même fenêtre (l'onglet formulaire
    ;; a disparu de la tab-line avec le kill-buffer).
    (when (buffer-live-p assistant)
      (switch-to-buffer assistant)))
  (message "Ajout d'agent annulé."))

;;; ──────────────────────────────────────────────────────────────────
;;;  Rendu du buffer (reconstruit à chaque pli/dépli)
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-rendre (&optional sans-capture)
  "(Re)construit le contenu du buffer formulaire courant.
Préserve les valeurs saisies via `metal-deps--form-valeurs' : chaque
widget relit sa valeur initiale à la création, plutôt que de se la faire
réinjecter après coup (ce qui provoquait « Overlapping fields »).

Si SANS-CAPTURE est non nil, ne recapture PAS les valeurs des widgets
vivants avant reconstruction.  À utiliser quand `metal-deps--form-valeurs'
vient d'être renseigné par programme (ex : détection d'arguments) et
qu'une capture écraserait ces valeurs avec le contenu vide des widgets
encore à l'écran."
  ;; 1. Mémoriser les saisies courantes AVANT destruction (sauf si on
  ;;    vient d'injecter des valeurs par programme).
  (unless sans-capture
    (metal-deps--form-capturer-valeurs))
  ;; 2. Détruire proprement les widgets existants, puis vider le buffer.
  (let ((inhibit-read-only t))
    (mapc (lambda (p) (ignore-errors (widget-delete (cdr p))))
          metal-deps--form-widgets)
    (setq metal-deps--form-widgets nil)
    (erase-buffer)
    (remove-overlays)
    (set-text-properties (point-min) (point-max) nil))

  (widget-insert
   (propertize "  Nouvel agent IA — catalogue MetalEmacs\n\n"
               'face '(:height 1.2 :weight bold)))
  (widget-insert
   (propertize
    (concat "  ID, Nom, Commande requis.  Champs vides / cases décochées "
            "non écrits.\n"
            "  Aide du champ courant : en bas (echo area).  "
            "Recharge à chaud, sans redémarrer.\n\n")
    'face 'shadow))

  (dolist (section metal-deps--form-sections)
    (metal-deps--form-inserer-section section))

  (widget-insert "\n")
  (widget-create 'push-button
                 :notify #'metal-deps--form-enregistrer
                 "  Enregistrer  ")
  (widget-insert "    ")
  (widget-create 'push-button
                 :notify #'metal-deps--form-annuler
                 "  Annuler  ")
  (widget-insert "\n")

  (widget-setup)

  ;; 3. Repositionner le point sur l'en-tête de la dernière section
  ;;    basculée, sinon sur le premier widget.
  (goto-char (point-min))
  (let ((cible metal-deps--form-derniere-section))
    (if (and cible
             (save-excursion
               (goto-char (point-min))
               (re-search-forward (regexp-quote (metal-deps--form-titre-de cible))
                                  nil t)))
        (progn (goto-char (match-beginning 0))
               (beginning-of-line))
      (ignore-errors (widget-forward 1)))))

(defvar-local metal-deps--form-mode-edition nil
  "Non-nil quand le formulaire édite un agent EXISTANT (vs en créer un).
Contient alors l'ID (symbole) de l'agent édité.  Utilisé pour ne pas
rejeter l'ID comme un doublon, et pour verrouiller le champ ID.")

(defun metal-deps--form-valeurs-depuis-spec (id spec)
  "Convertit ID + SPEC (plist du catalogue) en alist `metal-deps--form-valeurs'.
Inverse des conversions faites par `metal-deps--form-construire-spec' :
- listes (:args, :auth-args…) → chaîne d'éléments séparés par des espaces ;
- symboles (:format, :auth-verifier) → chaîne ;
- booléens (:via-process…) → t/nil ;
- :auth-mode 'externe → case à cocher :auth-mode-externe."
  (let ((v (list (cons :id (symbol-name id)))))
    (cl-flet ((mv (cle val) (push (cons cle val) v)))
      ;; Champs texte simples.
      (dolist (k '(:nom :commande :description :couleur :auth-aide
                        :paquet-npm :paquet-brew :paquet-pipx))
        (let ((x (plist-get spec k)))
          (when x (mv k (format "%s" x)))))
      ;; Format et auth-verifier : symbole → chaîne.
      (let ((f (plist-get spec :format)))
        (when f (mv :format (format "%s" f))))
      (let ((av (plist-get spec :auth-verifier)))
        (when av (mv :auth-verifier (format "%s" av))))
      ;; Listes → chaîne séparée par espaces.
      (dolist (k '(:args :auth-args :auth-fichiers :auth-env :auth-commande))
        (let ((lst (plist-get spec k)))
          (when lst
            (mv k (mapconcat (lambda (x) (format "%s" x)) lst " ")))))
      ;; Booléens / mode.
      (when (eq (plist-get spec :auth-mode) 'externe)
        (mv :auth-mode-externe t))
      (dolist (k '(:via-process :isoler-fichier :dernier-message
                                :prompt-via-stdin))
        (when (plist-get spec k) (mv k t)))
      ;; Sentinelle stdin (texte).
      (let ((s (plist-get spec :stdin-sentinelle)))
        (when s (mv :stdin-sentinelle (format "%s" s)))))
    (nreverse v)))

;;;###autoload
(defun metal-deps-formulaire-editer-agent (id)
  "Ouvre le formulaire pré-rempli pour ÉDITER l'agent existant ID.
À la sauvegarde, l'entrée de même ID est remplacée en place (upsert)."
  (interactive
   (list (let ((ids (mapcar (lambda (e) (symbol-name (car e)))
                            metal-deps-agents-catalogue)))
           (unless ids (user-error "Aucun agent dans le catalogue"))
           (intern (completing-read "Éditer quel agent ? " ids nil t)))))
  (require 'metal-agent nil t)
  (metal-deps--charger-catalogue)
  (let ((spec (cdr (assq id metal-deps-agents-catalogue))))
    (unless spec (user-error "Agent « %s » introuvable dans le catalogue" id))
    (let ((buf (get-buffer-create metal-deps--form-buffer-nom)))
      (with-current-buffer buf
        (kill-all-local-variables)
        (setq metal-deps--form-widgets nil)
        (setq metal-deps--form-mode-edition id)
        ;; Pré-remplir depuis la spec de l'agent existant.
        (setq metal-deps--form-valeurs
              (metal-deps--form-valeurs-depuis-spec id spec))
        (setq metal-deps--form-derniere-section nil)
        ;; Ouvrir toutes les sections : l'utilisateur voit d'emblée les
        ;; champs déjà remplis, sans avoir à déplier.
        (setq metal-deps--form-sections-ouvertes
              (mapcar (lambda (s) (cons (nth 0 s) t))
                      metal-deps--form-sections))
        (metal-deps--form-rendre)
        (use-local-map widget-keymap)
        (add-hook 'post-command-hook #'metal-deps--form-echo-aide nil t)
        (when (featurep 'tab-line)
          (setq-local tab-line-exclude nil)
          (tab-line-mode 1))
        (goto-char (point-min))
        (widget-forward 1))
      (switch-to-buffer buf))))

;;;###autoload
(defun metal-deps-formulaire-nouvel-agent ()
  "Ouvre un formulaire compact et repliable pour ajouter un agent.
À la sauvegarde : écrit dans `catalogue-agents.el' et recharge à chaud."
  (interactive)
  (require 'metal-agent nil t)
  (metal-deps--charger-catalogue)
  (let ((buf (get-buffer-create metal-deps--form-buffer-nom)))
    (with-current-buffer buf
      (kill-all-local-variables)
      (setq metal-deps--form-widgets nil)
      (setq metal-deps--form-valeurs nil)
      (setq metal-deps--form-mode-edition nil)
      (setq metal-deps--form-derniere-section nil)
      ;; État initial des sections : d'après la colonne « ouverte-par-défaut ».
      (setq metal-deps--form-sections-ouvertes
            (mapcar (lambda (s) (cons (nth 0 s) (nth 2 s)))
                    metal-deps--form-sections))
      (metal-deps--form-rendre)
      (use-local-map widget-keymap)
      ;; Aide à la demande : echo area au focus clavier.
      (add-hook 'post-command-hook #'metal-deps--form-echo-aide nil t)
      ;; Activer la tab-line localement pour garantir l'onglet, que ta
      ;; config utilise `global-tab-line-mode' ou une activation par
      ;; buffer.  Sans effet si la tab-line globale est déjà active.
      (when (featurep 'tab-line)
        (setq-local tab-line-exclude nil)
        (tab-line-mode 1))
      (goto-char (point-min))
      (widget-forward 1))
    ;; `switch-to-buffer' dans la fenêtre courante : le buffer rejoint
    ;; automatiquement la tab-line de cette fenêtre, aux côtés des
    ;; autres onglets (*scratch*, *Tableau-de-bord*, Assistant…).
    (switch-to-buffer buf)))

;;; ──────────────────────────────────────────────────────────────────
;;;  Aiguillage : « Saisir les paramètres… » → formulaire
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--ajouter-agent-personnalise ()
  "Ajoute un agent au catalogue.
Propose un modèle connu (pré-rempli), sinon ouvre le formulaire compact."
  (interactive)
  (require 'metal-agent nil t)
  (metal-deps--charger-catalogue)
  (let* ((etiquette-form "Saisir les paramètres (formulaire)…")
         (choix-modeles
          (append (mapcar (lambda (m) (cons (plist-get (cdr m) :nom) (car m)))
                          metal-deps-agents-modeles-connus)
                  (list (cons etiquette-form nil))))
         (choix (completing-read "Ajouter quel agent ? "
                                 (mapcar #'car choix-modeles) nil t))
         (modele-id (cdr (assoc choix choix-modeles)))
         (modele (and modele-id
                      (cdr (assq modele-id metal-deps-agents-modeles-connus)))))
    (if modele
        (metal-deps--ajouter-depuis-modele modele-id modele)
      (metal-deps-formulaire-nouvel-agent))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Onglets (tab-line) : Assistant et Nouvel agent
;;;
;;;  On n'impose PAS de regroupement custom : le formulaire et
;;;  l'Assistant apparaissent dans la tab-line NORMALE de la fenêtre,
;;;  aux côtés des autres buffers (*scratch*, *Tableau-de-bord*, …).
;;;  Le seul soin nécessaire : s'assurer que ces buffers au nom entre
;;;  astérisques ne soient pas filtrés hors de la tab-line, et qu'ils
;;;  s'ouvrent dans la fenêtre qui porte déjà cette tab-line.
;;; ──────────────────────────────────────────────────────────────────

(require 'tab-line nil t)

(defconst metal-deps--assistant-buffer-nom "*MetalEmacs Assistant*"
  "Nom du buffer de l'Assistant MetalEmacs (défini dans `metal-deps').")

(provide 'metal-agents-formulaire)

;;; metal-agents-formulaire.el ends here
