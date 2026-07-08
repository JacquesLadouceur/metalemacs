;;; metal-agents-formulaire.el --- Formulaire-widget d'ajout d'agent  -*- lexical-binding: t; -*-
;;
;; COMPLÉMENT à `metal-agents-catalogue-externe.el'.
;;
;; But : remplacer la saisie « gabarit texte » de « Saisir les paramètres »
;; par un VRAI formulaire interactif (buffer widget.el natif), avec un
;; champ par clé, une brève doc par champ, validation, puis écriture dans
;; `catalogue-agents.el' et rechargement à chaud (pas de redémarrage requis).
;;
;; INSTALLATION
;; ------------
;; Charger APRÈS le module catalogue externe :
;;
;;     (with-eval-after-load 'metal-agents-catalogue-externe
;;       (require 'metal-agents-formulaire))
;;
;; Ce fichier REDÉFINIT `metal-deps--ajouter-agent-personnalise' pour que
;; l'option « Saisir les paramètres… » ouvre le formulaire.  Les modèles
;; connus (Claude/ChatGPT/Antigravity pré-remplis) restent inchangés.
;;
;; Si tu avais chargé `metal-agents-catalogue-gabarit.el' (l'insertion de
;; gabarit texte), NE charge PAS les deux : ce formulaire le remplace.

(require 'metal-deps)
(require 'metal-agents-catalogue-externe)
(require 'widget)
(require 'wid-edit)
(require 'cl-lib)

;;; ──────────────────────────────────────────────────────────────────
;;;  Documentation par champ (brève : oriente une recherche web)
;;; ──────────────────────────────────────────────────────────────────

(defconst metal-deps--form-aide
  '((:id            . "Symbole interne unique, sans espace (ex: copilot). Ne plus le changer ensuite : il sert de clé partout.")
    (:nom           . "Nom affiché dans la toolbar et les menus (ex: GitHub Copilot).")
    (:description   . "Texte court affiché à côté de l'agent dans l'Assistant.")
    (:commande      . "Nom du binaire CLI, tel que trouvé dans le PATH (ex: copilot). Pas de chemin absolu, pas d'arguments.")
    (:couleur       . "Couleur hex de l'icône robot (ex: #4285F4). À choisir distincte des autres agents.")
    (:format        . "Comment extraire la réponse. claude-style : dernier bloc Markdown. codex-style : idem après avoir sauté l'en-tête de session. Chercher « <cli> non-interactive output format ».")
    (:args          . "Arguments du mode UNE REQUÊTE non interactif, séparés par des espaces. Doit contenir -p / --print / --prompt / exec. Ex Claude: -p --output-format text. Chercher « <cli> non-interactive -p prompt ».")
    (:via-process   . "Coché : lancé via make-process (recommandé, robuste). Décoché : via un shell.")
    (:isoler-fichier . "Coché pour un agent AUTONOME qui explore le disque / exécute des outils (type agy, Copilot). Le lance dans un dossier temporaire vide + ajoute un préambule anti-agentique. À ÉVITER pour la révision de prose (court-circuite le harnais Ediff).")
    (:dernier-message . "Coché si le CLI est verbeux mais sait écrire sa réponse finale seule via un drapeau type --output-last-message. Chercher « <cli> output last message / --output-format json ».")
    ;; Auth
    (:auth-mode     . "externe = auth gérée hors CLI (app, navigateur, trousseau), non vérifiable : statut neutre. Laisser vide si un mécanisme ci-dessous vérifie l'auth.")
    (:auth-verifier . "Nom d'une fonction Lisp sans argument retournant t si authentifié (ex: metal-deps--claude-authentifie-p). Avancé.")
    (:auth-commande . "Commande dont le code de sortie 0 signifie « authentifié », séparée par espaces (ex: gh auth status). Chercher « <cli> auth status exit code ».")
    (:auth-fichiers . "Chemins de fichiers de credentials, séparés par espaces ; un seul présent suffit. Penser aux 3 OS. Ex: ~/.codex/auth.json. Chercher « <cli> credentials file location ».")
    (:auth-env      . "Variables d'environnement de clé API, séparées par espaces ; une seule définie suffit (ex: ANTHROPIC_API_KEY). Chercher « <cli> API key environment variable ».")
    (:auth-args     . "Arguments ajoutés à la commande pour lancer le flux d'auth interactif (ex: login, ou auth login). Chercher « <cli> login command ».")
    (:auth-aide     . "Instructions affichées à l'utilisateur pendant l'auth interactive (quoi choisir, où aller).")
    ;; Installation
    (:paquet-npm    . "Nom du paquet npm pour installation auto (ex: @anthropic-ai/claude-code).")
    (:paquet-brew   . "Nom de la formule Homebrew (ex: claude-code).")
    (:paquet-pipx   . "Nom du paquet pipx/pip."))
  "Aide courte par champ, affichée sous chaque widget du formulaire.")

;;; ──────────────────────────────────────────────────────────────────
;;;  État du formulaire (widgets vivants)
;;; ──────────────────────────────────────────────────────────────────

(defvar-local metal-deps--form-widgets nil
  "Alist (CLÉ . widget) des champs du formulaire courant.")

(defconst metal-deps--form-buffer-nom "*MetalEmacs — Nouvel agent*"
  "Nom du buffer du formulaire d'ajout d'agent.")

;;; ──────────────────────────────────────────────────────────────────
;;;  Helpers de construction
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-aide-de (cle)
  "Texte d'aide pour CLE."
  (or (cdr (assq cle metal-deps--form-aide)) ""))

(defun metal-deps--form-inserer-aide (cle)
  "Insère l'aide de CLE en retrait, face atténuée."
  (insert "  ")
  (insert (propertize (metal-deps--form-aide-de cle)
                      'face 'shadow))
  (insert "\n\n"))

(defun metal-deps--form-champ-texte (cle etiquette &optional valeur)
  "Insère un champ éditable texte pour CLE, avec ETIQUETTE et aide.
Enregistre le widget dans `metal-deps--form-widgets'."
  (widget-insert (format "%-16s" etiquette))
  (let ((w (widget-create 'editable-field
                          :size 40
                          :format "%v"
                          (or valeur ""))))
    (push (cons cle w) metal-deps--form-widgets))
  (widget-insert "\n")
  (metal-deps--form-inserer-aide cle))

(defun metal-deps--form-champ-checkbox (cle etiquette &optional valeur)
  "Insère une case à cocher pour CLE booléenne."
  (let ((w (widget-create 'checkbox valeur)))
    (push (cons cle w) metal-deps--form-widgets))
  (widget-insert (format " %s\n" etiquette))
  (metal-deps--form-inserer-aide cle))

(defun metal-deps--form-champ-menu (cle etiquette choix &optional valeur)
  "Insère un menu déroulant pour CLE parmi CHOIX (liste de chaînes)."
  (widget-insert (format "%-16s" etiquette))
  (let ((w (apply #'widget-create 'menu-choice
                  :value (or valeur (car choix))
                  :format "%v"
                  (mapcar (lambda (c) `(item :tag ,c :value ,c)) choix))))
    (push (cons cle w) metal-deps--form-widgets))
  (widget-insert "\n")
  (metal-deps--form-inserer-aide cle))

;;; ──────────────────────────────────────────────────────────────────
;;;  Lecture / validation / construction de la plist
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-val (cle)
  "Valeur courante (chaîne ou booléen) du widget CLE."
  (let ((w (cdr (assq cle metal-deps--form-widgets))))
    (and w (widget-value w))))

(defun metal-deps--form-val-str (cle)
  "Valeur texte nettoyée du widget CLE, ou nil si vide."
  (let ((v (metal-deps--form-val cle)))
    (and (stringp v)
         (let ((s (string-trim v)))
           (and (not (string-empty-p s)) s)))))

(defun metal-deps--form-liste-de (cle)
  "Lit CLE comme une liste de chaînes séparées par espaces, ou nil."
  (let ((s (metal-deps--form-val-str cle)))
    (and s (split-string-and-unquote s))))

(defun metal-deps--form-assurer-print (args)
  "Garantit un drapeau non interactif dans ARGS (réutilise la logique externe)."
  (if (fboundp 'metal-deps--assurer-print)
      (metal-deps--assurer-print args)
    (if (or (member "-p" args) (member "--print" args)
            (member "--prompt" args) (member "exec" args))
        args
      (cons "-p" args))))

(defun metal-deps--form-construire-spec ()
  "Construit (ID . PLIST) depuis les widgets, ou signale une erreur.
Les clés booléennes/optionnelles absentes ne sont PAS incluses (pas de
:cle nil), pour rester cohérent avec le style du catalogue."
  (let* ((id-str (metal-deps--form-val-str :id))
         (id (and id-str (intern id-str)))
         (nom (metal-deps--form-val-str :nom))
         (commande (metal-deps--form-val-str :commande))
         (format-str (metal-deps--form-val :format))
         (args (metal-deps--form-assurer-print
                (metal-deps--form-liste-de :args)))
         spec)
    ;; --- Validation des obligatoires ---
    (unless id (user-error "Le champ « ID » est requis"))
    (when (assq id metal-deps-agents-catalogue)
      (user-error "L'ID « %s » existe déjà dans le catalogue" id-str))
    (unless nom (user-error "Le champ « Nom » est requis"))
    (unless commande (user-error "Le champ « Commande » est requise"))
    ;; --- Champs de base (toujours présents) ---
    (setq spec (list :nom nom :commande commande
                     :format (intern (or format-str "claude-style"))
                     :args args))
    ;; --- Optionnels texte ---
    (dolist (paire '((:description . :description)
                     (:couleur     . :couleur)
                     (:auth-aide   . :auth-aide)
                     (:paquet-npm  . :paquet-npm)
                     (:paquet-brew . :paquet-brew)
                     (:paquet-pipx . :paquet-pipx)))
      (let ((v (metal-deps--form-val-str (car paire))))
        (when v (setq spec (plist-put spec (cdr paire) v)))))
    ;; --- Optionnels liste ---
    (let ((v (metal-deps--form-liste-de :auth-args)))
      (when v (setq spec (plist-put spec :auth-args v))))
    (let ((v (metal-deps--form-liste-de :auth-fichiers)))
      (when v (setq spec (plist-put spec :auth-fichiers v))))
    (let ((v (metal-deps--form-liste-de :auth-env)))
      (when v (setq spec (plist-put spec :auth-env v))))
    (let ((v (metal-deps--form-liste-de :auth-commande)))
      (when v (setq spec (plist-put spec :auth-commande v))))
    ;; --- :auth-verifier : symbole d'une fonction ---
    (let ((v (metal-deps--form-val-str :auth-verifier)))
      (when v (setq spec (plist-put spec :auth-verifier (intern v)))))
    ;; --- :auth-mode externe (case) ---
    (when (metal-deps--form-val :auth-mode-externe)
      (setq spec (plist-put spec :auth-mode 'externe)))
    ;; --- Booléens (inclus seulement si cochés) ---
    (when (metal-deps--form-val :via-process)
      (setq spec (plist-put spec :via-process t)))
    (when (metal-deps--form-val :isoler-fichier)
      (setq spec (plist-put spec :isoler-fichier t)))
    (when (metal-deps--form-val :dernier-message)
      (setq spec (plist-put spec :dernier-message t)))
    (cons id spec)))

;;; ──────────────────────────────────────────────────────────────────
;;;  Actions (boutons)
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--form-enregistrer (&rest _)
  "Valide le formulaire, écrit dans le catalogue, recharge à chaud."
  (let* ((entry (metal-deps--form-construire-spec))
         (id (car entry))
         (nom (plist-get (cdr entry) :nom))
         (commande (plist-get (cdr entry) :commande)))
    ;; Avertir si le binaire est introuvable (mais permettre l'ajout).
    (unless (executable-find commande)
      (unless (yes-or-no-p
               (format "« %s » introuvable dans le PATH.  Ajouter quand même ? "
                       commande))
        (user-error "Annulé")))
    (metal-deps--charger-catalogue)
    (setq metal-deps-agents-catalogue
          (append metal-deps-agents-catalogue (list entry)))
    (metal-deps--sauver-catalogue)
    (metal-deps-recharger-catalogue)
    (let ((buf (get-buffer metal-deps--form-buffer-nom)))
      (when buf (kill-buffer buf)))
    (message "Agent « %s » ajouté au catalogue et rechargé. Aucun redémarrage requis."
             nom)
    (when (fboundp 'metal-deps-afficher-etat)
      (run-with-timer 0.2 nil #'metal-deps-afficher-etat))))

(defun metal-deps--form-annuler (&rest _)
  "Ferme le formulaire sans rien enregistrer."
  (let ((buf (get-buffer metal-deps--form-buffer-nom)))
    (when buf (kill-buffer buf)))
  (message "Ajout d'agent annulé."))

;;; ──────────────────────────────────────────────────────────────────
;;;  Construction du buffer formulaire
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps-formulaire-nouvel-agent ()
  "Ouvre un formulaire interactif pour ajouter un agent au catalogue.
À la sauvegarde : écrit dans `catalogue-agents.el' et recharge à chaud."
  (interactive)
  (require 'metal-agent nil t)
  (metal-deps--charger-catalogue)
  (let ((buf (get-buffer-create metal-deps--form-buffer-nom)))
    (with-current-buffer buf
      (kill-all-local-variables)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (remove-overlays)
      (setq metal-deps--form-widgets nil)

      (widget-insert
       (propertize "  Nouvel agent IA — catalogue MetalEmacs\n\n"
                   'face '(:height 1.2 :weight bold)))
      (widget-insert
       (propertize
        (concat
         "  Remplissez au moins ID, Nom et Commande.  Les cases décochées\n"
         "  et les champs vides ne sont pas écrits dans le catalogue.\n"
         "  Après enregistrement, le catalogue est rechargé sans redémarrer.\n\n")
        'face 'shadow))

      (widget-insert (propertize "── Identité ─────────────────────────────\n\n"
                                 'face 'bold))
      (metal-deps--form-champ-texte :id          "ID *")
      (metal-deps--form-champ-texte :nom         "Nom *")
      (metal-deps--form-champ-texte :description "Description")
      (metal-deps--form-champ-texte :couleur     "Couleur")

      (widget-insert (propertize "── Invocation ───────────────────────────\n\n"
                                 'face 'bold))
      (metal-deps--form-champ-texte :commande "Commande *")
      (metal-deps--form-champ-menu  :format   "Format"
                                    '("claude-style" "codex-style"))
      (metal-deps--form-champ-texte :args     "Arguments")
      (metal-deps--form-champ-checkbox :via-process    "via-process" t)
      (metal-deps--form-champ-checkbox :isoler-fichier "isoler-fichier")
      (metal-deps--form-champ-checkbox :dernier-message "dernier-message")

      (widget-insert (propertize "── Authentification ─────────────────────\n\n"
                                 'face 'bold))
      (metal-deps--form-champ-checkbox :auth-mode-externe "auth-mode externe")
      (metal-deps--form-champ-texte :auth-verifier "auth-verifier")
      (metal-deps--form-champ-texte :auth-commande "auth-commande")
      (metal-deps--form-champ-texte :auth-fichiers "auth-fichiers")
      (metal-deps--form-champ-texte :auth-env      "auth-env")
      (metal-deps--form-champ-texte :auth-args     "auth-args")
      (metal-deps--form-champ-texte :auth-aide     "auth-aide")

      (widget-insert (propertize "── Installation auto (optionnel) ────────\n\n"
                                 'face 'bold))
      (metal-deps--form-champ-texte :paquet-npm  "paquet-npm")
      (metal-deps--form-champ-texte :paquet-brew "paquet-brew")
      (metal-deps--form-champ-texte :paquet-pipx "paquet-pipx")

      (widget-insert "\n")
      (widget-create 'push-button
                     :notify #'metal-deps--form-enregistrer
                     "  Enregistrer dans le catalogue  ")
      (widget-insert "    ")
      (widget-create 'push-button
                     :notify #'metal-deps--form-annuler
                     "  Annuler  ")
      (widget-insert "\n")

      (use-local-map widget-keymap)
      (widget-setup)
      (goto-char (point-min))
      ;; Positionner sur le premier champ éditable (ID).
      (widget-forward 1))
    (switch-to-buffer buf)))

;;; ──────────────────────────────────────────────────────────────────
;;;  Aiguillage : « Saisir les paramètres… » → formulaire
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--ajouter-agent-personnalise ()
  "Ajoute un agent au catalogue.
Propose un modèle connu (pré-rempli), sinon ouvre le formulaire-widget."
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

(provide 'metal-agents-formulaire)

;;; metal-agents-formulaire.el ends here
