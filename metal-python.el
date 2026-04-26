;;; metal-python.el --- Configuration Python et Conda pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.6.1

;;; Commentary:
;; Configuration Python pour MetalEmacs :
;; - Activation automatique de l'environnement Conda à l'ouverture d'un .py
;; - Sélection automatique de l'interpréteur (IPython/Python)
;; - Gestion des environnements Conda (créer, supprimer, changer)
;; - Installation automatique de libmamba
;; - Indentation TAB/Shift-TAB
;; - Position du shell Python (bas/droite), avec ouverture automatique à l'exécution
;; - Complétion Corfu + Cape
;; - Débogueur visuel dape (DAP, auto-installation de debugpy), repli pdb
;; - Header-line cliquable pendant les sessions dape (continue/next/step/quit)
;; - Clic dans la marge gauche pour poser/enlever un breakpoint

;;; Code:

(require 'python)
(require 'cl-lib)
(require 'seq)
(require 'metal-utile)

;;; ═══════════════════════════════════════════════════════════════════
;;; 1. Groupe et variables personnalisables
;;; ═══════════════════════════════════════════════════════════════════

(defgroup metal-python nil
  "Réglages MetalEmacs pour Python et Conda."
  :group 'python)

(defcustom metal-conda-environnement-defaut nil
  "Chemin complet de l'environnement Conda par défaut (sauvegardé via `customize-save-variable')."
  :type '(choice (const :tag "Aucun (utiliser base)" nil) string)
  :group 'metal-python)

(defcustom metal-python-shell-position-defaut 'bottom
  "Position par défaut du shell Python : `bottom' (bas) ou `right' (droite)."
  :type '(choice (const bottom) (const right))
  :group 'metal-python)

(defcustom metal-python-shell-height-frac 0.30
  "Fraction de hauteur quand le shell s'ouvre en bas (0.0–1.0)."
  :type 'number
  :group 'metal-python)

(defcustom metal-python-shell-width-frac 0.30
  "Fraction de largeur quand le shell s'ouvre à droite (0.0–1.0)."
  :type 'number
  :group 'metal-python)

;;; ═══════════════════════════════════════════════════════════════════
;;; 2. Helpers privés
;;; ═══════════════════════════════════════════════════════════════════

(defun metal--indent-offset ()
  "Trouve l'offset d'indentation pour le mode courant."
  (or (bound-and-true-p python-indent-offset)
      (bound-and-true-p c-basic-offset)
      (bound-and-true-p js-indent-level)
      (bound-and-true-p typescript-ts-mode-indent-offset)
      (bound-and-true-p lisp-body-indent)
      (bound-and-true-p standard-indent)
      tab-width
      4))

(defun metal--region-or-line-bounds ()
  "Retourne (BEG . END) couvrant des lignes entières.
Si une région est active, étend au début de la première ligne
et à la fin de la dernière ligne."
  (if (use-region-p)
      (let* ((rb (region-beginning))
             (re (region-end)))
        (when (and (> re rb)
                   (= re (save-excursion (goto-char re) (line-beginning-position))))
          (setq re (1- re)))
        (cons (save-excursion (goto-char rb) (line-beginning-position))
              (save-excursion (goto-char re) (line-end-position))))
    (cons (line-beginning-position) (line-end-position))))

;;; ═══════════════════════════════════════════════════════════════════
;;; 3. Helpers Conda (détection exécutable)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-conda--get-conda-exe ()
  "Retourne l'exécutable conda ou nil si non trouvé."
  (or (executable-find "conda")
      (executable-find "conda.exe")))

(defun metal-conda--require-conda ()
  "Vérifier que conda est disponible. Retourne l'exécutable ou nil."
  (or (metal-conda--get-conda-exe)
      (progn
        (message "❌ Conda introuvable. Installez-le via M-x metal-deps-installer-miniconda")
        nil)))

(defun metal-conda--libmamba-installed-p ()
  "Vérifier si libmamba est configuré comme solver."
  (when-let ((conda-exe (metal-conda--get-conda-exe)))
    (string-match-p
     "libmamba"
     (shell-command-to-string (format "\"%s\" config --show solver" conda-exe)))))

(defun metal-conda--ensure-libmamba ()
  "Installer libmamba si nécessaire. Retourne t si prêt, nil sinon.
Si l'installation est nécessaire, elle est lancée dans un buffer Eat
et la fonction retourne nil (il faudra relancer la création après)."
  (let ((conda-exe (metal-conda--require-conda)))
    (when conda-exe
      (cond
       ((metal-conda--libmamba-installed-p)
        (message "✓ Solver libmamba déjà configuré") t)
       ((yes-or-no-p "⚡ Installer libmamba pour accélérer la création d'environnements ? ")
        (message "⏳ Installation de libmamba en cours...")
        (metal-util-run-in-eat
         (format "\"%s\" install -n base conda-libmamba-solver -y && \"%s\" config --set solver libmamba"
                 conda-exe conda-exe)
         "*Conda libmamba*"
         t)
        (message "📦 Installation lancée dans un terminal Eat. Relancez la création après.")
        nil)))))

;;; ═══════════════════════════════════════════════════════════════════
;;; 4. Configuration Conda (use-package)
;;; ═══════════════════════════════════════════════════════════════════

(use-package conda
  :ensure t
  :config
  ;; Détection du chemin Conda par inspection des emplacements standard.
  ;; Ordre : macOS (Homebrew) > Unix home > Linux /opt > Windows > nil.
  ;; Note : on n'utilise PAS `CONDA_PREFIX' car cette variable pointe vers
  ;; l'environnement actif (ex. .../envs/TAL), pas vers la racine de
  ;; l'installation conda.
  (setq conda-env-home-directory
        (cond
         ;; --- macOS ---
         ((file-directory-p "/opt/homebrew/Caskroom/miniconda/base")
          "/opt/homebrew/Caskroom/miniconda/base")        ; Apple Silicon
         ((file-directory-p "/usr/local/Caskroom/miniconda/base")
          "/usr/local/Caskroom/miniconda/base")           ; Intel
         ;; --- Unix (macOS/Linux/ChromeOS) dans le home ---
         ((file-directory-p (expand-file-name "~/miniconda3"))
          (expand-file-name "~/miniconda3"))
         ((file-directory-p (expand-file-name "~/anaconda3"))
          (expand-file-name "~/anaconda3"))
         ;; --- Linux / ChromeOS (Crostini), installs système ---
         ((file-directory-p "/opt/miniconda3") "/opt/miniconda3")
         ((file-directory-p "/opt/conda") "/opt/conda")   ; Docker, certaines distros
         ;; --- Windows ---
         ((file-directory-p "C:/ProgramData/miniconda3") "C:/ProgramData/miniconda3")
         ((file-directory-p "C:/ProgramData/Anaconda3")  "C:/ProgramData/Anaconda3")
         ((file-directory-p "C:/tools/miniconda3") "C:/tools/miniconda3")
         ((file-directory-p (expand-file-name "~/scoop/apps/miniconda3/current"))
          (expand-file-name "~/scoop/apps/miniconda3/current"))
         (t nil)))
  ;; Initialiser seulement si conda est disponible
  (when conda-env-home-directory
    (let ((conda-bin (expand-file-name "bin" conda-env-home-directory)))
      (when (and (file-directory-p conda-bin)
                 (not (executable-find "conda")))
        (add-to-list 'exec-path conda-bin)
        (setenv "PATH" (concat conda-bin path-separator (getenv "PATH")))))
    (ignore-errors
      (conda-env-initialize-interactive-shells)
      (conda-env-initialize-eshell))))

;;; ═══════════════════════════════════════════════════════════════════
;;; 4b. Débogueur visuel (dape - Debug Adapter Protocol)
;;; ═══════════════════════════════════════════════════════════════════

(use-package dape
  :ensure t
  :commands (dape
             dape-breakpoint-toggle
             dape-breakpoint-remove-all
             dape-next
             dape-step-in
             dape-step-out
             dape-continue
             dape-quit)
  :init
  ;; Panneaux (locals, stack, watches, breakpoints) à droite du code.
  (setq dape-buffer-window-arrangement 'right)
  ;; Afficher les valeurs au fil du code (Emacs 29+).
  (setq dape-inlay-hints t))

;;; ═══════════════════════════════════════════════════════════════════
;;; 5. Sélection de l'interpréteur Python
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-python-pick-interpreter ()
  "Choisir IPython si présent dans l'env actif, sinon Python (ou `py' sous Windows)."
  (let* ((ipy (executable-find "ipython"))
         (py  (or (executable-find "python")
                  (and (eq system-type 'windows-nt) (executable-find "py")))))
    (if ipy
        (progn
          (setq-local python-shell-interpreter ipy)
          ;; --InteractiveShell.warn_venv=False supprime l'avertissement
          ;; « Attempting to work in a virtualenv » qui apparaît sur Windows
          ;; quand IPython est dans l'env base et l'env actif est différent.
          (setq-local python-shell-interpreter-args
                      "--simple-prompt --no-banner --InteractiveShell.warn_venv=False")
          "ipython")
      (setq-local python-shell-interpreter (or py "python"))
      (setq-local python-shell-interpreter-args
                  (if (and py (string-match-p "py$" (file-name-nondirectory py)))
                      "-3 -i"
                    "-i"))
      "python")))

(defun metal-python--ensure-conda-env ()
  "Activer l'environnement Conda approprié. Retourne t si actif, nil sinon."
  (cond
   ;; 1. Un environnement est déjà actif
   ((and (boundp 'conda-env-current-name) conda-env-current-name) t)
   ;; 2. Un environnement par défaut est sauvegardé
   ((and metal-conda-environnement-defaut
         (file-directory-p metal-conda-environnement-defaut))
    (ignore-errors (conda-env-activate-path metal-conda-environnement-defaut))
    t)
   ;; 3. Conda est disponible, activer base
   (conda-env-home-directory
    (ignore-errors (conda-env-activate-path conda-env-home-directory))
    t)
   ;; 4. Conda n'est pas installé
   (t
    (message "⚠️ Python/Conda non disponible. Utilisez M-x metal-deps-installer-miniconda")
    nil)))

(defun metal-python-reselect-repl ()
  "Resélectionner l'interpréteur pour CE buffer selon l'env actif."
  (interactive)
  (message "REPL choisi : %s" (metal-python-pick-interpreter)))

;; Quand l'environnement Conda change, reconfigurer tous les buffers Python :
;; sélection d'interpréteur + mise à jour de la mode-line.
(with-eval-after-load 'conda
  (add-hook 'conda-postactivate-hook
            (lambda ()
              (dolist (buf (buffer-list))
                (with-current-buffer buf
                  (when (derived-mode-p 'python-mode 'python-ts-mode)
                    (metal-python-pick-interpreter)
                    (metal-conda-modeline)))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; 6. Indentation TAB / Shift-TAB
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-shift-right-at-point-or-region (&optional n)
  "Décaler à droite. Si région : décale des LIGNES ENTIÈRES de N colonnes.
Sinon : insère N espaces à POINT."
  (interactive "P")
  (let ((off (* (prefix-numeric-value (or n 1)) (metal--indent-offset))))
    (if (use-region-p)
        (let ((bds (metal--region-or-line-bounds)))
          (if (fboundp 'python-indent-shift-right)
              (python-indent-shift-right (car bds) (cdr bds) (/ off (metal--indent-offset)))
            (indent-rigidly (car bds) (cdr bds) off)))
      (insert (make-string off ?\s)))))

(defun metal-shift-left-at-point-or-region (&optional n)
  "Décaler à gauche. Si région : décale des LIGNES ENTIÈRES de N colonnes.
Sinon : retire jusqu'à N espaces juste avant POINT."
  (interactive "P")
  (let ((off (* (prefix-numeric-value (or n 1)) (metal--indent-offset))))
    (if (use-region-p)
        (let ((bds (metal--region-or-line-bounds)))
          (if (fboundp 'python-indent-shift-left)
              (python-indent-shift-left (car bds) (cdr bds) (/ off (metal--indent-offset)))
            (indent-rigidly (car bds) (cdr bds) (- off))))
      (cond
       ((<= (point) (save-excursion (back-to-indentation) (point)))
        (let ((bds (metal--region-or-line-bounds)))
          (indent-rigidly (car bds) (cdr bds) (- off))
          (back-to-indentation)))
       (t
        (let ((nremoved 0))
          (while (and (< nremoved off)
                      (> (point) (line-beginning-position))
                      (eq (char-before) ?\s))
            (delete-char -1)
            (setq nremoved (1+ nremoved)))))))))

(defun metal-python-tab ()
  "TAB : indentation normale ou décalage région."
  (interactive)
  (if (use-region-p)
      (metal-shift-right-at-point-or-region 1)
    (indent-for-tab-command)))

(defun metal-python-backtab ()
  "Shift-TAB : décale à gauche (ligne ou région)."
  (interactive)
  (metal-shift-left-at-point-or-region 1))

;;; ═══════════════════════════════════════════════════════════════════
;;; 7. Position du shell Python (bas/droite)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal--inferior-python-buffer-p (buf _action)
  "Retourne t si BUF est un buffer de shell Python."
  (with-current-buffer buf (eq major-mode 'inferior-python-mode)))

(defun metal--python-display-params (cote)
  "Retourne la liste de paramètres display-buffer pour COTE (bottom ou right)."
  (if (eq cote 'bottom)
      `((display-buffer-reuse-window display-buffer-below-selected)
        (inhibit-same-window . t)
        (window-height . ,metal-python-shell-height-frac))
    `((display-buffer-reuse-window display-buffer-in-direction)
      (direction . right)
      (inhibit-same-window . t)
      (window-width . ,metal-python-shell-width-frac))))

(defun metal--python-regle-affichage (cote)
  "Retourne la règle display-buffer-alist complète pour COTE."
  (cons 'metal--inferior-python-buffer-p (metal--python-display-params cote)))

(defun metal--python-appliquer-regle (cote)
  "Remplacer la règle d'affichage existante par celle pour COTE."
  (setq display-buffer-alist
        (cl-remove-if (lambda (r) (eq (car-safe r) #'metal--inferior-python-buffer-p))
                      display-buffer-alist))
  (add-to-list 'display-buffer-alist (metal--python-regle-affichage cote)))

(defun metal--python-afficher-ou-repositionner (buf cote)
  "Afficher BUF à la position COTE ; si déjà visible, le repositionner."
  (when-let ((win (get-buffer-window buf t)))
    (when (window-live-p win) (delete-window win)))
  (display-buffer buf (metal--python-display-params cote)))

;; Appliquer la règle actuelle au démarrage
(metal--python-appliquer-regle metal-python-shell-position-defaut)

(defun metal-python-shell-choisir-position ()
  "Choisir « bas » ou « droite » et (ré)afficher le shell Python."
  (interactive)
  (let* ((defaut (if (eq metal-python-shell-position-defaut 'bottom) "bas" "droite"))
         (choix  (completing-read "Ouvrir le shell Python où ? "
                                  '("bas" "droite") nil t nil nil defaut))
         (cote   (if (string= choix "bas") 'bottom 'right)))
    (customize-save-variable 'metal-python-shell-position-defaut cote)
    (metal--python-appliquer-regle cote)
    (let ((buf (python-shell-get-buffer)))
      (unless (and buf (buffer-live-p buf))
        (run-python)
        (setq buf (python-shell-get-buffer)))
      (metal--python-afficher-ou-repositionner buf cote))
    (message "✅ Shell Python : %s (%.0f%%)"
             (if (eq cote 'bottom) "en bas" "à droite")
             (* 100 (if (eq cote 'bottom)
                        metal-python-shell-height-frac
                      metal-python-shell-width-frac)))))

(defun metal-python-shell-bascule-position ()
  "Basculer la position du shell Python entre bas et droite."
  (interactive)
  (let ((nouvelle (if (eq metal-python-shell-position-defaut 'bottom) 'right 'bottom)))
    (customize-save-variable 'metal-python-shell-position-defaut nouvelle)
    (metal--python-appliquer-regle nouvelle)
    (when-let ((buf (python-shell-get-buffer)))
      (metal--python-afficher-ou-repositionner buf nouvelle))
    (message "Position du shell Python : %s"
             (if (eq nouvelle 'bottom) "bas" "droite"))))

;;; ═══════════════════════════════════════════════════════════════════
;;; 8. Exécution et débogage
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-python--shell-vivant-p ()
  "Retourne le buffer du shell Python s'il existe et tourne, nil sinon."
  (let ((buf (python-shell-get-buffer)))
    (and buf (buffer-live-p buf) (get-buffer-process buf) buf)))

(defun metal-python--ensure-shell-visible ()
  "S'assurer qu'un shell Python existe et est visible.
Retourne le buffer du shell."
  (let ((buf (metal-python--shell-vivant-p)))
    ;; Créer le shell s'il n'existe pas (sans voler le focus)
    (unless buf
      (save-window-excursion
        (run-python))
      (setq buf (python-shell-get-buffer)))
    ;; S'assurer qu'il est visible à la bonne position
    (unless (get-buffer-window buf t)
      (metal--python-afficher-ou-repositionner
       buf metal-python-shell-position-defaut))
    buf))

(defun metal-python-demarre ()
  "Démarrer le shell Python (ou le rendre visible s'il existe déjà)."
  (interactive)
  (metal-python--ensure-shell-visible))

(defun metal-python-redemarre ()
  "Redémarrer le shell Python avec l'environnement Conda actif."
  (interactive)
  (when-let ((buf (metal-python--shell-vivant-p)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buf)))
  (ignore-errors (conda-env-activate-for-buffer))
  (metal-python--ensure-shell-visible))

(defun metal-python-execute-cd ()
  "Exécuter le script dans le shell Python en ajustant le dossier de travail."
  (interactive)
  (unless buffer-file-name
    (user-error "Pas de fichier associé au buffer"))
  (let ((script-dir (file-name-directory (expand-file-name buffer-file-name))))
    (setq default-directory script-dir)
    ;; S'assurer que le shell est visible (normalement déjà démarré à l'ouverture)
    (metal-python--ensure-shell-visible)
    ;; Ajuster le dossier de travail du shell
    (python-shell-send-string
     (format "import os; os.chdir(r'%s')" script-dir))
    ;; Envoyer le buffer
    (python-shell-send-buffer)))

(defun metal-python-sauvegarde-execute ()
  "Sauvegarder et exécuter le buffer Python."
  (interactive)
  (save-buffer)
  (metal-python-execute-cd))

;;; --- Débogueurs : pdb (classique) et dape (visuel) ---

(defun metal-python--debugpy-disponible-p ()
  "Retourne t si `debugpy' est importable dans le Python de l'env actif.
On invoque `python -c \"import debugpy\"' et on teste le code de sortie :
0 = module trouvé, autre = absent ou env cassé."
  (let ((python (executable-find "python")))
    (and python
         (zerop (call-process python nil nil nil "-c" "import debugpy")))))

(defun metal-python--installer-debugpy ()
  "Proposer d'installer `debugpy' dans l'env Conda actif via pip.
Installation lancée dans un buffer Eat (visible) pour voir le progrès.
Retourne t si l'utilisateur a accepté (installation en cours), nil sinon.
L'utilisateur devra relancer le débogueur une fois l'installation finie."
  (let ((env (or (and (boundp 'conda-env-current-name) conda-env-current-name)
                 "l'env actif")))
    (when (yes-or-no-p
           (format "🐛 debugpy non installé dans %s. L'installer maintenant ? " env))
      (message "⏳ Installation de debugpy en cours dans %s..." env)
      (metal-util-run-in-eat
       "pip install debugpy"
       "*Install debugpy*"
       t)
      (message "📦 Installation lancée. Relancez le débogueur quand c'est terminé.")
      t)))

(defun metal-python-deboguer-pdb ()
  "Lancer le débogueur PDB classique (texte, dans le minibuffer).
Toujours disponible — ne nécessite que Python. Pour une expérience
plus visuelle, voir `metal-python-deboguer-dape'."
  (interactive)
  (unless buffer-file-name
    (user-error "Pas de fichier associé au buffer"))
  (let ((python-exec (or (executable-find "python")
                         (and (eq system-type 'windows-nt)
                              (executable-find "py"))
                         "python")))
    ;; Guillemets doubles (pas `shell-quote-argument') : gud re-parse la
    ;; ligne avec `split-string-and-unquote' qui comprend " mais pas \.
    (pdb (format "%s -m pdb \"%s\"" python-exec buffer-file-name))))

(defun metal-python-deboguer-dape ()
  "Lancer le débogueur visuel DAP (dape) sur le fichier courant.
Panneaux : variables locales, pile d'appels, watches, breakpoints.
Breakpoints : cliquer dans la marge gauche pour les poser/enlever.
Pendant une session, un header-line affiche les boutons de contrôle
(continue, next, step-in, step-out, quitter).
Survol d'une variable → sa valeur dans le minibuffer.

Nécessite `debugpy' dans l'env actif. Si absent, propose l'installation
et retombe sur PDB pour cette session."
  (interactive)
  (unless buffer-file-name
    (user-error "Pas de fichier associé au buffer"))
  (save-buffer)
  (cond
   ((metal-python--debugpy-disponible-p)
    ;; dape attend un plist complet AVEC placeholders résolus. Les entrées
    ;; de `dape-configs' contiennent des symboles comme `dape-cwd',
    ;; `dape-buffer-default' qui sont des fonctions/variables à évaluer
    ;; avant envoi JSON au serveur debugpy. `dape--config-eval' fait ce
    ;; travail. Sans lui, on obtient l'erreur :
    ;;   wrong-type-argument json-value-p dape-cwd
    (require 'dape)
    (let* ((raw-config (alist-get 'debugpy dape-configs))
           (config (and raw-config
                        (dape--config-eval 'debugpy (copy-tree raw-config)))))
      (unless config
        (user-error "Config `debugpy' introuvable dans `dape-configs'"))
      (dape config)
      ;; On active le header-line juste après (sans attendre `dape-start-hook'
      ;; qui ne tire pas toujours de façon fiable). Les hooks de désactivation
      ;; restent branchés pour retirer le header à la fin de session.
      (metal-python--dape-header-activer)))
   ;; Installation proposée et acceptée → pdb en attendant
   ((metal-python--installer-debugpy)
    (sit-for 1)
    (metal-python-deboguer-pdb))
   ;; Refus d'installer → pdb
   (t (metal-python-deboguer-pdb))))

(defun metal-python-deboguer ()
  "Lancer le débogueur : dape (visuel) si debugpy est dispo, sinon pdb.
Si debugpy n'est pas installé, propose de l'installer dans l'env actif.

Variantes directes :
  M-x `metal-python-deboguer-dape'  → forcer dape (visuel)
  M-x `metal-python-deboguer-pdb'   → forcer pdb  (classique)"
  (interactive)
  (unless buffer-file-name
    (user-error "Pas de fichier associé au buffer"))
  (save-buffer)
  (if (metal-python--debugpy-disponible-p)
      (metal-python-deboguer-dape)
    ;; Proposer l'install pour la prochaine fois ; entre-temps, pdb.
    (metal-python--installer-debugpy)
    (metal-python-deboguer-pdb)))

(defun metal-python-compile ()
  "Compiler le script Python en exécutable avec PyInstaller."
  (interactive)
  (let ((script (buffer-file-name)))
    (if script
        (let ((default-directory (file-name-directory script)))
          (shell-command (format "pyinstaller --onefile %s" (shell-quote-argument script)))
          (message "Script Python compilé en exécutable."))
      (message "Aucun fichier associé au buffer courant."))))

;;; ═══════════════════════════════════════════════════════════════════
;;; 9. Affichage mode-line Conda
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-conda-modeline ()
  "Afficher l'env Conda uniquement dans les buffers Python."
  (when (and (derived-mode-p 'python-mode 'python-ts-mode)
             (boundp 'conda-env-current-name)
             conda-env-current-name)
    (setq mode-name (format "Python (%s)" conda-env-current-name))))

;; Note : le hook `conda-postactivate-hook' est déjà installé plus haut
;; (section 5) et appelle `metal-conda-modeline' pour tous les buffers Python.
;; Pas besoin de l'ajouter séparément ici.

;;; ═══════════════════════════════════════════════════════════════════
;;; 10. Gestion des environnements Conda
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-conda-creer-environnement ()
  "Créer un environnement Conda à partir d'un fichier .yml dans ~/.emacs.d."
  (interactive)
  (unless (metal-conda--require-conda)
    (user-error "Conda n'est pas installé"))
  (metal-conda--ensure-libmamba)
  (let* ((yaml-dir (expand-file-name user-emacs-directory))
         (yaml-files (seq-filter
                      (lambda (f)
                        (let ((name (file-name-nondirectory f)))
                          (and (not (string-prefix-p "." name))
                               (not (string-prefix-p "_" name)))))
                      (directory-files yaml-dir t "\\.ya?ml$")))
         (choices (mapcar #'file-name-base yaml-files))
         (selected (completing-read "📦 Créer l'environnement à partir de : " choices nil t))
         (full-path (seq-find (lambda (f) (string= (file-name-base f) selected)) yaml-files))
         (conda-exe (metal-conda--get-conda-exe)))
    (if (and full-path (file-exists-p full-path))
        (progn
          (message "📦 Création de l'environnement '%s' en cours..." selected)
          (metal-util-run-in-eat
           (format "\"%s\" env create -f \"%s\"" conda-exe full-path)
           "*Conda Create*"
           t))
      (message "❌ Fichier YAML introuvable : %s" selected))))

(defun metal-conda-supprimer-environnement ()
  "Supprimer un environnement Conda (sauf `base')."
  (interactive)
  (unless (metal-conda--require-conda)
    (user-error "Conda n'est pas installé"))
  (require 'conda)
  (let* ((paths (conda-env-candidates))
         (names (mapcar #'file-name-nondirectory paths))
         (envs (seq-remove (lambda (e) (string= e "base")) names))
         (env (completing-read "🧹 Supprimer quel environnement Conda : " envs nil t))
         (active-env (or conda-env-current-name (getenv "CONDA_DEFAULT_ENV")))
         (conda-exe (metal-conda--get-conda-exe)))
    (cond
     ((and active-env (string= active-env env))
      (message "⚠️ Impossible de supprimer '%s' : cet environnement est actif." env))
     ((yes-or-no-p (format "Supprimer définitivement l'environnement '%s' ? " env))
      (message "🧹 Suppression de l'environnement '%s' en cours..." env)
      (metal-util-run-in-eat
       (format "\"%s\" env remove -n %s -y" conda-exe env)
       "*Conda Delete*"
       t)))))

(defun metal-conda-changer-environnement ()
  "Changer l'environnement Conda par défaut via une sélection interactive."
  (interactive)
  (unless (metal-conda--require-conda)
    (user-error "Conda n'est pas installé"))
  (require 'conda)
  (let* ((envs-dir (expand-file-name "envs" conda-env-home-directory))
         (env-paths (when (file-directory-p envs-dir)
                      (directory-files envs-dir t "^[^.]")))
         (env-alist (mapcar (lambda (p) (cons (file-name-nondirectory p) p))
                            (or env-paths '())))
         (env-alist-avec-base (cons (cons "base" conda-env-home-directory) env-alist))
         (noms (mapcar #'car env-alist-avec-base))
         (choix (completing-read "Choisir un environnement Conda : " noms nil t))
         (chemin-complet (cdr (assoc choix env-alist-avec-base))))
    (if (not chemin-complet)
        (message "❌ Environnement '%s' introuvable" choix)
      (customize-save-variable 'metal-conda-environnement-defaut chemin-complet)
      (conda-env-activate-path chemin-complet)
      (message "✅ Environnement Conda par défaut : %s (%s)" choix chemin-complet))))

(defun metal-spacy-installer-modele ()
  "Choisir un environnement Conda et y installer un modèle SpaCy."
  (interactive)
  (unless (metal-conda--require-conda)
    (user-error "Conda n'est pas installé"))
  (require 'conda)
  (let* ((paths (conda-env-candidates))
         (names (mapcar #'file-name-nondirectory paths))
         (env (completing-read "Choisir un environnement Conda : " names nil t))
         (model (completing-read "Choisir le modèle SpaCy à installer : "
                                 '("fr_core_news_sm" "fr_core_news_md" "fr_core_news_lg"
                                   "en_core_web_sm" "en_core_web_md" "en_core_web_lg"
                                   "de_core_news_sm" "es_core_news_sm"
                                   "pt_core_news_sm" "it_core_news_sm")
                                 nil t))
         (cmd (if (eq system-type 'windows-nt)
                  (format "CALL \"%s\" %s && python -m spacy download %s"
                          (expand-file-name "Scripts/activate.bat"
                                            conda-env-home-directory)
                          env model)
                (format "\"%s\" run -n %s python -m spacy download %s"
                        (expand-file-name "bin/conda" conda-env-home-directory)
                        env model))))
    (message "Installation du modèle %s dans l'environnement %s..." model env)
    (async-shell-command cmd "*SpaCy Model*")))

(defun metal-conda-shell (&optional env)
  "Ouvrir un terminal avec Conda configuré pour ENV (défaut : base).
Utilise Eat sur macOS/Linux (vraies couleurs ANSI, émulation TTY complète),
async-shell-command sur Windows (Eat non supporté). Le shell reste ouvert
pour permettre à l'utilisateur d'interagir avec conda manuellement.
Le répertoire de travail initial est toujours le dossier personnel.

Appelée interactivement, propose la liste des environnements Conda
disponibles via completing-read."
  (interactive
   (list
    (if (not conda-env-home-directory)
        nil  ; si conda pas dispo, le unless suivant va afficher user-error
      (let* ((envs-dir (expand-file-name "envs" conda-env-home-directory))
             (env-paths (when (file-directory-p envs-dir)
                          (directory-files envs-dir nil "^[^.]")))
             ;; "base" en premier, puis les autres envs triés
             (noms (cons "base" (sort (or env-paths '()) #'string<))))
        (completing-read "Environnement Conda : " noms nil t nil nil "base")))))
  (unless conda-env-home-directory
    (user-error "Conda non disponible. Utilisez M-x metal-deps-installer-miniconda"))
  (let* ((env-name (if (or (null env) (string-empty-p env)) "base" env))
         (buf-name (format "*Conda-Shell [%s]*" env-name))
         ;; Démarrer dans le dossier personnel plutôt que dans le répertoire
         ;; d'Emacs (ex. C:\Program Files\Emacs\...\bin sur Windows).
         (default-directory (file-name-as-directory
                             (or (getenv "HOME")
                                 (getenv "USERPROFILE")
                                 "~")))
         (cmd
          (cond
           ;; Windows : cmd /k garde le shell ouvert après l'activation.
           ;; On force d'abord un `cd /d' vers le dossier personnel, car
           ;; cmd.exe démarre par défaut dans le répertoire d'Emacs
           ;; (ex. C:\Program Files\Emacs\...\bin) et activate.bat ne
           ;; change pas le cwd.
           ((eq system-type 'windows-nt)
            (let ((activate-bat
                   (expand-file-name "Scripts/activate.bat" conda-env-home-directory))
                  (home (or (getenv "USERPROFILE") (getenv "HOME") "C:\\")))
              (unless (file-exists-p activate-bat)
                (user-error "activate.bat introuvable dans %s" conda-env-home-directory))
              (format "cmd /k \"cd /d \"%s\" && \"%s\" %s\""
                      home activate-bat env-name)))
           ;; macOS/Linux/ChromeOS : technique du rcfile temporaire.
           ;; On crée un répertoire temporaire avec un fichier rc qui :
           ;;   1. Source le vrai rc de l'utilisateur (prompt, alias)
           ;;   2. Active l'env conda (ce qui AJOUTE `(TAL)' au prompt)
           ;; Puis on lance le shell interactif sur ce fichier rc.
           ;; Résultat : le shell a le prompt utilisateur AVEC le préfixe conda.
           ;; On branche selon le shell : zsh (ZDOTDIR) vs bash (--rcfile).
           ;; Sur ChromeOS/Crostini, $SHELL vaut typiquement /bin/bash,
           ;; d'où l'importance de ne pas supposer zsh.
           (t
            (let* ((shell (or (getenv "SHELL") "/bin/bash"))
                   (shell-base (file-name-nondirectory shell))
                   (is-zsh (string-match-p "zsh" shell-base))
                   (conda-sh (expand-file-name "etc/profile.d/conda.sh"
                                               conda-env-home-directory))
                   (tmp-dir (make-temp-file "metal-conda-" t))
                   (home (or (getenv "HOME") "~")))
              (cond
               ;; --- zsh : ZDOTDIR + .zshrc ---
               (is-zsh
                (let ((tmp-zshrc (expand-file-name ".zshrc" tmp-dir))
                      (user-zshrc (expand-file-name ".zshrc" home)))
                  (with-temp-file tmp-zshrc
                    (insert "# Fichier généré par metal-conda-shell\n")
                    (when (file-exists-p user-zshrc)
                      (insert (format "source %s\n" (shell-quote-argument user-zshrc))))
                    (insert (format "source %s\n" (shell-quote-argument conda-sh)))
                    (insert (format "conda activate %s\n" env-name)))
                  (format "ZDOTDIR=%s %s -i"
                          (shell-quote-argument tmp-dir)
                          shell)))
               ;; --- bash (et compatibles) : --rcfile ---
               (t
                (let ((tmp-rc (expand-file-name ".bashrc-metal" tmp-dir))
                      (user-bashrc (expand-file-name ".bashrc" home)))
                  (with-temp-file tmp-rc
                    (insert "# Fichier généré par metal-conda-shell\n")
                    (when (file-exists-p user-bashrc)
                      (insert (format "source %s\n" (shell-quote-argument user-bashrc))))
                    (insert (format "source %s\n" (shell-quote-argument conda-sh)))
                    (insert (format "conda activate %s\n" env-name)))
                  (format "%s --rcfile %s -i"
                          shell
                          (shell-quote-argument tmp-rc)))))))))) 
    (metal-util-run-in-eat cmd buf-name nil)))

;;; ═══════════════════════════════════════════════════════════════════
;;; 11. Complétion (Corfu + Cape)
;;; ═══════════════════════════════════════════════════════════════════
;; Note : Corfu/Cape sont utilisés globalement. Si tu crées un jour
;; metal-completion.el, déplace les deux use-package là.

(use-package corfu
  :ensure t
  :custom
  (corfu-auto nil)
  (corfu-cycle t)
  (corfu-popupinfo-delay 0.2)
  :init
  (global-corfu-mode 1)
  :config
  (require 'corfu-popupinfo nil t)
  (add-hook 'corfu-mode-hook #'corfu-popupinfo-mode))

(use-package cape
  :ensure t)

;;; ═══════════════════════════════════════════════════════════════════
;;; 12. (Terminal Eat : configuré dans metal-utile.el)
;;; ═══════════════════════════════════════════════════════════════════
;; Eat est maintenant installé et configuré dans `metal-utile.el', puisque
;; c'est ce module qui l'utilise directement via `metal-util-run-in-eat'.
;; Le raccourci global `C-c t' (ouvrir un shell Eat interactif) est défini
;; là-bas. Sur Windows, Eat n'est pas chargé (non supporté) — voir
;; metal-utile.el pour les détails.

;;; ═══════════════════════════════════════════════════════════════════
;;; 12b. Barre de boutons dape (header-line dynamique)
;;; ═══════════════════════════════════════════════════════════════════
;; Ajoute une série de boutons cliquables (continue, next, step, quit…)
;; À LA SUITE de la barre d'icônes existante (bouton debug, shell, etc.),
;; uniquement quand une session dape est active. La barre existante
;; n'est jamais écrasée — on sauvegarde et on concatène, puis on restaure
;; à la fin de session. Idéal pour les étudiants : tout est à la souris,
;; les raccourcis clavier restent disponibles en parallèle.

(defvar-local metal-python--dape-header-saved nil
  "Sauvegarde de `header-line-format' avant l'affichage de la barre dape.
Permet de restaurer l'état original quand la session se termine.")

(defun metal-python--dape-session-active-p ()
  "Retourne t si une session dape est active (démarrée ou arrêtée)."
  (and (featurep 'dape)
       (boundp 'dape--connection)
       dape--connection))

(defun metal-python--dape-bouton (label help fn &optional face)
  "Construire un bouton cliquable pour le header-line.
LABEL : texte affiché. HELP : tooltip. FN : fonction appelée au clic.
FACE : face optionnelle pour colorer le bouton.

Note technique : dans un header-line, les clics arrivent comme
`header-line mouse-1'. La lambda doit accepter l'event (via
`interactive \"e\"') sinon Emacs ignore le clic. De plus, on bascule
dans le buffer qui a été cliqué (via posn-window de l'event) avant
d'appeler FN : les commandes dape comme `dape-continue' exigent que
le buffer courant soit celui de la session débuggée, sinon elles
échouent avec `No stopped debug connection'."
  (propertize
   (format " %s " label)
   'face (or face 'mode-line-emphasis)
   'mouse-face 'highlight
   'help-echo help
   'keymap (let ((map (make-sparse-keymap)))
             (define-key map [header-line mouse-1]
                         `(lambda (event)
                            (interactive "e")
                            (let* ((posn (event-start event))
                                   (window (posn-window posn))
                                   (buffer (and (windowp window)
                                                (window-buffer window))))
                              (if (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (select-window window)
                                    (call-interactively #',fn))
                                (call-interactively #',fn)))))
             map)))

(defun metal-python--dape-watch-depuis-selection-ou-symbole ()
  "Ajouter un watch : sélection active si présente, sinon symbole sous le curseur, sinon prompt.
Contournement du problème classique : un clic dans le header-line
désactive la région avant que la fonction soit appelée, donc
`dape-watch-dwim' ne voit jamais la sélection. On capture la région
ou le symbole à l'avance, avant le clic."
  (interactive)
  (require 'dape)
  (let ((expression
         (cond
          ;; 1. Région active → son contenu
          ((use-region-p)
           (buffer-substring-no-properties (region-beginning) (region-end)))
          ;; 2. Symbole sous le curseur (variable Python)
          ((thing-at-point 'symbol t))
          ;; 3. Sinon prompt
          (t (read-string "Expression à surveiller : ")))))
    (when (and expression (not (string-empty-p expression)))
      (dape-watch-dwim expression))))

(defun metal-python--dape-header-format ()
  "Construire la chaîne du header-line pour une session dape active."
  (concat
   (metal-python--dape-bouton "▶ Continue" "Continuer jusqu'au prochain breakpoint"
                              #'dape-continue 'success)
   " "
   (metal-python--dape-bouton "↷ Next" "Ligne suivante, sans entrer dans les fonctions"
                              #'dape-next)
   " "
   (metal-python--dape-bouton "↓ Step-in" "Entrer dans la fonction"
                              #'dape-step-in)
   " "
   (metal-python--dape-bouton "↑ Step-out" "Sortir de la fonction"
                              #'dape-step-out)
   "  │  "
   (metal-python--dape-bouton "◉ Watch"
                              "Surveiller la sélection ou le symbole sous le curseur"
                              #'metal-python--dape-watch-depuis-selection-ou-symbole)
   " "
   (metal-python--dape-bouton "● Breakpoint" "Poser/enlever un breakpoint à la ligne courante"
                              #'dape-breakpoint-toggle)
   " "
   (metal-python--dape-bouton "✕ Quitter" "Terminer la session de débogage"
                              #'dape-quit 'error)))

(defun metal-python--dape-header-activer ()
  "Remplacer le header-line par la barre de boutons dape.
L'ancienne barre (bouton debug, shell, etc.) est sauvegardée et
restaurée en fin de session. Pendant le débogage, seuls les boutons
dape sont visibles — ce choix évite que la barre combinée dépasse
la largeur de l'écran sur les ordinateurs à faible résolution."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'python-mode 'python-ts-mode)
        ;; Sauvegarder l'ancien format (une seule fois par session dape)
        (unless metal-python--dape-header-saved
          (setq metal-python--dape-header-saved (or header-line-format 'none)))
        ;; Remplacer par les boutons dape seulement (pas de concaténation)
        (setq header-line-format '(:eval (metal-python--dape-header-format)))
        (force-mode-line-update)))))

(defun metal-python--dape-header-desactiver ()
  "Retirer les boutons dape et restaurer la barre d'icônes originale."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'python-mode 'python-ts-mode)
        (when metal-python--dape-header-saved
          (setq header-line-format
                (if (eq metal-python--dape-header-saved 'none)
                    nil
                  metal-python--dape-header-saved))
          (setq metal-python--dape-header-saved nil))
        (force-mode-line-update)))))

(defun metal-python--dape-header-setup ()
  "Installer les hooks dape pour cacher le header-line à la fin de session.
L'activation est faite directement dans `metal-python-deboguer-dape' (plus
fiable que `dape-start-hook' qui ne tire pas toujours).

La désactivation passe par deux mécanismes :
- advice après `dape-quit' et `dape-kill' (fin demandée par l'utilisateur)
- hook `kill-buffer-hook' sur le buffer dape-repl (couvre toutes les autres
  fins : exit code, exception non-gérée, crash du serveur). Quand dape
  termine une session, il kille son REPL."
  (with-eval-after-load 'dape
    (advice-add 'dape-quit :after #'metal-python--dape-header-desactiver-advice)
    (advice-add 'dape-kill :after #'metal-python--dape-header-desactiver-advice)
    ;; Observer la fin de session via `dape-update-state' qui est appelée
    ;; avec 'exited quand le programme débugé se termine. C'est le point
    ;; le plus fiable, plus que `dape-update-ui-hook' qui tire trop souvent
    ;; (y compris pendant le démarrage où `dape--connection' est transitoirement nil).
    (advice-add 'dape--update-state :after
                #'metal-python--dape-header-sur-etat)))

(defun metal-python--dape-header-sur-etat (&rest args)
  "Désactiver le header quand l'état dape indique fin de session.
ARGS vient de l'advice sur `dape--update-state'. Sa signature varie
selon les versions : (CONN STATE) ou (CONN STATE ...). On scanne
ARGS pour trouver un symbole d'état terminal."
  (when (cl-some (lambda (x) (memq x '(exited terminated))) args)
    (metal-python--dape-header-desactiver)))

(defun metal-python--dape-header-desactiver-advice (&rest _args)
  "Wrapper pour l'advice — ignore les arguments passés à `dape-quit'/`dape-kill'."
  (metal-python--dape-header-desactiver))

;;; --- Clic dans la marge pour toggle un breakpoint ---

(defun metal-python-toggle-breakpoint-marge (event)
  "Poser/enlever un breakpoint à la ligne cliquée dans la marge gauche.
EVENT est l'événement souris. Nécessite dape chargé."
  (interactive "e")
  (require 'dape)
  (let* ((posn (event-start event))
         (pos (posn-point posn)))
    (when pos
      (save-excursion
        (goto-char pos)
        (dape-breakpoint-toggle)))))



(defun metal-python--setup-buffer ()
  "Configuration complète d'un buffer Python.
Appelé via `python-mode-hook' et `python-ts-mode-hook'."
  ;; --- Indentation ---
  (setq-local indent-tabs-mode nil)
  (setq-local python-indent-offset 4)
  (setq-local tab-width 4)
  ;; --- TAB / Shift-TAB ---
  (local-set-key (kbd "<tab>")   #'metal-python-tab)
  (local-set-key (kbd "TAB")     #'metal-python-tab)
  (local-set-key [backtab]       #'metal-python-backtab)
  (local-set-key (kbd "<S-tab>") #'metal-python-backtab)
  ;; --- Raccourcis exécution ---
  (local-set-key [f5]           #'metal-python-sauvegarde-execute)
  (local-set-key (kbd "C-<f5>") #'metal-python-deboguer)
  (local-set-key [f6]           #'metal-python-redemarre)
  ;; --- Breakpoints : clic gauche dans la marge pour poser/enlever ---
  ;; (Les raccourcis clavier F5/F10/F11 sont gérés par le header-line
  ;; pendant une session dape — voir section 13b.)
  (local-set-key (kbd "<left-margin> <mouse-1>") #'metal-python-toggle-breakpoint-marge)
  (local-set-key (kbd "<left-fringe> <mouse-1>") #'metal-python-toggle-breakpoint-marge)
  ;; --- Header-line dape : apparaît pendant une session de débogage ---
  (metal-python--dape-header-setup)
  ;; --- Complétion CAPF (Corfu/Cape) ---
  (setq-local completion-at-point-functions
              (list (car (default-value 'completion-at-point-functions))
                    #'cape-keyword
                    #'cape-dabbrev
                    #'cape-file))
  ;; --- Eldoc : une ligne seulement dans l'echo area ---
  (setq-local eldoc-echo-area-use-multiline-p 1)
  (setq-local eldoc-echo-area-prefer-doc-buffer t)
  ;; --- Activer Conda (pick-interpreter + modeline sont déclenchés
  ;;     automatiquement via `conda-postactivate-hook'). Si aucun env ne
  ;;     peut être activé, on configure quand même l'interpréteur avec ce
  ;;     qui est dispo dans PATH.
  (unless (metal-python--ensure-conda-env)
    (metal-python-pick-interpreter))
  ;; --- Démarrer un shell Python s'il n'y en a pas déjà un ---
  ;; Déféré via run-with-idle-timer pour ne pas bloquer l'ouverture du fichier
  ;; et laisser Emacs finir la configuration du buffer d'abord.
  (unless (metal-python--shell-vivant-p)
    (run-with-idle-timer 0 nil #'metal-python--ensure-shell-visible)))

(add-hook 'python-mode-hook    #'metal-python--setup-buffer)
(add-hook 'python-ts-mode-hook #'metal-python--setup-buffer)

;;; metal-python-toolbar-snippet.el --- À ajouter dans metal-python.el -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Ce fichier contient les définitions à AJOUTER dans `metal-python.el',
;; en remplacement des fonctions `my/python-header-line' et
;; `my/format-toolbar-button-icon' qui se trouvent actuellement dans
;; `init.el' (et qu'il faut RETIRER de là après migration).
;;
;; Côté init.el, plus rien à faire pour la barre Python : il suffit que
;; `metal-python' soit chargé (require), et le hook fait le reste.

;;; Code:

(require 'metal-toolbar)

;; Ajustement de hauteur d'icône spécifique à Python (Windows compense
;; un rendu plus gros des nerd-icons sur cette plateforme).
(defcustom metal-python-icon-height
  (if (eq system-type 'windows-nt) 0.8 1.2)
  "Hauteur des icônes de la barre Python."
  :type 'number
  :group 'metal-python)

(defun metal-python--icon (name color)
  "Icône NAME (FontAwesome) colorée avec COLOR pour la barre Python."
  (metal-toolbar-icon name :color color :height metal-python-icon-height))

(defun metal-python-toolbar-format ()
  "Construit la barre d'outils Python."
  (concat
   (metal-toolbar-vpadding) " "

   (metal-toolbar-button
    (metal-python--icon "nf-fa-play" "#34C759")
    "Exécuter le script"
    #'metal-python-sauvegarde-execute)

   (metal-toolbar-button
    (metal-python--icon "nf-fa-bug" "#FF3B30")
    "Lancer le débogueur"
    #'metal-python-deboguer)

   (metal-toolbar-button
    (metal-python--icon "nf-fa-refresh" "#007AFF")
    "Démarrer Python"
    #'metal-python-redemarre)

   (metal-toolbar-separator)

   (metal-toolbar-button
    (metal-python--icon "nf-fa-arrows" "#8E8E93")
    (format "Basculer la position du shell Python (actuel : %s)"
            (if (eq metal-python-shell-position-defaut 'bottom)
                "en bas" "à droite"))
    #'metal-python-shell-bascule-position)

   (metal-toolbar-separator)

   (metal-toolbar-button
    (metal-python--icon "nf-fa-list_alt" "#FF9500")
    "Aide-mémoire"
    #'aide-memoire-python)

   (metal-toolbar-button
    (metal-python--icon "nf-fa-comments" "#AF52DE")
    "ChatGPT"
    #'chatgpt)

   " " (metal-toolbar-vpadding)))

(defun metal-python-header-line ()
  "Active la barre d'outils dans le tampon Python courant."
  (setq-local header-line-format
              '(:eval (metal-python-toolbar-format))))

;; Active automatiquement dans tous les buffers Python.
(add-hook 'python-mode-hook #'metal-python-header-line)
;; Si tu utilises python-ts-mode (tree-sitter) :
;; (add-hook 'python-ts-mode-hook #'metal-python-header-line)

(provide 'metal-python-toolbar)
;;; metal-python-toolbar-snippet.el ends here



;;; ═══════════════════════════════════════════════════════════════════
;;; 14. Clés globales et ajustements généraux
;;; ═══════════════════════════════════════════════════════════════════
;; Note : ces réglages affectent plus que Python. À déplacer vers
;; metal-base.el ou metal-keys.el si cela existe un jour.

;; BACKTAB décodé partout (TTY/Windows/macOS)
(define-key input-decode-map "\e[Z" [backtab])
(define-key key-translation-map (kbd "S-TAB")           [backtab])
(define-key key-translation-map (kbd "S-<tab>")         [backtab])
(define-key key-translation-map (kbd "<S-tab>")         [backtab])
(define-key key-translation-map (kbd "<S-iso-lefttab>") [backtab])

;; Éviter que yasnippet vole TAB
(with-eval-after-load 'yasnippet
  (define-key yas-minor-mode-map (kbd "TAB")     nil)
  (define-key yas-minor-mode-map (kbd "<tab>")   nil)
  (define-key yas-minor-mode-map (kbd "<backtab>") nil)
  (define-key yas-minor-mode-map (kbd "S-TAB")  nil))

(setq tab-always-indent nil)
(global-set-key (kbd "M-TAB")  #'completion-at-point)
(global-set-key (kbd "C-c C-e") #'metal-python-compile)

(provide 'metal-python)

;;; metal-python.el ends here
