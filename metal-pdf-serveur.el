;;; metal-pdf-serveur.el --- Serveur epdfinfo : état et mise à jour -*- coding: utf-8; lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, pdf

;;; Commentary:
;;
;; Deux responsabilités, volontairement séparées :
;;
;;   LECTURE  — `metal-pdf-serveur-etat' et `metal-pdf-serveur-etat-ligne'
;;              n'écrivent rien.  L'Assistant (metal-deps.el) les appelle
;;              pour afficher l'état du serveur epdfinfo.
;;
;;   ÉCRITURE — `metal-pdfinfo-mise-a-jour', disponible seulement par M-x,
;;              installe le paquet MSYS2, recalcule le commit et réécrit
;;              metal-pdf-version.el.  Destinée au mainteneur : les
;;              étudiants reçoivent le résultat par `git pull', ils ne
;;              lancent jamais cette commande.
;;
;; Sous Windows, le serveur vient du paquet MSYS2
;; `mingw-w64-x86_64-emacs-pdf-tools-server'.  Son intérêt principal :
;; epdfinfo.exe y côtoie toutes ses DLL MinGW dans le même répertoire,
;; ce qui évite le conflit classique avec les bibliothèques de Git for
;; Windows.

;;; Code:

(require 'cl-lib)
(require 'metal-pdf-version)

(defgroup metal-pdf-serveur nil
  "Gestion du serveur epdfinfo de pdf-tools."
  :group 'metal-pdf
  :prefix "metal-pdf-serveur-")

(defcustom metal-pdf-serveur-msys2-racine nil
  "Racine de l'installation MSYS2 sous Windows.
Nil signifie détection automatique parmi
`metal-pdf-serveur-msys2-racines-candidates'.  Ne fixer une valeur que
si MSYS2 vit à un endroit inhabituel."
  :type '(choice (const :tag "Détection automatique" nil) directory)
  :group 'metal-pdf-serveur)

(defun metal-pdf-serveur-msys2-racines-candidates ()
  "Emplacements où chercher MSYS2, du plus probable au moins probable.
Scoop vient en premier : c'est le canal d'installation retenu par
MetalEmacs sous Windows, et il n'installe pas dans C:/msys64."
  (delq nil
        (list (getenv "MSYS2_ROOT")
              (expand-file-name "scoop/apps/msys2/current/" (or (getenv "USERPROFILE") "~"))
              (expand-file-name "scoop/apps/msys2/current/" "~")
              "C:/msys64/"
              "C:/tools/msys64/"
              (expand-file-name "msys64/" (or (getenv "LOCALAPPDATA") "~")))))

(defun metal-pdf-serveur-msys2-racine ()
  "Racine MSYS2 effectivement utilisable, ou nil.
Retourne `metal-pdf-serveur-msys2-racine' si elle est fixée et valide,
sinon la première candidate contenant pacman.exe."
  (cl-find-if
   (lambda (r) (and r (file-executable-p (expand-file-name "usr/bin/pacman.exe" r))))
   (if metal-pdf-serveur-msys2-racine
       (list metal-pdf-serveur-msys2-racine)
     (metal-pdf-serveur-msys2-racines-candidates))))

(defconst metal-pdf-serveur-paquet-msys2
  "mingw-w64-x86_64-emacs-pdf-tools-server"
  "Nom du paquet MSYS2 fournissant epdfinfo.exe et ses DLL.")

(defconst metal-pdf-serveur-depot "https://github.com/vedang/pdf-tools"
  "Dépôt amont, interrogé pour résoudre une version en commit.")

(defvar metal-pdf-serveur-fichier-version
  (expand-file-name "metal-pdf-version.el" user-emacs-directory)
  "Fichier réécrit par `metal-pdfinfo-mise-a-jour'.")

;;; --- Accès à MSYS2 (lecture seule) ---------------------------------------

(defun metal-pdf-serveur--pacman ()
  "Chemin de pacman.exe, ou nil si MSYS2 est introuvable."
  (let ((racine (metal-pdf-serveur-msys2-racine)))
    (when racine
      (expand-file-name "usr/bin/pacman.exe" racine))))

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

(defun metal-pdf-serveur--analyser-q (sortie)
  "Extrait la version d'une SORTIE de `pacman -Q'.
Le nom du paquet contient des chiffres (w64, x86_64) : on prend le
dernier champ de la première ligne, jamais le premier nombre trouvé."
  (when (stringp sortie)
    (let ((ligne (car (split-string sortie "\n" t))))
      (when ligne
        (metal-pdf-serveur--version-nue
         (car (last (split-string ligne "[ \t]+" t))))))))

(defun metal-pdf-serveur--analyser-si (sortie)
  "Extrait la version d'une SORTIE de `pacman -Si'."
  (when (and (stringp sortie)
             (string-match "^Version[ \t]*:[ \t]*\\([^ \t\n]+\\)" sortie))
    (metal-pdf-serveur--version-nue (match-string 1 sortie))))

(defun metal-pdf-serveur-version-installee ()
  "Version du paquet MSYS2 installé, ou nil."
  (metal-pdf-serveur--analyser-q
   (metal-pdf-serveur--pacman-sortie "-Q" metal-pdf-serveur-paquet-msys2)))

(defun metal-pdf-serveur-version-disponible ()
  "Version du paquet MSYS2 offerte par les dépôts, ou nil.
N'actualise pas la base : lancer `pacman -Sy' au préalable pour une
réponse à jour."
  (metal-pdf-serveur--analyser-si
   (metal-pdf-serveur--pacman-sortie "-Si" metal-pdf-serveur-paquet-msys2)))

(defun metal-pdf-serveur-programme ()
  "Chemin d'epdfinfo.exe fourni par MSYS2, ou nil.
Le binaire y côtoie ses DLL MinGW, ce qui évite le conflit classique
avec les bibliothèques de Git for Windows."
  (let ((racine (metal-pdf-serveur-msys2-racine)))
    (when racine
      (let ((exe (expand-file-name "mingw64/bin/epdfinfo.exe" racine)))
        (and (file-executable-p exe) exe)))))

;;; --- Témoin de construction (macOS, Linux) -------------------------------

;; Hors Windows, le serveur est compilé par straight/pdf-tools et non fourni
;; par un gestionnaire de paquets : aucune version n'est interrogeable.  On
;; dépose donc un témoin après chaque construction réussie, contenant le
;; commit épinglé au moment de la construction.  L'état devient alors la
;; même comparaison sur les trois plateformes.

(defvar metal-pdf-serveur-fichier-temoin
  (expand-file-name ".epdfinfo-commit" user-emacs-directory)
  "Fichier notant le commit à partir duquel le serveur a été construit.")

(defun metal-pdf-serveur-noter-construction ()
  "Note que le serveur courant provient de `metal-pdf-commit-attendu'.
À appeler juste après un `pdf-tools-install' réussi."
  (ignore-errors
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file metal-pdf-serveur-fichier-temoin
        (insert metal-pdf-commit-attendu "\n")))))

(defun metal-pdf-serveur-commit-construit ()
  "Commit noté par le dernier `metal-pdf-serveur-noter-construction', ou nil."
  (when (file-readable-p metal-pdf-serveur-fichier-temoin)
    (with-temp-buffer
      (insert-file-contents metal-pdf-serveur-fichier-temoin)
      (let ((s (string-trim (buffer-string))))
        (and (string-match-p "\\`[0-9a-f]\\{40\\}\\'" s) s)))))

;;; --- État, pour l'Assistant ----------------------------------------------

(defun metal-pdf-serveur--etat-temoin ()
  "État hors Windows, déduit du binaire et du témoin de construction."
  (let ((exe (and (boundp 'pdf-info-epdfinfo-program)
                  pdf-info-epdfinfo-program)))
    (cond
     ((not (and exe (file-executable-p exe))) (cons 'absent nil))
     (t
      (let ((c (metal-pdf-serveur-commit-construit)))
        (cond
         ((null c) (cons 'inconnu nil))
         ((string= c metal-pdf-commit-attendu) (cons 'ok metal-pdf-version-attendue))
         (t (cons 'desaccorde (substring c 0 12)))))))))

(defun metal-pdf-serveur-etat ()
  "État du serveur epdfinfo, sous forme (SYMBOLE . DÉTAIL).

  sans-msys2   — Windows sans MSYS2, le paquet ne peut pas être interrogé
  absent       — aucun binaire epdfinfo utilisable
  inconnu      — binaire présent, origine inconnue (aucun témoin)
  ok           — serveur accordé à la version épinglée
  desaccorde   — serveur et Lisp désaccordés ; DÉTAIL porte ce qui est installé

Sous Windows, la comparaison se fait sur la version du paquet MSYS2 ;
ailleurs, sur le témoin de construction.  Fonction de lecture pure :
aucun appel réseau, aucune écriture."
  (if (eq system-type 'windows-nt)
      (cond
       ((null (metal-pdf-serveur--pacman)) (cons 'sans-msys2 nil))
       (t
        (let ((v (metal-pdf-serveur-version-installee)))
          (cond
           ((null v) (cons 'absent nil))
           ((string= v metal-pdf-version-attendue) (cons 'ok v))
           (t (cons 'desaccorde v))))))
    (metal-pdf-serveur--etat-temoin)))

(defun metal-pdf-serveur-etat-ligne ()
  "Ligne d'état lisible, destinée à l'Assistant."
  (let* ((etat (metal-pdf-serveur-etat))
         (sym (car etat))
         (v (cdr etat)))
    (pcase sym
      ('sans-msys2 "MSYS2 absent — serveur non vérifiable")
      ('absent (format "non installé (attendu %s)" metal-pdf-version-attendue))
      ('inconnu (format "présent, origine inconnue (attendu %s)"
                        metal-pdf-version-attendue))
      ('ok (format "accordé (%s)" v))
      ('desaccorde
       (format "%s installé, %s attendu — les PDF peuvent mal s'ouvrir"
               v metal-pdf-version-attendue))
      (_ "état indéterminé"))))

;;; --- Résolution version vers commit --------------------------------------

(defun metal-pdf-serveur--commit-de-version (version)
  "Commit git de la balise vVERSION dans le dépôt amont, ou nil.
Préfère l'entrée déréférencée « ^{} », qui donne le commit lui-même
plutôt que l'objet de balise annotée."
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
                   (match-string 1 texte))))))))

;;; --- Écriture du fichier de version --------------------------------------

(defun metal-pdf-serveur--contenu-version (version commit)
  "Texte complet de metal-pdf-version.el pour VERSION et COMMIT."
  (concat
   ";;; metal-pdf-version.el --- Version pdf-tools -*- lexical-binding: t -*-\n"
   ";;; -*- coding: utf-8 -*-\n\n"
   ";; Author: Jacques Ladouceur\n"
   ";; Keywords: tools, pdf\n\n"
   ";;; Commentary:\n;;\n"
   ";; Source unique de vérité pour la version de pdf-tools retenue par\n"
   ";; MetalEmacs.  Lue par init.el (le `:commit' de la recette\n"
   ";; straight.el), par metal-deps.el (affichage) et par\n"
   ";; metal-pdf-serveur.el (comparaison).\n;;\n"
   ";; FICHIER GÉNÉRÉ — réécrit par `M-x metal-pdfinfo-mise-a-jour'.\n\n"
   ";;; Code:\n\n"
   (format "(defconst metal-pdf-version-attendue %S\n" version)
   "  \"Version de pdf-tools épinglée pour toute la distribution.\n"
   "Le serveur `epdfinfo' installé doit porter cette version, sinon le\n"
   "Lisp et le binaire se désaccordent.\")\n\n"
   (format "(defconst metal-pdf-commit-attendu %S\n" commit)
   "  \"Commit git correspondant à la balise v`metal-pdf-version-attendue'.\n"
   "Utilisé comme `:commit' dans la recette straight.el de pdf-tools.\")\n\n"
   "(provide 'metal-pdf-version)\n"
   ";;; metal-pdf-version.el ends here\n"))

(defun metal-pdf-serveur--ecrire-version (version commit)
  "Réécrit `metal-pdf-serveur-fichier-version' avec VERSION et COMMIT.

Le contenu est assemblé en mémoire puis écrit par `write-region'.
Passer par un tampon (`with-temp-file' + `insert') exposerait le texte
aux hooks de modification et de remplissage de la configuration
courante : une seule coupure dans la ligne d'en-tête suffit à sortir le
cookie `lexical-binding' de son commentaire, et le fichier devient
inchargeable au démarrage suivant.  Les lignes sont en outre gardées
sous 80 colonnes."
  (let ((coding-system-for-write 'utf-8-dos))
    (write-region (metal-pdf-serveur--contenu-version version commit)
                  nil metal-pdf-serveur-fichier-version nil 'silencieux)))

;;;###autoload
(defun metal-pdf-serveur-accorde-p ()
  "Retourne non-nil si le serveur epdfinfo est accordé au Lisp épinglé."
  (eq (car (metal-pdf-serveur-etat)) 'ok))


;;; --- Installation (actions de l'Assistant) -------------------------------

(defun metal-pdf-serveur-msys2-present-p ()
  "Retourne non-nil si MSYS2 est installé et utilisable."
  (and (metal-pdf-serveur-msys2-racine) t))

;;;###autoload
(defun metal-pdf-serveur-installer-msys2 ()
  "Installe MSYS2 via Scoop.
MSYS2 fournit `pacman', par lequel MetalEmacs installe le serveur
epdfinfo et ses DLL MinGW sous Windows."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "MSYS2 ne concerne que Windows"))
  (if (metal-pdf-serveur-msys2-present-p)
      (message "✓ MSYS2 déjà installé")
    (unless (executable-find "scoop")
      (user-error "⚠ Scoop requis — installez-le d'abord depuis l'Assistant"))
    (message "📦 Installation de MSYS2 via Scoop (plusieurs minutes)...")
    (let ((tampon "*MSYS2 Install*"))
      (set-process-sentinel
       (start-process-shell-command "msys2-install" tampon "scoop install msys2")
       (lambda (proc _e)
         (when (eq (process-status proc) 'exit)
           (if (= (process-exit-status proc) 0)
               (message "✅ MSYS2 installé — installez maintenant le serveur epdfinfo")
             (message "❌ Échec de l'installation de MSYS2. Voir %s" tampon))
           (metal-pdf-serveur--rafraichir-assistant))))
      (display-buffer tampon))))

(defun metal-pdf-serveur--rafraichir-assistant ()
  "Redessine l'Assistant s'il est affiché."
  (when (and (fboundp 'metal-deps-afficher-etat)
             (get-buffer "*MetalEmacs Assistant*")
             (get-buffer-window "*MetalEmacs Assistant*" t))
    (ignore-errors (metal-deps-afficher-etat))))

;;;###autoload
(defun metal-pdf-serveur-installer ()
  "Installe ou réinstalle le serveur epdfinfo depuis MSYS2.

Asynchrone : `pacman' télécharge plusieurs dizaines de paquets et
l'opération dure plusieurs minutes, pendant lesquelles Emacs reste
utilisable.  La sortie défile dans un tampon dédié.

Ne peut pas corriger un désaccord de version : les dépôts MSYS2 n'offrent
qu'une version à la fois.  Si elle diffère de la version épinglée, le
correctif appartient au mainteneur, qui relance
`metal-pdfinfo-mise-a-jour' et publie le résultat."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "Sous macOS et Linux, le serveur se construit par M-x pdf-tools-install"))
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
               (cond
                ((null v) (message "❌ Paquet installé mais version illisible"))
                ((string= v metal-pdf-version-attendue)
                 (message "✅ Serveur epdfinfo %s installé — redémarrez Emacs" v))
                (t
                 (message
                  (concat "⚠ Serveur %s installé alors que MetalEmacs attend %s. "
                          "Signalez-le : seul le mainteneur peut réaccorder la version")
                  v metal-pdf-version-attendue)))))
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
    (when (yes-or-no-p "Retirer le serveur epdfinfo ? Les PDF passeront à doc-view ")
      (let ((tampon "*epdfinfo Uninstall*"))
        (set-process-sentinel
         (start-process-shell-command
          "epdfinfo-uninstall" tampon
          (format "%s -R --noconfirm %s"
                  (shell-quote-argument pacman)
                  metal-pdf-serveur-paquet-msys2))
         (lambda (_p _e) (metal-pdf-serveur--rafraichir-assistant)))
        (display-buffer tampon)))))

(defun metal-pdf-serveur-desinstaller-msys2 ()
  "Retire MSYS2 via Scoop.
Le serveur epdfinfo disparaît avec lui : les PDF repasseront à doc-view."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "MSYS2 ne concerne que Windows"))
  (unless (metal-pdf-serveur-msys2-present-p)
    (user-error "MSYS2 n'est pas installé"))
  (when (yes-or-no-p
         "Retirer MSYS2 ? Le serveur epdfinfo part avec, les PDF passeront à doc-view ")
    (let ((tampon "*MSYS2 Uninstall*"))
      (set-process-sentinel
       (start-process-shell-command "msys2-uninstall" tampon "scoop uninstall msys2")
       (lambda (proc _e)
         (when (eq (process-status proc) 'exit)
           (if (= (process-exit-status proc) 0)
               (message "MSYS2 retiré — redémarrez Emacs")
             (message "❌ Échec du retrait. Voir %s" tampon))
           (metal-pdf-serveur--rafraichir-assistant))))
      (display-buffer tampon))))

;;; --- Alignement du clone straight ----------------------------------------

;; straight.el ne rebascule pas un dépôt déjà cloné lorsque le `:commit' de
;; la recette change : il conserve le clone existant.  Après une mise à jour
;; de l'épinglage — la tienne par `metal-pdfinfo-mise-a-jour', celle des
;; étudiants par `git pull' — le Lisp resterait donc à l'ancienne version
;; pendant que le binaire passe à la nouvelle.  C'est précisément le
;; désaccord que tout ce module cherche à éviter.  On compare donc le HEAD
;; du clone au commit attendu, et on purge s'il diffère : straight reclone
;; alors au bon commit au démarrage suivant.

(defun metal-pdf-serveur--dossiers-straight ()
  "Les dossiers straight de pdf-tools : dépôt et compilation."
  (list (expand-file-name "straight/repos/pdf-tools" user-emacs-directory)
        (expand-file-name "straight/build/pdf-tools" user-emacs-directory)))

(defun metal-pdf-serveur--commit-clone ()
  "HEAD du clone straight de pdf-tools, ou nil s'il n'existe pas."
  (let ((depot (car (metal-pdf-serveur--dossiers-straight))))
    (when (file-directory-p depot)
      (with-temp-buffer
        (when (= 0 (call-process "git" nil t nil "-C" depot "rev-parse" "HEAD"))
          (let ((s (string-trim (buffer-string))))
            (and (string-match-p "\\`[0-9a-f]\\{40\\}\\'" s) s)))))))

;;;###autoload
(defun metal-pdf-serveur-purger-straight ()
  "Supprime les dossiers straight de pdf-tools.
straight les recrée au démarrage suivant, sur la branche par défaut ;
`metal-pdf-serveur-aligner-straight' les ramène ensuite sur le commit
épinglé."
  (interactive)
  (dolist (d (metal-pdf-serveur--dossiers-straight))
    (when (file-directory-p d)
      (delete-directory d t)
      (metal-pdf-serveur--journal "purgé : %s" d)))
  (message "pdf-tools purgé de straight — redémarrez Emacs"))

(defun metal-pdf-serveur--git (&rest args)
  "Lance git dans le clone straight de pdf-tools ; retourne t si succès."
  (let ((depot (car (metal-pdf-serveur--dossiers-straight))))
    (= 0 (apply #'call-process "git" nil nil nil "-C" depot args))))

;;;###autoload
(defun metal-pdf-serveur-aligner-straight ()
  "Place le clone straight de pdf-tools sur `metal-pdf-commit-attendu'.

À appeler APRÈS `straight-use-package', jamais avant : le clone doit
exister.  Retourne t si un basculement a eu lieu.

straight.el ne connaît pas de mot-clé `:commit' dans ses recettes : il
l'ignore en silence et laisse le dépôt sur sa branche par défaut.
L'épinglage doit donc être fait ici, par git, puis suivi d'une
reconstruction — sinon le Lisp compilé reste celui de la branche.

Ne purge rien : supprimer les dossiers ne ferait que provoquer un
nouveau clone sur la branche par défaut, donc une boucle."
  (let ((clone (metal-pdf-serveur--commit-clone)))
    (when (and clone (not (string= clone metal-pdf-commit-attendu)))
      ;; Le commit visé peut manquer localement (clone superficiel, ou
      ;; commit plus récent que le clone) : on complète l'historique.
      (unless (metal-pdf-serveur--git
               "cat-file" "-e" (concat metal-pdf-commit-attendu "^{commit}"))
        (or (metal-pdf-serveur--git "fetch" "--unshallow" "--tags" "origin")
            (metal-pdf-serveur--git "fetch" "--tags" "origin")))
      (if (metal-pdf-serveur--git "checkout" "--detach" "--force"
                                  metal-pdf-commit-attendu)
          (progn
            (metal-pdf-serveur--journal
             "pdf-tools : clone basculé de %s vers %s (épinglé)"
             (substring clone 0 12) (substring metal-pdf-commit-attendu 0 12))
            ;; Le Lisp compilé provient de l'ancien commit : à refaire.
            (when (fboundp 'straight-rebuild-package)
              (ignore-errors (straight-rebuild-package "pdf-tools" t)))
            t)
        (metal-pdf-serveur--journal
         "pdf-tools : bascule vers %s IMPOSSIBLE — le Lisp reste en %s"
         (substring metal-pdf-commit-attendu 0 12) (substring clone 0 12))
        nil))))

(defun metal-pdf-serveur--journal (fmt &rest args)
  "Journalise dans *Messages* sans encombrer l'écho."
  (let ((message-log-max t))
    (message "MetalEmacs : %s" (apply #'format fmt args))))

;;; --- Commande de mise à jour (mainteneur) --------------------------------

;;;###autoload
(defun metal-pdfinfo-mise-a-jour ()
  "Met à jour le serveur epdfinfo et réaccorde la version épinglée.

Réservée au mainteneur : installe le paquet MSYS2, lit la version
obtenue, résout le commit amont correspondant et réécrit
metal-pdf-version.el.  Les étudiants reçoivent le résultat par
`git pull' ; cette commande n'est pas exposée dans l'Assistant.

Asynchrone : le téléchargement pacman dure plusieurs minutes et Emacs
reste utilisable pendant ce temps.  La suite du travail — lecture de la
version, résolution du commit, écriture du fichier — se fait dans la
sentinelle du processus.

À faire ensuite : relire le fichier généré, le commiter, supprimer
straight/repos/pdf-tools et straight/build/pdf-tools, puis redémarrer."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "Commande réservée à Windows (source MSYS2 du serveur)"))
  (unless (executable-find "git")
    (user-error "git est requis pour résoudre la version en commit"))
  (let ((pacman (metal-pdf-serveur--pacman)))
    (unless pacman
      (user-error "MSYS2 introuvable — cherché dans : %s"
                  (mapconcat #'identity
                             (metal-pdf-serveur-msys2-racines-candidates) ", ")))
    (unless (yes-or-no-p
             (format "Installer le serveur et réaccorder l'épinglage (actuel : %s) ? "
                     metal-pdf-version-attendue))
      (user-error "Abandon"))
    (message "📦 pacman en cours — Emacs reste utilisable...")
    (let* ((tampon "*MetalEmacs pdf-tools*")
           (q (shell-quote-argument pacman))
           (cmd (format "%s -Sy --noconfirm && %s -S --needed --noconfirm %s"
                        q q metal-pdf-serveur-paquet-msys2)))
      (with-current-buffer (get-buffer-create tampon) (erase-buffer))
      (set-process-sentinel
       (start-process-shell-command "epdfinfo-maj" tampon cmd)
       #'metal-pdf-serveur--sentinelle-mise-a-jour)
      (display-buffer tampon))))

(defun metal-pdf-serveur--sentinelle-mise-a-jour (proc _evenement)
  "Poursuit `metal-pdfinfo-mise-a-jour' une fois PROC terminé."
  (when (eq (process-status proc) 'exit)
    (if (/= (process-exit-status proc) 0)
        (message "❌ Échec de pacman. Voir %s" (buffer-name (process-buffer proc)))
      (let ((obtenue (metal-pdf-serveur-version-installee)))
        (cond
         ((null obtenue)
          (message "❌ Paquet installé mais version illisible"))
         (t
          (message "Résolution de la balise v%s..." obtenue)
          (let ((commit (metal-pdf-serveur--commit-de-version obtenue)))
            (cond
             ((null commit)
              (message
               (concat "❌ Aucune balise v%s en amont — le paquet MSYS2 ne suit "
                       "pas les balises du dépôt ; épinglage inchangé")
               obtenue))
             ((and (string= obtenue metal-pdf-version-attendue)
                   (string= commit metal-pdf-commit-attendu))
              (message "✓ Déjà accordé (version %s) — rien à réécrire" obtenue))
             (t
              (metal-pdf-serveur--ecrire-version obtenue commit)
              (let ((metal-pdf-commit-attendu commit))
                (metal-pdf-serveur-noter-construction))
              ;; L'épinglage vient de changer : le clone straight porte
              ;; encore l'ancien commit et ne rebasculera pas tout seul.
              (dolist (d (metal-pdf-serveur--dossiers-straight))
                (when (file-directory-p d) (ignore-errors (delete-directory d t))))
              (find-file metal-pdf-serveur-fichier-version)
              (message
               (concat "pdf-tools épinglé à %s (%s), straight purgé. "
                       "Relisez et commitez le fichier, puis redémarrez")
               obtenue (substring commit 0 12)))))))))
    (metal-pdf-serveur--rafraichir-assistant)))

(provide 'metal-pdf-serveur)
;;; metal-pdf-serveur.el ends here
