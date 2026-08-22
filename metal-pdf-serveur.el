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

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'metal-pdf-version)

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

(defun metal-pdf-serveur--commit-de-version (version)
  "Commit de la balise vVERSION dans le dépôt amont, ou nil.

Trois sources dans l'ordre, pour n'atteindre le réseau qu'en dernier
recours : la version de référence, le cache d'un accord précédent, puis
`git ls-remote'."
  (cond
   ((null version) nil)
   ((string= version metal-pdf-version-attendue) metal-pdf-commit-attendu)
   ((let ((c (metal-pdf-serveur--lire-cache)))
      (and c (string= (car c) version) (cdr c))))
   (t
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

(defun metal-pdf-serveur-commit-vise ()
  "Commit que le clone straight doit porter, ou nil."
  (metal-pdf-serveur--commit-de-version (metal-pdf-serveur-version-visee)))

;;; --- Alignement ----------------------------------------------------------

(defun metal-pdf-serveur--journal (fmt &rest args)
  "Journalise dans *Messages* sans encombrer l'écho."
  (let ((message-log-max t))
    (message "MetalEmacs : %s" (apply #'format fmt args))))

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
        (vise (metal-pdf-serveur-commit-vise)))
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
            (metal-pdf-serveur--journal
             "pdf-tools : Lisp aligné sur le serveur — %s vers %s (%s)"
             (substring clone 0 12) (substring vise 0 12)
             (metal-pdf-serveur-version-visee))
            (when (fboundp 'straight-rebuild-package)
              (ignore-errors (straight-rebuild-package "pdf-tools" t)))
            (metal-pdf-serveur--ecrire-cache
             (metal-pdf-serveur-version-visee) vise)
            t)
        (metal-pdf-serveur--journal
         "pdf-tools : bascule vers %s IMPOSSIBLE — le Lisp reste en %s"
         (substring vise 0 12) (substring clone 0 12))
        nil)))))

;;; --- État, pour l'Assistant ----------------------------------------------

(defun metal-pdf-serveur-etat ()
  "État de l'accord, sous forme (SYMBOLE . DÉTAIL).

  sans-msys2    — Windows sans MSYS2 : pas de serveur possible
  absent        — aucun serveur epdfinfo utilisable
  sans-clone    — le paquet Lisp n'est pas encore cloné
  indetermine   — version du serveur non résoluble en commit
  ok            — Lisp et serveur accordés ; DÉTAIL porte la version
  a-aligner     — accord à rétablir ; DÉTAIL porte la version du serveur

Lecture pure : pas d'écriture, et pas de réseau tant que la version
visée est celle de référence ou celle du cache."
  (let ((clone (metal-pdf-serveur--commit-clone))
        (pilote (metal-pdf-serveur-pilote-par-le-serveur-p)))
    (cond
     ((and pilote (not (metal-pdf-serveur-msys2-present-p)))
      (cons 'sans-msys2 nil))
     ((and pilote (not (metal-pdf-serveur-version-installee)))
      (cons 'absent nil))
     ((and (not pilote)
           (not (and (boundp 'pdf-info-epdfinfo-program)
                     pdf-info-epdfinfo-program
                     (file-executable-p pdf-info-epdfinfo-program))))
      (cons 'absent nil))
     ((null clone) (cons 'sans-clone nil))
     (t
      (let ((vise (metal-pdf-serveur-commit-vise))
            (v (metal-pdf-serveur-version-visee)))
        (cond
         ((null vise) (cons 'indetermine v))
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
      ('indetermine
       (format "serveur %s — version amont introuvable, accord non vérifiable" v))
      ('ok (if (string= v metal-pdf-version-attendue)
               (format "accordé (%s)" v)
             (format "accordé (%s ; référence %s)" v metal-pdf-version-attendue)))
      ('a-aligner (format "serveur %s, Lisp désaccordé — bouton Réparer" v))
      (_ "état indéterminé"))))

;;; --- Réparation : point d'entrée unique ----------------------------------

(defun metal-pdf-serveur--rafraichir-assistant ()
  "Redessine l'Assistant s'il est affiché."
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
       ((not (metal-pdf-serveur-msys2-present-p))
        (user-error "MSYS2 requis — installez-le depuis l'Assistant"))
       ((not (metal-pdf-serveur-version-installee))
        (metal-pdf-serveur-installer))
       ((metal-pdf-serveur-aligner-straight)
        (metal-pdf-serveur--rafraichir-assistant)
        (message "✅ Lisp aligné sur le serveur %s — redémarrez Emacs"
                 (metal-pdf-serveur-version-visee)))
       (t (message "✓ Déjà accordé (%s)" (metal-pdf-serveur-version-visee))))
    ;; macOS, Linux : recompiler le serveur depuis les sources du Lisp.
    (if (fboundp 'pdf-tools-install)
        (progn
          (message "🔧 Compilation du serveur epdfinfo...")
          (pdf-tools-install t)
          (metal-pdf-serveur-noter-construction)
          (metal-pdf-serveur--rafraichir-assistant))
      (user-error "pdf-tools n'est pas chargé"))))

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
    (let ((tampon "*MSYS2 Install*"))
      (set-process-sentinel
       (start-process-shell-command "msys2-install" tampon "scoop install msys2")
       (lambda (proc _e)
         (when (eq (process-status proc) 'exit)
           (if (= (process-exit-status proc) 0)
               (message "✅ MSYS2 installé — installez le serveur epdfinfo")
             (message "❌ Échec. Voir %s" tampon))
           (metal-pdf-serveur--rafraichir-assistant))))
      (display-buffer tampon))))

;;;###autoload
(defun metal-pdf-serveur-desinstaller-msys2 ()
  "Retire MSYS2 via Scoop.  Le serveur epdfinfo part avec lui."
  (interactive)
  (unless (metal-pdf-serveur-msys2-present-p)
    (user-error "MSYS2 n'est pas installé"))
  (when (yes-or-no-p "Retirer MSYS2 ? Les PDF repasseront à doc-view ")
    (let ((tampon "*MSYS2 Uninstall*"))
      (set-process-sentinel
       (start-process-shell-command "msys2-uninstall" tampon
                                    "scoop uninstall msys2")
       (lambda (_p _e) (metal-pdf-serveur--rafraichir-assistant)))
      (display-buffer tampon))))

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
    (message "📦 Installation du serveur epdfinfo (plusieurs minutes)...")
    (let* ((tampon "*epdfinfo Install*")
           (q (shell-quote-argument pacman))
           (cmd (format "%s -Sy --noconfirm && %s -S --needed --noconfirm %s"
                        q q metal-pdf-serveur-paquet-msys2)))
      (set-process-sentinel
       (start-process-shell-command "epdfinfo-install" tampon cmd)
       (lambda (proc _e)
         (when (eq (process-status proc) 'exit)
           (if (/= (process-exit-status proc) 0)
               (message "❌ Échec de l'installation. Voir %s" tampon)
             (let ((v (metal-pdf-serveur-version-installee)))
               (if (null v)
                   (message "❌ Paquet installé mais version illisible")
                 (metal-pdf-serveur-aligner-straight)
                 (message "✅ Serveur %s installé, Lisp aligné — redémarrez Emacs"
                          v))))
           (metal-pdf-serveur--rafraichir-assistant))))
      (display-buffer tampon))))

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
      (let ((tampon "*epdfinfo Uninstall*"))
        (set-process-sentinel
         (start-process-shell-command
          "epdfinfo-uninstall" tampon
          (format "%s -R --noconfirm %s" (shell-quote-argument pacman)
                  metal-pdf-serveur-paquet-msys2))
         (lambda (_p _e) (metal-pdf-serveur--rafraichir-assistant)))
        (display-buffer tampon)))))

(provide 'metal-pdf-serveur)
;;; metal-pdf-serveur.el ends here
