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

;;; --- Commande de mise à jour (mainteneur) --------------------------------

;;;###autoload
(defun metal-pdfinfo-mise-a-jour ()
  "Met à jour le serveur epdfinfo et réaccorde la version épinglée.

Réservée au mainteneur : installe le paquet MSYS2, lit la version
obtenue, résout le commit amont correspondant et réécrit
metal-pdf-version.el.  Les étudiants reçoivent le résultat par
`git pull' ; cette commande n'est pas exposée dans l'Assistant.

À faire ensuite, dans l'ordre : relire le fichier généré, le commiter,
supprimer straight/repos/pdf-tools et straight/build/pdf-tools, puis
redémarrer Emacs."
  (interactive)
  (unless (eq system-type 'windows-nt)
    (user-error "Commande réservée à Windows (source MSYS2 du serveur)"))
  (unless (metal-pdf-serveur--pacman)
    (user-error "MSYS2 introuvable — cherché dans : %s"
                (mapconcat #'identity
                           (metal-pdf-serveur-msys2-racines-candidates) ", ")))
  (unless (executable-find "git")
    (user-error "git est requis pour résoudre la version en commit"))
  (let ((tampon (get-buffer-create "*MetalEmacs pdf-tools*"))
        (pacman (metal-pdf-serveur--pacman)))
    (with-current-buffer tampon (erase-buffer))
    (display-buffer tampon)
    (message "Actualisation de la base de paquets MSYS2...")
    (call-process pacman nil tampon t "-Sy" "--noconfirm")
    (let ((disponible (metal-pdf-serveur-version-disponible))
          (installee (metal-pdf-serveur-version-installee)))
      (unless disponible
        (user-error "Paquet %s introuvable dans les dépôts MSYS2"
                    metal-pdf-serveur-paquet-msys2))
      (when (and installee (string= installee disponible)
                 (string= installee metal-pdf-version-attendue))
        (user-error "Déjà à jour et accordé (version %s)" installee))
      (unless (yes-or-no-p
               (format "Installer le serveur %s (installé : %s, épinglé : %s) ? "
                       disponible (or installee "aucun")
                       metal-pdf-version-attendue))
        (user-error "Abandon"))
      (unless (= 0 (call-process pacman nil tampon t "-S" "--needed"
                                 "--noconfirm"
                                 metal-pdf-serveur-paquet-msys2))
        (error "Échec de l'installation — voir %s" (buffer-name tampon)))
      (let ((obtenue (metal-pdf-serveur-version-installee)))
        (unless obtenue
          (error "Paquet installé mais version illisible"))
        (message "Résolution de la balise v%s..." obtenue)
        (let ((commit (metal-pdf-serveur--commit-de-version obtenue)))
          (unless commit
            (error "Aucune balise v%s dans %s — le paquet MSYS2 ne suit pas les balises amont"
                   obtenue metal-pdf-serveur-depot))
          (metal-pdf-serveur--ecrire-version obtenue commit)
          ;; Le témoin doit suivre : le serveur MSYS2 fraîchement installé
          ;; correspond désormais au commit qu'on vient d'épingler.
          (let ((metal-pdf-commit-attendu commit))
            (metal-pdf-serveur-noter-construction))
          (find-file metal-pdf-serveur-fichier-version)
          (message
           (concat "pdf-tools épinglé à %s (%s). "
                   "Relisez et commitez ce fichier, supprimez "
                   "straight/repos/pdf-tools et straight/build/pdf-tools, "
                   "puis redémarrez Emacs")
           obtenue (substring commit 0 12)))))))

(provide 'metal-pdf-serveur)
;;; metal-pdf-serveur.el ends here
