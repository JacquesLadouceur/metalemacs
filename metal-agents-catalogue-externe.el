;;; metal-agents-catalogue-externe.el --- Catalogue d'agents IA externalise -*- lexical-binding: t; -*-
;;
;; Surcharge la gestion du catalogue d'agents de metal-deps.el pour le
;; rendre entierement editable via un fichier externe.  A charger APRES
;; metal-deps :
;;
;;     (with-eval-after-load 'metal-deps
;;       (require 'metal-agents-catalogue-externe))
;;
;; Objectifs :
;;   - Aucun agent code en dur : tout vit dans un fichier editable.
;;   - N'importe quel agent peut etre ajoute ou supprime via l'Assistant.
;;   - Resistance a l'evolution des CLI : on edite des donnees, pas du code.
;;
;; L'affichage de l'Assistant reste identique.

(require 'metal-deps)
(require 'cl-lib)

;;; ──────────────────────────────────────────────────────────────────
;;;  Emplacement du fichier catalogue
;;; ──────────────────────────────────────────────────────────────────

(defcustom metal-deps-agents-catalogue-fichier
  (expand-file-name "Documents/MetalEmacs/profils-agentiques/catalogue-agents.el"
                    (or (getenv "HOME") "~"))
  "Fichier editable contenant le catalogue des agents IA.
Voir `metal-deps-editer-catalogue' pour l'ouvrir et
`metal-deps-recharger-catalogue' pour le relire."
  :type 'file
  :group 'metal-deps)

;;; ──────────────────────────────────────────────────────────────────
;;;  Seed : contenu par defaut (le code reste autonome)
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--catalogue-seed ()
  "Retourne le texte par defaut du fichier catalogue.
Ecrit dans le fichier s'il n'existe pas, de sorte que l'Assistant
fonctionne des la premiere utilisation et que la suppression du
fichier soit recuperable."
  metal-deps--catalogue-seed-texte)

(defvar metal-deps--catalogue-seed-texte
  ";;; catalogue-agents.el --- Catalogue des agents IA de MetalEmacs -*- lexical-binding: t; -*-
;;
;; Ce fichier est lu par l'Assistant MetalEmacs (metal-deps.el) pour
;; connaître les agents IA (CLI) installables et utilisables.
;;
;; ┌─────────────────────────────────────────────────────────────────┐
;; │  COMMENT ÉDITER CE FICHIER                                        │
;; │                                                                   │
;; │  - C'est une simple liste Lisp : (ID  :champ valeur  :champ ...). │
;; │  - Après édition : M-x metal-deps-recharger-catalogue            │
;; │    (ou rouvrir l'Assistant) pour prendre en compte les           │
;; │    changements, sans redémarrer Emacs.                           │
;; │  - L'Assistant offre aussi des commandes pour ajouter / retirer  │
;; │    un agent sans éditer à la main :                              │
;; │       M-x metal-deps-catalogue-ajouter-agent                     │
;; │       M-x metal-deps-catalogue-supprimer-agent                   │
;; └─────────────────────────────────────────────────────────────────┘
;;
;; CHAMPS DISPONIBLES POUR CHAQUE AGENT
;; ------------------------------------
;;   :nom          (obligatoire) Nom affiché, ex: \"Claude\".
;;   :commande     (obligatoire) Binaire CLI invoqué, ex: \"claude\".
;;   :description  Texte court affiché à côté de l'agent.
;;   :gratuit      t  -> suffixe \"(gratuit)\" ; \"texte\" -> \"(texte)\" ;
;;                 nil -> rien (abonnement payant sous-entendu).
;;   :couleur      Couleur hex de l'icône robot dans la toolbar.
;;   :format       claude-style  ou  codex-style  (extraction de la réponse).
;;   :args         Arguments par défaut du mode \"une requête\" (liste de
;;                 chaines).  Doit contenir le drapeau non interactif :
;;                 \"-p\" / \"--print\" pour la plupart, \"exec ...\" pour Codex.
;;   :via-process  t si l'agent est invoqué via make-process (sinon shell).
;;
;; INSTALLATION AUTOMATIQUE (optionnel — sinon installation manuelle)
;;   :paquet-npm   Nom du paquet npm   (ex: \"@anthropic-ai/claude-code\").
;;   :paquet-brew  Nom du paquet brew  (ex: \"claude-code\").
;;   :paquet-pipx  Nom du paquet pipx/pip.
;;   :install-manuelle  alist ((darwin . \"...\") (windows-nt . \"...\")
;;                 (gnu/linux . \"...\") (t . \"fallback\")) d'instructions
;;                 affichées quand aucun gestionnaire ne convient.
;;
;; AUTHENTIFICATION — l'Assistant essaie, dans l'ORDRE :
;;   :auth-verifier  Symbole d'une fonction Lisp (sans argument) qui
;;                   retourne t si authentifié.  Définie dans metal-deps.el.
;;   :auth-commande  Liste (PROG ARG...) ; code de sortie 0 = authentifié.
;;   :auth-fichiers  Liste de chemins ; un seul présent suffit.  Penser aux
;;                   3 OS (~/.config, ~/Library/Application Support,
;;                   ~/AppData).
;;   :auth-env       Liste de variables d'env ; une seule définie suffit.
;;   :auth-mode      'externe  -> auth gérée hors du CLI (app, navigateur,
;;                   trousseau) et NON vérifiable : l'Assistant affiche un
;;                   statut neutre, sans bouton trompeur \"authentifier\".
;;   :auth-args      Arguments à ajouter à la commande pour lancer le flux
;;                   d'auth interactif (ex: (\"login\")).  nil = commande seule.
;;   :auth-aide      Instructions affichées pendant l'auth interactive.
;;
;; Si AUCUN champ d'auth n'est fourni, l'agent est traité comme
;; :auth-mode 'externe (statut neutre).

(
 ;; ─────────────────────────────────────────────────────────────────
 ;;  Antigravity (agy) — successeur du Gemini CLI pour comptes Google
 ;; ─────────────────────────────────────────────────────────────────
 (antigravity
  :nom         \"Antigravity\"
  :description \"Inclus avec un abonnement Google AI (Pro/Ultra)\"
  :gratuit     \"compte Google AI\"
  :commande    \"agy\"
  :couleur     \"#4285F4\"
  :format      claude-style
  :args        (\"--print-timeout\" \"10m\" \"-p\")
  :via-process t
  ;; agy est un agent EXPLORATOIRE : sans isolation, il fouille le
  ;; repertoire du fichier au lieu de reviser.  :isoler-fichier t le
  ;; lance dans un dossier temporaire vide (copie unique du fichier).
  :isoler-fichier t
  ;; agy n'expose pas de sous-commande d'auth ni de fichier de
  ;; credentials : l'authentification passe par l'app Antigravity
  ;; (agy auth login ouvre l'interface).  Non vérifiable -> externe.
  :auth-mode   externe
  :auth-args   (\"auth\" \"login\")
  :auth-aide   \"agy délègue l'authentification à l'app Antigravity / au navigateur.  Suivez le flux qui s'ouvre, puis fermez ce buffer (C-x k).  L'Assistant ne peut pas vérifier l'état d'auth automatiquement pour cet agent.\"
  :install-manuelle
  ((darwin    . \"Installez le CLI Antigravity :\\n  curl -fsSL https://antigravity.google/cli/install.sh | bash\\nPuis assurez-vous que ~/.local/bin est dans le PATH.\")
   (gnu/linux . \"Installez le CLI Antigravity :\\n  curl -fsSL https://antigravity.google/cli/install.sh | bash\\nPuis assurez-vous que ~/.local/bin est dans le PATH.\")
   (windows-nt . \"Installez le CLI Antigravity (agy) dans PowerShell :\\n  irm https://antigravity.google/cli/install.ps1 | iex\\nLe binaire agy est place dans %LOCALAPPDATA%\\\\agy\\\\bin ; ouvrez un nouveau terminal pour que le PATH soit pris en compte.\")
   (t          . \"Voir https://antigravity.google pour installer le CLI agy.\")))

 ;; ─────────────────────────────────────────────────────────────────
 ;;  ChatGPT (Codex CLI)
 ;; ─────────────────────────────────────────────────────────────────
 (codex
  :nom         \"ChatGPT\"
  :description \"Gratuit avec ChatGPT Free ou abonnement Plus/Pro\"
  :gratuit     t
  :paquet-npm  \"@openai/codex\"
  :paquet-brew \"codex\"
  :commande    \"codex\"
  :couleur     \"#10A37F\"
  :format      codex-style
  :args        (\"exec\" \"--sandbox\" \"read-only\" \"--skip-git-repo-check\")
  ;; codex exec produit une sortie verbeuse (en-tete de session, echo du
  ;; prompt, compteur de tokens, parfois la reponse en double).  Avec
  ;; :dernier-message t, metal-agent insere -o/--output-last-message et lit
  ;; la reponse depuis ce fichier propre au lieu de parser la sortie brute.
  :dernier-message t
  ;; codex consulte stdin meme quand un prompt est passe en argument.
  ;; Lance via make-process (stdin = pipe non-TTY), il se bloque en
  ;; attente sur Windows et ne traite jamais l'argument.  On passe donc
  ;; le prompt PAR stdin, avec la sentinelle `-' que codex exec exige.
  :prompt-via-stdin t
  :stdin-sentinelle \"-\"
  :auth-args   (\"login\")
:auth-aide   \"Dans le TERMINAL qui vient de s'ouvrir, choisissez « Sign in with ChatGPT » puis appuyez sur Entree : le navigateur s'ouvre sur la page de connexion ChatGPT habituelle (courriel, ou Google / Apple / Microsoft).  Connectez-vous avec votre compte ChatGPT (fonctionne avec ChatGPT Free) ; il n'y a PAS de bouton « Sign in with ChatGPT » sur la page web elle-meme.  Alternative : « Sign in with API key » pour une cle OpenAI.  Une fois connecte, fermez ce buffer (C-x k).\"
  :auth-fichiers (\"~/.codex/auth.json\" \"~/.codex/config.toml\"))

 ;; ─────────────────────────────────────────────────────────────────
 ;;  Claude (Claude Code CLI)
 ;; ─────────────────────────────────────────────────────────────────
 (claude
  :nom         \"Claude\"
  :description \"Avec abonnement Claude Pro/Max ou clé API\"
  :gratuit     nil
  :paquet-npm  \"@anthropic-ai/claude-code\"
  :paquet-brew \"claude-code\"
  :commande    \"claude\"
  :couleur     \"#D97757\"
  :format      claude-style
  :args        (\"-p\" \"--output-format\" \"text\")
  :via-process t
  ;; claude lit stdin nativement avec -p quand stdin est un pipe.
  ;; Meme motif que codex : on lui passe le prompt par stdin pour
  ;; eviter le blocage sous Windows.  Pas de sentinelle requise.
  :prompt-via-stdin t
  :auth-args   (\"auth\" \"login\")
  :auth-aide   \"Le navigateur va s'ouvrir pour l'OAuth Anthropic.  Si rien ne s'ouvre, appuyez sur « c » pour copier l'URL et collez-la dans votre navigateur.  Revenez ici après autorisation, puis fermez le buffer (C-x k).\"
  :auth-fichiers (\"~/.claude/.credentials.json\")
  :auth-verifier metal-deps--claude-authentifie-p)
 )

;;; catalogue-agents.el ends here
"
  "Texte du catalogue par defaut, ecrit dans le fichier s'il est absent.")

;;; ──────────────────────────────────────────────────────────────────
;;;  Modeles connus (source pour l'ajout assiste — PAS un catalogue actif)
;;; ──────────────────────────────────────────────────────────────────

(defvar metal-deps-agents-modeles-connus
  '((antigravity
     :nom "Antigravity" :commande "agy"
     :description "Inclus avec un abonnement Google AI (Pro/Ultra)"
     :gratuit "compte Google AI" :couleur "#4285F4" :format claude-style
     :args ("--print-timeout" "10m" "-p") :via-process t
     :isoler-fichier t
     :auth-mode externe)
    (codex
     :nom "ChatGPT" :commande "codex"
     :description "Gratuit avec ChatGPT Free ou abonnement Plus/Pro"
     :gratuit t :paquet-npm "@openai/codex" :paquet-brew "codex"
     :couleur "#10A37F" :format codex-style
     :args ("-p")
     :dernier-message t
     :auth-args ("login")
     :auth-fichiers ("~/.codex/auth.json" "~/.codex/config.toml"))
    (claude
     :nom "Claude" :commande "claude"
     :description "Avec abonnement Claude Pro/Max ou cle API"
     :gratuit nil :paquet-npm "@anthropic-ai/claude-code" :paquet-brew "claude-code"
     :couleur "#D97757" :format claude-style
     :args ("-p" "--output-format" "text") :via-process t
     :auth-args ("auth" "login")
     :auth-fichiers ("~/.claude/.credentials.json")
     :auth-verifier metal-deps--claude-authentifie-p))
  "Modeles d'agents pre-remplis proposes lors de l'ajout assiste.
Ce n'est PAS le catalogue actif (qui est dans le fichier).  Sert
uniquement a remplir rapidement les champs quand on (re)ajoute un
agent connu via l'Assistant.")

;;; ──────────────────────────────────────────────────────────────────
;;;  Chargement / validation / sauvegarde
;;; ──────────────────────────────────────────────────────────────────

;; Le catalogue actif n'est plus code en dur : variable peuplee au chargement.
(setq metal-deps-agents-catalogue nil)

(defun metal-deps--valider-entree-agent (entry)
  "Verifie qu'ENTRY est (ID :nom S :commande S ...).  Signale sinon."
  (unless (and (consp entry) (symbolp (car entry)))
    (error "Entree d'agent malformee (doit commencer par un symbole ID) : %S" entry))
  (let ((spec (cdr entry)))
    (unless (plist-get spec :nom)
      (error "Agent %s : champ :nom manquant" (car entry)))
    (unless (plist-get spec :commande)
      (error "Agent %s : champ :commande manquant" (car entry))))
  t)

(defun metal-deps--valider-catalogue (data)
  "Verifie que DATA est une liste d'entrees d'agents valides.
Une liste VIDE est rejetee : elle signale un fichier ecrase ou
corrompu, pas un catalogue legitime.  Cela permet a
`metal-deps--charger-catalogue' de regenerer le seed."
  (unless (listp data)
    (error "Le catalogue doit etre une liste d'agents"))
  (when (null data)
    (error "Catalogue vide : fichier ecrase ou corrompu, re-seed requis"))
  (let (ids)
    (dolist (entry data)
      (metal-deps--valider-entree-agent entry)
      (when (memq (car entry) ids)
        (error "ID d'agent en double : %s" (car entry)))
      (push (car entry) ids)))
  t)

(defun metal-deps--lire-catalogue-fichier (f)
  "Lit et renvoie la structure Lisp du fichier catalogue F.
Renvoie nil si le fichier est illisible, vide, ou ne contient pas de
donnees lisibles (par ex. uniquement l'en-tete de commentaires)."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (read (current-buffer)))))

(defun metal-deps--ecrire-seed-catalogue (f)
  "Ecrit le seed par defaut dans le fichier catalogue F.
Cree le repertoire parent au besoin.  Signale un message en cas
d'echec plutot que de lever une erreur seche."
  (condition-case err
      (progn
        (make-directory (file-name-directory f) t)
        (with-temp-file f (insert (metal-deps--catalogue-seed)))
        (metal-deps--journaliser "Catalogue d'agents (re)cree : %s" f)
        t)
    (error
     (message "⚠ Impossible de creer le catalogue d'agents (%s) : %s"
              f (error-message-string err))
     nil)))

(defun metal-deps--charger-catalogue (&optional _force)
  "Charge le catalogue depuis le fichier ; (re)cree le seed si absent,
vide ou invalide.

Robustesse : si le fichier existe mais que sa lecture ou sa validation
echoue (fichier vide, liste `()' ecrasee, contenu corrompu), le seed est
regenere UNE fois puis relu, au lieu de conserver silencieusement un
catalogue nil (ce qui faisait disparaitre la section Agents IA).  En
dernier recours seulement, l'ancien catalogue est conserve."
  (let ((f metal-deps-agents-catalogue-fichier))
    ;; 1) Fichier absent : ecrire le seed.
    (unless (file-exists-p f)
      (metal-deps--ecrire-seed-catalogue f))
    ;; 2) Lire + valider.  En cas d'echec, regenerer le seed puis relire.
    (when (file-exists-p f)
      (let ((data (metal-deps--lire-catalogue-fichier f)))
        (if (ignore-errors (metal-deps--valider-catalogue data))
            (setq metal-deps-agents-catalogue data)
          ;; Fichier present mais vide/invalide : re-seed puis relecture.
          (metal-deps--journaliser
           "Catalogue illisible ou vide — regeneration du seed : %s" f)
          (when (metal-deps--ecrire-seed-catalogue f)
            (let ((data2 (metal-deps--lire-catalogue-fichier f)))
              (if (ignore-errors (metal-deps--valider-catalogue data2))
                  (setq metal-deps-agents-catalogue data2)
                (message
                 "⚠ Catalogue d'agents irrecuperable (%s) — version precedente conservee"
                 f)))))))
    metal-deps-agents-catalogue))

(defun metal-deps--sauver-catalogue ()
  "Ecrit `metal-deps-agents-catalogue' dans le fichier, en preservant
l'en-tete de commentaires existant (au-dessus de la 1re parenthese).

REFUSE d'ecrire une liste vide : cela ecraserait le seed et ferait
disparaitre les agents par defaut (Antigravity, ChatGPT, Claude).  Un
catalogue nil au moment d'une sauvegarde signale un etat transitoire
(chargement incomplet), pas une suppression legitime de tous les agents."
  (if (null metal-deps-agents-catalogue)
      (metal-deps--journaliser
       "Sauvegarde du catalogue ignoree : catalogue vide (protection anti-ecrasement)")
    (let* ((f metal-deps-agents-catalogue-fichier)
           (entete
            (when (file-exists-p f)
              (with-temp-buffer
                (insert-file-contents f)
                (goto-char (point-min))
                ;; en-tete = tout avant la 1re '(' en colonne 0
                (if (re-search-forward "^(" nil t)
                    (buffer-substring (point-min) (match-beginning 0))
                  "")))))
      (make-directory (file-name-directory f) t)
      (with-temp-file f
        (when (and entete (> (length entete) 0))
          (insert entete))
        (insert "(\n")
        (dolist (entry metal-deps-agents-catalogue)
          (insert (format " %S\n" entry)))
        (insert ")\n"))
      (metal-deps--journaliser "Catalogue d'agents sauvegarde (%d agents)"
                               (length metal-deps-agents-catalogue)))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Detection d'authentification revisee
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--agent-auth-verifiable-p (spec)
  "Retourne nil si l'auth de SPEC ne peut pas etre verifiee.
Vrai pour :auth-verifier, :auth-commande, :auth-fichiers, :auth-env.
Faux si :auth-mode est `externe' ou si aucun mecanisme n'est fourni."
  (and (not (eq (plist-get spec :auth-mode) 'externe))
       (or (plist-get spec :auth-verifier)
           (plist-get spec :auth-commande)
           (plist-get spec :auth-fichiers)
           (plist-get spec :auth-env))))

(defun metal-deps--agent-authentifie-p (spec)
  "Retourne t si l'agent SPEC semble authentifie.
Ordre : :auth-verifier > :auth-commande (code 0) > :auth-fichiers >
:auth-env.  Pour un agent non verifiable (:auth-mode externe ou aucun
mecanisme), retourne nil — l'affichage utilisera un statut neutre via
`metal-deps--agent-auth-verifiable-p'."
  (let ((verifier (plist-get spec :auth-verifier))
        (commande (plist-get spec :auth-commande))
        (fichiers (plist-get spec :auth-fichiers))
        (env-vars (plist-get spec :auth-env)))
    (or (and verifier (functionp verifier)
             (ignore-errors (funcall verifier)))
        (and commande (listp commande)
             (ignore-errors
               (zerop (apply #'call-process (car commande) nil nil nil
                             (cdr commande)))))
        (and fichiers
             (cl-some (lambda (f) (file-exists-p (expand-file-name f))) fichiers))
        (and env-vars
             (cl-some (lambda (v) (let ((val (getenv v)))
                                    (and val (not (string-empty-p val)))))
                      env-vars)))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Affichage unifie : tout agent vient du catalogue (fichier)
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--collecter-outils-agents ()
  "Retourne la liste des outils-agents, tous issus du catalogue (fichier).
Recharge le catalogue d'abord pour refleter les editions du fichier."
  (metal-deps--charger-catalogue)
  (mapcar #'metal-deps--agent-catalogue->outil metal-deps-agents-catalogue))

;;; ──────────────────────────────────────────────────────────────────
;;;  Suppression : retire du fichier ET du registre (tout est supprimable)
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--desinstaller-agent-ia (id)
  "Retire l'agent ID du catalogue (fichier) ET du registre actif.
La CLI installee n'est PAS supprimee du systeme (l'utilisateur la gere)."
  (let* ((spec (cdr (assq id metal-deps-agents-catalogue)))
         (nom  (or (plist-get spec :nom) (symbol-name id))))
    (when (yes-or-no-p
           (format "Retirer l'agent « %s » du catalogue et de la liste active ? " nom))
      ;; 1) Retirer du registre actif
      (when (and (boundp 'metal-agent-providers)
                 (assq id metal-agent-providers))
        (customize-save-variable
         'metal-agent-providers
         (assq-delete-all id metal-agent-providers))
        (when (and (boundp 'metal-agent-provider)
                   (eq metal-agent-provider id))
          (customize-save-variable
           'metal-agent-provider
           (car-safe (car-safe metal-agent-providers)))))
      ;; 2) Retirer du catalogue (fichier)
      (setq metal-deps-agents-catalogue
            (assq-delete-all id metal-deps-agents-catalogue))
      (metal-deps--sauver-catalogue)
      (metal-deps--journaliser "Agent « %s » retire du catalogue" nom)
      (message "« %s » retire." nom)
      (when (fboundp 'metal-deps-afficher-etat)
        (run-with-timer 0.2 nil #'metal-deps-afficher-etat)))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Ajout assiste : ecrit dans le fichier catalogue
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--ajouter-agent-personnalise ()
  "Ajoute un agent au catalogue (fichier).
Propose d'abord un modele connu (pre-rempli) ou une saisie libre.
Garantit la presence du drapeau non interactif « -p » par defaut."
  (interactive)
  (require 'metal-agent nil t)
  (metal-deps--charger-catalogue)
  (let* ((choix-modeles
          (append (mapcar (lambda (m) (cons (plist-get (cdr m) :nom) (car m)))
                          metal-deps-agents-modeles-connus)
                  '(("Saisie libre (autre agent)" . nil))))
         (choix (completing-read "Ajouter quel agent ? "
                                 (mapcar #'car choix-modeles) nil t))
         (modele-id (cdr (assoc choix choix-modeles)))
         (modele (and modele-id
                      (cdr (assq modele-id metal-deps-agents-modeles-connus)))))
    (if modele
        (metal-deps--ajouter-depuis-modele modele-id modele)
      (metal-deps--ajouter-saisie-libre))))

(defun metal-deps--ajouter-depuis-modele (id modele)
  "Ajoute l'agent ID au catalogue a partir de MODELE (pre-rempli)."
  (when (assq id metal-deps-agents-catalogue)
    (user-error "L'agent « %s » est deja dans le catalogue" id))
  (setq metal-deps-agents-catalogue
        (append metal-deps-agents-catalogue
                (list (cons id (copy-sequence modele)))))
  (metal-deps--sauver-catalogue)
  (message "Agent « %s » ajoute au catalogue." (plist-get modele :nom))
  (when (fboundp 'metal-deps-afficher-etat)
    (run-with-timer 0.2 nil #'metal-deps-afficher-etat)))

(defun metal-deps--assurer-print (args)
  "Garantit que ARGS contient un drapeau non interactif.
Si ni -p ni --print ni un sous-mode (exec) n'est present, prefixe -p."
  (if (or (member "-p" args) (member "--print" args)
          (member "--prompt" args) (member "exec" args))
      args
    (cons "-p" args)))

(defun metal-deps--ajouter-saisie-libre ()
  "Ajoute un agent au catalogue par saisie manuelle des champs."
  (let* ((id-str (string-trim (read-string "ID unique (symbole, ex: mon-agent) : ")))
         (id (and (not (string-empty-p id-str)) (intern id-str))))
    (unless id (user-error "ID requis"))
    (when (assq id metal-deps-agents-catalogue)
      (user-error "L'ID « %s » existe deja dans le catalogue" id-str))
    (let* ((nom (string-trim (read-string "Nom affiche (ex: Mon Agent) : ")))
           (commande (string-trim (read-string "Commande CLI (ex: mon-cli) : ")))
           (args-str (read-string "Arguments (espaces ; vide = \"-p\" par defaut) : "))
           (args (metal-deps--assurer-print
                  (if (string-empty-p (string-trim args-str))
                      nil
                    (split-string-and-unquote args-str))))
           (format-str (completing-read "Format de sortie : "
                                        '("claude-style" "codex-style")
                                        nil t nil nil "claude-style"))
           (desc (string-trim (read-string "Description courte (optionnel) : "))))
      (when (string-empty-p nom) (user-error "Nom requis"))
      (when (string-empty-p commande) (user-error "Commande requise"))
      (unless (executable-find commande)
        (unless (yes-or-no-p
                 (format "« %s » introuvable dans le PATH.  Ajouter quand meme ? " commande))
          (user-error "Annule")))
      (let ((spec (list :nom nom :commande commande
                        :args args :format (intern format-str)
                        :via-process t
                        :auth-mode 'externe)))
        (when (and desc (not (string-empty-p desc)))
          (setq spec (plist-put spec :description desc)))
        (setq metal-deps-agents-catalogue
              (append metal-deps-agents-catalogue (list (cons id spec))))
        (metal-deps--sauver-catalogue)
        (message "Agent « %s » ajoute au catalogue." nom)
        (when (fboundp 'metal-deps-afficher-etat)
          (run-with-timer 0.2 nil #'metal-deps-afficher-etat))))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Commandes utilisateur : editer / recharger / supprimer
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps-editer-catalogue ()
  "Ouvre le fichier catalogue d'agents pour edition.
Apres edition : `metal-deps-recharger-catalogue'."
  (interactive)
  (let ((f metal-deps-agents-catalogue-fichier))
    (unless (file-exists-p f) (metal-deps--charger-catalogue))
    (find-file f)
    (message "Editez, puis M-x metal-deps-recharger-catalogue (ou rouvrez l'Assistant).")))

(defun metal-deps-recharger-catalogue ()
  "Relit le fichier catalogue et rafraichit l'Assistant si ouvert."
  (interactive)
  (metal-deps--charger-catalogue 'force)
  (message "Catalogue recharge : %d agent(s)." (length metal-deps-agents-catalogue))
  (when (and (fboundp 'metal-deps-afficher-etat)
             (get-buffer "*MetalEmacs — Assistant*"))
    (metal-deps-afficher-etat)))

(defun metal-deps-catalogue-supprimer-agent ()
  "Choisit un agent du catalogue et le retire (fichier + registre)."
  (interactive)
  (metal-deps--charger-catalogue)
  (unless metal-deps-agents-catalogue
    (user-error "Le catalogue est vide"))
  (let* ((choix (mapcar (lambda (e)
                          (cons (format "%s (%s)"
                                        (or (plist-get (cdr e) :nom) (car e))
                                        (car e))
                                (car e)))
                        metal-deps-agents-catalogue))
         (sel (completing-read "Supprimer quel agent ? " (mapcar #'car choix) nil t))
         (id (cdr (assoc sel choix))))
    (when id (metal-deps--desinstaller-agent-ia id))))

(defalias 'metal-deps-catalogue-ajouter-agent
  #'metal-deps--ajouter-agent-personnalise
  "Ajoute un agent au catalogue (modele connu ou saisie libre).")

;;; ──────────────────────────────────────────────────────────────────
;;;  Chargement initial
;;; ──────────────────────────────────────────────────────────────────

(metal-deps--charger-catalogue)

(provide 'metal-agents-catalogue-externe)
;;; metal-agents-catalogue-externe.el ends here
