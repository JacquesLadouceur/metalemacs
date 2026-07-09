;;; metal-agents-formulaire-detection.el --- Détection assistée des arguments  -*- lexical-binding: t; -*-
;;
;; EXTENSION de `metal-agents-formulaire.el'.
;;
;; Ajoute un bouton « Détecter les arguments » sous le champ Commande.
;; Au clic : le nom du binaire saisi est envoyé à L'AGENT ACTIF COURANT
;; (`metal-agent-provider') via la couche `metal-agent--run-codex'.  La
;; réponse — synthèse des arguments non interactifs, format, isolation —
;; est AFFICHÉE D'ABORD dans une fenêtre de prévisualisation ; c'est un
;; clic sur « Appliquer » qui remplit alors les champs du formulaire.
;;
;; PRUDENCE : la synthèse est GÉNÉRÉE par un modèle et peut halluciner un
;; drapeau inexistant ou périmé.  Elle est donc présentée comme une
;; PROPOSITION À VÉRIFIER, jamais appliquée sans validation explicite.
;;
;; REPLI : si aucun agent n'est configuré ni disponible, le bouton se
;; contente de renvoyer à l'aide texte du champ Arguments (comportement
;; inchangé du formulaire).
;;
;; INSTALLATION (après le formulaire) :
;;     (with-eval-after-load 'metal-agents-formulaire
;;       (require 'metal-agents-formulaire-detection))

(require 'metal-agents-formulaire)
(require 'metal-agent nil t)
(require 'cl-lib)

;;; ──────────────────────────────────────────────────────────────────
;;;  Prompt de détection (réponse structurée, sans prose)
;;; ──────────────────────────────────────────────────────────────────

(defconst metal-deps--detect-prompt-modele
  "Tu documentes l'intégration d'un outil CLI dans un éditeur.
Pour le binaire nommé « %s », indique COMMENT l'invoquer en mode NON
INTERACTIF, une seule requête, réponse sur la sortie standard — c.-à-d.
l'équivalent de `claude -p` ou `codex exec` — ET comment il s'authentifie.

Réponds EXACTEMENT dans ce format, sans aucune autre phrase :

ARGS: <les arguments fixes à passer avant le prompt, séparés par des espaces>
FORMAT: <claude-style ou codex-style>
ISOLER: <oui ou non>
AUTH-METHODE: <login-interactif | cle-api-env | fichier-credentials | externe>
AUTH-COMMANDE: <commande dont le code de sortie 0 = authentifié, ou —>
AUTH-FICHIERS: <chemins de fichiers de credentials séparés par espaces, ou —>
AUTH-ENV: <variables d'environnement de clé API séparées par espaces, ou —>
AUTH-LOGIN: <sous-commande de login non interactif (ex: login), ou —>
AUTH-AIDE: <une phrase : comment l'utilisateur s'authentifie concrètement>
NOTE: <une phrase : incertitude éventuelle, drapeau à vérifier>

Règles :
- ARGS doit contenir le drapeau de mode non interactif (-p, --print,
  --prompt, exec, ou équivalent réel de CE binaire).  N'invente pas de
  drapeau : si tu n'es pas sûr, mets ce que tu proposes et signale-le
  dans NOTE.
- FORMAT : claude-style si la réponse est un simple bloc de texte /
  Markdown ; codex-style s'il faut d'abord sauter un en-tête de session.
- ISOLER : oui si l'outil est un agent autonome qui explore le disque ou
  exécute des commandes ; non si c'est un simple appel requête-réponse.
- AUTH-METHODE : le mécanisme principal.
    login-interactif  = navigateur / device flow / sous-commande login ;
    cle-api-env       = variable d'environnement contenant une clé API ;
    fichier-credentials = jeton stocké dans un fichier local ;
    externe           = auth gérée hors du CLI, non vérifiable par programme.
- AUTH-COMMANDE : SEULEMENT si une commande de statut renvoie un code de
  sortie fiable (ex: `gh auth status`).  Sinon —.
- AUTH-FICHIERS / AUTH-ENV : renseigne si tu les connais, sinon —.  Pense
  aux 3 OS pour les chemins.
- AUTH-LOGIN : la sous-commande de login SI elle s'exécute en une passe
  (ex: `login`).  Si le login se fait DANS l'interface interactive
  (ex: une commande slash), mets — et explique-le dans AUTH-AIDE.
- Si le binaire « %s » ne t'est pas connu, ne devine pas au hasard :
  mets des valeurs plausibles ET écris clairement dans NOTE qu'il faut
  vérifier dans la documentation officielle."
  "Gabarit de prompt pour la détection des arguments et de l'auth d'un CLI.
Deux %%s : le nom du binaire (utilisé deux fois).")

;;; ──────────────────────────────────────────────────────────────────
;;;  Disponibilité d'un agent pour la détection
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--detect-agent-pret-p ()
  "Retourne t si un agent actif est configuré et sa CLI disponible."
  (and (boundp 'metal-agent-provider)
       metal-agent-provider
       (fboundp 'metal-agent-disponible-p)
       (fboundp 'metal-agent--run-codex)
       (ignore-errors (metal-agent-disponible-p))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Analyse de la réponse structurée
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--detect-parser (reponse)
  "Extrait un plist des champs de la REPONSE structurée.
Clés : :args :format :isoler :auth-methode :auth-commande :auth-fichiers
:auth-env :auth-login :auth-aide :note.  Tolérant : lit chaque ligne
CLÉ: où qu'elle soit.  Une valeur « — » (tiret) est traitée comme vide."
  (let ((vals (make-hash-table :test 'equal)))
    (dolist (ligne (split-string (or reponse "") "\n"))
      (let ((l (string-trim ligne)))
        (when (string-match "\\`\\([A-Z-]+\\):[ \t]*\\(.*\\)\\'" l)
          (let ((cle (match-string 1 l))
                (val (string-trim (match-string 2 l))))
            ;; « — », « - » ou vide => nil
            (when (or (string-empty-p val)
                      (string-match-p "\\`[—-]+\\'" val))
              (setq val nil))
            (puthash cle val vals)))))
    (let ((g (lambda (k) (gethash k vals))))
      (let ((fmt (funcall g "FORMAT")))
        (list
         :args         (funcall g "ARGS")
         :format       (cond ((and fmt (string-match-p "codex" fmt)) "codex-style")
                             ((and fmt (string-match-p "claude" fmt)) "claude-style")
                             (t nil))
         :isoler       (let ((v (funcall g "ISOLER")))
                         (and v (string-match-p "\\`\\(oui\\|yes\\|o\\|y\\)"
                                                (downcase v))))
         :auth-methode (funcall g "AUTH-METHODE")
         :auth-commande (funcall g "AUTH-COMMANDE")
         :auth-fichiers (funcall g "AUTH-FICHIERS")
         :auth-env     (funcall g "AUTH-ENV")
         :auth-login   (funcall g "AUTH-LOGIN")
         :auth-aide    (funcall g "AUTH-AIDE")
         :note         (funcall g "NOTE"))))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Application de la proposition aux widgets du formulaire
;;; ──────────────────────────────────────────────────────────────────


(defun metal-deps--detect-appliquer (form-buffer prop)
  "Remplit les champs du FORM-BUFFER depuis la proposition PROP (plist).
Remplit Arguments / Format / isoler-fichier ET la section
Authentification (auth-commande, auth-fichiers, auth-env, auth-args,
auth-aide, ou la case auth-mode externe selon la méthode détectée)."
  (when (buffer-live-p form-buffer)
    (with-current-buffer form-buffer
      ;; D'ABORD : capturer la saisie manuelle déjà présente (Commande,
      ;; Nom, etc.) dans le stockage persistant, pour ne pas la perdre.
      (metal-deps--form-capturer-valeurs)
      ;; ENSUITE : écrire les valeurs détectées PAR-DESSUS.
      (cl-flet ((memo (cle val)
                  (when (and val (stringp val) (not (string-empty-p val)))
                    (setf (alist-get cle metal-deps--form-valeurs) val))))
        ;; --- Invocation ---
        (memo :args (plist-get prop :args))
        (memo :format (plist-get prop :format))
        (when (plist-get prop :isoler)
          (setf (alist-get :isoler-fichier metal-deps--form-valeurs) t))
        ;; --- Authentification ---
        (let ((methode (plist-get prop :auth-methode)))
          (if (and methode (string-match-p "externe" (downcase methode)))
              ;; Non vérifiable : cocher auth-mode externe.
              (setf (alist-get :auth-mode-externe metal-deps--form-valeurs) t)
            ;; Vérifiable : remplir les mécanismes connus, décocher externe.
            (setf (alist-get :auth-mode-externe metal-deps--form-valeurs) nil)
            (memo :auth-commande (plist-get prop :auth-commande))
            (memo :auth-fichiers (plist-get prop :auth-fichiers))
            (memo :auth-env      (plist-get prop :auth-env))
            (memo :auth-args     (plist-get prop :auth-login))))
        (memo :auth-aide (plist-get prop :auth-aide)))
      ;; Ouvrir les deux sections concernées pour montrer le résultat.
      (setf (alist-get 'invocation metal-deps--form-sections-ouvertes) t)
      ;; Ouvrir Auth seulement si quelque chose y a été rempli.
      (when (or (plist-get prop :auth-methode)
                (plist-get prop :auth-commande)
                (plist-get prop :auth-env)
                (plist-get prop :auth-fichiers)
                (plist-get prop :auth-login)
                (plist-get prop :auth-aide))
        (setf (alist-get 'auth metal-deps--form-sections-ouvertes) t))
      (setq metal-deps--form-derniere-section 'invocation)
      ;; Reconstruire SANS recapturer : les valeurs viennent d'être posées
      ;; dans `metal-deps--form-valeurs' ; une capture les écraserait avec
      ;; le contenu vide des widgets encore affichés.
      (metal-deps--form-rendre t)
      (message "Proposition appliquée aux champs. À VÉRIFIER avant d'enregistrer."))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Fenêtre de prévisualisation
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--detect-previsualiser (form-buffer binaire reponse)
  "Affiche la REPONSE de l'agent pour BINAIRE, avec boutons Appliquer/Ignorer."
  (let* ((prop (metal-deps--detect-parser reponse))
         (buf (get-buffer-create "*MetalEmacs — Détection arguments*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer))
      (remove-overlays)
      (kill-all-local-variables)
      (widget-insert
       (propertize (format "  Proposition pour « %s »\n\n" binaire)
                   'face '(:height 1.1 :weight bold)))
      (widget-insert
       (propertize
        (concat "  ⚠ Générée par l'agent actif — à VÉRIFIER dans la doc\n"
                "  officielle avant d'enregistrer.  Un modèle peut se tromper\n"
                "  de drapeau.\n\n")
        'face 'shadow))
      (widget-insert (propertize "── Proposé ──────────────────────\n\n" 'face 'bold))
      (widget-insert (format "  Arguments  : %s\n" (or (plist-get prop :args) "—")))
      (widget-insert (format "  Format     : %s\n" (or (plist-get prop :format) "—")))
      (widget-insert (format "  isoler-fichier : %s\n"
                             (if (plist-get prop :isoler) "oui" "non")))
      (widget-insert (propertize "\n── Authentification proposée ────\n\n" 'face 'bold))
      (widget-insert (format "  Méthode    : %s\n" (or (plist-get prop :auth-methode) "—")))
      (widget-insert (format "  auth-commande : %s\n" (or (plist-get prop :auth-commande) "—")))
      (widget-insert (format "  auth-fichiers : %s\n" (or (plist-get prop :auth-fichiers) "—")))
      (widget-insert (format "  auth-env      : %s\n" (or (plist-get prop :auth-env) "—")))
      (widget-insert (format "  login (auth-args) : %s\n" (or (plist-get prop :auth-login) "—")))
      (when (plist-get prop :auth-aide)
        (widget-insert (format "  Comment s'authentifier : %s\n"
                               (plist-get prop :auth-aide))))
      (when (plist-get prop :note)
        (widget-insert (propertize (format "\n  Note : %s\n" (plist-get prop :note))
                                   'face 'warning)))
      (widget-insert (propertize "\n── Réponse brute ────────────────\n\n" 'face 'bold))
      (let ((deb (point)))
        (widget-insert (string-trim (or reponse "")))
        (add-text-properties deb (point) '(face shadow)))
      (widget-insert "\n\n")
      ;; Capturer form-buffer et prop DANS la closure (lexical) à la
      ;; création : ne pas dépendre des variables locales au moment du
      ;; clic, car `quit-window' peut avoir changé de buffer entre-temps.
      (let ((fb form-buffer)
            (pr prop)
            (preview buf))
        (widget-create 'push-button
                       :notify (lambda (&rest _)
                                 (when (buffer-live-p preview)
                                   (with-current-buffer preview
                                     (quit-window t)))
                                 (metal-deps--detect-appliquer fb pr))
                       "  Appliquer au formulaire  ")
        (widget-insert "   ")
        (widget-create 'push-button
                       :notify (lambda (&rest _)
                                 (when (buffer-live-p preview)
                                   (with-current-buffer preview
                                     (quit-window t))))
                       "  Ignorer  "))
      (widget-insert "\n")
      (use-local-map widget-keymap)
      (widget-setup)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

;;; ──────────────────────────────────────────────────────────────────
;;;  Lancement de la détection
;;; ──────────────────────────────────────────────────────────────────

(defun metal-deps--detect-lancer ()
  "Détecte les arguments du binaire saisi via l'agent actif.
Repli sur l'aide texte si aucun agent n'est disponible."
  (let* ((form-buffer (current-buffer))
         (binaire (metal-deps--form-val-str :commande)))
    (cond
     ((not binaire)
      (message "Renseignez d'abord le champ « Commande » (nom du binaire)."))
     ((not (metal-deps--detect-agent-pret-p))
      ;; Repli : renvoyer à l'aide texte existante du champ Arguments.
      (message "%s"
               (concat "Aucun agent actif disponible. "
                       "Renseignez les Arguments à la main — voir l'aide du "
                       "champ (mode non interactif : -p / --print / exec).")))
     (t
      (let ((prompt (format metal-deps--detect-prompt-modele binaire binaire)))
        (message "Détection des arguments de « %s » via l'agent actif…" binaire)
        (metal-agent--run-codex
         prompt
         (format "Détection arguments : %s" binaire)
         (lambda (code reponse)
           (if (and (integerp code) (zerop code)
                    reponse (not (string-empty-p (string-trim reponse))))
               (metal-deps--detect-previsualiser form-buffer binaire reponse)
             (message "Détection échouée (code %s). Renseignez les Arguments à la main."
                      code)))
         "Détection des arguments"))))))

;;; ──────────────────────────────────────────────────────────────────
;;;  Injection du bouton dans le formulaire
;;; ──────────────────────────────────────────────────────────────────
;;
;; On « avise » `metal-deps--form-inserer-section' : après avoir inséré la
;; section « invocation », on ajoute le bouton de détection.  Ainsi le
;; formulaire de base reste inchangé.

(defun metal-deps--detect-apres-section (section)
  "Ajoute le bouton de détection juste après la section « invocation »."
  (when (eq (nth 0 section) 'invocation)
    (when (metal-deps--form-section-ouverte-p 'invocation)
      (widget-insert "  ")
      (widget-create 'push-button
                     :notify (lambda (&rest _) (metal-deps--detect-lancer))
                     :help-echo
                     "Interroge l'agent actif pour proposer les arguments (à vérifier)."
                     " Détecter les arguments ")
      (widget-insert
       (propertize "  (via l'agent actif — proposition à vérifier)\n\n"
                   'face 'shadow)))))

(advice-add 'metal-deps--form-inserer-section :after
            #'metal-deps--detect-apres-section)

(provide 'metal-agents-formulaire-detection)

;;; metal-agents-formulaire-detection.el ends here
