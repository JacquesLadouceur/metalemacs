;;; metal-git.el --- Mise à jour de MetalEmacs via Git -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur

;;; Commentary:
;;
;; Système de mise à jour de MetalEmacs basé sur Git.  Permet aux
;; étudiants de récupérer la dernière version officielle du code
;; source depuis le dépôt GitHub.
;;
;; Commandes principales :
;;   M-x metal-git-mise-a-jour   — récupérer la dernière version
;;   M-x metal-git-statut        — voir l'état actuel sans rien changer
;;
;; ATTENTION : la mise à jour ÉCRASE toute modification locale faite
;; aux fichiers du dépôt.  Les étudiants qui veulent personnaliser
;; MetalEmacs doivent placer leurs réglages dans ~/.emacs.d/perso.el
;; (qui n'est jamais touché par les mises à jour).

;;; Code:

(require 'cl-lib)

;;; --- Configuration --------------------------------------------------------

(defgroup metal-git nil
  "Mise à jour de MetalEmacs via Git."
  :group 'convenience
  :prefix "metal-git-")

(defcustom metal-git-depot
  user-emacs-directory
  "Répertoire racine du dépôt Git MetalEmacs."
  :type 'directory
  :group 'metal-git)

(defcustom metal-git-tampon "*MetalEmacs : mise à jour*"
  "Nom du tampon utilisé pour afficher la progression."
  :type 'string
  :group 'metal-git)

;;; --- Helpers --------------------------------------------------------------

(defun metal-git--depot-valide-p ()
  "Retourne t si `metal-git-depot' est un dépôt Git."
  (file-directory-p (expand-file-name ".git" metal-git-depot)))

(defun metal-git--executer (&rest args)
  "Exécute `git ARGS' dans le dépôt et retourne (CODE . SORTIE)."
  (let ((default-directory metal-git-depot))
    (with-temp-buffer
      (let ((code (apply #'call-process "git" nil t nil args)))
        (cons code (string-trim (buffer-string)))))))

(defun metal-git--executer-ok (&rest args)
  "Exécute `git ARGS' et retourne la sortie ; lance une erreur si échec."
  (pcase-let ((`(,code . ,sortie) (apply #'metal-git--executer args)))
    (unless (zerop code)
      (error "git %s a échoué : %s" (string-join args " ") sortie))
    sortie))

(defun metal-git--branche ()
  "Retourne le nom de la branche actuelle."
  (metal-git--executer-ok "rev-parse" "--abbrev-ref" "HEAD"))

(defun metal-git--commit ()
  "Retourne le hash court du commit actuel."
  (metal-git--executer-ok "rev-parse" "--short" "HEAD"))

(defun metal-git--message-commit (hash)
  "Retourne le message du commit HASH (première ligne)."
  (metal-git--executer-ok "log" "-1" "--pretty=%s" hash))

;;; --- Tampon de progression ------------------------------------------------

(defun metal-git--ouvrir-tampon ()
  "Ouvre (ou réinitialise) le tampon de progression."
  (let ((buf (get-buffer-create metal-git-tampon)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Mise à jour MetalEmacs — %s\n"
                        (format-time-string "%Y-%m-%d %H:%M")))
        (insert (make-string 60 ?─) "\n\n"))
      (special-mode))
    (display-buffer buf)
    buf))

(defun metal-git--ecrire (buf format-string &rest args)
  "Écrit dans BUF avec format."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (apply #'format format-string args))
      (insert "\n"))))

;;; --- Diagnostic des prérequis ---------------------------------------------

(defun metal-git--diagnostiquer ()
  "Vérifie les prérequis ; retourne nil si OK, message d'erreur sinon."
  (cond
   ((not (executable-find "git"))
    "Git n'est pas installé sur ce système.

Installer Git puis relancer la mise à jour :
  • macOS    : brew install git
  • Windows  : scoop install git
  • Linux    : sudo apt install git")

   ((not (metal-git--depot-valide-p))
    (format
     "MetalEmacs n'est pas installé via Git (le dossier .git/ est absent dans %s).

Pour bénéficier des mises à jour automatiques, réinstaller MetalEmacs
depuis GitHub :

  1. Sauvegarder l'installation actuelle :
       mv ~/.emacs.d ~/.emacs.d.ancien

  2. Cloner le dépôt :
       git clone https://github.com/JacquesLadouceur/metalemacs.git ~/.emacs.d

  3. Récupérer vos préférences personnelles depuis l'ancienne
     installation au besoin (metal-prefs.el, perso.el, etc.)"
     (abbreviate-file-name metal-git-depot)))))

;;; --- Helpers de pull ------------------------------------------------------

(defun metal-git--echec (buf sortie)
  "Affiche dans BUF un message d'erreur après échec du pull."
  (metal-git--ecrire buf "")
  (metal-git--ecrire buf "✗ Échec de la mise à jour :")
  (metal-git--ecrire buf "%s" sortie)
  (metal-git--ecrire buf "")
  (metal-git--ecrire
   buf "Causes possibles : connexion Internet absente, dépôt \
GitHub inaccessible, ou divergence d'historique."))

(defun metal-git--succes (buf commit-avant)
  "Affiche dans BUF le résumé des changements depuis COMMIT-AVANT."
  (let ((commit-apres (metal-git--commit)))
    (metal-git--ecrire buf "")
    (cond
     ((string= commit-avant commit-apres)
      (metal-git--ecrire buf "✓ MetalEmacs était déjà à jour"))
     (t
      (metal-git--ecrire buf "✓ Mise à jour réussie")
      (metal-git--ecrire buf "")
      (metal-git--ecrire buf "Changements appliqués :")
      (let ((diff (cdr (metal-git--executer
                        "diff" "--stat" commit-avant commit-apres))))
        (dolist (ligne (split-string diff "\n" t))
          (metal-git--ecrire buf "  %s" ligne)))
      (metal-git--ecrire buf "")
      (metal-git--ecrire
       buf "💡 Redémarrer Emacs pour activer les changements.")))))

(defun metal-git--executer-pull (buf)
  "Effectue le `git pull' dans BUF (écrase les modifs locales)."
  (let ((commit-avant (metal-git--commit)))
    ;; Étape 1 : effacer les modifications locales
    (metal-git--ecrire buf "Annulation des modifications locales éventuelles…")
    (metal-git--executer "reset" "--hard" "HEAD")
    (metal-git--executer "clean" "-fd"
                         ;; Préserver les fichiers personnels essentiels
                         "-e" "perso.el"
                         "-e" "metal-prefs.el"
                         "-e" "metal-custom.el"
                         "-e" ".authinfo*")
    ;; Étape 2 : récupérer la dernière version
    (metal-git--ecrire buf "Récupération depuis GitHub…")
    (redisplay)
    (pcase-let ((`(,code . ,sortie)
                 (metal-git--executer "pull" "--ff-only")))
      (if (not (zerop code))
          (metal-git--echec buf sortie)
        (metal-git--succes buf commit-avant)))))

;;; --- Commandes interactives -----------------------------------------------

;;;###autoload
(defun metal-git-statut ()
  "Affiche l'état du dépôt MetalEmacs sans rien modifier.
Indique la branche, le commit actuel, et si une mise à jour est
disponible sur GitHub."
  (interactive)
  (let ((diag (metal-git--diagnostiquer)))
    (when diag
      (user-error "%s" diag)))
  (let ((buf (metal-git--ouvrir-tampon)))
    (metal-git--ecrire buf "État du dépôt MetalEmacs")
    (metal-git--ecrire buf
                       "Emplacement : %s"
                       (abbreviate-file-name metal-git-depot))
    (metal-git--ecrire buf "Branche     : %s" (metal-git--branche))
    (let ((commit (metal-git--commit)))
      (metal-git--ecrire buf
                         "Commit      : %s — %s"
                         commit (metal-git--message-commit commit)))
    (metal-git--ecrire buf "")
    (metal-git--ecrire buf "Vérification des mises à jour disponibles…")
    (redisplay)
    (pcase-let ((`(,code . ,_sortie)
                 (metal-git--executer "fetch" "--quiet")))
      (cond
       ((not (zerop code))
        (metal-git--ecrire
         buf "⚠ Impossible de joindre GitHub (vérifier la connexion)"))
       (t
        (let* ((local (metal-git--executer-ok "rev-parse" "HEAD"))
               (remote (metal-git--executer-ok "rev-parse" "@{upstream}")))
          (cond
           ((string= local remote)
            (metal-git--ecrire buf "✓ MetalEmacs est à jour"))
           (t
            (let ((nb (metal-git--executer-ok
                       "rev-list" "--count" "HEAD..@{upstream}")))
              (metal-git--ecrire
               buf "↓ %s nouveau(x) commit(s) disponible(s) sur GitHub" nb)
              (metal-git--ecrire
               buf "  Lancer M-x metal-git-mise-a-jour pour récupérer."))))))))))

;;;###autoload
(defun metal-git-mise-a-jour ()
  "Met à jour MetalEmacs depuis le dépôt GitHub officiel.

ATTENTION : toute modification locale faite aux fichiers du dépôt
sera écrasée.  Les fichiers personnels (perso.el, metal-prefs.el,
metal-custom.el, .authinfo*) sont préservés.

Pour personnaliser MetalEmacs sans risquer de perdre vos réglages,
placez-les dans ~/.emacs.d/perso.el (ignoré par Git)."
  (interactive)
  (let ((diag (metal-git--diagnostiquer)))
    (when diag
      (user-error "%s" diag)))
  (unless (yes-or-no-p
           "Mettre à jour MetalEmacs ?  Les modifications locales seront écrasées. ")
    (user-error "Mise à jour annulée"))
  (let ((buf (metal-git--ouvrir-tampon)))
    (metal-git--executer-pull buf)))

(provide 'metal-git)
;;; metal-git.el ends here
