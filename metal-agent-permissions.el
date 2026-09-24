;;; metal-agent-permissions.el --- Permissions de lecture des agents IA -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur

;;; Commentaire:
;;
;; Certains agents refusent par défaut de lire les fichiers hors de leur
;; espace de travail — c'est le cas d'Antigravity (agy), qui ne sert
;; alors à rien pour un agent à `:isoler-fichier' : le fichier isolé se
;; trouve justement hors de l'espace de travail.
;;
;; Ce module accorde (ou retire) la lecture d'une liste de dossiers en
;; modifiant le fichier de réglages de l'agent.  Il est générique : chaque
;; agent décrit, dans une SPEC, le fichier à modifier et les opérations à y
;; appliquer.  La SPEC se trouve, dans l'ordre :
;;
;;   1. sous `:permissions' dans l'entrée du catalogue d'agents ;
;;   2. sinon dans `metal-agent-permissions-defauts', indexée par le nom
;;      de l'exécutable de l'agent (« agy », « claude »…) — ce qui évite
;;      de dépendre des ID internes du catalogue.
;;
;; Forme d'une SPEC déclarative (fichier JSON) :
;;
;;   (:fichier "~/.gemini/antigravity-cli/settings.json"
;;    :format json
;;    :operations
;;    ((:fixer   ("allowNonWorkspaceAccess") :valeur t)
;;     (:ajouter ("permissions" "allow")     :modele "read_file(%s)")))
;;
;;   :fixer CHEMIN :valeur V   — pose la clé ; au retrait, la clé est
;;                               SUPPRIMÉE (l'agent reprend son défaut).
;;   :ajouter CHEMIN :modele M — ajoute au tableau (format M DOSSIER) pour
;;                               chaque dossier ; au retrait, ces éléments
;;                               seuls sont enlevés, le reste est intact.
;;
;; Forme d'une SPEC procédurale (TOML, YAML, ou tout autre cas) :
;;
;;   (:format fonction
;;    :active-p   FN   ; (FN DOSSIERS) → non-nil si déjà accordé
;;    :activer    FN   ; (FN DOSSIERS)
;;    :desactiver FN)  ; (FN DOSSIERS)
;;
;; Avant la première modification d'un fichier, une copie est laissée à
;; côté sous le suffixe « .metal-bak ».

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defvar metal-deps-agents-catalogue)

(defgroup metal-agent-permissions nil
  "Permissions de lecture accordées aux agents IA."
  :group 'metal-deps)

(defcustom metal-agent-permissions-dossiers
  (list temporary-file-directory)
  "Dossiers que les agents doivent pouvoir lire.
Y mettre au minimum le dossier où MetalEmacs dépose les fichiers isolés
(`:isoler-fichier').  Les chemins sont développés avant écriture."
  :type '(repeat directory)
  :group 'metal-agent-permissions)

(defcustom metal-agent-permissions-defauts
  '(("agy"
     :fichier "~/.gemini/antigravity-cli/settings.json"
     :format json
     :operations ((:fixer ("allowNonWorkspaceAccess") :valeur t)
                  (:ajouter ("permissions" "allow") :modele "read_file(%s)"))))
  "SPEC de permissions par nom d'exécutable d'agent.
Utilisée quand l'entrée du catalogue n'a pas de `:permissions'.
N'y inscrire QUE les agents qui bloquent la lecture par défaut : un agent
listé ici affiche « bloqué » tant que la permission n'est pas accordée.
Claude et Codex n'y figurent donc pas — ils lisent déjà les fichiers."
  :type '(alist :key-type string :value-type plist)
  :group 'metal-agent-permissions)

;;; ─── Recherche de la SPEC ─────────────────────────────────────────

(defun metal-agent-permissions--entree (id)
  "Entrée du catalogue (plist sans ID) de l'agent ID, ou nil."
  (and (boundp 'metal-deps-agents-catalogue)
       (cdr (assq id metal-deps-agents-catalogue))))

(defun metal-agent-permissions--executable (entree)
  "Nom de base de l'exécutable décrit par ENTREE (sans extension)."
  (let ((cmd (or (plist-get entree :executable)
                 (car (split-string (or (plist-get entree :commande) ""))))))
    (and cmd (not (string-empty-p cmd))
         (file-name-base cmd))))

(defun metal-agent-permissions-spec (id)
  "Retourne la SPEC de permissions de l'agent ID, ou nil s'il n'en a pas."
  (let ((entree (metal-agent-permissions--entree id)))
    (or (plist-get entree :permissions)
        (let ((exe (metal-agent-permissions--executable entree)))
          (and exe (cdr (assoc exe metal-agent-permissions-defauts)))))))

(defun metal-agent-permissions--dossiers ()
  "Dossiers à autoriser, en chemins absolus sans barre finale."
  (mapcar (lambda (d) (directory-file-name (expand-file-name d)))
          metal-agent-permissions-dossiers))

;;; ─── JSON : lecture, chemins, impression ──────────────────────────
;;
;; Représentation : objets = alists à clés symboles, tableaux = vecteurs,
;; `:false' / `:null' pour false / null.  L'aller-retour conserve ainsi
;; l'ordre des clés et toutes les valeurs que l'agent a écrites.

(defun metal-agent-permissions--json-lire (fichier)
  "Lit FICHIER en JSON ; nil (objet vide) s'il est absent ou vide."
  (when (file-exists-p fichier)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents fichier))
      (goto-char (point-min))
      (unless (string-blank-p (buffer-string))
        (json-parse-buffer :object-type 'alist :array-type 'array
                           :null-object :null :false-object :false)))))

(defun metal-agent-permissions--objet-p (v)
  "Non-nil si V représente un objet JSON (alist, éventuellement vide)."
  (listp v))

(defun metal-agent-permissions--obtenir (obj chemin)
  "Valeur de OBJ au CHEMIN (liste de clés chaînes), ou nil."
  (cond ((null chemin) obj)
        ((not (metal-agent-permissions--objet-p obj)) nil)
        (t (metal-agent-permissions--obtenir
            (alist-get (intern (car chemin)) obj) (cdr chemin)))))

(defun metal-agent-permissions--poser (obj chemin valeur)
  "Copie de OBJ où CHEMIN vaut VALEUR (objets intermédiaires créés)."
  (let* ((obj (if (metal-agent-permissions--objet-p obj) obj nil))
         (cle (intern (car chemin)))
         (val (if (cdr chemin)
                  (metal-agent-permissions--poser (alist-get cle obj)
                                                  (cdr chemin) valeur)
                valeur)))
    (if (assq cle obj)
        (mapcar (lambda (p) (if (eq (car p) cle) (cons cle val) p)) obj)
      (append obj (list (cons cle val))))))

(defun metal-agent-permissions--retirer (obj chemin)
  "Copie de OBJ sans la clé désignée par CHEMIN."
  (cond ((not (metal-agent-permissions--objet-p obj)) obj)
        ((null (cdr chemin))
         (cl-remove (intern (car chemin)) obj :key #'car))
        (t (let ((cle (intern (car chemin))))
             (if (assq cle obj)
                 (mapcar (lambda (p)
                           (if (eq (car p) cle)
                               (cons cle (metal-agent-permissions--retirer
                                          (cdr p) (cdr chemin)))
                             p))
                         obj)
               obj)))))

(defun metal-agent-permissions--scalaire (v)
  "Sérialise la valeur scalaire V (chaîne, nombre, t, :false, :null)."
  ;; Passer par un tableau : `json-serialize' n'accepte pas un scalaire
  ;; au premier niveau sur toutes les versions d'Emacs.
  (let ((s (json-serialize (vector v))))
    (substring s 1 -1)))

(defun metal-agent-permissions--imprimer (v &optional niveau)
  "Représentation JSON indentée (2 espaces) de V au NIVEAU d'imbrication."
  (let* ((niveau (or niveau 0))
         (ind  (make-string (* 2 niveau) ?\s))
         (ind2 (make-string (* 2 (1+ niveau)) ?\s)))
    (cond
     ((null v) "{}")
     ((consp v)
      (concat "{\n"
              (mapconcat
               (lambda (p)
                 (concat ind2
                         (metal-agent-permissions--scalaire (symbol-name (car p)))
                         ": "
                         (metal-agent-permissions--imprimer (cdr p) (1+ niveau))))
               v ",\n")
              "\n" ind "}"))
     ((and (vectorp v) (= (length v) 0)) "[]")
     ((vectorp v)
      (concat "[\n"
              (mapconcat
               (lambda (e)
                 (concat ind2 (metal-agent-permissions--imprimer e (1+ niveau))))
               v ",\n")
              "\n" ind "]"))
     (t (metal-agent-permissions--scalaire v)))))

(defun metal-agent-permissions--sauvegarder (fichier)
  "Copie FICHIER en FICHIER.metal-bak, une seule fois."
  (let ((bak (concat fichier ".metal-bak")))
    (when (and (file-exists-p fichier) (not (file-exists-p bak)))
      (copy-file fichier bak))))

(defun metal-agent-permissions--json-ecrire (fichier obj)
  "Écrit OBJ dans FICHIER (UTF-8, fins de ligne Unix)."
  (make-directory (file-name-directory fichier) t)
  (metal-agent-permissions--sauvegarder fichier)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file fichier
      (insert (metal-agent-permissions--imprimer obj) "\n"))))

;;; ─── Opérations déclaratives ──────────────────────────────────────

(defun metal-agent-permissions--elements (op dossiers)
  "Éléments de tableau que l'opération `:ajouter' OP produit pour DOSSIERS."
  (mapcar (lambda (d) (format (plist-get op :modele) d)) dossiers))

(defun metal-agent-permissions--op-satisfaite-p (obj op dossiers)
  "Non-nil si OBJ satisfait déjà l'opération OP pour DOSSIERS."
  (cond
   ((plist-member op :fixer)
    (equal (metal-agent-permissions--obtenir obj (plist-get op :fixer))
           (plist-get op :valeur)))
   ((plist-member op :ajouter)
    (let ((tab (append (metal-agent-permissions--obtenir
                        obj (plist-get op :ajouter))
                       nil)))
      (cl-every (lambda (e) (member e tab))
                (metal-agent-permissions--elements op dossiers))))))

(defun metal-agent-permissions--op-appliquer (obj op dossiers activer)
  "Applique OP à OBJ pour DOSSIERS ; retire si ACTIVER est nil."
  (cond
   ((plist-member op :fixer)
    (let ((chemin (plist-get op :fixer)))
      (if activer
          (metal-agent-permissions--poser obj chemin (plist-get op :valeur))
        (metal-agent-permissions--retirer obj chemin))))
   ((plist-member op :ajouter)
    (let* ((chemin (plist-get op :ajouter))
           (actuel (metal-agent-permissions--obtenir obj chemin))
           (tab (and (vectorp actuel) (append actuel nil)))
           (elems (metal-agent-permissions--elements op dossiers))
           (nouveau (if activer
                        (append tab (cl-remove-if (lambda (e) (member e tab))
                                                  elems))
                      (cl-remove-if (lambda (e) (member e elems)) tab))))
      (if (and (null nouveau) (not activer))
          (metal-agent-permissions--retirer obj chemin)
        (metal-agent-permissions--poser obj chemin (vconcat nouveau)))))
   (t obj)))

;;; ─── API publique ─────────────────────────────────────────────────

(defun metal-agent-permissions--fichier (spec)
  "Chemin absolu du fichier de réglages décrit par SPEC."
  (expand-file-name (plist-get spec :fichier)))

(defun metal-agent-permissions-active-p (id)
  "Non-nil si l'agent ID peut déjà lire `metal-agent-permissions-dossiers'."
  (let ((spec (metal-agent-permissions-spec id))
        (dossiers (metal-agent-permissions--dossiers)))
    (pcase (plist-get spec :format)
      ('nil nil)
      ('fonction (funcall (plist-get spec :active-p) dossiers))
      ('json
       (let ((obj (ignore-errors (metal-agent-permissions--json-lire
                                  (metal-agent-permissions--fichier spec)))))
         (cl-every (lambda (op)
                     (metal-agent-permissions--op-satisfaite-p obj op dossiers))
                   (plist-get spec :operations))))
      (f (error "Format de permissions inconnu : %s" f)))))

(defun metal-agent-permissions--arreter-sessions (id)
  "Arrête les processus vivants de l'agent ID ; retourne leur nombre.
L'agent ne relit ses réglages qu'au lancement : une session déjà ouverte
garderait l'ancienne permission jusqu'au redémarrage d'Emacs."
  (let ((exe (metal-agent-permissions--executable
              (metal-agent-permissions--entree id)))
        (n 0))
    (when exe
      (dolist (p (process-list))
        (let ((cmd (process-command p)))
          (when (and (consp cmd)
                     (process-live-p p)
                     ;; Les trois premiers mots suffisent : « agy … »,
                     ;; « cmd.exe /c agy … », « sh -c "agy …" ».
                     (cl-some (lambda (arg)
                                (and (stringp arg)
                                     (let ((mot (car (split-string arg))))
                                       (and mot (string= (file-name-base mot)
                                                         exe)))))
                              (seq-take cmd 3)))
            (delete-process p)
            (cl-incf n)))))
    n))

(defun metal-agent-permissions--appliquer (id activer)
  "Accorde (ACTIVER non-nil) ou retire la lecture à l'agent ID."
  (let ((spec (or (metal-agent-permissions-spec id)
                  (user-error "L'agent « %s » n'a pas de réglage de permissions" id)))
        (dossiers (metal-agent-permissions--dossiers)))
    (pcase (plist-get spec :format)
      ('fonction
       (funcall (plist-get spec (if activer :activer :desactiver)) dossiers))
      ('json
       (let* ((fichier (metal-agent-permissions--fichier spec))
              (obj (condition-case err
                       (metal-agent-permissions--json-lire fichier)
                     (json-error
                      (user-error "%s n'est pas du JSON valide (%s) — rien n'est modifié"
                                  (abbreviate-file-name fichier)
                                  (error-message-string err))))))
         (dolist (op (plist-get spec :operations))
           (setq obj (metal-agent-permissions--op-appliquer
                      obj op dossiers activer)))
         (metal-agent-permissions--json-ecrire fichier obj)))
      (f (error "Format de permissions inconnu : %s" f)))
    (let ((n (metal-agent-permissions--arreter-sessions id)))
      (message "%s : accès aux fichiers %s — effet dès la prochaine requête%s"
               (or (plist-get (metal-agent-permissions--entree id) :nom) id)
               (if activer "autorisé" "bloqué")
               (if (> n 0)
                   (format " (session en cours fermée : %d)" n)
                 "")))))

(defun metal-agent-permissions-activer (id)
  "Accorde à l'agent ID la lecture de `metal-agent-permissions-dossiers'."
  (metal-agent-permissions--appliquer id t))

(defun metal-agent-permissions-desactiver (id)
  "Retire à l'agent ID la lecture de `metal-agent-permissions-dossiers'."
  (metal-agent-permissions--appliquer id nil))

(defun metal-agent-permissions--ids ()
  "ID des agents du catalogue qui ont une SPEC de permissions."
  (cl-loop for (id . _) in (and (boundp 'metal-deps-agents-catalogue)
                                metal-deps-agents-catalogue)
           when (metal-agent-permissions-spec id) collect id))

;;;###autoload
(defun metal-agent-permissions-basculer (id)
  "Autorise ou bloque l'accès de l'agent ID aux dossiers configurés."
  (interactive
   (let ((ids (metal-agent-permissions--ids)))
     (unless ids (user-error "Aucun agent n'a de réglage de permissions"))
     (list (intern (completing-read "Agent : " (mapcar #'symbol-name ids)
                                    nil t)))))
  (if (metal-agent-permissions-active-p id)
      (metal-agent-permissions-desactiver id)
    (metal-agent-permissions-activer id)))

(provide 'metal-agent-permissions)
;;; metal-agent-permissions.el ends here
