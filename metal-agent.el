;;; metal-agent.el --- MetalEmacs + Codex, toolbar native -*- lexical-binding: t; coding: utf-8; -*-

;; Solution clé en main :
;; - Pas d'application de diff fragile.
;; - Codex retourne du CODE FINAL dans un bloc Markdown.
;; - Emacs affiche un diff Avant/Après.
;; - Emacs demande confirmation.
;; - Si oui, Emacs remplace la sélection ou le buffer complet.
;;
;; Seul buffer externe : *Metal Codex* pour la sortie Codex.

(require 'subr-x)
(require 'cl-lib)
(require 'diff)
(require 'metal-toolbar)

;; Déclarations pour satisfaire le byte-compiler (chargement paresseux).
(declare-function ansi-color-apply-on-region "ansi-color" (begin end))
(defvar compilation-filter-start)

(defgroup metal-agent nil
  "Interface MetalEmacs pour Codex."
  :group 'tools)

;;; --- Configuration des fournisseurs (providers) -------------------------

(defcustom metal-agent-provider nil
  "ID symbolique de l'agent IA actif.
Doit correspondre à une clé de `metal-agent-providers'.  nil = aucun
agent sélectionné — utiliser l'Assistant (M-x metal-deps-afficher-etat)
pour installer et configurer un agent.

Persistance : la valeur Custom est l'agent **par défaut**, restauré
au démarrage d'Emacs.  Les changements via `metal-agent-choisir-provider'
(C-c m p, ou depuis les modes Python/Prolog) modifient cette variable
en mémoire pour la session courante uniquement — le défaut persistant
n'est modifiable que depuis l'Assistant MetalEmacs."
  :type 'symbol
  :group 'metal-agent)

(defcustom metal-agent-status-buffer-name "*Metal Agent*"
  "Nom du buffer d'état affiché pendant la préparation des corrections."
  :type 'string
  :group 'metal-agent)

(defcustom metal-agent-auto-integrate t
  "Si non nil, ajouter automatiquement le bouton Agent aux modes pertinents."
  :type 'boolean
  :group 'metal-agent)

;;; --- Registre des providers ---------------------------------------

(defcustom metal-agent-providers nil
  "Liste des agents IA configurés (persistée via Custom).
Chaque entrée est (ID . PLIST) où PLIST contient :
  :label STR        Nom affiché.
  :color HEXSTR     Couleur de l'icône robot.
  :command STR      Commande CLI.
  :args LISTE       Arguments par défaut pour proposer sans modifier.
  :buffer-name STR  Nom du buffer de sortie.
  :format SYM       `codex-style' ou `claude-style'.

Géré par l'Assistant MetalEmacs (M-x metal-deps-afficher-etat).
Ne modifier manuellement que via `customize-variable'."
  :type '(alist :key-type symbol :value-type plist)
  :group 'metal-agent
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'metal-agent--reconstruire-providers)
           (metal-agent--reconstruire-providers))))

(defvar metal-agent--providers nil
  "Registre runtime des providers, dérivé de `metal-agent-providers'.
La différence : `:format' (codex-style/claude-style) est résolu en
`:extract-fn' (fonction réelle).")

(defun metal-agent--provider-entry->runtime (entry)
  "Convertit une entrée (ID . PLIST) en entrée runtime avec :extract-fn."
  (let* ((id (car entry))
         (spec (cdr entry))
         (format (plist-get spec :format)))
    (cons id
          (plist-put (copy-sequence spec)
                     :extract-fn
                     (pcase format
                       ('codex-style 'metal-agent--extract-code-block-codex)
                       (_            'metal-agent--extract-code-block-claude))))))

(defun metal-agent--reconstruire-providers ()
  "Reconstruit `metal-agent--providers' à partir de `metal-agent-providers'."
  (setq metal-agent--providers
        (mapcar #'metal-agent--provider-entry->runtime metal-agent-providers)))

;; Initialisation immédiate.
(metal-agent--reconstruire-providers)

(defun metal-agent--provider-prop (key &optional provider)
  "Récupère KEY pour PROVIDER (par défaut : `metal-agent-provider')."
  (let* ((p (or provider metal-agent-provider))
         (entry (cdr (assq p metal-agent--providers))))
    (plist-get entry key)))

(defun metal-agent--current-command ()
  "Commande CLI du provider courant."
  (metal-agent--provider-prop :command))

(defun metal-agent--current-buffer-name ()
  "Nom du buffer de sortie du provider courant."
  (or (metal-agent--provider-prop :buffer-name)
      (format "*Metal %s*" (or (metal-agent--current-label) "Agent"))))

(defun metal-agent--current-propose-args ()
  "Arguments CLI du provider courant pour proposer."
  (metal-agent--provider-prop :args))

(defun metal-agent--current-extract-fn ()
  "Fonction d'extraction du provider courant."
  (metal-agent--provider-prop :extract-fn))

(defun metal-agent--current-label ()
  "Étiquette d'affichage du provider courant."
  (metal-agent--provider-prop :label))

(defun metal-agent--current-color ()
  "Couleur d'affichage du provider courant."
  (metal-agent--provider-prop :color))

(defvar-local metal-agent-active nil
  "Si non nil, afficher la toolbar Codex complète dans le buffer courant.")

(defvar-local metal-agent--auto-header-original nil)
(defvar-local metal-agent--auto-header-active nil)

(defvar metal-agent--source-buffer nil)
(defvar metal-agent--saved-region-beg nil)
(defvar metal-agent--saved-region-end nil)

(defvar metal-agent--last-original nil
  "Dernier texte original envoyé à Codex.")

(defvar metal-agent--last-proposed nil
  "Dernier code proposé par Codex.")

(defvar metal-agent--last-target nil
  "Cible de la dernière proposition : `region' ou `buffer'.")

(defvar metal-agent--last-target-buffer nil)
(defvar metal-agent--last-target-beg nil)
(defvar metal-agent--last-target-end nil)

;;; --- Profils (programmeur virtuel TAL) -----------------------------

(require 'metal-agent-profils nil t)

(defcustom metal-agent-profil-actif 'tronc-commun
  "Profil actuellement actif (symbole `:id' d'un profil de `metal-agent-profils').
Contrôle le contexte système et les options par défaut envoyés à
l'agent.  Les boutons rapides (Corriger, Expliquer, etc.) utilisent
ce profil avec ses options par défaut.

La valeur peut changer automatiquement à l'ouverture d'un buffer
si `metal-agent-auto-selection-profil' est non-nil et qu'un profil
correspond au mode courant."
  :type 'symbol
  :group 'metal-agent)

(defcustom metal-agent-auto-selection-profil t
  "Si non-nil, sélectionne automatiquement un profil selon le major-mode.
À chaque changement de major-mode, on cherche dans `metal-agent-profils'
un profil dont le champ `:modes' matche le mode courant et dont
`:auto-defaut' est non-nil.  Le premier trouvé devient actif.
Si aucun ne correspond, on bascule sur `tronc-commun' (fallback)."
  :type 'boolean
  :group 'metal-agent)

(defvar metal-agent--options-actives nil
  "Plist des options actives (override) sur le profil courant.
Forme : (:id-option t/nil ...).  Les valeurs absentes utilisent le
défaut du profil.  Réinitialisé quand on change de profil.")

(defvar metal-agent--instructions-libres ""
  "Instructions supplémentaires libres ajoutées au prompt.
Saisies via le panneau transient, conservées entre les appels.")

(defun metal-agent--profil (&optional id)
  "Retourne le plist du profil ID (par défaut : `metal-agent-profil-actif').
Retourne nil si introuvable."
  (let ((target (or id metal-agent-profil-actif)))
    (seq-find (lambda (p) (eq (plist-get p :id) target))
              metal-agent-profils)))

(defun metal-agent--profil-prop (key &optional id)
  "Récupère KEY dans le profil ID (par défaut : profil actif)."
  (plist-get (metal-agent--profil id) key))

(defun metal-agent--profil-options (id)
  "Liste des options disponibles pour le profil ID."
  (metal-agent--profil-prop :options-disponibles id))

(defun metal-agent--option-active-p (option-id &optional profil-id)
  "Retourne t si OPTION-ID est cochée pour PROFIL-ID.
Consulte d'abord `metal-agent--options-actives' (override session),
puis le défaut du profil."
  (let ((override (plist-member metal-agent--options-actives option-id)))
    (if override
        (cadr override)
      (plist-get (metal-agent--profil-prop :options-defaut profil-id)
                 option-id))))

(defun metal-agent--basculer-option (option-id)
  "Bascule l'état de OPTION-ID dans `metal-agent--options-actives'."
  (let ((nouveau (not (metal-agent--option-active-p option-id))))
    (setq metal-agent--options-actives
          (plist-put metal-agent--options-actives option-id nouveau))))

(defun metal-agent--reinitialiser-options ()
  "Réinitialise les options aux valeurs par défaut du profil actif."
  (interactive)
  (setq metal-agent--options-actives nil)
  (when (called-interactively-p 'any)
    (message "Options réinitialisées aux valeurs par défaut du profil.")))

;; ─────────────────────────────────────────────────────────────────
;; Sauvegarde de l'état des options dans le fichier .org du profil
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--sauvegarder-etat-dans-fichier (chemin options-disponibles)
  "Écrire l'état actuel des options dans le fichier .org CHEMIN.
Pour chaque option de OPTIONS-DISPONIBLES, remplace le `:: t' ou
`:: f' du titre par la valeur active dans la session courante."
  (with-temp-buffer
    (insert-file-contents chemin)
    (dolist (opt options-disponibles)
      (let* ((nom (plist-get opt :nom))
             (id (plist-get opt :id))
             (actif (metal-agent--option-active-p id))
             (valeur (if actif "t" "f"))
             ;; Échapper les caractères regex spéciaux dans le nom
             (nom-regex (regexp-quote nom))
             ;; Pattern : titre niveau 1 (* Nom :: t-ou-f), tolérant aux
             ;; espaces variables avant ::
             (pattern (format "^\\(\\*[ \t]+%s[ \t]*::[ \t]*\\)[a-zA-Z]+\\([ \t]*\\)$"
                              nom-regex)))
        (goto-char (point-min))
        (when (re-search-forward pattern nil t)
          (replace-match (concat "\\1" valeur "\\2") t nil))))
    (write-region (point-min) (point-max) chemin nil 'silent)))

(defun metal-agent--profil-est-defaut-p (profil)
  "Retourne t si PROFIL provient du dossier des profils par défaut."
  (eq (plist-get profil :origine) 'defaut))

(defun metal-agent--personnaliser-profil-defaut (profil)
  "Copier le PROFIL par défaut vers le dossier personnel.
Retourne le nouveau chemin du fichier personnel."
  (let* ((chemin-defaut (plist-get profil :chemin))
         (nom-fichier (file-name-nondirectory chemin-defaut))
         (chemin-perso (expand-file-name nom-fichier
                                         metal-agent-profils-directory)))
    (make-directory metal-agent-profils-directory t)
    (copy-file chemin-defaut chemin-perso t)
    chemin-perso))

(defun metal-agent-sauvegarder-etat ()
  "Sauvegarder l'état actuel des options dans le fichier .org du profil.
Modifie les `:: t' / `:: f' du fichier pour refléter les options
actuellement cochées.  Si le profil est livré par défaut (origine
`defaut'), demande confirmation pour créer une copie personnelle
avant de la modifier — les profils par défaut restent intacts."
  (interactive)
  (let* ((profil (metal-agent--profil))
         (chemin (plist-get profil :chemin))
         (options (plist-get profil :options-disponibles))
         (nom (plist-get profil :nom))
         (est-defaut (metal-agent--profil-est-defaut-p profil)))
    (cond
     ((null profil)
      (user-error "Aucun profil actif"))
     ((null chemin)
      (user-error "Le profil « %s » n'a pas de fichier source" nom))
     (est-defaut
      (if (yes-or-no-p
           (format
            "Le profil « %s » est livré par défaut.\nCréer une copie personnelle dans %s et y sauvegarder l'état ? "
            nom
            (abbreviate-file-name metal-agent-profils-directory)))
          (let ((nouveau-chemin
                 (metal-agent--personnaliser-profil-defaut profil)))
            (metal-agent--sauvegarder-etat-dans-fichier nouveau-chemin options)
            ;; Recharger les profils pour que la copie personnelle
            ;; éclipse le profil par défaut
            (when (fboundp 'metal-agent-recharger-profils)
              (metal-agent-recharger-profils))
            (message "État sauvegardé dans la copie personnelle : %s"
                     (abbreviate-file-name nouveau-chemin)))
        (message "Sauvegarde annulée — le profil par défaut reste intact.")))
     (t
      (metal-agent--sauvegarder-etat-dans-fichier chemin options)
      (message "État sauvegardé dans %s"
               (abbreviate-file-name chemin))))))

(defun metal-agent--fragments-actifs ()
  "Retourne la liste des fragments de prompt pour les options cochées."
  (let ((options (metal-agent--profil-options metal-agent-profil-actif))
        fragments)
    (dolist (opt options)
      (when (metal-agent--option-active-p (plist-get opt :id))
        (push (plist-get opt :fragment) fragments)))
    (nreverse fragments)))

(defun metal-agent--profil-systeme ()
  "Retourne le préambule système du profil actif (ou nil)."
  (metal-agent--profil-prop :systeme))

(defun metal-agent--profil-matche-mode-p (profil mode)
  "Retourne t si PROFIL est pertinent pour MODE.
Un profil avec `:modes t' matche tous les modes."
  (let ((modes (plist-get profil :modes)))
    (cond
     ((eq modes t) t)
     ((listp modes)
      (or (memq mode modes)
          (seq-some (lambda (m)
                      (and (symbolp m)
                           (let ((parent (get m 'derived-mode-parent)))
                             (and parent (memq parent modes)))))
                    (list mode))))
     (t nil))))

(defun metal-agent--profils-pour-mode (mode &optional auto-only)
  "Retourne la liste des profils pertinents pour MODE.
Si AUTO-ONLY est non-nil, ne retient que les profils marqués
`:auto-defaut t'."
  (seq-filter (lambda (p)
                (and (metal-agent--profil-matche-mode-p p mode)
                     (or (not auto-only)
                         (plist-get p :auto-defaut))))
              metal-agent-profils))

(defun metal-agent--profil-defaut-pour-mode (mode)
  "Retourne l'`:id' du profil `:auto-defaut t' qui matche MODE.
Préfère TOUJOURS un profil spécifique (`:modes' = liste contenant MODE)
à un profil universel (`:modes' = t).  Si aucun profil spécifique ne
matche, retourne `tronc-commun'."
  (let* ((candidats (metal-agent--profils-pour-mode mode t))
         ;; On sépare les profils spécifiques (`:modes' est une liste)
         ;; des profils universels (`:modes' est `t').
         (specifiques (seq-filter
                       (lambda (p)
                         (let ((m (plist-get p :modes)))
                           (and (listp m) (memq mode m))))
                       candidats))
         (choisi (or (car specifiques)
                     (seq-find (lambda (p) (eq (plist-get p :id) 'tronc-commun))
                               metal-agent-profils))))
    (if choisi
        (plist-get choisi :id)
      'tronc-commun)))

(defun metal-agent--auto-selectionner-profil ()
  "Met à jour `metal-agent-profil-actif' selon le major-mode courant.
N'a d'effet que si `metal-agent-auto-selection-profil' est non-nil.
Réinitialise les options actives si le profil change."
  (when (and metal-agent-auto-selection-profil
             metal-agent-profils
             ;; Ne s'applique qu'aux buffers fichiers ou aux modes
             ;; programmation/texte, pas aux buffers internes.
             (not (string-prefix-p " " (buffer-name)))
             (not (string-prefix-p "*" (buffer-name))))
    (let ((nouveau (metal-agent--profil-defaut-pour-mode major-mode)))
      (unless (eq nouveau metal-agent-profil-actif)
        (setq metal-agent-profil-actif nouveau)
        (metal-agent--reinitialiser-options)))))

(defun metal-agent--auto-selectionner-profil-window-change (_window)
  "Wrapper de `metal-agent--auto-selectionner-profil' pour `window-buffer-change-functions'.
Le hook reçoit la fenêtre en argument, qu'on ignore puisqu'on lit
`major-mode' du buffer courant."
  (metal-agent--auto-selectionner-profil))

(defun metal-agent-present-p ()
  "Retourne t si metal-agent est chargé."
  t)

(defun metal-agent-codex-disponible-p ()
  "Retourne t si la CLI du provider courant est disponible."
  (when-let ((cmd (metal-agent--current-command)))
    (executable-find cmd)))

(defalias 'metal-agent-disponible-p 'metal-agent-codex-disponible-p
  "Alias provider-agnostique de `metal-agent-codex-disponible-p'.")

(defun metal-agent--project-root ()
  "Retourne la racine du projet courant, sinon `default-directory'."
  (or (when (fboundp 'project-current)
        (when-let ((proj (project-current nil)))
          (expand-file-name (project-root proj))))
      default-directory))

(defun metal-agent--source-directory ()
  "Retourne le dossier de travail du buffer source."
  (if (buffer-live-p metal-agent--source-buffer)
      (with-current-buffer metal-agent--source-buffer
        (metal-agent--project-root))
    default-directory))

(defun metal-agent--source-file ()
  "Retourne le fichier source absolu ou le nom du buffer."
  (if (buffer-live-p metal-agent--source-buffer)
      (with-current-buffer metal-agent--source-buffer
        (or buffer-file-name (buffer-name)))
    (or buffer-file-name (buffer-name))))

(defun metal-agent--source-file-short ()
  "Retourne le nom court du fichier source."
  (let ((f (metal-agent--source-file)))
    (if (and f (file-name-absolute-p f))
        (file-name-nondirectory f)
      f)))

(defun metal-agent--source-language ()
  "Retourne une étiquette de langage pour le buffer source."
  (let ((buf (or metal-agent--source-buffer (current-buffer))))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (cond
           ((or (derived-mode-p 'prolog-mode)
                (and buffer-file-name (string-match-p "\\.pl\\'" buffer-file-name)))
            "SWI-Prolog")
           ((or (derived-mode-p 'python-mode)
                (and buffer-file-name (string-match-p "\\.py\\'" buffer-file-name)))
            "Python")
           ((or (derived-mode-p 'emacs-lisp-mode)
                (and buffer-file-name (string-match-p "\\.el\\'" buffer-file-name)))
            "Emacs Lisp")
           ((or (derived-mode-p 'org-mode)
                (and buffer-file-name (string-match-p "\\.org\\'" buffer-file-name)))
            "Org-mode")
           ((or (derived-mode-p 'markdown-mode)
                (and buffer-file-name
                     (string-match-p "\\.\\(md\\|markdown\\)\\'" buffer-file-name)))
            "Markdown")
           ((or (memq major-mode '(poly-quarto-mode quarto-mode))
                (and buffer-file-name (string-match-p "\\.qmd\\'" buffer-file-name)))
            "Quarto Markdown")
           ((derived-mode-p 'js-mode 'js-ts-mode 'typescript-mode 'typescript-ts-mode)
            "JavaScript/TypeScript")
           ((derived-mode-p 'c-mode 'c-ts-mode)
            "C")
           ((derived-mode-p 'c++-mode 'c++-ts-mode)
            "C++")
           ((derived-mode-p 'java-mode 'java-ts-mode)
            "Java")
           ((derived-mode-p 'rust-mode 'rust-ts-mode)
            "Rust")
           ((derived-mode-p 'go-mode 'go-ts-mode)
            "Go")
           ((derived-mode-p 'sh-mode 'bash-ts-mode)
            "Shell")
           ((derived-mode-p 'sql-mode)
            "SQL")
           (t
            (symbol-name major-mode))))
      "inconnu")))

(defun metal-agent--prolog-p ()
  "Retourne t si le buffer courant semble être du SWI-Prolog."
  (or (string-match-p "Prolog" (metal-agent--source-language))
      (and buffer-file-name (string-match-p "\\.pl\\'" buffer-file-name))))

(defun metal-agent--code-block-language ()
  "Retourne le nom du langage pour les blocs Markdown."
  (let ((lang (downcase (metal-agent--source-language))))
    (cond
     ((string-match-p "prolog" lang) "prolog")
     ((string-match-p "python" lang) "python")
     ((string-match-p "javascript\\|typescript" lang) "javascript")
     ((string-match-p "c\\+\\+" lang) "cpp")
     ((string-match-p "\\`c\\'" lang) "c")
     ((string-match-p "java" lang) "java")
     ((string-match-p "rust" lang) "rust")
     ((string-match-p "\\`go\\'" lang) "go")
     ((string-match-p "shell" lang) "bash")
     ((string-match-p "sql" lang) "sql")
     ((string-match-p "org" lang) "org")
     ((string-match-p "quarto\\|markdown" lang) "markdown")
     ((string-match-p "emacs" lang) "elisp")
     (t ""))))

(defun metal-agent--save-current-buffer-and-selection ()
  "Sauvegarde le buffer courant et la sélection éventuelle."
  (setq metal-agent--source-buffer (current-buffer))
  (let ((bounds
         (cond
          ((use-region-p)
           (cons (region-beginning) (region-end)))
          ((and (mark t)
                (/= (point) (mark t)))
           (cons (min (point) (mark t))
                 (max (point) (mark t))))
          (t nil))))
    (if bounds
        (setq metal-agent--saved-region-beg (car bounds)
              metal-agent--saved-region-end (cdr bounds))
      (setq metal-agent--saved-region-beg nil
            metal-agent--saved-region-end nil))))

(defun metal-agent--selection-text ()
  "Retourne la sélection sauvegardée ou active."
  (metal-agent--save-current-buffer-and-selection)
  (unless (and metal-agent--saved-region-beg metal-agent--saved-region-end)
    (user-error "Sélectionnez une région dans le buffer source"))
  (with-current-buffer metal-agent--source-buffer
    (buffer-substring-no-properties
     metal-agent--saved-region-beg
     metal-agent--saved-region-end)))

(defun metal-agent--file-text ()
  "Retourne tout le texte du buffer courant/source."
  (setq metal-agent--source-buffer (current-buffer))
  (with-current-buffer metal-agent--source-buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun metal-agent--codex-buffer ()
  "Retourne le buffer interne contenant la sortie brute du provider courant.
Le configure pour un affichage agréable de Markdown : `markdown-mode'
(ou variantes view/gfm) si disponible, numéros de lignes, word-wrap
visuel.  Configuration idempotente — n'écrase pas le mode déjà actif."
  (let ((buf (get-buffer-create (metal-agent--current-buffer-name))))
    (with-current-buffer buf
      ;; Choisir un mode de visualisation Markdown si pas déjà fait.
      ;; gfm-view-mode (GitHub-flavored, lecture seule) est l'idéal,
      ;; sinon fallback en cascade.
      (unless (derived-mode-p 'markdown-mode 'gfm-mode 'text-mode)
        (cond
         ((fboundp 'gfm-view-mode)      (gfm-view-mode))
         ((fboundp 'gfm-mode)            (gfm-mode))
         ((fboundp 'markdown-view-mode) (markdown-view-mode))
         ((fboundp 'markdown-mode)       (markdown-mode))
         (t (text-mode))))
      ;; Numéros de lignes à gauche (pour repérer / citer du code).
      (when (and (fboundp 'display-line-numbers-mode)
                 (not (bound-and-true-p display-line-numbers-mode)))
        (display-line-numbers-mode 1))
      ;; Word-wrap visuel : pas de horizontal scroll pour les longs paragraphes.
      (unless (bound-and-true-p visual-line-mode)
        (visual-line-mode 1)))
    buf))

(defun metal-agent--status-buffer ()
  "Retourne le buffer d'état utilisateur de Metal Agent."
  (let ((buf (get-buffer-create metal-agent-status-buffer-name)))
    (with-current-buffer buf
      (setq-local buffer-read-only nil)
      (fundamental-mode)
      (when (fboundp 'tab-line-mode)
        (tab-line-mode 1)
        (unless tab-line-format
          (kill-local-variable 'tab-line-format))))
    buf))

(defun metal-agent--show-status-message (texte &optional append)
  "Afficher TEXTE dans le buffer d'état.
Si APPEND est non nil, ajoute le texte à la fin ; sinon remplace le contenu."
  (let ((buf (metal-agent--status-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (unless append
          (erase-buffer))
        (goto-char (point-max))
        (insert texte)
        (unless (or (string-empty-p texte)
                    (string-suffix-p "\n" texte))
          (insert "\n"))
        (goto-char (point-max))))
    (display-buffer buf)
    (when-let ((win (get-buffer-window buf t)))
      (with-selected-window win
        (goto-char (point-max))))
    (redisplay t)
    buf))

(defun metal-agent--close-ui-buffers ()
  "Fermer les buffers UI temporaires de Metal Agent."
  (dolist (name (list metal-agent-status-buffer-name
                      (metal-agent--current-buffer-name)))
    (when-let ((buf (get-buffer name)))
      (when-let ((win (get-buffer-window buf t)))
        (ignore-errors (delete-window win)))
      (ignore-errors (kill-buffer buf)))))

(defun metal-agent--codex-command (args prompt)
  "Construire la commande CLI du provider courant avec ARGS et PROMPT."
  (append (list (metal-agent--current-command)) args (list prompt)))

(defun metal-agent--run-codex (prompt title callback)
  "Lancer la CLI du provider courant avec PROMPT et TITLE.

CALLBACK reçoit le code de sortie et la sortie brute."
  (unless (metal-agent-disponible-p)
    (user-error "%s CLI introuvable : %s"
                (metal-agent--current-label)
                (metal-agent--current-command)))
  (let* ((default-directory (metal-agent--source-directory))
         (buf (metal-agent--codex-buffer))
         (label (metal-agent--current-label))
         (proc nil))
    (metal-agent--message-preparation-corrections)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s — %s

" label title))))
    (setq proc
          (make-process
           :name (format "metal-agent-%s" (symbol-name metal-agent-provider))
           :buffer buf
           :command (metal-agent--codex-command
                     (metal-agent--current-propose-args) prompt)
           :noquery t
           :connection-type 'pipe
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (let ((code (process-exit-status process))
                     (raw (with-current-buffer (process-buffer process)
                            (buffer-substring-no-properties (point-min) (point-max)))))
                 (when callback
                   (funcall callback code raw)))))))
    (process-send-eof proc)
    proc))

(defun metal-agent--extract-code-block-codex (raw)
  "Extraire le dernier bloc de code utile de RAW (sortie Codex CLI).
On préfère la portion située après le dernier marqueur \"codex\" afin
d'éviter de reprendre le bloc de code du prompt utilisateur."
  (let ((txt raw))
    ;; Tronquer avant le dernier "codex\n" pour ignorer le prompt utilisateur.
    (let ((last-codex nil)
          (pos 0))
      (while (string-match "\ncodex\n" txt pos)
        (setq last-codex (match-end 0)
              pos (match-end 0)))
      (when last-codex
        (setq txt (substring txt last-codex))))
    ;; Retirer les statistiques finales éventuelles.
    (when (string-match "\ntokens used\\(?:.\\|\n\\)*\\'" txt)
      (setq txt (substring txt 0 (match-beginning 0))))
    ;; Extraire tous les blocs Markdown et garder le dernier non-diff.
    (let ((pos 0)
          blocks)
      (while (string-match
              "```\\([[:alnum:]_-]*\\)?[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n```"
              txt pos)
        (let ((lang (match-string 1 txt))
              (body (match-string 2 txt)))
          (unless (and lang (not (string-empty-p lang))
                       (string-match-p "\\`diff\\'" lang))
            (push (string-trim body) blocks)))
        (setq pos (match-end 0)))
      ;; `push` met en tête, donc `(car blocks)` est le DERNIER bloc trouvé.
      (car blocks))))

(defun metal-agent--extract-code-block-claude (raw)
  "Extraire le dernier bloc de code utile de RAW (sortie Claude Code CLI).
La sortie en mode --print/text est directement la réponse, sans préambule
à filtrer comme avec Codex.  On extrait simplement le dernier bloc de
code Markdown non-diff."
  (let ((pos 0)
        blocks)
    (while (string-match
            "```\\([[:alnum:]_-]*\\)?[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n```"
            raw pos)
      (let ((lang (match-string 1 raw))
            (body (match-string 2 raw)))
        (unless (and lang (not (string-empty-p lang))
                     (string-match-p "\\`diff\\'" lang))
          (push (string-trim body) blocks)))
      (setq pos (match-end 0)))
    (car blocks)))

(defun metal-agent--extract-code-block (raw)
  "Extraire le bloc de code de RAW via la fonction du provider courant."
  (funcall (metal-agent--current-extract-fn) raw))

(defun metal-agent--show-before-after-diff (old new)
  "Afficher un vrai diff Avant/Après entre OLD et NEW.

On écrit OLD et NEW dans deux fichiers temporaires, puis on appelle la
commande système `diff -u'. C'est plus fiable que d'utiliser directement
`diff-no-select' avec des chaînes."
  (let* ((old-file (make-temp-file "metal-agent-avant-"))
         (new-file (make-temp-file "metal-agent-apres-"))
         (buf (get-buffer-create "*Metal Codex Diff*")))
    (unwind-protect
        (progn
          (with-temp-file old-file
            (insert old))
          (with-temp-file new-file
            (insert new))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (call-process "diff" nil buf nil "-u"
                            "--label" "AVANT"
                            "--label" "APRÈS"
                            old-file
                            new-file)
              (goto-char (point-min))
              (diff-mode)))
          (display-buffer buf))
      (ignore-errors (delete-file old-file))
      (ignore-errors (delete-file new-file)))))

(defun metal-agent--store-target (target original &optional beg end)
  "Mémoriser la cible TARGET avec ORIGINAL, BEG et END."
  (setq metal-agent--last-target target
        metal-agent--last-original original
        metal-agent--last-proposed nil
        metal-agent--last-target-buffer metal-agent--source-buffer
        metal-agent--last-target-beg beg
        metal-agent--last-target-end end))

(defun metal-agent--apply-proposed-code ()
  "Appliquer `metal-agent--last-proposed' dans le buffer cible."
  (interactive)
  (unless metal-agent--last-proposed
    (user-error "Aucune proposition Codex à appliquer"))
  (unless (and metal-agent--last-target-buffer
               (buffer-live-p metal-agent--last-target-buffer))
    (user-error "Buffer cible introuvable"))
  (with-current-buffer metal-agent--last-target-buffer
    (save-excursion
      (pcase metal-agent--last-target
        ('region
         (unless (and metal-agent--last-target-beg
                      metal-agent--last-target-end)
           (user-error "Région cible invalide"))
         (delete-region metal-agent--last-target-beg
                        metal-agent--last-target-end)
         (goto-char metal-agent--last-target-beg)
         (insert metal-agent--last-proposed))
        ('buffer
         (delete-region (point-min) (point-max))
         (goto-char (point-min))
         (insert metal-agent--last-proposed))
        (_
         (user-error "Type de cible inconnu"))))
    (set-buffer-modified-p t))
  (message "Modification appliquée dans le buffer."))

(defun metal-agent--handle-codex-code-response (code raw)
  "Traiter la réponse Codex RAW.
Si une proposition est obtenue et qu'elle diffère du code original,
ouvre ediff pour révision hunk par hunk.  À la sortie d'ediff, le
contenu du buffer AVANT (modifié par l'utilisateur en copiant les
hunks souhaités depuis APRÈS) est appliqué dans le buffer cible."
  (cond
   ((/= code 0)
    (message nil)
    (display-buffer (metal-agent--codex-buffer))
    (cond
     ((metal-agent--erreur-auth-p raw)
      (let ((label (metal-agent--current-label))
            (buf-name (metal-agent--current-buffer-name)))
        (metal-agent--show-status-message
         (format "🔐 L'agent %s n'est pas authentifié.  Voir %s pour les détails."
                 label buf-name))
        (when (yes-or-no-p
               (format "Agent %s non authentifié.  Lancer l'assistant d'authentification maintenant ? "
                       label))
          (metal-agent-authentifier-cli))))
     (t
      (let ((buf-name (metal-agent--current-buffer-name))
            (label (or (metal-agent--current-label) "Agent")))
        (metal-agent--show-status-message
         (format "Erreur de l'agent.  Voir %s pour les détails." buf-name))
        (message "Erreur %s.  Voir %s." label buf-name)))))
   (t
    (let ((proposed (metal-agent--extract-code-block raw)))
      (if (not proposed)
          (message nil)
          (metal-agent--show-status-message "🤖 Aucune correction exploitable n'a été retournée.")
        (if (and metal-agent--last-original
                 (string= (string-trim proposed)
                          (string-trim metal-agent--last-original)))
            (progn
              (setq metal-agent--last-proposed nil)
              (message nil)
              (metal-agent--show-status-message "🤖 Aucune modification à suggérer.")
              (message "Codex n'a proposé aucune modification (le code est déjà correct)."))
          (setq metal-agent--last-proposed proposed)
          (when-let ((status (get-buffer metal-agent-status-buffer-name)))
            (when-let ((win (get-buffer-window status t)))
              (ignore-errors (delete-window win)))
            (ignore-errors (kill-buffer status)))
          (metal-agent--reviser-via-ediff metal-agent--last-original proposed)))))))

;;; --- Révision interactive via ediff (hunk par hunk) -------------------

(defcustom metal-agent-ediff-frame-name "Metal Agent — Révision Ediff"
  "Nom du frame séparé utilisé pour la révision Ediff."
  :type 'string
  :group 'metal-agent)

(defcustom metal-agent-ediff-frame-width 180
  "Largeur du frame séparé utilisé pour la révision Ediff."
  :type 'integer
  :group 'metal-agent)

(defcustom metal-agent-ediff-frame-height 48
  "Hauteur du frame séparé utilisé pour la révision Ediff."
  :type 'integer
  :group 'metal-agent)

(defvar metal-agent--ediff-target-buffer nil)
(defvar metal-agent--ediff-target-kind   nil)
(defvar metal-agent--ediff-target-beg    nil)
(defvar metal-agent--ediff-target-end    nil)
(defvar metal-agent--ediff-avant-buf     nil)
(defvar metal-agent--ediff-apres-buf     nil)
(defvar metal-agent--ediff-original-text nil)
(defvar metal-agent--ediff-window-config nil)
(defvar metal-agent--ediff-source-frame nil)
(defvar metal-agent--ediff-frame nil)
(defvar metal-agent--ediff-control-buffer nil
  "Buffer de controle Ediff de la session Metal Agent courante.")
(defvar metal-agent--ediff-cleanup-en-cours nil
  "Non-nil pendant le nettoyage manuel de la session Ediff Metal Agent.")
(defvar-local metal-agent--ediff-temp-buffer-p nil
  "Non-nil si le buffer est un buffer temporaire Ediff Metal Agent.")
(defvar metal-agent--ediff-saved-setup-fn nil
  "Valeur précédente de `ediff-window-setup-function' à restaurer en sortie.")
(defvar metal-agent--ediff-saved-split-fn nil
  "Valeur précédente de `ediff-split-window-function' à restaurer en sortie.")
(defvar metal-agent--ediff-saved-control-frame-parameters nil
  "Valeur précédente de `ediff-control-frame-parameters' à restaurer en sortie.")
(defvar metal-agent--ediff-saved-use-long-help-message nil
  "Valeur précédente de `ediff-use-long-help-message' à restaurer en sortie.")
(defvar metal-agent--ediff-saved-verbose-help-p nil
  "Valeur précédente de `ediff-verbose-help-p' à restaurer en sortie.")
(defvar metal-agent--ediff-saved-tab-line-mode nil
  "Valeur précédente de `global-tab-line-mode', si disponible.")
(defvar metal-agent--ediff-variables-saved-p nil
  "Non-nil si les variables Ediff globales ont été sauvegardées.")

(defun metal-agent--message-preparation-corrections ()
  "Afficher le message de préparation dans la minibuffer jusqu'à l'ouverture d'Ediff."
  (message "🤖 Préparation des corrections...")
  (redisplay t))

(defun metal-agent--ediff-make-wide-control-buffer-id-autour (orig-fn &rest args)
  "Protéger Ediff contre une erreur de format dans son panneau wide.

Dans notre interface, le panneau Ediff officiel reste vivant mais caché.
Certaines versions/configurations d'Ediff tentent quand même de reconstruire
un identifiant de panneau de contrôle wide et peuvent produire :

  ediff-make-wide-control-buffer-id: Format specifier doesn’t match argument type

Cette protection ne change pas l'interface Metal Agent ; elle empêche
simplement cette erreur interne d'être affichée dans *Messages*."
  (condition-case nil
      (apply orig-fn args)
    (error "*Ediff Control Panel*")))

(defun metal-agent--ediff-installer-protection-wide ()
  "Installer la protection contre le panneau de contrôle wide d'Ediff."
  (when (fboundp 'ediff-make-wide-control-buffer-id)
    (advice-add 'ediff-make-wide-control-buffer-id
                :around #'metal-agent--ediff-make-wide-control-buffer-id-autour)))

(defun metal-agent--ediff-retirer-protection-wide ()
  "Retirer la protection contre le panneau de contrôle wide d'Ediff."
  (when (fboundp 'ediff-make-wide-control-buffer-id)
    (advice-remove 'ediff-make-wide-control-buffer-id
                   #'metal-agent--ediff-make-wide-control-buffer-id-autour)))

(defun metal-agent--ediff-refresh-mode-lines-autour (orig-fn &rest args)
  "Neutraliser le faux positif de buffer Ediff vital pendant le nettoyage.

La révision Metal Agent se termine correctement, mais certaines versions
 d'Ediff tentent encore un rafraîchissement tardif des mode-lines. Quand cela
 arrive après fermeture visuelle de notre frame, Ediff peut signaler à tort
 qu'un buffer vital a été tué. On supprime uniquement ce bruit interne."
  (condition-case err
      (apply orig-fn args)
    (error
     (let ((msg (error-message-string err)))
       (unless (string-match-p "vital Ediff buffer" msg)
         (signal (car err) (cdr err)))))))

(defun metal-agent--ediff-installer-protection-refresh ()
  "Installer la protection contre les faux positifs de refresh Ediff."
  (when (fboundp 'ediff-refresh-mode-lines)
    (advice-add 'ediff-refresh-mode-lines
                :around #'metal-agent--ediff-refresh-mode-lines-autour)))

(defun metal-agent--ediff-retirer-protection-refresh ()
  "Retirer la protection contre les faux positifs de refresh Ediff."
  (when (fboundp 'ediff-refresh-mode-lines)
    (advice-remove 'ediff-refresh-mode-lines
                   #'metal-agent--ediff-refresh-mode-lines-autour)))

(defun metal-agent--ediff-tuer-buffers-temporaires ()
  "Nettoyer doucement les anciens buffers temporaires Metal Agent.

On évite ici tout `kill-buffer' sur des buffers qui ont pu servir à une
session Ediff précédente, car certaines versions d'Ediff continuent de les
considérer brièvement comme vitaux. On les enterre simplement."
  (dolist (buf (buffer-list))
    (let ((name (buffer-name buf)))
      (when (and (buffer-live-p buf)
                 (not (eq buf metal-agent--ediff-avant-buf))
                 (not (eq buf metal-agent--ediff-apres-buf))
                 (or (buffer-local-value 'metal-agent--ediff-temp-buffer-p buf)
                     (and name
                          (string-match-p
                           "\`\*Metal Agent: \(AVANT\|APRÈS\)\*"
                           name))))
        (ignore-errors (bury-buffer buf))))))

(defun metal-agent--ediff-action (fn)
  "Appeler FN dans le buffer de controle Ediff Metal Agent courant."
  (let ((control metal-agent--ediff-control-buffer))
    (if (buffer-live-p control)
        (condition-case err
            (with-current-buffer control
              ;; Les commandes Ediff se fient aux variables locales du
              ;; buffer de controle.  Il faut donc les executer depuis ce
              ;; buffer, meme si le clic vient de la header-line du buffer
              ;; APRES.
              (funcall fn))
          (error
           (message "Commande Ediff impossible : %s" (error-message-string err))))
      (message "Aucune session Ediff active."))))

(defun metal-agent-ediff-suivant ()
  "Aller à la différence suivante dans la session Ediff Metal Agent."
  (interactive)
  (metal-agent--ediff-action #'ediff-next-difference))

(defun metal-agent-ediff-precedent ()
  "Aller à la différence précédente dans la session Ediff Metal Agent."
  (interactive)
  (metal-agent--ediff-action #'ediff-previous-difference))

(defun metal-agent-ediff-accepter ()
  "Accepter la modification proposée pour la différence courante.
Dans Ediff, cela copie le buffer APRÈS (B) vers le buffer AVANT (A)."
  (interactive)
  (metal-agent--ediff-action
   (lambda ()
     ;; `ediff-copy-B-to-A' n'est pas une commande interactive sans
     ;; argument : elle attend le numéro de la différence courante.
     ;; Les boutons de la header-line appellent donc explicitement la
     ;; fonction avec `ediff-current-difference'.
     (let ((diff (and (boundp 'ediff-current-difference)
                      ediff-current-difference)))
       (if (numberp diff)
           (progn
             ;; Dans Ediff, `ediff-current-difference' est indexé à partir de 0,
             ;; mais `ediff-copy-B-to-A' attend un numéro de région à partir de 1.
             (ediff-copy-B-to-A (1+ diff))
             (ignore-errors (ediff-next-difference)))
         (message "Aucune différence courante à accepter."))))))

(defun metal-agent-ediff-ignorer ()
  "Ignorer la modification courante et passer à la suivante.
Le code AVANT (A) reste inchangé pour cette différence."
  (interactive)
  (metal-agent-ediff-suivant))

(defun metal-agent-ediff-quitter ()
  "Terminer la session Ediff Metal Agent et appliquer les hunks acceptés.

On n'appelle pas `ediff-quit' ici, car dans notre interface sans panneau de
contrôle visible Ediff peut tenter de reconstruire son control panel et
provoquer une erreur de format.

Le bouton Terminer applique donc directement le contenu du buffer AVANT
révisé dans la cible, puis nettoie le frame et les buffers temporaires."
  (interactive)
  (metal-agent--ediff-terminer-sans-ediff-quit))

(defun metal-agent--ediff-terminer-sans-ediff-quit ()
  "Nettoyer la session Metal Agent sans appeler `ediff-quit'."
  (if metal-agent--ediff-cleanup-en-cours
      (message "Nettoyage Ediff déjà en cours.")
    (setq metal-agent--ediff-cleanup-en-cours t)
    (let ((control metal-agent--ediff-control-buffer))
      ;; Éviter que le hook Ediff officiel redéclenche notre nettoyage après
      ;; la fermeture manuelle du frame/buffer.
      (when (buffer-live-p control)
        (with-current-buffer control
          (remove-hook 'ediff-quit-hook #'metal-agent--ediff-quit-hook t)))
      (unwind-protect
          (metal-agent--ediff-quit-hook)
        ;; Ne pas tuer le buffer de contrôle Ediff ici : certaines versions
        ;; d'Ediff lancent encore un rafraîchissement asynchrone après la
        ;; fermeture visuelle du frame. Le tuer provoque parfois des erreurs
        ;; "vital Ediff buffer". Il est simplement enterré.
        (when (buffer-live-p control)
          (with-current-buffer control
            (bury-buffer)))
        (setq metal-agent--ediff-cleanup-en-cours nil)))))

(defun metal-agent--ediff-button (label command help)
  "Créer un bouton de header-line LABEL appelant COMMAND avec HELP."
  (let ((cmd (lambda ()
               (interactive)
               (call-interactively command))))
    (propertize label
                'face 'mode-line-highlight
                'mouse-face 'highlight
                'help-echo help
                'local-map
                (let ((map (make-sparse-keymap)))
                  (define-key map [header-line mouse-1] cmd)
                  (define-key map [mode-line mouse-1] cmd)
                  map))))

(defun metal-agent--ediff-alignement-code ()
  "Retourner un préfixe de header-line aligné sur le début du code.

On aligne le libellé après la zone des numéros de ligne, avec un petit
écart supplémentaire pour que ORIGINAL et CORRECTION(S) commencent au
même endroit visuel que le code Python."
  (let* ((cols (cond
                ((fboundp 'line-number-display-width)
                 (line-number-display-width))
                ((and (boundp 'display-line-numbers-width)
                      (integerp display-line-numbers-width))
                 display-line-numbers-width)
                (t 3)))
         ;; largeur des numéros + séparateur + petit décalage visuel
         (offset (+ cols 2)))
    (propertize " " 'display `(space :align-to ,offset))))

(defun metal-agent--ediff-apres-header-line ()
  "Header-line compacte du buffer APRÈS avec actions Ediff en icônes."
  (concat
   (metal-agent--ediff-alignement-code)
   "CORRECTION(S)  "
   (metal-agent--ediff-button " ◀ " #'metal-agent-ediff-precedent
                              "Différence précédente")
   " "
   (metal-agent--ediff-button " ▶ " #'metal-agent-ediff-suivant
                              "Différence suivante")
   " "
   (metal-agent--ediff-button " ✅ " #'metal-agent-ediff-accepter
                              "Accepter cette modification")
   " "
   (metal-agent--ediff-button " ⏭ " #'metal-agent-ediff-ignorer
                              "Ignorer cette modification")
   " "
   (metal-agent--ediff-button " ✖ " #'metal-agent-ediff-quitter
                              "Terminer et appliquer les changements acceptés")
   "  "))

(defun metal-agent--ediff-creer-frame ()
  "Créer et sélectionner le frame séparé de révision Ediff."
  (let ((frame (make-frame `((name . ,metal-agent-ediff-frame-name)
                             (width . ,metal-agent-ediff-frame-width)
                             (height . ,metal-agent-ediff-frame-height)
                             (minibuffer . t)))))
    (select-frame-set-input-focus frame)
    (delete-other-windows)
    frame))

(defun metal-agent--ediff-preparer-buffer (buffer texte mode)
  "Remplir BUFFER avec TEXTE et activer MODE si possible."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert texte)
      (goto-char (point-min)))
    (when (and mode (fboundp mode))
      (ignore-errors (funcall mode)))
    ;; Dans le frame de révision, on veut uniquement deux fenêtres :
    ;; AVANT à gauche et APRÈS à droite.  Si `tab-line-mode' est actif
    ;; globalement, il peut afficher des onglets de buffers inutiles
    ;; (*Python*, fichier source, doublons, etc.).  On masque donc la
    ;; tab-line dans les buffers temporaires de révision.
    (setq-local tab-line-format nil)
    (setq-local metal-agent--ediff-temp-buffer-p t)
    buffer))

(defun metal-agent--reviser-via-ediff (original proposed)
  "Lancer Ediff dans un frame séparé pour réviser ORIGINAL vs PROPOSED.
Le code AVANT est affiché à gauche dans un buffer temporaire.
Le code APRÈS proposé est affiché à droite dans un buffer temporaire.
Les boutons de navigation et de validation sont affichés dans la
header-line du buffer APRÈS.

À la fermeture d'Ediff, seul le contenu du buffer AVANT révisé est
réinjecté dans le fichier ou dans la région cible. Ainsi, Ediff ne
travaille jamais directement sur le buffer original, ce qui évite les
conflits avec les fenêtres déjà ouvertes, les buffers REPL, Shackle,
Treemacs et les fenêtres dédiées."
  (metal-agent--ediff-tuer-buffers-temporaires)
  (require 'ediff)
  (metal-agent--ediff-installer-protection-wide)
  (metal-agent--ediff-installer-protection-refresh)
  (setq metal-agent--ediff-saved-setup-fn ediff-window-setup-function
        metal-agent--ediff-saved-split-fn ediff-split-window-function
        metal-agent--ediff-saved-control-frame-parameters ediff-control-frame-parameters
        metal-agent--ediff-saved-use-long-help-message (and (boundp 'ediff-use-long-help-message)
                                                            ediff-use-long-help-message)
        metal-agent--ediff-saved-verbose-help-p (and (boundp 'ediff-verbose-help-p)
                                                     ediff-verbose-help-p)
        metal-agent--ediff-saved-tab-line-mode (and (boundp 'global-tab-line-mode)
                                                    global-tab-line-mode)
        metal-agent--ediff-variables-saved-p t
        ;; Ediff reste dans le frame courant, qui sera notre frame séparé.
        ediff-window-setup-function #'ediff-setup-windows-plain
        ;; A gauche / B droite.
        ediff-split-window-function #'split-window-horizontally
        ;; On évite un frame de contrôle séparé : les commandes utiles sont
        ;; dans la header-line du buffer APRÈS.
        ediff-control-frame-parameters '((visibility . nil))
        ;; Important : empêcher Ediff de reconstruire un panneau de contrôle
        ;; "wide". Dans cette interface intégrée, cette reconstruction peut
        ;; provoquer : ediff-make-wide-control-buffer-id: Format specifier...
        ediff-use-long-help-message nil
        ediff-verbose-help-p nil)
  (let* ((target metal-agent--last-target-buffer)
         (kind   metal-agent--last-target)
         (mode (and (buffer-live-p target)
                    (with-current-buffer target major-mode)))
         (source-frame (selected-frame))
         (source-config (current-window-configuration))
         (avant (generate-new-buffer " *metal-agent-original*"))
         (apres (generate-new-buffer " *metal-agent-corrections*"))
         (frame (metal-agent--ediff-creer-frame)))
    ;; Évite que les onglets de buffers du frame source polluent le frame Ediff.
    ;; On restaure l'état global à la sortie.
    (when (and (boundp 'global-tab-line-mode) global-tab-line-mode)
      (global-tab-line-mode -1))
    (metal-agent--ediff-preparer-buffer avant original mode)
    (metal-agent--ediff-preparer-buffer apres proposed mode)
    (with-current-buffer apres
      (setq-local header-line-format '(:eval (metal-agent--ediff-apres-header-line))))
    (setq metal-agent--ediff-target-buffer target
          metal-agent--ediff-target-kind   kind
          metal-agent--ediff-target-beg    metal-agent--last-target-beg
          metal-agent--ediff-target-end    metal-agent--last-target-end
          metal-agent--ediff-avant-buf     avant
          metal-agent--ediff-apres-buf     apres
          metal-agent--ediff-original-text original
          metal-agent--ediff-source-frame  source-frame
          metal-agent--ediff-frame         frame
          metal-agent--ediff-window-config source-config)
    ;; Important : le frame Ediff ne contient qu'une fenêtre avant l'appel.
    ;; `ediff-setup-windows-plain' crée ensuite lui-même la disposition A/B.
    (switch-to-buffer avant)
    (ediff-buffers avant apres '(metal-agent--ediff-setup-hook))))

(defun metal-agent--ediff-imposer-layout ()
  "Imposer le layout visuel Metal Agent dans le frame Ediff.

Cette fonction ne tue pas la session Ediff.  Elle cache simplement le
panneau de controle et tous les buffers parasites en reconstruisant le
frame de revision avec deux fenetres : AVANT a gauche et APRES a droite."
  (when (and (frame-live-p metal-agent--ediff-frame)
             (buffer-live-p metal-agent--ediff-avant-buf)
             (buffer-live-p metal-agent--ediff-apres-buf))
    (select-frame-set-input-focus metal-agent--ediff-frame)
    (let ((ignore-window-parameters t)
          (window-min-height 1)
          (window-min-width 1))
      ;; Tres important : le *Ediff Control Panel* est souvent affiche dans
      ;; une fenetre dediee.  Il faut enlever la dedication AVANT tout appel a
      ;; `delete-other-windows' ou `set-window-buffer', sinon Emacs signale :
      ;; "Window is dedicated to '*Ediff Control Panel*'".
      (walk-windows
       (lambda (win)
         (set-window-dedicated-p win nil))
       nil metal-agent--ediff-frame)
      ;; Choisir explicitement une fenetre du frame Ediff, puis reconstruire
      ;; le frame a partir de cette fenetre.
      (let ((base (frame-selected-window metal-agent--ediff-frame)))
        (select-window base)
        (delete-other-windows base)
        (set-window-dedicated-p base nil)
        (set-window-buffer base metal-agent--ediff-avant-buf)
        (let ((droite (split-window base nil 'right)))
          (set-window-dedicated-p droite nil)
          (set-window-buffer droite metal-agent--ediff-apres-buf)
          (with-current-buffer metal-agent--ediff-avant-buf
            (setq-local header-line-format '(:eval (concat (metal-agent--ediff-alignement-code) "ORIGINAL")))
            (setq-local tab-line-format nil))
          (with-current-buffer metal-agent--ediff-apres-buf
            (setq-local header-line-format '(:eval (metal-agent--ediff-apres-header-line)))
            (setq-local tab-line-format nil))
          (select-window droite))))))

(defun metal-agent--ediff-setup-hook ()
  "Finaliser l'interface apres la creation officielle des fenetres Ediff.

On laisse d'abord Ediff initialiser completement sa session, puis on impose
le layout visuel souhaite : uniquement AVANT a gauche et APRES a droite dans
le frame separe.  Le buffer de controle Ediff reste vivant, mais il n'est
pas affiche ; les commandes utiles sont dans la header-line du buffer APRES."
  ;; Ce hook est execute depuis le buffer de controle Ediff.  On le garde
  ;; explicitement, car les clics dans la header-line du buffer APRES ne
  ;; voient pas toujours la variable globale `ediff-control-buffer'.
  (setq metal-agent--ediff-control-buffer (current-buffer))
  (message nil)
  (add-hook 'ediff-quit-hook #'metal-agent--ediff-quit-hook nil t)
  ;; Ediff reorganise parfois les fenetres juste apres son hook de setup.
  ;; On applique donc le nettoyage une premiere fois tout de suite, puis une
  ;; deuxieme fois au prochain tour de boucle, ce qui evite les buffers
  ;; parasites (*Python*, *Messages*, fichier source, doublons, Control Panel).
  (ignore-errors (metal-agent--ediff-imposer-layout))
  (run-at-time 0.05 nil #'metal-agent--ediff-imposer-layout))

(defun metal-agent--ediff-restaurer-variables ()
  "Restaurer les variables Ediff modifiées par Metal Agent."
  (metal-agent--ediff-retirer-protection-wide)
  (metal-agent--ediff-retirer-protection-refresh)
  (when metal-agent--ediff-variables-saved-p
    (setq ediff-window-setup-function metal-agent--ediff-saved-setup-fn
          ediff-split-window-function metal-agent--ediff-saved-split-fn
          ediff-control-frame-parameters metal-agent--ediff-saved-control-frame-parameters
          ediff-use-long-help-message metal-agent--ediff-saved-use-long-help-message
          ediff-verbose-help-p metal-agent--ediff-saved-verbose-help-p
          metal-agent--ediff-saved-setup-fn nil
          metal-agent--ediff-saved-split-fn nil
          metal-agent--ediff-saved-control-frame-parameters nil
          metal-agent--ediff-saved-use-long-help-message nil
          metal-agent--ediff-saved-verbose-help-p nil
          metal-agent--ediff-variables-saved-p nil)
    (when (and (boundp 'global-tab-line-mode)
               metal-agent--ediff-saved-tab-line-mode
               (not global-tab-line-mode))
      (global-tab-line-mode 1))
    (setq metal-agent--ediff-saved-tab-line-mode nil)))

(defun metal-agent--ediff-texte-buffer (buffer)
  "Retourner le texte complet de BUFFER, sans propriétés."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun metal-agent--ediff-quit-hook ()
  "Nettoyer après Ediff et appliquer les changements acceptés.
Le buffer AVANT temporaire contient le résultat final de la révision.
Ce résultat est appliqué au buffer cible complet ou à la région cible."
  ;; Ce hook peut être appelé soit par Ediff, soit par le bouton ✔.  Toute
  ;; erreur de nettoyage doit être silencieuse pour ne pas laisser Emacs dans
  ;; un frame Ediff à moitié fermé.
  (let* ((avant   metal-agent--ediff-avant-buf)
         (target  metal-agent--ediff-target-buffer)
         (kind    metal-agent--ediff-target-kind)
         (beg     metal-agent--ediff-target-beg)
         (end     metal-agent--ediff-target-end)
         (orig    metal-agent--ediff-original-text)
         (config  metal-agent--ediff-window-config)
         (source-frame metal-agent--ediff-source-frame)
         (ediff-frame  metal-agent--ediff-frame)
         (nouveau (metal-agent--ediff-texte-buffer avant)))
    (pcase kind
      ('buffer
       (cond
        ((not (buffer-live-p target))
         (message "Révision annulée — buffer cible disparu."))
        ((or (null nouveau) (string= nouveau orig))
         (message "Aucun hunk accepté — buffer inchangé."))
        (t
         (with-current-buffer target
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert nouveau))
           (set-buffer-modified-p t))
         (message "Modifications appliquées dans le buffer cible."))))
      ('region
       (cond
        ((or (null nouveau) (not (buffer-live-p target)))
         (message "Révision annulée."))
        ((string= nouveau orig)
         (message "Aucun hunk accepté — région inchangée."))
        (t
         (with-current-buffer target
           (save-excursion
             (when (and beg end)
               (let ((inhibit-read-only t))
                 (delete-region beg end)
                 (goto-char beg)
                 (insert nouveau))))
           (set-buffer-modified-p t))
         (message "Modifications appliquées dans la région cible."))))
      (_
       (message "Révision terminée, mais la cible est inconnue.")))
    ;; Ne pas tuer ici les buffers ORIGINAL/CORRECTION(S) : Ediff peut encore
    ;; tenter de rafraîchir leurs mode-lines au prochain tour de boucle.
    ;; On les enterre simplement ; ils seront réutilisés ou nettoyés au
    ;; lancement suivant sans déclencher l'erreur de buffer vital tué.
    (dolist (buf (list avant metal-agent--ediff-apres-buf))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq-local header-line-format nil)
          (bury-buffer))))
    (metal-agent--ediff-restaurer-variables)
    (when (and (frame-live-p source-frame) config)
      (select-frame-set-input-focus source-frame)
      (ignore-errors (set-window-configuration config)))
    (when (and (frame-live-p ediff-frame)
               (not (eq ediff-frame source-frame)))
      (ignore-errors (delete-frame ediff-frame t)))
    (metal-agent--close-ui-buffers)
    (setq metal-agent--ediff-target-buffer nil
          metal-agent--ediff-target-kind nil
          metal-agent--ediff-target-beg nil
          metal-agent--ediff-target-end nil
          metal-agent--ediff-avant-buf nil
          metal-agent--ediff-apres-buf nil
          metal-agent--ediff-original-text nil
          metal-agent--ediff-window-config nil
          metal-agent--ediff-source-frame nil
          metal-agent--ediff-frame nil
          metal-agent--ediff-control-buffer nil
          metal-agent--ediff-cleanup-en-cours nil)))

(defun metal-agent--context-header ()
  "Contexte commun envoyé au provider courant (Codex ou Claude).
Inclut le préambule système du profil actif s'il existe."
  (let ((systeme (metal-agent--profil-systeme))
        (profil-nom (metal-agent--profil-prop :nom))
        (base (format
"Contexte MetalEmacs:
- Fichier: %s
- Langage: %s
- Tu dois retourner un CODE FINAL complet, pas un diff.
"
               (metal-agent--source-file)
               (metal-agent--source-language))))
    (if systeme
        (format "[Profil : %s]\n%s\n\n%s" profil-nom systeme base)
      base)))

(defun metal-agent--prompt-final-code (instruction code &optional target-label)
  "Construire un prompt demandant un code final.
Injecte les fragments des options actives et les instructions libres
saisies via le panneau transient."
  (let ((fragments (metal-agent--fragments-actifs))
        (libre (and (stringp metal-agent--instructions-libres)
                    (not (string-empty-p
                          (string-trim metal-agent--instructions-libres)))
                    metal-agent--instructions-libres)))
    (format
"%s
Tâche :
%s

Contraintes obligatoires :
- Retourne uniquement le code final.
- Ne retourne pas de diff.
- Ne donne pas d'explication.
- Encadre le code final dans un seul bloc Markdown ```%s.
- Le bloc doit contenir %s.
%s%s
Règle de modification minimale (TRÈS IMPORTANT) :
- Si le code est déjà correct et fonctionnel, retourne-le EXACTEMENT tel quel,
  caractère par caractère, sans aucune modification.
- Ne change RIEN qui ne soit pas strictement nécessaire pour accomplir la tâche :
  ne modifie pas la casse, l'indentation, les guillemets (simples vs doubles),
  les noms de variables, l'ordre des lignes, ni la mise en forme.
- N'uniformise pas le style, n'ajoute pas de commentaires, ne reformate pas.
- Préfère TOUJOURS la version la plus proche du code original.

Code actuel :
```%s
%s
```"
            (metal-agent--context-header)
            instruction
            (metal-agent--code-block-language)
            (or target-label "le code corrigé")
            (if fragments
                (concat "\nContraintes du profil :\n"
                        (mapconcat (lambda (f) (concat "- " f)) fragments "\n")
                        "\n")
              "")
            (if libre
                (format "\nInstructions supplémentaires :\n%s\n" libre)
              "")
            (metal-agent--code-block-language)
            code)))

(defun metal-agent-corriger-selection ()
  "Corriger la sélection avec Codex, puis appliquer dans le buffer après confirmation."
  (interactive)
  (let* ((code (metal-agent--selection-text))
         (beg metal-agent--saved-region-beg)
         (end metal-agent--saved-region-end))
    (metal-agent--store-target 'region code beg end)
    (metal-agent--run-codex
     (metal-agent--prompt-final-code
      "Corrige uniquement cette sélection."
      code
      "uniquement la sélection corrigée")
     "correction de la sélection"
     #'metal-agent--handle-codex-code-response)))

(defun metal-agent-corriger-fichier ()
  "Corriger tout le fichier avec Codex, puis appliquer dans le buffer après confirmation."
  (interactive)
  (let ((code (metal-agent--file-text)))
    (metal-agent--store-target 'buffer code)
    (metal-agent--run-codex
     (metal-agent--prompt-final-code
      "Corrige uniquement ce fichier. Ne regarde pas les autres fichiers du dossier."
      code
      "le fichier complet corrigé")
     "correction du fichier"
     #'metal-agent--handle-codex-code-response)))

(defun metal-agent-expliquer-selection ()
  "Demander à Codex d'expliquer la sélection."
  (interactive)
  (let ((code (metal-agent--selection-text)))
    (metal-agent--run-codex
     (format
"%s
Explique cette sélection en français, clairement.

```%s
%s
```"
      (metal-agent--context-header)
      (metal-agent--code-block-language)
      code)
     "explication"
     (lambda (exit-code _raw)
       (let ((buf-name (metal-agent--current-buffer-name))
             (label (or (metal-agent--current-label) "Agent")))
         (if (= exit-code 0)
             (progn
               ;; Ouvrir automatiquement le buffer de sortie pour que
               ;; l'utilisateur n'ait pas à le chercher.
               (when-let ((buf (get-buffer buf-name)))
                 (display-buffer buf))
               (message "Explication %s terminée — voir %s." label buf-name))
           (when-let ((buf (get-buffer buf-name)))
             (display-buffer buf))
           (message "Erreur %s — voir %s." label buf-name)))))))

(defun metal-agent-ajouter-fonction ()
  "Ajouter une fonction/prédicat dans le fichier via code final complet."
  (interactive)
  (setq metal-agent--source-buffer (current-buffer))
  (let* ((label (if (metal-agent--prolog-p) "prédicat" "fonction"))
         (demande (read-string (format "Ajouter quel %s ? " label)))
         (code (metal-agent--file-text)))
    (metal-agent--store-target 'buffer code)
    (metal-agent--run-codex
     (metal-agent--prompt-final-code
      (format "Ajoute un %s qui fait ceci : %s" label demande)
      code
      "le fichier complet modifié")
     (format "ajout de %s" label)
     #'metal-agent--handle-codex-code-response)))

(defun metal-agent-demande-libre ()
  "Demande libre à l'agent IA.
Si une région est active dans le buffer source, on envoie UNIQUEMENT
la sélection à l'agent et la modification s'applique à la sélection
seule.  Sinon, on envoie le fichier entier et la modification
remplace tout le buffer."
  (interactive)
  ;; Capturer la sélection AVANT toute interaction (qui changerait
  ;; éventuellement le buffer ou la marque).
  (metal-agent--save-current-buffer-and-selection)
  (let* ((sur-selection (and metal-agent--saved-region-beg
                             metal-agent--saved-region-end))
         (demande (read-string
                   (if sur-selection
                       "Demande libre (sur la sélection) : "
                     "Demande libre (sur le fichier) : ")))
         (code (if sur-selection
                   (metal-agent--selection-text)
                 (metal-agent--file-text)))
         (target-label (if sur-selection
                           "uniquement la sélection modifiée"
                         "le fichier complet modifié")))
    (if sur-selection
        (metal-agent--store-target 'region
                                   code
                                   metal-agent--saved-region-beg
                                   metal-agent--saved-region-end)
      (metal-agent--store-target 'buffer code))
    (metal-agent--run-codex
     (metal-agent--prompt-final-code demande code target-label)
     (if sur-selection "demande libre (sélection)" "demande libre")
     #'metal-agent--handle-codex-code-response)))

(defun metal-agent-afficher-codex ()
  "Afficher le buffer du provider courant.
Le nom historique est conservé pour la rétrocompatibilité."
  (interactive)
  (display-buffer (metal-agent--codex-buffer)))

(defun metal-agent-masquer-codex ()
  "Masquer le buffer du provider courant s'il est affiché."
  (interactive)
  (let ((buf (get-buffer (metal-agent--current-buffer-name))))
    (when buf
      (dolist (win (get-buffer-window-list buf nil t))
        (when (window-live-p win)
          (delete-window win))))))

(defun metal-agent-toggle-codex-window ()
  "Afficher ou masquer le buffer du provider courant."
  (interactive)
  (if (get-buffer-window (metal-agent--current-buffer-name) nil)
      (metal-agent-masquer-codex)
    (metal-agent-afficher-codex)))

(defun metal-agent-toggle-active ()
  "Basculer entre le bouton Agent compact et la toolbar Codex complète."
  (interactive)
  (setq metal-agent-active (not metal-agent-active))
  (when metal-agent-active
    (setq metal-agent--source-buffer (current-buffer)))
  (force-mode-line-update t)
  (redraw-display))

(defun metal-agent-choisir-provider ()
  "Choisir l'agent IA actif pour la session courante.
La sélection n'est PAS persistée — au redémarrage d'Emacs, l'agent par
défaut configuré dans l'Assistant MetalEmacs sera restauré.

Pour modifier l'agent par défaut (persistant), utiliser l'Assistant :
M-x metal-deps-afficher-etat → section Agents IA → bouton « ◉ Définir
par défaut » à côté de l'agent désiré.

Si aucun agent n'est configuré, redirige vers l'Assistant."
  (interactive)
  (let ((dispo (cl-remove-if-not
                (lambda (p)
                  (executable-find (plist-get (cdr p) :command)))
                metal-agent--providers)))
    (cond
     ((null dispo)
      (when (yes-or-no-p
             "Aucun agent IA installé.  Ouvrir l'Assistant MetalEmacs pour en installer un ? ")
        (when (fboundp 'metal-deps-afficher-etat)
          (metal-deps-afficher-etat))))
     (t
      (let* ((choices (mapcar (lambda (p)
                                (cons (plist-get (cdr p) :label) (car p)))
                              dispo))
             (label (completing-read
                     (format "Agent IA pour cette session (actuel : %s) : "
                             (or (metal-agent--current-label) "aucun"))
                     (mapcar #'car choices)
                     nil t))
             (sym (cdr (assoc label choices))))
        (when sym
          ;; setq seulement : changement de session, non persisté.
          ;; Le défaut persistant est géré par l'Assistant MetalEmacs.
          (setq metal-agent-provider sym)
          (force-mode-line-update t)
          (redraw-display)
          (message "Agent actif pour cette session : %s  (défaut persistant inchangé)"
                   (metal-agent--current-label))))))))


;;; --- Assistant d'authentification de CLI ---------------------------

(defcustom metal-agent-erreur-auth-regexp
  (concat "\\b\\("
          "API[ _]?key"
          "\\|Auth\\(?: method\\| token\\| required\\)?"
          "\\|authenticate"
          "\\|Please \\(log\\|sign\\) in"
          "\\|unauthori[sz]ed"
          "\\|HTTP 40[13]"
          "\\|GEMINI_API_KEY\\|ANTHROPIC_API_KEY\\|OPENAI_API_KEY"
          "\\|GOOGLE_GENAI_USE_VERTEXAI\\|GOOGLE_GENAI_USE_GCA"
          "\\|Set an Auth"
          "\\|credentials \\(missing\\|required\\|not found\\|expired\\)"
          "\\|not authenticated"
          "\\|run.*\\b\\(login\\|auth\\)\\b"
          "\\)\\b")
  "Expression régulière détectant les erreurs d'authentification dans
la sortie d'une CLI.  Quand `metal-agent--handle-codex-code-response'
voit un code de retour ≠ 0 et que cette regex matche, il propose
`metal-agent-authentifier-cli'."
  :type 'regexp
  :group 'metal-agent)

(defun metal-agent--erreur-auth-p (raw)
  "Retourne t si RAW contient un indice d'erreur d'authentification."
  (and (stringp raw)
       (string-match-p metal-agent-erreur-auth-regexp raw)))

(declare-function vterm "vterm")
(declare-function ansi-term "term")
(declare-function eat "eat")
(declare-function metal-deps-afficher-etat "metal-deps")
;; Le catalogue d'agents vit dans metal-deps.el ; on le déclare pour le
;; byte-compiler (référencé dans `metal-agent--auth-info-pour').
(defvar metal-deps-agents-catalogue)
;; Déclarations spéciales pour permettre le binding dynamique sous
;; `lexical-binding: t' (sinon ces `let' sont lexicaux et les paquets
;; terminal ne voient pas nos surcharges).
(defvar vterm-buffer-name)
(defvar vterm-shell)
(defvar eat-buffer-name)

(defcustom metal-agent-terminal-externe
  (cond
   ((eq system-type 'darwin) 'macos-terminal)
   ((and (memq system-type '(gnu/linux gnu))
         (executable-find "x-terminal-emulator"))
    'x-terminal-emulator)
   ((eq system-type 'windows-nt)
    ;; Préférer Windows Terminal s'il est installé (rendu TUI bien meilleur),
    ;; sinon PowerShell, sinon cmd en dernier recours.
    (cond ((executable-find "wt")         'windows-terminal)
          ((executable-find "powershell") 'powershell)
          (t                              'cmd)))
   (t nil))
  "Méthode pour ouvrir un terminal externe (assistant d'authentification).
Utilisé par `metal-agent-authentifier-cli' quand ni EAT ni vterm ne
sont disponibles — ansi-term rend mal les TUI Ink/React modernes
(Gemini CLI, Codex, Claude Code)."
  :type '(choice
          (const :tag "macOS Terminal.app (via osascript)" macos-terminal)
          (const :tag "macOS iTerm2 (via osascript)"       iterm2)
          (const :tag "Linux x-terminal-emulator"          x-terminal-emulator)
          (const :tag "Windows Terminal (wt.exe)"          windows-terminal)
          (const :tag "Windows PowerShell"                 powershell)
          (const :tag "Windows cmd.exe"                    cmd)
          (const :tag "Aucun (fallback ansi-term)"         nil))
  :group 'metal-agent)

(declare-function w32-shell-execute "w32fns.c")

(defun metal-agent--lancer-terminal-externe (command)
  "Lancer COMMAND dans un terminal externe selon `metal-agent-terminal-externe'."
  (pcase metal-agent-terminal-externe
    ('macos-terminal
     (call-process
      "osascript" nil 0 nil
      "-e" (format "tell application \"Terminal\" to do script \"%s\""
                   (replace-regexp-in-string "\"" "\\\\\"" command))
      "-e" "tell application \"Terminal\" to activate"))
    ('iterm2
     (call-process
      "osascript" nil 0 nil
      "-e" (format "tell application \"iTerm\" to create window with default profile command \"%s\""
                   (replace-regexp-in-string "\"" "\\\\\"" command))))
    ('x-terminal-emulator
     (call-process "x-terminal-emulator" nil 0 nil "-e" command))
    ('windows-terminal
     ;; wt new-tab cmd /K command — la commande reste affichée après exit.
     (call-process "wt.exe" nil 0 nil "new-tab" "cmd" "/K" command))
    ('powershell
     ;; -NoExit garde la fenêtre ouverte après la fin de la commande.
     (if (fboundp 'w32-shell-execute)
         (w32-shell-execute "open" "powershell.exe"
                            (format "-NoExit -Command \"%s\"" command))
       (call-process "powershell.exe" nil 0 nil
                     "-NoExit" "-Command" command)))
    ('cmd
     (if (fboundp 'w32-shell-execute)
         (w32-shell-execute "open" "cmd.exe" (format "/K %s" command))
       (call-process "cmd.exe" nil 0 nil "/C" "start" "cmd" "/K" command)))
    (_
     (user-error "Aucun terminal externe configuré (voir `metal-agent-terminal-externe')"))))

(defun metal-agent--auth-info-pour (id key)
  "Retourne la valeur de KEY (`:auth-args' ou `:auth-aide') pour l'agent ID.

Lit en priorité dans `metal-deps-agents-catalogue' (la source vivante :
toute mise à jour du catalogue est visible immédiatement, sans avoir
à réinstaller l'agent).  Fallback sur le provider enregistré (pour
les agents hors catalogue)."
  (or (and (boundp 'metal-deps-agents-catalogue)
           (plist-get (cdr (assq id metal-deps-agents-catalogue)) key))
      (metal-agent--provider-prop key id)))

(defun metal-agent--installer-aide-auth (buf aide)
  "Installer une header-line d'aide dans le buffer terminal BUF.
AIDE est le texte d'instruction.  La header-line reste visible pendant
toute la session terminal, sans gêner la CLI."
  (when (and (buffer-live-p buf) aide)
    (with-current-buffer buf
      (setq-local header-line-format
                  (propertize (concat " 📋 " aide)
                              'face '(:weight bold))))))

(defun metal-agent-authentifier-cli (&optional provider-id forcer-ansi-term)
  "Lancer la CLI de PROVIDER-ID en mode interactif pour s'authentifier.

La commande lancée est `command + :auth-args' (ex: `codex login',
`claude auth login') si :auth-args est défini, sinon la commande nue
(ex: `gemini' qui ouvre son menu interactif).  Ces métadonnées sont
lues prioritairement dans `metal-deps-agents-catalogue' (vivant),
fallback sur le provider enregistré.

Le texte d'aide :auth-aide est affiché en header-line du buffer terminal
pour guider l'utilisateur (que choisir dans le menu, où aller, etc.).

Ordre de préférence du terminal :
  1. EAT (si installé) — excellent rendu des TUI Ink/React.
  2. vterm (si installé) — intégré, très bon rendu.
  3. Terminal externe (cf. `metal-agent-terminal-externe').
  4. ansi-term — fallback ; rend mal les TUI modernes.

Avec un préfixe (`C-u', FORCER-ANSI-TERM non nil), force ansi-term."
  (interactive "i\nP")
  (let* ((id        (or provider-id metal-agent-provider))
         (label     (metal-agent--provider-prop :label id))
         (command   (let ((metal-agent-provider id))
                      (metal-agent--current-command)))
         (auth-args (metal-agent--auth-info-pour id :auth-args))
         (auth-aide (metal-agent--auth-info-pour id :auth-aide))
         ;; Liste complète d'arguments pour l'auth (vide si pas d'auth-args).
         (cmd-line  (if auth-args
                        (mapconcat #'identity (cons command auth-args) " ")
                      command)))
    (unless (executable-find command)
      (user-error
       "CLI « %s » introuvable.  Installer d'abord via l'Assistant (M-x metal-deps-afficher-etat)"
       command))
    (when auth-aide
      ;; Affichage initial dans l'écho area (sera dupliqué en header-line).
      (message "🔐 %s : %s" label auth-aide))
    (let ((buffer-name (format "*Metal Agent — Auth %s*" label)))
      ;; Si un ancien buffer d'auth existe (avec l'ancienne commande), le
      ;; tuer pour repartir propre avec la nouvelle commande.
      (when-let ((old-buf (get-buffer buffer-name)))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer old-buf)))
      (cond
       (forcer-ansi-term
        (ansi-term cmd-line (format "Metal Agent — Auth %s" label))
        (metal-agent--installer-aide-auth
         (get-buffer (format "*Metal Agent — Auth %s*" label)) auth-aide))
       ((and (require 'eat nil t) (fboundp 'eat))
        (let ((eat-buffer-name buffer-name))
          (eat cmd-line))
        (metal-agent--installer-aide-auth (get-buffer buffer-name) auth-aide))
       ((and (require 'vterm nil t) (fboundp 'vterm))
        (let ((vterm-buffer-name buffer-name)
              (vterm-shell cmd-line))
          (vterm buffer-name))
        (metal-agent--installer-aide-auth (get-buffer buffer-name) auth-aide))
       (metal-agent-terminal-externe
        (metal-agent--lancer-terminal-externe cmd-line)
        (when auth-aide
          (display-message-or-buffer
           (format "Authentification %s\n\n%s\n\nUne fois terminé, fermez la fenêtre du terminal et relancez la commande dans Emacs."
                   label auth-aide)
           "*Metal Agent — Aide auth*")))
       (t
        (ansi-term cmd-line (format "Metal Agent — Auth %s" label))
        (metal-agent--installer-aide-auth
         (get-buffer (format "*Metal Agent — Auth %s*" label)) auth-aide)
        (message
         "ansi-term peut mal rendre l'UI de %s.  Installer `eat' ou `vterm' pour un meilleur rendu."
         label))))))

;;; --- Panneau de configuration (buffer dédié) -----------------------

(defun metal-agent-choisir-profil (&optional tous)
  "Choisir un profil de travail parmi `metal-agent-profils'.
Par défaut, ne propose que les profils pertinents pour le major-mode
courant (plus le profil « Tronc commun » et « Correction de travaux »
qui sont toujours utiles).
Avec un préfixe (`C-u'), propose TOUS les profils."
  (interactive "P")
  (unless metal-agent-profils
    (user-error "Aucun profil chargé.  Vérifiez metal-agent-profils.el"))
  (let* ((profils-filtres
          (if tous
              metal-agent-profils
            (let ((pertinents (metal-agent--profils-pour-mode major-mode)))
              ;; Toujours ajouter Tronc commun s'il n'y est pas déjà
              (let ((tronc (seq-find (lambda (p) (eq (plist-get p :id) 'tronc-commun))
                                     metal-agent-profils)))
                (when (and tronc (not (memq tronc pertinents)))
                  (setq pertinents (append pertinents (list tronc)))))
              ;; Toujours ajouter Correction de travaux (transversal)
              (let ((correction (seq-find (lambda (p) (eq (plist-get p :id) 'correction-travaux))
                                          metal-agent-profils)))
                (when (and correction (not (memq correction pertinents)))
                  (setq pertinents (append pertinents (list correction)))))
              pertinents)))
         (choices (mapcar (lambda (p)
                            (cons (plist-get p :nom) (plist-get p :id)))
                          profils-filtres))
         (current (metal-agent--profil-prop :nom))
         (label (completing-read
                 (format "Profil %s(actuel : %s) : "
                         (if tous "[TOUS] " "")
                         (or current "?"))
                 (mapcar #'car choices)
                 nil t))
         (sym (cdr (assoc label choices))))
    (when sym
      (setq metal-agent-profil-actif sym)
      (metal-agent--reinitialiser-options)
      (force-mode-line-update t)
      (message "Profil actif : %s" label))))

(defun metal-agent-editer-instructions-libres ()
  "Éditer les instructions libres dans un buffer dédié.
Le contenu est sauvegardé dans `metal-agent--instructions-libres'."
  (interactive)
  (let ((buf (get-buffer-create "*Metal Agent — Instructions libres*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert metal-agent--instructions-libres)
      (text-mode)
      (use-local-map (copy-keymap text-mode-map))
      (local-set-key (kbd "C-c C-c")
                     (lambda ()
                       (interactive)
                       (setq metal-agent--instructions-libres
                             (buffer-substring-no-properties (point-min) (point-max)))
                       (message "Instructions libres enregistrées (%d caractères)"
                                (length metal-agent--instructions-libres))
                       (kill-buffer-and-window)))
      (local-set-key (kbd "C-c C-k")
                     (lambda () (interactive) (kill-buffer-and-window)))
      (setq header-line-format
            "  C-c C-c : enregistrer    C-c C-k : annuler"))
    (pop-to-buffer buf)))

(defun metal-agent--effacer-instructions-libres ()
  "Vider les instructions libres."
  (interactive)
  (setq metal-agent--instructions-libres "")
  (message "Instructions libres effacées."))

(defvar metal-agent-apercu-buffer-name "*Aperçu de la consigne*"
  "Nom du buffer d'aperçu de la consigne envoyée à l'agent.")

(defvar metal-agent-apercu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'metal-agent-apercu-fermer)
    (define-key map (kbd "g") #'metal-agent-apercu-prompt)
    map)
  "Keymap du buffer d'aperçu de la consigne.")

(define-derived-mode metal-agent-apercu-mode special-mode "MetalAgent-Apercu"
  "Mode majeur pour le buffer d'aperçu de la consigne envoyée à l'agent.
\\{metal-agent-apercu-mode-map}"
  (setq buffer-read-only t)
  (setq header-line-format
        (propertize " Aperçu de la consigne — Appuyer sur q pour fermer, g pour rafraîchir "
                    'face '(:weight bold))))

(defun metal-agent-apercu-fermer ()
  "Fermer le buffer d'aperçu de la consigne."
  (interactive)
  (let ((buffer (get-buffer metal-agent-apercu-buffer-name)))
    (when buffer
      (kill-buffer buffer))))

(defun metal-agent-apercu-prompt ()
  "Afficher dans un onglet la consigne qui serait envoyée à l'agent.
La consigne est construite à partir du profil actif, des options
activées, des instructions libres et de la sélection courante.  Utile
pour vérifier le contenu de la requête avant l'envoi."
  (interactive)
  (let* ((buffer-source (current-buffer))
         (code (or (and (use-region-p)
                        (buffer-substring-no-properties
                         (region-beginning) (region-end)))
                   "<sélection ou buffer ici>"))
         (prompt (metal-agent--prompt-final-code
                  "Corrige uniquement cette sélection."
                  code))
         (nom-profil (or (metal-agent--profil-prop :nom) "?"))
         (nom-agent (metal-agent--current-label))
         (buf (get-buffer-create metal-agent-apercu-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'metal-agent-apercu-mode)
        (metal-agent-apercu-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (format "Aperçu de la consigne\n\n")
                 'face '(:weight bold :height 1.1)))
        (insert (format "  Profil : %s\n" nom-profil))
        (insert (format "  Agent  : %s\n" nom-agent))
        (insert (format "  Source : %s\n\n"
                        (or (buffer-name buffer-source) "?")))
        (insert (propertize
                 "Contenu de la consigne envoyée :\n\n"
                 'face '(:weight bold)))
        (insert prompt))
      (goto-char (point-min)))
    (switch-to-buffer buf)))

(defun metal-agent--description-options ()
  "Retourne une chaîne décrivant l'état des options du profil actif."
  (let ((options (metal-agent--profil-options metal-agent-profil-actif)))
    (if (null options)
        "(aucune option pour ce profil)"
      (mapconcat
       (lambda (opt)
         (format "  %s %s"
                 (if (metal-agent--option-active-p (plist-get opt :id))
                     "[✓]" "[ ]")
                 (plist-get opt :nom)))
       options
       "\n"))))

(defun metal-agent-basculer-options-interactif ()
  "Bascule les options du profil actif via completing-read.
Boucle jusqu'à ce que l'utilisateur sélectionne « — Terminer — » ou
appuie sur C-g.  À la fin, réaffiche le panneau pour que l'utilisateur
voie l'état mis à jour des options."
  (interactive)
  (let* ((options (metal-agent--profil-options metal-agent-profil-actif))
         (terminer-label "  ✓ Terminer (retour au panneau)"))
    (unless options (user-error "Aucune option pour ce profil"))
    (let (continuer)
      (setq continuer t)
      (while continuer
        (let* ((options-choices
                (mapcar
                 (lambda (opt)
                   (cons (format "%s %s"
                                 (if (metal-agent--option-active-p (plist-get opt :id))
                                     "[✓]" "[ ]")
                                 (plist-get opt :nom))
                         (plist-get opt :id)))
                 options))
               ;; On met l'entrée « Terminer » en tête de liste
               (choices (cons (cons terminer-label nil) options-choices))
               (labels (mapcar #'car choices))
               ;; Préserver l'ordre original (désactiver le tri côté
               ;; vertico/ivy/etc.).
               (collection
                (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action labels string pred))))
               (label (condition-case nil
                          (completing-read
                           "Option à basculer (« Terminer » pour fermer) : "
                           collection nil t)
                        (quit nil)))
               (id (and label (cdr (assoc label choices)))))
          (cond
           ;; C-g (label=nil) ou sélection de « Terminer » (id=nil)
           ((or (null label) (string= label terminer-label))
            (setq continuer nil))
           ;; Bascule normale d'une option
           (id
            (metal-agent--basculer-option id)
            (let ((opt (seq-find (lambda (o) (eq (plist-get o :id) id)) options)))
              (message "Option « %s » : %s"
                       (plist-get opt :nom)
                       (if (metal-agent--option-active-p id) "activée" "désactivée"))))
           ;; Cas inattendu (ne devrait pas arriver avec require-match)
           (t (setq continuer nil))))))
    ;; Réafficher le panneau avec l'état mis à jour.
    (metal-agent-panneau-rafraichir)))

;; ─────────────────────────────────────────────────────────────────
;; Panneau de configuration : buffer dédié avec mode majeur
;; ─────────────────────────────────────────────────────────────────

(defvar metal-agent-panneau-buffer-name "*Configuration agent*"
  "Nom du buffer du panneau de configuration de l'agent.")

(defface metal-agent-bouton-face
  '((t :inherit default :underline nil))
  "Face des boutons du panneau de configuration de l'agent.
Hérite de la face par défaut sans soulignement.  Le pointeur souris
indique déjà le caractère cliquable des éléments."
  :group 'metal-agent)

(defvar metal-agent-config-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Actions principales (reprises du transient)
    (define-key map (kbd "a") #'metal-agent-choisir-provider)
    (define-key map (kbd "L") #'metal-agent-authentifier-cli)
    (define-key map (kbd "p") #'metal-agent-choisir-profil)
    (define-key map (kbd "o") #'metal-agent-basculer-options-interactif)
    (define-key map (kbd "r") #'metal-agent--reinitialiser-options)
    (define-key map (kbd "s") #'metal-agent-sauvegarder-etat)
    (define-key map (kbd "M") #'metal-deps-afficher-etat)
    (define-key map (kbd "e") #'metal-agent-editer-instructions-libres)
    (define-key map (kbd "E") #'metal-agent--effacer-instructions-libres)
    (define-key map (kbd "?") #'metal-agent-apercu-prompt)
    ;; Navigation
    (define-key map (kbd "g") #'metal-agent-panneau-rafraichir)
    (define-key map (kbd "q") #'metal-agent-panneau-fermer)
    ;; Interactions souris et clavier sur les boutons
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "RET") #'push-button)
    (define-key map [mouse-1] #'push-button)
    map)
  "Keymap du buffer de configuration de l'agent.")

(define-derived-mode metal-agent-config-mode special-mode "MetalAgent-Config"
  "Mode majeur pour le panneau de configuration de l'agent.
\\{metal-agent-config-mode-map}"
  (setq buffer-read-only t)
  (setq cursor-type nil)
  ;; Header-line pour l'apparence d'onglet
  (setq header-line-format
        (propertize " Configuration de l'agent — Appuyer sur q pour fermer "
                    'face '(:weight bold))))

(defun metal-agent-panneau--toggle-option (option-id)
  "Action de bouton : basculer l'option OPTION-ID puis rafraîchir."
  (metal-agent--basculer-option option-id)
  (metal-agent-panneau-rafraichir))

(defun metal-agent-panneau--inserer-options ()
  "Insérer la liste des options du profil actif avec des boutons cliquables."
  (let ((options (metal-agent--profil-options metal-agent-profil-actif)))
    (if (null options)
        (insert "  (aucune option pour ce profil)\n")
      (dolist (opt options)
        (let* ((id (plist-get opt :id))
               (nom (plist-get opt :nom))
               (active (metal-agent--option-active-p id))
               (case-label (if active "[✓]" "[ ]"))
               (option-id id))  ; capturer pour la closure
          (insert "  ")
          (insert-button case-label
                         'action (lambda (_b)
                                   (metal-agent-panneau--toggle-option option-id))
                         'follow-link t
                         'face 'metal-agent-bouton-face
                         'help-echo (format "Basculer : %s" nom))
          (insert " ")
          (insert-button nom
                         'action (lambda (_b)
                                   (metal-agent-panneau--toggle-option option-id))
                         'follow-link t
                         'face 'metal-agent-bouton-face
                         'help-echo (format "Basculer : %s" nom))
          (insert "\n"))))))

(defun metal-agent-panneau--inserer-bouton (raccourci label action)
  "Insérer un bouton ligne : « raccourci  label »."
  (insert (propertize (format "  %s  " raccourci)
                      'face '(:weight bold)))
  (insert-button label
                 'action (lambda (_b)
                           (call-interactively action))
                 'follow-link t
                 'face 'metal-agent-bouton-face
                 'help-echo (format "Exécuter : %s" label))
  (insert "\n"))

(defun metal-agent-panneau--render ()
  "Régénérer entièrement le contenu du panneau de configuration.
Doit être appelé dans le buffer du panneau, en mode lecture-écriture."
  (let ((inhibit-read-only t))
    (erase-buffer)

    ;; ÉTAT ACTUEL
    (insert (propertize "État actuel\n\n" 'face '(:weight bold :height 1.1)))
    (insert (format "  Agent IA  : %s   (%s)\n"
                    (metal-agent--current-label)
                    (if (metal-agent-disponible-p)
                        "CLI disponible"
                      "CLI introuvable")))
    (insert (format "  Profil    : %s\n"
                    (or (metal-agent--profil-prop :nom) "?")))
    (insert "  Options   :\n")
    (metal-agent-panneau--inserer-options)
    (insert (format "\n  Instructions libres : %s\n"
                    (if (string-empty-p (string-trim metal-agent--instructions-libres))
                        "(aucune)"
                      (format "%d caractères"
                              (length metal-agent--instructions-libres)))))
    (insert "\n\n")

    ;; CONFIGURATION
    (insert (propertize "Configuration\n" 'face '(:weight bold :height 1.1)))
    (metal-agent-panneau--inserer-bouton
     "a" "Choisir l'agent IA actif" #'metal-agent-choisir-provider)
    (metal-agent-panneau--inserer-bouton
     "L" "Authentifier la CLI (login)…" #'metal-agent-authentifier-cli)
    (metal-agent-panneau--inserer-bouton
     "p" "Choisir le profil de travail" #'metal-agent-choisir-profil)
    (metal-agent-panneau--inserer-bouton
     "o" "Basculer une option du profil" #'metal-agent-basculer-options-interactif)
    (metal-agent-panneau--inserer-bouton
     "r" "Réinitialiser les options du profil" #'metal-agent--reinitialiser-options)
    (metal-agent-panneau--inserer-bouton
     "s" "Sauvegarder l'état des options" #'metal-agent-sauvegarder-etat)
    (insert "\n")

    ;; ASSISTANT METALEMACS
    (insert (propertize "Assistant MetalEmacs\n" 'face '(:weight bold :height 1.1)))
    (metal-agent-panneau--inserer-bouton
     "M" "Installer / désinstaller des agents…" #'metal-deps-afficher-etat)
    (insert "\n")

    ;; INSTRUCTIONS LIBRES
    (insert (propertize "Instructions libres\n" 'face '(:weight bold :height 1.1)))
    (metal-agent-panneau--inserer-bouton
     "e" "Éditer les instructions libres" #'metal-agent-editer-instructions-libres)
    (metal-agent-panneau--inserer-bouton
     "E" "Effacer les instructions libres" #'metal-agent--effacer-instructions-libres)
    (insert "\n")

    ;; VÉRIFICATION
    (insert (propertize "Vérification\n" 'face '(:weight bold :height 1.1)))
    (metal-agent-panneau--inserer-bouton
     "?" "Aperçu de la consigne à envoyer" #'metal-agent-apercu-prompt)
    (insert "\n")

    ;; QUITTER
    (insert (propertize "Quitter\n" 'face '(:weight bold :height 1.1)))
    (metal-agent-panneau--inserer-bouton
     "q" "Fermer ce panneau" #'metal-agent-panneau-fermer)

    (goto-char (point-min))))

(defun metal-agent-panneau-rafraichir ()
  "Rafraîchir le contenu du panneau de configuration s'il est ouvert."
  (interactive)
  (let ((buffer (get-buffer metal-agent-panneau-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (metal-agent-panneau--render)))))

(defun metal-agent-panneau-fermer ()
  "Fermer le panneau de configuration de l'agent.
Tue le buffer pour libérer l'onglet et revient au buffer précédent."
  (interactive)
  (let ((buffer (get-buffer metal-agent-panneau-buffer-name)))
    (when buffer
      (kill-buffer buffer))))

(defun metal-agent-panneau ()
  "Afficher le panneau de configuration de l'agent dans un buffer dédié.
Le buffer apparaît comme un onglet à côté du fichier en cours via le
header-line. Si le panneau est déjà ouvert, bascule vers son onglet.

Avant l'affichage, le profil actif est synchronisé avec le mode majeur
du buffer source (celui qui était courant au moment de l'appel), afin
que le panneau reflète bien le profil applicable à ce fichier."
  (interactive)
  ;; Sauvegarder le buffer source AVANT de basculer vers le panneau,
  ;; et y forcer la sélection automatique du profil pour s'assurer que
  ;; `metal-agent-profil-actif' correspond bien au mode du fichier
  ;; courant. Cela corrige le cas où le panneau était ouvert avant que
  ;; la sélection automatique n'ait pu se produire.
  (let ((buffer-source (current-buffer))
        (buffer (get-buffer-create metal-agent-panneau-buffer-name)))
    (when (and metal-agent-auto-selection-profil
               (buffer-live-p buffer-source)
               (not (eq buffer-source buffer)))
      (with-current-buffer buffer-source
        (metal-agent--auto-selectionner-profil)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'metal-agent-config-mode)
        (metal-agent-config-mode))
      (metal-agent-panneau--render))
    (switch-to-buffer buffer)))

(defun metal-agent-ouvrir-panneau ()
  "Alias pour `metal-agent-panneau' (compatibilité historique)."
  (interactive)
  (metal-agent-panneau))

;; ─────────────────────────────────────────────────────────────────
;; Rafraîchissement automatique du panneau après modification
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--rafraichir-panneau-si-ouvert (&rest _)
  "Rafraîchir le panneau de configuration s'il est ouvert.
Utilisé comme advice :after sur les commandes qui modifient l'état."
  (when (get-buffer metal-agent-panneau-buffer-name)
    (metal-agent-panneau-rafraichir)))

(dolist (cmd '(metal-agent-choisir-provider
               metal-agent-choisir-profil
               metal-agent--reinitialiser-options
               metal-agent-sauvegarder-etat
               metal-agent-editer-instructions-libres
               metal-agent--effacer-instructions-libres))
  (when (fboundp cmd)
    (advice-add cmd :after #'metal-agent--rafraichir-panneau-si-ouvert)))

(defcustom metal-agent-icon-size 1.0
  "Hauteur des icônes de la toolbar Agent."
  :type 'number :group 'metal-agent)

(defun metal-agent--icon (name color &optional height)
  (if (fboundp 'nerd-icons-mdicon)
      (or (ignore-errors
            (nerd-icons-mdicon name
                               :face `(:foreground ,color)
                               :height (or height metal-agent-icon-size)
                               :v-adjust -0.05))
          "")
    ""))

(defun metal-agent--padding ()
  (propertize " " 'face `(:height ,(+ metal-agent-icon-size 0.2))))

(defun metal-agent--toolbar-button (label action help)
  "Construit un bouton cliquable pour header-line."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] action)
    (define-key map [mode-line mouse-1] action)
    (define-key map [mouse-1] action)
    (propertize label
                'mouse-face 'highlight
                'help-echo help
                'local-map map)))

(defun metal-agent-toolbar-compact ()
  (concat
   (metal-agent--padding)
   "  |  "
   (metal-agent--toolbar-button
    (metal-toolbar-emoji "🤖" :color (metal-agent--current-color))
    #'metal-agent-toggle-active
    (format "Activer les boutons %s (Agent)" (metal-agent--current-label)))
   (metal-agent--padding)))

;; (defun metal-agent-toolbar-expanded ()
;;   "Toolbar Codex complète."
;;   (concat (metal-agent--padding)
;;    "  |  "
;;    (metal-agent--toolbar-button
;;     (propertize "🤖" 'face '(:height 1.4))
;;     #'metal-agent-afficher-codex
;;     "Afficher Codex")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon "nf-md-bug_check" "#c0392b") " Corriger sel.")
;;     #'metal-agent-corriger-selection
;;     "Corriger la sélection")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon "nf-md-file_document_edit" "#2980b9" :height 2.0) " Corriger fichier")
;;     #'metal-agent-corriger-fichier
;;     "Corriger le fichier")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon "nf-md-comment_question" "#16a085") " Expliquer")
;;     #'metal-agent-expliquer-selection
;;     "Expliquer la sélection")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon
;;              (if (metal-agent--prolog-p) "nf-md-database_plus" "nf-md-function")
;;              "#d35400")
;;             (if (metal-agent--prolog-p) " Prédicat" " Fonction"))
;;     #'metal-agent-ajouter-fonction
;;     "Ajouter une fonction ou un prédicat")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon "nf-md-message_text" "#8e44ad") " Demander")
;;     #'metal-agent-demande-libre
;;     "Demande libre")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon "nf-md-check_circle" "#27ae60") " Appliquer")
;;     #'metal-agent--apply-proposed-code
;;     "Appliquer la dernière proposition")
;;    "  "
;;    (metal-agent--toolbar-button
;;     (concat (metal-agent--icon "nf-md-eye" "#7f8c8d") " Afficher/Masquer")
;;     #'metal-agent-toggle-codex-window
;;     "Afficher ou masquer Codex")
;;    "  "
;;    (metal-agent--toolbar-button
;;     "◀ Agent"
;;     #'metal-agent-toggle-active
;;     "Réduire la toolbar Codex")
;;    (metal-agent--padding)))

(defun metal-agent-toolbar-expanded ()
  "Toolbar agent complète (emojis Unicode).
Le label des infobulles s'adapte au provider courant.  Toutes les icônes
passent par `metal-toolbar-emoji', ce qui les rend cohérentes avec Python
et Prolog et sensibles à `metal-toolbar-emoji-size-offset'."
  (let ((label (metal-agent--current-label))
        (color (metal-agent--current-color)))
    (concat
     (metal-agent--padding)
     "  |  "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "🤖" :color color)
      #'metal-agent-toggle-active
      (format "Réduire la toolbar %s (revenir au mode compact)" label))
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "🪄")
      #'metal-agent-corriger-selection
      "Corriger la sélection")
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "📝")
      #'metal-agent-corriger-fichier
      "Corriger le fichier")
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "💡")
      #'metal-agent-expliquer-selection
      "Expliquer la sélection")
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji (if (metal-agent--prolog-p) "➕" "ƒ"))
      #'metal-agent-ajouter-fonction
      (if (metal-agent--prolog-p) "Ajouter un prédicat" "Ajouter une fonction"))
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "💬")
      #'metal-agent-demande-libre
      (format "Demande libre à %s" label))
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "✅")
      #'metal-agent--apply-proposed-code
      "Appliquer la dernière proposition")
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "👁️")
      #'metal-agent-toggle-codex-window
      (format "Afficher ou masquer %s" label))
     "  |  "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "⚙️")
      #'metal-agent-ouvrir-panneau
      (format "Configurer l'agent (profil + options + agent IA — actuel : %s / %s)"
              label
              (or (metal-agent--profil-prop :nom) "?")))
     "   "
     (metal-agent--toolbar-button
      (metal-toolbar-emoji "❌")
      #'metal-agent-toggle-active
      "Réduire la toolbar")
     (metal-agent--padding))))


(defun metal-agent-toolbar-buttons ()
  "Boutons Agent/Codex à ajouter dans les toolbars MetalEmacs."
  (if metal-agent-active
      (metal-agent-toolbar-expanded)
    (metal-agent-toolbar-compact)))

(defun metal-agent--header-already-has-agent-p ()
  "Retourne t si la header-line semble déjà contenir Agent/Codex."
  (let ((s (ignore-errors (format-mode-line header-line-format))))
    (and (stringp s)
         (string-match-p "\\(Agent\\|Codex\\)" s))))

(defcustom metal-agent-modes-exclus
  '(dired-mode
    treemacs-mode
    dirvish-mode
    minibuffer-mode
    minibuffer-inactive-mode
    fundamental-mode
    help-mode
    Info-mode
    Custom-mode
    magit-status-mode
    magit-log-mode
    magit-diff-mode
    image-mode
    pdf-view-mode
    eww-mode
    vterm-mode
    eshell-mode
    shell-mode
    term-mode)
  "Modes dans lesquels la toolbar Agent ne doit PAS apparaître.
On exclut les modes spéciaux (dired, magit, treemacs, terminaux, etc.)
qui ont leurs propres affichages ou ne contiennent pas de texte éditable
au sens classique."
  :type '(repeat symbol)
  :group 'metal-agent)

(defun metal-agent--mode-eligible-p ()
  "Retourne t si le mode courant doit recevoir le bouton Agent.
Inclut tous les modes de programmation, le texte, l'org, le markdown, et
Quarto.  Les modes spéciaux listés dans `metal-agent-modes-exclus' sont
explicitement écartés."
  (and (not (memq major-mode metal-agent-modes-exclus))
       (not (string-prefix-p " " (buffer-name))) ; buffers internes (espace en tête)
       (or (derived-mode-p 'prog-mode)
           (derived-mode-p 'text-mode)
           (derived-mode-p 'org-mode)
           (derived-mode-p 'markdown-mode)
           (memq major-mode '(poly-quarto-mode quarto-mode))
           (and buffer-file-name
                (string-match-p "\\.\\(qmd\\|txt\\|md\\|org\\)\\'" buffer-file-name)))))

;; (defun metal-agent-auto-enable-in-buffer ()
;;   "Ajouter automatiquement Metal Agent à la header-line du buffer courant."
;;   (when (and metal-agent-auto-integrate
;;              (display-graphic-p)
;;              (metal-agent--mode-eligible-p)
;;              (not metal-agent--auto-header-active)
;;              (not (metal-agent--header-already-has-agent-p)))
;;     (setq-local metal-agent--auto-header-original header-line-format)
;;     (setq-local metal-agent--auto-header-active t)
;;     (setq-local header-line-format
;;                 '(:eval
;;                   (let ((agent-buttons
;;                          (or (and (fboundp 'metal-agent-toolbar-buttons)
;;                                   (metal-agent-toolbar-buttons))
;;                              "")))
;;                     (if metal-agent-active
;;                         agent-buttons
;;                       (concat
;;                        (or (and metal-agent--auto-header-original
;;                                 (format-mode-line metal-agent--auto-header-original))
;;                            "")
;;                        agent-buttons)))))))

(defun metal-agent-auto-enable-in-buffer ()
  "Remplacer la header-line par la toolbar Agent dans le buffer courant."
  (when (and metal-agent-auto-integrate
             (display-graphic-p)
             (metal-agent--mode-eligible-p)
             (not metal-agent--auto-header-active)
             (not (metal-agent--header-already-has-agent-p)))
    (setq-local metal-agent--auto-header-original header-line-format)
    (setq-local metal-agent--auto-header-active t)
    (setq-local header-line-format
                '(:eval
                  (or (and (fboundp 'metal-agent-toolbar-buttons)
                           (metal-agent-toolbar-buttons))
                      "")))))

(defun metal-agent-reset ()
  "Réinitialiser l'état local de la toolbar Agent."
  (interactive)
  (setq metal-agent-active nil)
  (force-mode-line-update t)
  (redraw-display))

(add-hook 'prog-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'text-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'org-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'markdown-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'gfm-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'poly-quarto-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'quarto-mode-hook #'metal-agent-auto-enable-in-buffer)
(add-hook 'after-change-major-mode-hook #'metal-agent-auto-enable-in-buffer)

;; Sélection automatique du profil selon le major-mode.
;; Deux déclencheurs nécessaires :
;;   1. À la création/changement de mode d'un buffer.
(add-hook 'after-change-major-mode-hook #'metal-agent--auto-selectionner-profil)
;;   2. Au switch entre buffers existants (le mode ne change pas mais le
;;      buffer affiché oui — il faut donc réajuster le profil global).
(if (boundp 'window-buffer-change-functions)
    (add-hook 'window-buffer-change-functions
              #'metal-agent--auto-selectionner-profil-window-change)
  ;; Fallback pour Emacs < 27 (peu probable, mais on ne casse rien).
  (add-hook 'buffer-list-update-hook #'metal-agent--auto-selectionner-profil))

(global-set-key (kbd "C-c m a") #'metal-agent-toggle-active)
(global-set-key (kbd "C-c m c") #'metal-agent-afficher-codex)
(global-set-key (kbd "C-c m p") #'metal-agent-choisir-provider)
(global-set-key (kbd "C-c m P") #'metal-agent-choisir-profil)
(global-set-key (kbd "C-c m e") #'metal-agent-ouvrir-panneau)

(provide 'metal-agent)
;;; metal-agent.el ends here
