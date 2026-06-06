;;; metal-distribution.el --- Préparation d'une distribution MetalEmacs -*- lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, distribution

;;; Commentary:
;;
;; Commande `metal-preparer-distribution' : assemble une copie propre
;; de ~/.emacs.d (sans .elc, sans .DS_Store, sans les préférences
;; locales) et la compresse en ZIP dans le dossier sélectionné dans
;; Treemacs.  Utilisé pour diffuser MetalEmacs aux étudiants en TAL.
;;
;; Dépendances : Treemacs (sélection de la destination) et la variable
;; `metal-securite-inhiber' de `metal-securite' (pour permettre les
;; suppressions sans corbeille pendant l'assemblage).

;;; Code:

(require 'cl-lib)
(require 'treemacs nil t)
(require 'metal-securite nil t)

;; Déclaré dans `metal-securite' ; defvar défensif si le module n'est
;; pas chargé, pour éviter une variable libre à la compilation.
(defvar metal-securite-inhiber nil)

(defun metal-preparer-distribution ()
  "Prépare une distribution MetalEmacs en ZIP dans le dossier sélectionné dans Treemacs."
  (interactive)
  (let* ((dest-base
          (let* ((tb (treemacs-get-local-buffer))
                 (node (when tb
                         (with-current-buffer tb
                           (save-excursion
                             (treemacs--prop-at-point :path))))))
            (cond
             ((null node)
              (user-error "Cliquez d'abord sur un dossier dans Treemacs"))
             ((file-directory-p node)
              (file-name-as-directory node))
             (t
              (file-name-directory node)))))
         (source (expand-file-name "~/.emacs.d/"))
         (timestamp (format-time-string "%Y%m%d"))
         (dest-name (format "MetalEmacs-%s" timestamp))
         (dist-dir (expand-file-name (concat dest-name "/") dest-base))
         (emacs-dir (expand-file-name ".emacs.d/" dist-dir))
         (zip-file (expand-file-name "emacs.d.zip" dist-dir))
         ;; Fichiers .el : tous ceux à la racine sauf les exclus
         (el-exclus '("metal-prefs.el" "metal-custom.el"))
         (fichiers-el (cl-remove-if
                       (lambda (f) (member (file-name-nondirectory f) el-exclus))
                       (directory-files source nil "^.*\\.el$")))
         ;; Autres fichiers à copier (non-.el)
         (fichiers-autres '("metal-news.org"
                            "Document.cfg" "METAL.cfg" "Presentation.cfg"
                            "MetalEmacs-lisez-moi.txt"
                            "TAL-MacIntel-Windows-Linux.yml" "TAL-MacM.yml"
                            "METAL.org" "METAL.pdf"
                            "AideMemoire-Python.pdf" "orgcard.pdf"
                            "Quarto_Cheat_Sheet.pdf" "SWI-Prolog-9.2.2.pdf"))
         ;; Tous les fichiers à copier
         (fichiers (append fichiers-el fichiers-autres))
         ;; Dossiers à copier intégralement
         (dossiers '("icons" "modeles" "snippets" ".cache"
                     "zip" "PortableGit" "quarto" "pdf-tools" "straight")))
    ;; Confirmation graphique
    (unless (x-popup-dialog
             t
             `(,(format "Créer la distribution MetalEmacs ?\n\n📁 Destination : %s\n📄 %d fichiers .el détectés"
                        (abbreviate-file-name dist-dir)
                        (length fichiers-el))
               ("✓ Créer" . t)
               ("✗ Annuler" . nil)))
      (user-error "Opération annulée"))
    (message "▶ Préparation de la distribution MetalEmacs en cours...")
    (redisplay)
    ;; Nettoyage si une ancienne préparation existe (sans corbeille)
    (when (file-exists-p dist-dir)
      (let ((metal-securite-inhiber t)
            (delete-by-moving-to-trash nil))
        (delete-directory dist-dir t)))
    ;; Créer le répertoire .emacs.d dans la distribution
    (make-directory emacs-dir t)
    ;; Copier les fichiers individuels
    (dolist (f fichiers)
      (let ((src (concat source f)))
        (when (file-exists-p src)
          (copy-file src (concat emacs-dir f) t))))
    ;; Copier les dossiers (sans .elc)
    (dolist (d dossiers)
      (let ((src (concat source d)))
        (when (file-directory-p src)
          (copy-directory src (concat emacs-dir d) nil t t))))
    ;; Supprimer tous les .elc et .DS_Store (sans corbeille)
    (let ((metal-securite-inhiber t)
          (delete-by-moving-to-trash nil))
      (dolist (elc (directory-files-recursively emacs-dir "\\.elc$"))
        (delete-file elc))
      (dolist (ds (directory-files-recursively emacs-dir "^\\.DS_Store$"))
        (delete-file ds)))
    ;; Créer le ZIP
    (call-process-shell-command
     (format "cd %s && zip -r emacs.d.zip .emacs.d"
             (shell-quote-argument dist-dir))
     nil nil nil)
    ;; Supprimer le dossier .emacs.d temporaire, ne garder que le ZIP (sans corbeille)
    (let ((metal-securite-inhiber t)
          (delete-by-moving-to-trash nil))
      (delete-directory emacs-dir t))
    ;; Rafraîchir Treemacs pour voir le résultat
    (treemacs-refresh)
    ;; Confirmation finale
    (x-popup-dialog
     t
     `(,(format "✓ Distribution MetalEmacs créée !\n\n📦 %s"
                (abbreviate-file-name zip-file))
       ("OK" . t)))
    (message "✓ Distribution créée : %s" zip-file)))

(provide 'metal-distribution)

;;; metal-distribution.el ends here
