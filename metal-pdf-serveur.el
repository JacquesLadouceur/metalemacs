;;; metal-pdf-serveur.el --- Accord entre pdf-tools et son serveur -*- lexical-binding: t -*-
;;; -*- coding: utf-8 -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, pdf

;;; Commentary:
;;
;; pdf-tools a deux moitiés : du Lisp, et un serveur natif `epdfinfo'.
;; Si elles ne proviennent pas du même commit, le Lisp envoie au serveur
;; des options qu'il ignore ; le mode échoue à s'initialiser et les PDF
;; retombent silencieusement sur doc-view.
;;
;; PRINCIPE : ce qui ne peut pas changer localement fait autorité.
;;
;;   Windows       — le serveur vient du paquet MSYS2, dans la version
;;                   que ce dépôt sert ce jour-là.  On ne la choisit
;;                   pas : c'est donc ELLE qui fait autorité, et le clone
;;                   straight du Lisp bascule sur le commit correspondant.
;;
;;   macOS, Linux  — le serveur est COMPILÉ depuis les sources du paquet
;;                   Lisp.  C'est donc le Lisp qui fait autorité, et
;;                   l'accord est acquis par construction.
;;
;; Conséquence : aucun poste ne dépend d'une intervention du mainteneur
;; pour rester cohérent.  Une machine installée dans six mois s'accorde
;; sur ce que son dépôt lui sert.
;;
;; La version de `metal-pdf-version.el' n'est plus une contrainte mais
;; une RÉFÉRENCE : celle qui a été testée, servant de repli quand la
;; version du serveur n'est pas déterminable, et affichée à titre
;; indicatif par l'Assistant.
;;
;; RÈGLE DE CE FICHIER : aucun sous-processus ne passe par un shell.
;; Les installateurs lançaient leur commande par
;; `start-process-shell-command', c.-à-d. une CHAÎNE confiée à cmd.exe
;; sous Windows.  Le chemin de pacman, produit par `expand-file-name'
;; (donc en barres obliques), y traversait `shell-quote-argument', un
;; `&&' et l'analyse de ligne de commande de `cmd /c' : cmd répondait
;; « Le chemin d'accès spécifié est introuvable » (ERROR_PATH_NOT_FOUND)
;; sur un binaire que `file-executable-p' venait de valider et que
;; `call-process' lance sans peine quelques lignes plus haut.  Une LISTE
;; d'arguments supprime la classe entière de pannes : plus de citation,
;; plus d'interprétation, et plus de page de codes OEM sur les messages
;; d'erreur — pacman, lui, écrit en UTF-8.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'metal-pdf-version)

;; Autoréparation de pacman : elle vit dans `metal-deps.el', qui charge ce
;; module.  Chaque appel est gardé par `fboundp' pour que ce fichier reste
;; utilisable seul.
(declare-function metal-deps-msys2-traiter-echec "metal-deps" (tampon relancer))
(declare-function metal-deps-msys2-degager "metal-deps" ())
(declare-function metal-deps-msys2-nouvelle-operation "metal-deps" ())

(defgroup metal-pdf-serveur nil
  "Accord entre le Lisp de pdf-tools et son serveur natif."
  :group 'metal-pdf
  :prefix "metal-pdf-serveur-")

(defconst metal-pdf-serveur-paquet-msys2
  "mingw-w64-x86_64-emacs-pdf-tools-server"
  "Paquet MSYS2 fournissant epdfinfo.exe et ses DLL MinGW.")

(defconst metal-pdf-serveur-depot "https://github.com/vedang/pdf-tools"
  "Dépôt amont, interrogé pour résoudre une version en commit.")

(defvar metal-pdf-serveur-cache
  (expand-file-name ".epdfinfo-alignement" user-emacs-directory)
  "Cache de l'accord : « VERSION COMMIT » de la dernière bascule réussie.
Évite tout accès réseau au démarrage tant que la version du serveur n'a
pas changé.")

;;; --- Localisation de MSYS2 (Windows) -------------------------------------

(defcustom metal-pdf-serveur-msys2-racine nil
  "Racine de l'installation MSYS2.
Nil signifie détection automatique.  Ne fixer une valeur que si MSYS2
vit à un endroit inhabituel."
  :type '(choice (const :tag "Détection automatique" nil) directory)
  :group 'metal-pdf-serveur)

(defun metal-pdf-serveur-msys2-racines-candidates ()
  "Emplacements où chercher MSYS2, du plus probable au moins probable."
  (delq nil
        (list (getenv "MSYS2_ROOT")
              (expand-file-name "scoop/apps/msys2/current/"
                                (or (getenv "USERPROFILE") "~"))
              (expand-file-name "scoop/apps/msys2/current/" "~")
              "C:/msys64/"
              "C:/tools/msys64/"
              (expand-file-name "msys64/" (or (getenv "LOCALAPPDATA") "~")))))

(defun metal-pdf-serveur-msys2-racine ()
  "Racine MSYS2 utilisable, ou nil."
  (cl-find-if
   (lambda (r)
     (and r (file-executable-p (expand-file-name "usr/bin/pacman.exe" r))))
   (if metal-pdf-serveur-msys2-racine
       (list metal-pdf-serveur-msys2-racine)
     (metal-pdf-serveur-msys2-racines-candidates))))

(defun metal-pdf-serveur-msys2-present-p ()
  "Retourne non-nil si MSYS2 est installé."
  (and (metal-pdf-serveur-msys2-racine) t))

(defun metal-pdf-serveur--pacman ()
  "Chemin de pacman.exe, ou nil."
  (let ((racine (metal-pdf-serveur-msys2-racine)))
    (when racine (expand-file-name "usr/bin/pacman.exe" racine))))

(defun metal-pdf-serveur--pacman-sortie (&rest args)
  "Sortie de pacman appelé avec ARGS, ou nil si l'appel échoue."
  (let ((pacman (metal-pdf-serveur--pacman)))
    (when pacman
      (with-temp-buffer
        (when (= 0 (apply #'call-process pacman nil t nil args))
          (buffer-string))))))

(defun metal-pdf-serveur--version-nue (brut)
  "Retire la révision MSYS2 de BRUT : « 1.3.0-1 » donne « 1.3.0 »."
  (when (and (stringp brut)
             (string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)*\\)" brut))
    (match-string 1 brut)))

(defun metal-pdf-serveur-version-installee ()
  "Version du serveur MSYS2 installé, ou nil.
Le nom du paquet contient des chiffres : on prend le dernier champ de la
première ligne, jamais le premier nombre rencontré."
  (let ((sortie (metal-pdf-serveur--pacman-sortie
                 "-Q" metal-pdf-serveur-paquet-msys2)))
    (when sortie
      (let ((ligne (car (split-string sortie "\n" t))))
        (when ligne
          (metal-pdf-serveur--version-nue
           (car (last (split-string ligne "[ \t]+" t)))))))))

(defun metal-pdf-serveur-programme ()
  "Chemin d'epdfinfo.exe fourni par MSYS2, ou nil.
Le binaire y côtoie ses DLL MinGW, ce qui évite le conflit classique
avec les bibliothèques de Git for Windows."
  (let ((racine (metal-pdf-serveur-msys2-racine)))
    (when racine
      (let ((exe (expand-file-name "mingw64/bin/epdfinfo.exe" racine)))
        (and (file-executable-p exe) exe)))))

(defvar pdf-info-epdfinfo-program)      ; défini par `pdf-info.el'

(defun metal-pdf-serveur-brancher-programme ()
  "Pointe `pdf-info-epdfinfo-program' sur le binaire fourni par MSYS2.
Retourne le chemin retenu, ou nil.

Sans ce branchement, `metal-pdf-serveur-programme' ne servait à rien :
pdf-tools lançait le binaire de son dossier de compilation straight,
qui sous Windows ne contient rien.  Le paquet MSYS2 pouvait donc être
installé et le serveur rester introuvable au démarrage — les PDF
retombant sur doc-view sans autre explication.

Poser la valeur AVANT le chargement de `pdf-info' ne la perd pas : son
`defcustom' respecte une variable déjà affectée."
  (let ((exe (metal-pdf-serveur-programme)))
    (when exe
      (setq pdf-info-epdfinfo-program exe)
      (metal-pdf-serveur-invalider-etat)
      exe)))

;;; --- Clone straight ------------------------------------------------------

(defun metal-pdf-serveur--dossiers-straight ()
  "Les dossiers straight de pdf-tools : dépôt et compilation."
  (list (expand-file-name "straight/repos/pdf-tools" user-emacs-directory)
        (expand-file-name "straight/build/pdf-tools" user-emacs-directory)))

(defun metal-pdf-serveur--git (&rest args)
  "Lance git dans le clone straight de pdf-tools ; t si succès."
  (let ((depot (car (metal-pdf-serveur--dossiers-straight))))
    (and (file-directory-p depot)
         (= 0 (apply #'call-process "git" nil nil nil "-C" depot args)))))

(defun metal-pdf-serveur--commit-clone ()
  "HEAD du clone straight de pdf-tools, ou nil."
  (let ((depot (car (metal-pdf-serveur--dossiers-straight))))
    (when (file-directory-p depot)
      (with-temp-buffer
        (when (= 0 (call-process "git" nil t nil "-C" depot "rev-parse" "HEAD"))
          (let ((s (string-trim (buffer-string))))
            (and (string-match-p "\\`[0-9a-f]\\{40\\}\\'" s) s)))))))

;;; --- Cache de l'accord ---------------------------------------------------

(defun metal-pdf-serveur--lire-cache ()
  "Retourne (VERSION . COMMIT) du dernier accord, ou nil."
  (when (file-readable-p metal-pdf-serveur-cache)
    (with-temp-buffer
      (insert-file-contents metal-pdf-serveur-cache)
      (let ((champs (split-string (string-trim (buffer-string)) "[ \t\n]+" t)))
        (when (and (= 2 (length champs))
                   (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (nth 1 champs)))
          (cons (nth 0 champs) (nth 1 champs)))))))

(defun metal-pdf-serveur--ecrire-cache (version commit)
  "Note que VERSION du serveur correspond à COMMIT."
  (ignore-errors
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (format "%s %s\n" version commit) nil
                    metal-pdf-serveur-cache nil 'silencieux))))

(defun metal-pdf-serveur-noter-construction ()
  "Note que le serveur courant provient du commit de référence.
Appelée après un `pdf-tools-install' réussi, là où le serveur est
compilé depuis les sources du paquet Lisp."
  (metal-pdf-serveur--ecrire-cache metal-pdf-version-attendue
                                   metal-pdf-commit-attendu))

;;; --- Résolution version vers commit --------------------------------------

(defun metal-pdf-serveur--commit-connu (version)
  "Commit de VERSION s'il est connu SANS accès réseau, sinon nil.
Deux sources : la version de référence, et le cache d'un accord
précédent.  Utilisée par tout ce qui s'exécute dans un chemin
d'affichage, où un appel réseau bloquerait l'interface."
  (cond
   ((null version) nil)
   ((string= version metal-pdf-version-attendue) metal-pdf-commit-attendu)
   (t (let ((c (metal-pdf-serveur--lire-cache)))
        (and c (string= (car c) version) (cdr c))))))

(defun metal-pdf-serveur--commit-de-version (version)
  "Commit de la balise vVERSION dans le dépôt amont, ou nil.

Peut interroger le réseau : à n'appeler que depuis une action explicite
de l'utilisateur, jamais depuis l'affichage."
  (or (metal-pdf-serveur--commit-connu version)
      (when version
    (let ((tag (concat "v" version)))
      (with-temp-buffer
        (when (= 0 (call-process "git" nil t nil "ls-remote" "--tags"
                                 metal-pdf-serveur-depot
                                 tag (concat tag "^{}")))
          (let ((texte (buffer-string)))
            (or (and (string-match
                      (format "\\([0-9a-f]\\{40\\}\\)[ \t]+refs/tags/%s\\^{}"
                              (regexp-quote tag))
                      texte)
                     (match-string 1 texte))
                (and (string-match
                      (format "\\([0-9a-f]\\{40\\}\\)[ \t]+refs/tags/%s$"
                              (regexp-quote tag))
                      texte)
                     (match-string 1 texte))))))))))

;;; --- Cible : qui fait autorité -------------------------------------------

(defun metal-pdf-serveur-pilote-par-le-serveur-p ()
  "Retourne non-nil là où le serveur est FOURNI plutôt que compilé.
Sous Windows, MSYS2 impose sa version : elle fait autorité.  Ailleurs,
le serveur est compilé depuis les sources du Lisp, qui fait autorité."
  (eq system-type 'windows-nt))

(defun metal-pdf-serveur-version-visee ()
  "Version de pdf-tools que cette machine doit viser."
  (or (and (metal-pdf-serveur-pilote-par-le-serveur-p)
           (metal-pdf-serveur-version-installee))
      metal-pdf-version-attendue))

(defun metal-pdf-serveur-commit-vise (&optional resoudre)
  "Commit que le clone straight doit porter, ou nil.
Sans RESOUDRE, s'en tient aux sources locales : aucun accès réseau."
  (let ((v (metal-pdf-serveur-version-visee)))
    (if resoudre
        (metal-pdf-serveur--commit-de-version v)
      (metal-pdf-serveur--commit-connu v))))

;;; --- Alignement ----------------------------------------------------------

(defun metal-pdf-serveur--journal (fmt &rest args)
  "Journalise dans *Messages* sans encombrer l'écho."
  (let ((message-log-max t))
    (message "MetalEmacs : %s" (apply #'format fmt args))))

(defvar metal-pdf-serveur--issue-alignement nil
  "Issue du dernier `metal-pdf-serveur-aligner-straight'.
  bascule         — le clone a changé de commit
  deja            — le clone portait déjà le commit visé
  sans-clone      — straight n'a pas encore cloné pdf-tools
  indeterminable  — le commit de la version visée n'a pu être résolu
  impossible      — le `git checkout' a échoué
La valeur de retour de la fonction (t ou nil) confondait les quatre
dernières : `metal-pdf-serveur-reparer' annonçait « Déjà accordé »
alors que l'alignement avait échoué.")

(defun metal-pdf-serveur--bilan-alignement (version)
  "Message décrivant l'issue du dernier alignement sur VERSION."
  (pcase metal-pdf-serveur--issue-alignement
    ('bascule (format "✅ Lisp aligné sur le serveur %s — redémarrez Emacs" version))
    ('deja (format "✓ Déjà accordé (%s)" version))
    ('sans-clone "⚠ pdf-tools n'est pas encore cloné — redémarrez Emacs")
    ('indeterminable
     (format "⚠ Commit de pdf-tools %s introuvable (réseau ou git ?) — voir *Messages*"
             version))
    ('impossible
     (format "⚠ Bascule du Lisp vers %s impossible — voir *Messages*" version))
    (_ "⚠ Alignement non effectué")))

;;;###autoload
(defun metal-pdf-serveur-aligner-straight ()
  "Bascule le clone straight de pdf-tools sur le commit visé.

À appeler APRÈS `straight-use-package' : le clone doit exister.
Retourne t si une bascule a eu lieu.

straight.el n'a pas de mot-clé `:commit' dans ses recettes — il
l'ignorerait en silence.  L'épinglage se fait donc ici, par git, suivi
d'un `straight-rebuild-package' : sans lui, le Lisp compilé resterait
celui de l'ancien commit.

Ne purge jamais les dossiers : les supprimer provoquerait un nouveau
clone sur la branche par défaut, donc une boucle."
  (let ((clone (metal-pdf-serveur--commit-clone))
        (vise (metal-pdf-serveur-commit-vise t)))
    (setq metal-pdf-serveur--issue-alignement
          (cond ((null clone) 'sans-clone)
                ((null vise) 'indeterminable)
                ((string= clone vise) 'deja)
                (t 'impossible)))   ; corrigé en `bascule' si le checkout réussit
    (cond
     ((null clone) nil)                 ; straight n'a pas encore cloné
     ((null vise)
      (metal-pdf-serveur--journal
       "pdf-tools : version cible indéterminable — clone laissé en %s"
       (substring clone 0 12))
      nil)
     ((string= clone vise) nil)         ; déjà accordé
     (t
      ;; Le commit visé peut manquer localement : clone superficiel, ou
      ;; commit plus récent que le clone.
      (unless (metal-pdf-serveur--git "cat-file" "-e" (concat vise "^{commit}"))
        (or (metal-pdf-serveur--git "fetch" "--unshallow" "--tags" "origin")
            (metal-pdf-serveur--git "fetch" "--tags" "origin")))
      (if (metal-pdf-serveur--git "checkout" "--detach" "--force" vise)
          (progn
            (setq metal-pdf-serveur--issue-alignement 'bascule)
            (metal-pdf-serveur--journal
             "pdf-tools : Lisp aligné sur le serveur — %s vers %s (%s)"
             (substring clone 0 12) (substring vise 0 12)
             (metal-pdf-serveur-version-visee))
            (when (fboundp 'straight-rebuild-package)
              (ignore-errors (straight-rebuild-package "pdf-tools" t)))
            (metal-pdf-serveur--ecrire-cache
             (metal-pdf-serveur-version-visee) vise)
            (metal-pdf-serveur-invalider-etat)
            t)
        (metal-pdf-serveur--journal
         "pdf-tools : bascule vers %s IMPOSSIBLE — le Lisp reste en %s"
         (substring vise 0 12) (substring clone 0 12))
        nil)))))

;;; --- État, pour l'Assistant ----------------------------------------------

(defvar metal-pdf-serveur--etat-memo nil
  "Dernier état calculé, sous forme (INSTANT . ÉTAT).")

(defcustom metal-pdf-serveur-memo-secondes 20
  "Durée de validité de l'état mémorisé, en secondes.

Calculer l'état lance `pacman' et `git' — deux sous-processus, lents
sous Windows.  L'Assistant interroge l'état plusieurs fois par rendu (le
vérificateur, puis la description) : sans mémorisation, chaque
rafraîchissement multiplie ces lancements et l'interface se fige."
  :type 'integer
  :group 'metal-pdf-serveur)

(defun metal-pdf-serveur-invalider-etat ()
  "Oublie l'état mémorisé.  À appeler après toute action le modifiant."
  (setq metal-pdf-serveur--etat-memo nil))

(defun metal-pdf-serveur-etat ()
  "État de l'accord, mémorisé quelques secondes.  Voir `metal-pdf-serveur--etat'."
  (let ((memo metal-pdf-serveur--etat-memo))
    (if (and memo
             (< (float-time (time-subtract (current-time) (car memo)))
                metal-pdf-serveur-memo-secondes))
        (cdr memo)
      (let ((etat (metal-pdf-serveur--etat)))
        (setq metal-pdf-serveur--etat-memo (cons (current-time) etat))
        etat))))

(defun metal-pdf-serveur--etat ()
  "État de l'accord, sous forme (SYMBOLE . DÉTAIL).

  sans-msys2    — Windows sans MSYS2 : pas de serveur possible
  absent        — aucun serveur epdfinfo utilisable
  sans-clone    — le paquet Lisp n'est pas encore cloné
  a-resoudre    — version du serveur jamais résolue ici (bouton Réparer)
  ok            — Lisp et serveur accordés ; DÉTAIL porte la version
  a-aligner     — accord à rétablir ; DÉTAIL porte la version du serveur

Lecture pure : pas d'écriture, et pas de réseau tant que la version
visée est celle de référence ou celle du cache."
  (let* ((pilote (metal-pdf-serveur-pilote-par-le-serveur-p))
         ;; Une seule interrogation du serveur par calcul : chaque appel
         ;; lance pacman, coûteux sous Windows.
         (installee (and pilote (metal-pdf-serveur-version-installee)))
         (v (or installee metal-pdf-version-attendue)))
    (cond
     ((and pilote (not (metal-pdf-serveur-msys2-present-p)))
      (cons 'sans-msys2 nil))
     ((and pilote (null installee)) (cons 'absent nil))
     ((and (not pilote)
           (not (and (boundp 'pdf-info-epdfinfo-program)
                     pdf-info-epdfinfo-program
                     (file-executable-p pdf-info-epdfinfo-program))))
      (cons 'absent nil))
     (t
      (let ((clone (metal-pdf-serveur--commit-clone))
            (vise (metal-pdf-serveur--commit-connu v)))
        (cond
         ((null clone) (cons 'sans-clone nil))
         ((null vise) (cons 'a-resoudre v))
         ((string= clone vise) (cons 'ok v))
         (t (cons 'a-aligner v))))))))

(defun metal-pdf-serveur-accorde-p ()
  "Retourne non-nil si le Lisp et le serveur sont accordés."
  (eq (car (metal-pdf-serveur-etat)) 'ok))

(defun metal-pdf-serveur-etat-ligne ()
  "Ligne d'état lisible, destinée à l'Assistant."
  (let* ((etat (metal-pdf-serveur-etat))
         (v (cdr etat)))
    (pcase (car etat)
      ('sans-msys2 "MSYS2 requis pour lire les PDF dans Emacs (~1 Go)")
      ('absent (if (metal-pdf-serveur-pilote-par-le-serveur-p)
                   "serveur non installé — les PDF passent par doc-view"
                 "serveur non compilé — bouton Réparer"))
      ('sans-clone "paquet Lisp pas encore installé")
      ;; Le bouton de cette ligne s'intitule « Installer » tant qu'elle
      ;; n'est pas validée : l'ancien texte renvoyait à un bouton
      ;; « Réparer » qui n'existe pas sur la ligne.
      ('a-resoudre
       (if (and (metal-pdf-serveur-pilote-par-le-serveur-p)
                (version< v metal-pdf-version-attendue))
           (format "serveur %s périmé (référence %s) — bouton Installer"
                   v metal-pdf-version-attendue)
         (format "serveur %s — accord à établir, bouton Installer" v)))
      ('ok (if (string= v metal-pdf-version-attendue)
               (format "accordé (%s)" v)
             (format "accordé (%s ; référence %s)" v metal-pdf-version-attendue)))
      ('a-aligner
       (if (and (metal-pdf-serveur-pilote-par-le-serveur-p)
                (version< v metal-pdf-version-attendue))
           (format "serveur %s périmé (référence %s) — bouton Installer"
                   v metal-pdf-version-attendue)
         (format "serveur %s, Lisp désaccordé — bouton Installer" v)))
      (_ "état indéterminé"))))

;;; --- Réparation : point d'entrée unique ----------------------------------

(defun metal-pdf-serveur--rafraichir-assistant ()
  "Oublie l'état mémorisé et redessine l'Assistant s'il est affiché."
  (metal-pdf-serveur-invalider-etat)
  (when (and (fboundp 'metal-deps-afficher-etat)
             (get-buffer-window "*MetalEmacs Assistant*" t))
    (ignore-errors (metal-deps-afficher-etat))))

;;;###autoload
(defun metal-pdf-serveur-reparer ()
  "Rétablit l'accord entre pdf-tools et son serveur.

Point d'entrée unique pour toute cette famille de pannes : PDF qui
s'ouvrent dans doc-view, barre d'outils absente, option inconnue du
serveur.  Fait le geste adapté à la plateforme — aligner le Lisp sur le
serveur fourni, ou recompiler le serveur depuis les sources du Lisp."
  (interactive)
  (if (metal-pdf-serveur-pilote-par-le-serveur-p)
      (cond
       ((progn
          ;; Le serveur peut être là depuis une session précédente sans que
          ;; pdf-tools le sache : on rebranche avant de conclure quoi que
          ;; ce soit.
          (metal-pdf-serveur-brancher-programme)
          (not (metal-pdf-serveur-msys2-present-p)))
        (user-error "MSYS2 requis — installez-le depuis l'Assistant"))
       ((not (metal-pdf-serveur-version-installee))
        (metal-pdf-serveur-installer))
       ;; Serveur PLUS ANCIEN que la référence : on le met à jour plutôt
       ;; que de rétrograder le Lisp.  Un MSYS2 installé hors de MetalEmacs
       ;; et jamais mis à jour imposait sinon un pdf-tools aussi vieux que
       ;; lui.  L'installation fait `-Syu', puis aligne le Lisp sur la
       ;; version obtenue : si MSYS2 n'offre toujours pas la référence,
       ;; on retombe sur l'alignement vers le bas, qui au moins fonctionne.
       ((version< (metal-pdf-serveur-version-installee)
                  metal-pdf-version-attendue)
        (message "⬆ Serveur %s antérieur à la référence %s — mise à jour par MSYS2…"
                 (metal-pdf-serveur-version-installee)
                 metal-pdf-version-attendue)
        (metal-pdf-serveur-installer))
       (t
        (metal-pdf-serveur-aligner-straight)
        (metal-pdf-serveur--rafraichir-assistant)
        (message "%s" (metal-pdf-serveur--bilan-alignement
                       (metal-pdf-serveur-version-visee)))))
    ;; macOS, Linux : recompiler le serveur depuis les sources du Lisp.
    (if (fboundp 'pdf-tools-install)
        (progn
          (message "🔧 Compilation du serveur epdfinfo...")
          (pdf-tools-install t)
          (metal-pdf-serveur-noter-construction)
          (metal-pdf-serveur--rafraichir-assistant))
      (user-error "pdf-tools n'est pas chargé"))))

;;; --- Sous-processus : une liste d'arguments, jamais un shell -------------

(defconst metal-pdf-serveur-codage-msys2 'utf-8-unix
  "Codage de la sortie des outils MSYS2 (pacman), qui écrivent en UTF-8.")

(defconst metal-pdf-serveur-codage-windows
  (or locale-coding-system 'utf-8-unix)
  "Codage de la sortie des outils Windows natifs (scoop, PowerShell).
Eux suivent la page de codes du système, pas l'UTF-8.")

(defun metal-pdf-serveur--nom-console (etiquette)
  "Nom de tampon pour ETIQUETTE.
Emprunte la normalisation de `metal-deps.el' quand elle est chargée, ce
qui fait router le tampon vers la fenêtre de console dédiée plutôt que
de le laisser s'ouvrir n'importe où."
  (if (fboundp 'metal-console-nom)
      (metal-console-nom etiquette)
    (format "*%s*" etiquette)))

(defun metal-pdf-serveur--console (etiquette programme args)
  "Prépare et retourne le tampon de console d'ETIQUETTE.

Le tampon est VIDÉ et reçoit un en-tête portant la commande exacte.  Il
ne l'était pas : deux tentatives successives y empilaient leurs sorties,
et la même erreur affichée deux fois passait pour une commande exécutée
deux fois.  Sans l'en-tête, la commande lancée restait invisible — seul
son message d'échec parvenait à l'utilisateur."
  (let ((tampon (get-buffer-create (metal-pdf-serveur--nom-console etiquette))))
    (with-current-buffer tampon
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Marqué comme écho : le diagnostic des échecs ne doit lire que
        ;; ce que les processus ont écrit.  Le nom de paquet
        ;; « msys2-keyring » de la commande suffisait à faire prendre
        ;; n'importe quel échec pour un refus de signatures.
        (insert (propertize
                 (concat (format-time-string "[%H:%M:%S] ")
                         (mapconcat #'identity (cons programme args) " ") "\n"
                         (make-string 60 ?─) "\n")
                 'metal-console-echo t)))
      ;; Le tampon héritait du répertoire courant de l'Assistant.  Un
      ;; répertoire inexistant fait échouer le démarrage du processus
      ;; lui-même, avec un message qui n'a rien à voir avec la commande.
      (setq default-directory (expand-file-name "~/")))
    tampon))

(defun metal-pdf-serveur--enchainer (nom tampon programme etapes fin)
  "Lance à la suite chaque liste d'arguments d'ETAPES, et s'arrête au 1er échec.
FIN reçoit le code de sortie de la dernière étape exécutée — 0 si toutes
ont abouti.  Chaque commande est écrite dans TAMPON avant d'être lancée :
sans cet écho, une séquence qui échoue au milieu ne dit pas à quelle
étape.  ETAPES est une liste de listes d'arguments ; le shell n'intervient
toujours pas."
  (if (null etapes)
      (funcall fin 0)
    (with-current-buffer tampon
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (propertize
                 (concat "\n$ "
                         (mapconcat #'identity (cons programme (car etapes)) " ")
                         "\n")
                 'metal-console-echo t))))
    (metal-pdf-serveur--lancer
     nom tampon programme (car etapes)
     (lambda (code)
       (if (/= code 0)
           (funcall fin code)
         (metal-pdf-serveur--enchainer nom tampon programme (cdr etapes) fin))))))

(defconst metal-pdf-serveur--motif-signature
  (concat "PGP signature\\|signature from\\|unknown trust\\|marginal trust"
          "\\|Public keyring not found\\|keyring is not writable\\|clé inconnue")
  "Motifs par lesquels pacman dénonce un problème de trousseau.
Plus de « keyring » ni de « pacman-key » nus : ils trouvaient l'écho de
la commande (« … msys2-keyring ») et faisaient de tout échec un refus de
signatures.  Ne sert plus que de repli quand `metal-deps.el' est absent.
Cherchés seulement après un code de sortie non nul : un paquet dont la
signature est vérifiée sans incident n'en parle pas.")

(defvar metal-pdf-serveur-signatures-refusees nil
  "Non-nil quand pacman a refusé des signatures lors de la dernière tentative.

Drapeau PERSISTANT, à lire par l'Assistant.  La proposition de réparation
ne vivait que dans le minibuffer : un `C-g' ou une frappe au mauvais
moment, et elle disparaissait sans laisser de trace — l'utilisateur se
retrouvait devant un Assistant qui ne disait rien de plus qu'avant.  Levé
au premier échec de signature, abaissé à la première réussite.")

(defun metal-pdf-serveur--echec-signature-p (tampon)
  "Non-nil si la sortie de pacman dans TAMPON met en cause le trousseau."
  (and (buffer-live-p tampon)
       (with-current-buffer tampon
         (save-excursion
           (goto-char (point-min))
           (let ((case-fold-search t))
             (and (re-search-forward metal-pdf-serveur--motif-signature nil t)
                  t))))))

(defun metal-pdf-serveur--signaler-echec (tampon nom)
  "Signale l'échec de l'installation, TAMPON portant la sortie et NOM son nom.

Quand pacman a refusé des signatures, le message brut (« ❌ Échec ») ne
dit rien d'exploitable : c'est le trousseau qu'il faut rétablir, et
`metal-deps-msys2-reparer-trousseau' le fait.  La question part par un
timer plutôt que depuis la sentinelle elle-même : un `y-or-n-p' appelé
dans une sentinelle interrompt l'utilisateur au milieu de ce qu'il tape."
  (if (not (metal-pdf-serveur--echec-signature-p tampon))
      (message "❌ Échec de l'installation. Voir %s" nom)
    ;; Le drapeau vaut indépendamment de la suite : même si l'utilisateur
    ;; décline la réparation immédiate, l'Assistant doit continuer à
    ;; afficher la cause et le geste.
    (setq metal-pdf-serveur-signatures-refusees t)
    (metal-pdf-serveur--rafraichir-assistant)
    (message "❌ pacman a refusé les signatures — trousseau MSYS2 en cause")
    (unless (fboundp 'metal-deps-msys2-reparer-trousseau)
      (message "❌ Signatures refusées par pacman. Voir %s" nom))
    (run-with-timer
     0 nil
     (lambda ()
       (when (and (fboundp 'metal-deps-msys2-reparer-trousseau)
                  (y-or-n-p
                   "pacman refuse les signatures.  Rétablir le trousseau MSYS2 ? "))
         (metal-deps-msys2-reparer-trousseau))))))

;; Le verdict n'était écrit nulle part : `metal-pdf-serveur--lancer' ne
;; pose qu'une sentinelle muette, et une désinstallation réussie laissait
;; la console figée sur « removing … » sans rien dire de plus.  On ne peut
;; pas l'écrire dans `--lancer' lui-même : `--enchainer' l'appelle à
;; chaque étape, et un « Terminé » au milieu d'une séquence tromperait.
(defun metal-pdf-serveur--conclure (tampon code reussite echec)
  "Écrit le verdict de CODE à la fin de TAMPON et l'annonce.
REUSSITE et ECHEC sont les messages du minibuffer ; ECHEC reçoit le nom
du tampon en argument de `format'."
  (when (buffer-live-p tampon)
    (with-current-buffer tampon
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (if (= code 0)
                    "\n✓ Terminé.\n"
                  (format "\n⚠ Échec (code %d).\n" code))))))
  (if (= code 0)
      (message "%s" reussite)
    (message echec (if (buffer-live-p tampon) (buffer-name tampon) "la console"))))

(defun metal-pdf-serveur--lancer (nom tampon programme args suite &optional codage)
  "Lance PROGRAMME avec ARGS dans TAMPON ; appelle SUITE avec le code de sortie.
ARGS est une liste transmise telle quelle : aucun shell n'intervient, donc
aucune citation à faire ni à défaire.  CODAGE vaut par défaut celui de
MSYS2."
  (let* ((coding-system-for-read (or codage metal-pdf-serveur-codage-msys2))
         (coding-system-for-write coding-system-for-read)
         (proc (apply #'start-process nom tampon programme args)))
    (set-process-sentinel
     proc
     (lambda (p _e)
       (when (eq (process-status p) 'exit)
         (funcall suite (process-exit-status p)))))
    proc))

;;; --- Trousseau pacman (Windows) ------------------------------------------
;;
;; L'installateur officiel de MSYS2 crée le trousseau de signatures à son
;; premier lancement.  Scoop, lui, se contente de déposer l'archive : sans
;; ce premier démarrage, tout `pacman -S' échoue en série sur les
;; signatures PGP.  `metal-deps.el' greffe bien ce démarrage sur son bouton
;; « MSYS2 », mais par un timer plafonné à vingt minutes : MSYS2 installé
;; autrement, ou Emacs redémarré entre-temps, et la garantie disparaît.  On
;; la reprend donc ici, juste avant d'en avoir besoin, et à partir de la
;; racine que CE fichier a résolue.

(defun metal-pdf-serveur--trousseau-present-p ()
  "Non-nil si le trousseau pacman de MSYS2 existe déjà."
  (let ((racine (metal-pdf-serveur-msys2-racine)))
    (and racine
         (file-exists-p
          (expand-file-name "etc/pacman.d/gnupg/pubring.gpg" racine)))))

(defun metal-pdf-serveur--initialiser-trousseau (suite)
  "Fait le premier démarrage de MSYS2 si nécessaire, puis appelle SUITE.

DEUX passages sont nécessaires : le premier crée le trousseau et
l'arborescence, le second termine la mise à jour du runtime.  Les options
comptent — `-defterm' évite l'ouverture d'une fenêtre mintty, `-no-start'
empêche le détachement du processus, sans quoi la suite s'enchaînerait
alors que les scripts tournent encore."
  (let* ((racine (metal-pdf-serveur-msys2-racine))
         (script (and racine (expand-file-name "msys2_shell.cmd" racine)))
         (options '("-defterm" "-no-start" "-here" "-c" "exit")))
    (if (or (null script)
            (not (file-exists-p script))
            (metal-pdf-serveur--trousseau-present-p))
        (funcall suite)
      (let ((tampon (metal-pdf-serveur--console "MSYS2 Init" script options))
            (restants 2))
        (display-buffer tampon)
        (message "⏳ Premier démarrage de MSYS2 — patientez…")
        (letrec ((passe
                  (lambda (_code)
                    (setq restants (1- restants))
                    (if (> restants 0)
                        (metal-pdf-serveur--lancer
                         "msys2-init" tampon script options passe)
                      (funcall suite)))))
          (metal-pdf-serveur--lancer
           "msys2-init" tampon script options passe))))))

;;; --- Installation, depuis l'Assistant ------------------------------------

;;;###autoload
(defun metal-pdf-serveur-installer-msys2 ()
  "Installe MSYS2 via Scoop.
MSYS2 fournit le serveur epdfinfo et ses DLL sous Windows."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "MSYS2 ne concerne que Windows"))
  (if (metal-pdf-serveur-msys2-present-p)
      (message "✓ MSYS2 déjà installé")
    (unless (executable-find "scoop")
      (user-error "⚠ Scoop requis — installez-le d'abord depuis l'Assistant"))
    (message "📦 Installation de MSYS2 (~1 Go, plusieurs minutes)...")
    (let* ((scoop (executable-find "scoop"))
           (args '("install" "msys2"))
           (tampon (metal-pdf-serveur--console "MSYS2 Install" scoop args)))
      (display-buffer tampon)
      (metal-pdf-serveur--lancer
       "msys2-install" tampon scoop args
       (lambda (code)
         (metal-pdf-serveur--conclure
          tampon code
          "✅ MSYS2 installé — installez le serveur epdfinfo"
          "❌ Échec de l'installation de MSYS2. Voir %s")
         (metal-pdf-serveur--rafraichir-assistant))
       metal-pdf-serveur-codage-windows))))

;;;###autoload
(defun metal-pdf-serveur-desinstaller-msys2 ()
  "Retire MSYS2 via Scoop.  Le serveur epdfinfo part avec lui."
  (interactive)
  (unless (metal-pdf-serveur-msys2-present-p)
    (user-error "MSYS2 n'est pas installé"))
  (when (yes-or-no-p "Retirer MSYS2 ? Les PDF repasseront à doc-view ")
    (let ((scoop (executable-find "scoop"))
          (args '("uninstall" "msys2")))
      (unless scoop (user-error "Scoop introuvable"))
      ;; Un gpg-agent ou un pacman orphelin garde des fichiers de MSYS2
      ;; ouverts : Scoop ne pourrait pas les supprimer, et la
      ;; désinstallation laisserait un dossier à moitié vidé — celui sur
      ;; lequel toute réinstallation échoue ensuite.
      (when (and (fboundp 'metal-deps-msys2-degager)
                 (eq (metal-deps-msys2-degager) 'occupe))
        (user-error "Une opération MSYS2 est en cours — attendez qu'elle se termine"))
      (let ((tampon (metal-pdf-serveur--console "MSYS2 Uninstall" scoop args)))
        (display-buffer tampon)
        (metal-pdf-serveur--lancer
         "msys2-uninstall" tampon scoop args
         (lambda (code)
           (metal-pdf-serveur--conclure
            tampon code
            "✅ MSYS2 retiré"
            "❌ Échec de la désinstallation de MSYS2. Voir %s")
           (setq pdf-info-epdfinfo-program nil)
           (metal-pdf-serveur--rafraichir-assistant))
         metal-pdf-serveur-codage-windows)))))

;;;###autoload
(defun metal-pdf-serveur-installer ()
  "Installe le serveur epdfinfo depuis MSYS2, puis aligne le Lisp dessus.

Asynchrone : pacman télécharge plusieurs dizaines de paquets.  À la fin,
le Lisp bascule sur le commit correspondant à la version obtenue —
l'accord est donc acquis sans autre intervention."
  (interactive)
  (unless (metal-pdf-serveur-pilote-par-le-serveur-p)
    (user-error "Ici le serveur se compile : utilisez Réparer"))
  (let ((pacman (metal-pdf-serveur--pacman)))
    (unless pacman
      (user-error "MSYS2 introuvable — installez-le d'abord depuis l'Assistant"))
    ;; Nouvelle opération : chaque remède automatique redevient
    ;; disponible.  Puis déblocage préventif — un verrou ou un gpg-agent
    ;; laissés par une tentative interrompue ne doivent pas coûter un
    ;; premier échec.
    (when (fboundp 'metal-deps-msys2-nouvelle-operation)
      (metal-deps-msys2-nouvelle-operation))
    (when (and (fboundp 'metal-deps-msys2-degager)
               (eq (metal-deps-msys2-degager) 'occupe))
      (user-error "Une opération MSYS2 est déjà en cours — attendez qu'elle se termine"))
    ;; Le trousseau d'abord : sans lui, les deux appels qui suivent
    ;; échouent sur les signatures, avec un message que personne ne
    ;; rattache à MSYS2.
    (metal-pdf-serveur--initialiser-trousseau
     (lambda () (metal-pdf-serveur--installer-paquet pacman)))))

(defun metal-pdf-serveur--installer-paquet (pacman)
  "Met MSYS2 à jour puis installe le paquet du serveur, avec PACMAN.

TROIS appels séparés, enchaînés par les sentinelles.  Ils étaient réunis
par un `&&' dans une chaîne de shell : c'est ce passage par cmd.exe qui
rendait le chemin de pacman introuvable.

Le TROUSSEAU d'abord, seul.  `msys2-keyring' porte les clés reconnues et
révoquées, et il est lui-même signé : tant qu'il est périmé, tout le
reste échoue en cascade sur les signatures, sans que le message n'indique
jamais la cause.  Le mettre à jour en premier est aussi la seule séquence
qui fonctionne — un trousseau utilisable est requis pour vérifier la
signature de sa propre mise à jour.

Puis `-Syu' plutôt que `-Sy' : synchroniser les dépôts sans mettre à jour
les paquets installés est la mise à jour partielle que la documentation
de MSYS2 déconseille — elle laisse des dépendances incohérentes que
l'installation suivante paie."
  (message "📦 Installation du serveur epdfinfo (plusieurs minutes)...")
  ;; `--disable-download-timeout' : pacman abandonne par défaut un
  ;; téléchargement lent au bout de dix secondes, ce qui suffit à faire
  ;; échouer l'installation sur un réseau de campus chargé.
  (let* ((trousseau '("-Sy" "--needed" "--noconfirm"
                      "--disable-download-timeout" "msys2-keyring"))
         (maj '("-Syu" "--noconfirm" "--disable-download-timeout"))
         (pose (list "-S" "--needed" "--noconfirm" "--disable-download-timeout"
                     metal-pdf-serveur-paquet-msys2))
         (tampon (metal-pdf-serveur--console "epdfinfo Install" pacman nil))
         (nom (buffer-name tampon)))
    (display-buffer tampon)
    (metal-pdf-serveur--enchainer
     ;; `-Syu' DEUX fois : sur un MSYS2 ancien, le premier passage ne met
     ;; à jour que le cœur (runtime, pacman) et s'arrête là ; le second
     ;; fait le reste.  Sur un MSYS2 à jour, le second ne fait rien.
     "epdfinfo-install" tampon pacman (list trousseau maj maj pose)
     (lambda (code)
       (if (/= code 0)
           ;; Autoréparation : diagnostic, remède, nouvel essai — sans
           ;; question.  Le repli sur l'ancien signalement ne sert que si
           ;; `metal-deps.el' n'est pas chargé.
           (if (fboundp 'metal-deps-msys2-traiter-echec)
               (metal-deps-msys2-traiter-echec
                tampon
                (lambda () (metal-pdf-serveur--installer-paquet pacman)))
             (metal-pdf-serveur--signaler-echec tampon nom))
         (metal-pdf-serveur--conclure tampon 0 "" "")
         (setq metal-pdf-serveur-signatures-refusees nil)
         (when (boundp 'metal-deps-msys2-dernier-echec)
           (setq metal-deps-msys2-dernier-echec nil))
         (metal-pdf-serveur-invalider-etat)
         (metal-pdf-serveur-brancher-programme)
         (let ((v (metal-pdf-serveur-version-installee)))
           (if (null v)
               (message "❌ Paquet installé mais version illisible")
             (metal-pdf-serveur-aligner-straight)
             (message "✅ Serveur %s installé. %s" v
                      (metal-pdf-serveur--bilan-alignement v)))))
       (metal-pdf-serveur--rafraichir-assistant)))))

;;;###autoload
(defun metal-pdf-serveur-desinstaller ()
  "Retire le paquet MSYS2 fournissant le serveur epdfinfo."
  (interactive)
  (let ((pacman (metal-pdf-serveur--pacman)))
    (unless pacman (user-error "MSYS2 introuvable"))
    (unless (metal-pdf-serveur-version-installee)
      (user-error "Le serveur epdfinfo n'est pas installé"))
    (when (yes-or-no-p
           "Retirer le serveur epdfinfo ? Les PDF passeront à doc-view ")
      (let* ((args (list "-R" "--noconfirm" metal-pdf-serveur-paquet-msys2))
             (tampon (metal-pdf-serveur--console "epdfinfo Uninstall"
                                                 pacman args)))
        (display-buffer tampon)
        (metal-pdf-serveur--lancer
         "epdfinfo-uninstall" tampon pacman args
         (lambda (code)
           (metal-pdf-serveur--conclure
            tampon code
            "✅ Serveur epdfinfo retiré — les PDF s'ouvriront dans doc-view"
            "❌ Échec du retrait du serveur epdfinfo. Voir %s")
           (setq pdf-info-epdfinfo-program nil)
           (metal-pdf-serveur--rafraichir-assistant)))))))

;; Le branchement doit avoir lieu au CHARGEMENT : c'est au démarrage que
;; pdf-tools résout son serveur, et un binaire installé lors d'une session
;; précédente resterait autrement ignoré.
(when (eq system-type 'windows-nt)
  (metal-pdf-serveur-brancher-programme))

(provide 'metal-pdf-serveur)
;;; metal-pdf-serveur.el ends here
