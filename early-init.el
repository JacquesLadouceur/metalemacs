;;; early-init.el --- MetalEmacs early init -*- lexical-binding: t; coding: utf-8; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;; S'exécute AVANT init.el (Emacs 27+)
;; Objectifs (Windows) :
;; - Si HOME est problématique (espaces ou non-ASCII), basculer vers un HOME ASCII sûr.
;; - Créer ~/Documents dans le nouveau HOME (pas de lien symbolique).
;; - Informer l'utilisateur (une fois) APRÈS l'affichage du premier frame.
;; - Assurer que git est disponible for straight.el; si manquant, installer PortableGit.
;; - L'installation PortableGit utilise une fenêtre PowerShell VISIBLE window (Emacs attend).
;; - Configurer le frame UNE SEULE FOIS pour éviter les redimensionnements multiples.

;;; Code:

;; ----------------------------
;; Bases de performance au démarrage
;; ----------------------------

;; Préférer .elc pour la vitesse
(setq load-prefer-newer nil)

;; Accélérer le démarrage : augmenter le seuil GC, restaurer après le démarrage
(setq gc-cons-threshold most-positive-fixnum)
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 16 1024 1024)))) ; 16MB

;; Ne pas auto-initialiser package.el (straight.el gérera les packages)
(setq package-enable-at-startup nil)

;; Éviter le bruit visuel avant le premier frame
(setq inhibit-startup-screen t)
(setq inhibit-startup-message t)

;; ═══════════════════════════════════════════════════════════════════
;; CONFIGURATION DU FRAME - CONSOLIDÉE POUR ÉVITER LES REDIMENSIONNEMENTS
;; ═══════════════════════════════════════════════════════════════════

;; Empêcher les redimensionnements automatiques causés par les changements de police/UI
(setq frame-inhibit-implied-resize t)

;; Permettre le redimensionnement au pixel près
(setq frame-resize-pixelwise t)

;; Configurer la police AVANT la création du frame (Windows)
;; Cela évite un redimensionnement quand la police est chargée plus tard
(when (eq system-type 'windows-nt)
  (set-face-attribute 'default nil :family "Consolas" :height 110))

;; Configurer la police sur macOS
(when (eq system-type 'darwin)
  (set-face-attribute 'default nil :family "Menlo" :height 130))

;; Taille initiale minimale - sera ajustée par tailleInitiale dans init.el
;; Ces valeurs sont utilisées SEULEMENT si tailleInitiale n'est pas appelée
(unless (assq 'width default-frame-alist)
  (add-to-list 'default-frame-alist '(width . 120)))
(unless (assq 'height default-frame-alist)
  (add-to-list 'default-frame-alist '(height . 35)))

;; Copier dans initial-frame-alist pour cohérence
(setq initial-frame-alist default-frame-alist)

;; Note: On ne masque PAS menu-bar/tool-bar ici car l'utilisateur les veut

;; ----------------------------
;; Petits utilitaires Windows
;; ----------------------------

(defun metal-early--win-path (p)
  "Convertit le chemin P en forme compatible Windows pour PowerShell (barres obliques inverses)."
  (replace-regexp-in-string "/" "\\\\" (expand-file-name p) t t))

(defun metal-early--path-has-problematic-chars-p (path)
  "Retourne non-nil si PATH contient des caractères problématiques.
Cherche tout caractère qui n'est PAS: a-z A-Z 0-9 / \\ : . _ -"
  (and (stringp path)
       (string-match-p "[^-a-zA-Z0-9/\\\\:._]" path)))

(defvar metal-early-setx-home-enabled nil
  "Si non-nil, MetalEmacs peut persister HOME en utilisant setx sur Windows (désactivé par défaut).")

(defun metal-early--configure-home-permanently (new-home)
  "Persist HOME via `setx HOME` only if `metal-early-setx-home-enabled` is non-nil."
  (when (and (eq system-type 'windows-nt)
             metal-early-setx-home-enabled
             (stringp new-home)
             (file-directory-p new-home))
    (call-process "cmd.exe" nil nil nil "/c"
                  (concat "setx HOME " "\"" new-home "\""))))

(defun metal-early--sanitize-username-ascii (s)
  "Nom d'utilisateur ASCII uniquement (meilleur effort).
Utilise les codes Unicode pour être indépendant de l'encodage du fichier."
  (let ((s (downcase (or s ""))))
    ;; Translittération avec codes Unicode explicites (plus robuste)
    (dolist (pair `((,(string #x00E0) . "a")   ; à
                    (,(string #x00E2) . "a")   ; â
                    (,(string #x00E4) . "a")   ; ä
                    (,(string #x00E9) . "e")   ; é
                    (,(string #x00E8) . "e")   ; è
                    (,(string #x00EA) . "e")   ; ê
                    (,(string #x00EB) . "e")   ; ë
                    (,(string #x00EF) . "i")   ; ï
                    (,(string #x00EE) . "i")   ; î
                    (,(string #x00F4) . "o")   ; ô
                    (,(string #x00F6) . "o")   ; ö
                    (,(string #x00F9) . "u")   ; ù
                    (,(string #x00FB) . "u")   ; û
                    (,(string #x00FC) . "u")   ; ü
                    (,(string #x00E7) . "c"))) ; ç
      (setq s (replace-regexp-in-string (car pair) (cdr pair) s t t)))
    ;; Remplacer les espaces et tout ce qui n'est pas ASCII par un underscore
    (setq s (replace-regexp-in-string "[^[:ascii:]]" "_" s))
    (setq s (replace-regexp-in-string "[[:space:]]+" "_" s))
    s))

;; ------------------------------------------------------------
;; Avis d'ajustement HOME (affiché une fois, après le premier frame)
;; ------------------------------------------------------------

(defvar metal-early--home-adjusted-p nil)
(defvar metal-early--home-original nil)
(defvar metal-early--home-safe nil)

(defvar metal-early--home-notice-marker
  (expand-file-name ".metal-home-adjusted-notice" user-emacs-directory)
  "Fichier marqueur pour éviter de répéter l'avertissement HOME-adjusted.")

(defun metal-early--notify-home-adjustment ()
  "Notifie l'utilisateur une fois que HOME a été changé et que Documents a été créé."
  (when (and metal-early--home-adjusted-p
             (not (file-exists-p metal-early--home-notice-marker)))
    (with-temp-file metal-early--home-notice-marker
      (insert "ok\n"))
    (let* ((docs (expand-file-name "Documents/" (or metal-early--home-safe "")))
           (msg (format
                 (concat "MetalEmacs: HOME contained espaces ou non-ASCII characters.\n\n"
                         "HOME original :\n  %s\n\n"
                         "Nouveau HOME (sûr) :\n  %s\n\n"
                         "Dossier assuré :\n  %s\n\n"
                         "Note : Ceci ne crée PAS de lien symbolique vers votre profil original.\n"
                         "Si vous voulez persister HOME au niveau système, activez metal-early-setx-home-enabled.")
                 (or metal-early--home-original "")
                 (or metal-early--home-safe "")
                 docs)))
      ;; Message UI visible (après que le premier frame existe)
      (ignore-errors (message-box "%s" msg))
      ;; Écrire aussi dans *Messages*
      (message "%s" (replace-regexp-in-string "\n" " " msg)))))

(add-hook 'window-setup-hook #'metal-early--notify-home-adjustment 100)

;; ----------------------------
;; HOME fix (pas de lien symbolique)
;; ----------------------------

(defun metal-early--fix-problematic-home ()
  "Ensure HOME is safe on Windows (no spaces, no non-ascii) for tools like git/conda.
Si un lien symbolique ASCII existe, l'utilise automatiquement.
Sinon, prépare des instructions pour l'utilisateur."
  (when (eq system-type 'windows-nt)
    (let* ((home (getenv "HOME"))
           (userprofile (getenv "USERPROFILE")))
      
      ;; IMPORTANT: Si HOME est défini mais n'existe pas, revenir à USERPROFILE
      (when (and (stringp home) 
                 (not (string= home ""))
                 (not (file-directory-p home)))
        (message "MetalEmacs: HOME=%s n'existe pas, utilisation de USERPROFILE=%s" home userprofile)
        (setq home userprofile)
        (setenv "HOME" home))
      
      ;; If HOME is missing, prefer USERPROFILE
      (when (or (not (stringp home)) (string= home ""))
        (when (and (stringp userprofile) (not (string= userprofile "")))
          (setq home userprofile)
          (setenv "HOME" home)))
      
      ;; If HOME is problematic, chercher un lien symbolique ASCII
      (when (and (stringp home) (metal-early--path-has-problematic-chars-p home))
        (let* ((uname (or (getenv "USERNAME") "user"))
               (safe-uname (metal-early--sanitize-username-ascii uname))
               (safe-home (format "C:/Users/%s" safe-uname)))
          
          (if (file-exists-p safe-home)
              ;; Le lien existe, l'utiliser silencieusement
              (progn
                (setenv "HOME" safe-home)
                (setenv "USERPROFILE" safe-home)
                (setq metal-early--home-adjusted-p t)
                (setq metal-early--home-original home)
                (setq metal-early--home-safe safe-home)
                (message "MetalEmacs: HOME → %s" safe-home))
            
            ;; Le lien n'existe pas, préparer les instructions
            (setq metal-early--symlink-instructions
                  (list :needed t
                        :original home
                        :safe safe-home
                        :safe-win (replace-regexp-in-string "/" "\\\\" safe-home)
                        :original-win (replace-regexp-in-string "/" "\\\\" home)))))))))

(defvar metal-early--symlink-instructions nil
  "Instructions pour créer le lien symbolique si nécessaire.")

(defun metal-early--show-symlink-instructions ()
  "Affiche les instructions pour créer le lien symbolique."
  (when (and metal-early--symlink-instructions
             (plist-get metal-early--symlink-instructions :needed))
    (let* ((original (plist-get metal-early--symlink-instructions :original))
           (safe (plist-get metal-early--symlink-instructions :safe))
           (safe-win (plist-get metal-early--symlink-instructions :safe-win))
           (original-win (plist-get metal-early--symlink-instructions :original-win))
           (buf (get-buffer-create "*MetalEmacs - Configuration HOME*")))
      (with-current-buffer buf
        (erase-buffer)
        (insert "╔══════════════════════════════════════════════════════════════════╗\n")
        (insert "║           MetalEmacs - Configuration HOME requise                ║\n")
        (insert "╚══════════════════════════════════════════════════════════════════╝\n\n")
        (insert (format "Votre dossier HOME contient des caractères spéciaux :\n  %s\n\n" original))
        (insert "Cela peut causer des problèmes avec conda, git et d'autres outils.\n\n")
        (insert "══════════════════════════════════════════════════════════════════\n")
        (insert "ÉTAPE 1 : Créer un lien symbolique (une seule fois)\n")
        (insert "══════════════════════════════════════════════════════════════════\n\n")
        (insert "Ouvrez une invite de commandes EN TANT QU'ADMINISTRATEUR et collez :\n\n")
        (insert (format "    mklink /D \"%s\" \"%s\"\n\n" safe-win original-win))
        (insert "══════════════════════════════════════════════════════════════════\n")
        (insert "ÉTAPE 2 : Définir HOME de façon permanente (optionnel mais recommandé)\n")
        (insert "══════════════════════════════════════════════════════════════════\n\n")
        (insert "IMPORTANT: Faites l'étape 1 D'ABORD sinon Emacs ne démarrera plus !\n\n")
        (insert "Dans la même invite de commandes (ou une nouvelle), collez :\n\n")
        (insert (format "    setx HOME \"%s\"\n\n" safe-win))
        (insert "Si vous avez fait setx AVANT de créer le lien, supprimez HOME avec :\n\n")
        (insert "    reg delete \"HKCU\\Environment\" /v HOME /f\n\n")
        (insert "══════════════════════════════════════════════════════════════════\n")
        (insert "ÉTAPE 3 : Redémarrer Emacs\n")
        (insert "══════════════════════════════════════════════════════════════════\n\n")
        (insert "Après ces étapes, redémarrez Emacs. Ce message ne réapparaîtra plus.\n\n")
        (insert "──────────────────────────────────────────────────────────────────\n")
        (insert (format "Lien symbolique : %s\n" safe))
        (insert (format "Pointe vers     : %s\n" original))
        (goto-char (point-min))
        (special-mode))
      ;; Afficher dans la fenêtre principale (pas treemacs), comme un onglet
      (let ((win (or (get-window-with-predicate
                      (lambda (w)
                        (not (string-match-p "Treemacs" (buffer-name (window-buffer w))))))
                     (selected-window))))
        (select-window win)
        (switch-to-buffer buf)))))

(add-hook 'emacs-startup-hook #'metal-early--show-symlink-instructions 99)

;; Appliquer la correction de HOME tôt
(metal-early--fix-problematic-home)

;; ----------------------------
;; PortableGit (Windows) pour straight.el
;; ----------------------------

(defvar metal-early-git-portable-dir
  (expand-file-name "PortableGit" user-emacs-directory)
  "Répertoire d'installation de PortableGit sous user-emacs-directory.")

(defvar metal-early--git-config-marker
  (expand-file-name ".metal-git-config-done" user-emacs-directory)
  "Fichier marqueur utilisé pour éviter d'exécuter git config à chaque démarrage.")

(defun metal-early--ensure-git-tuning (git-exe)
  "Applique quelques paramètres git une seule fois (aide à éviter certains problèmes HTTP)."
  (when (and (stringp git-exe)
             (file-exists-p git-exe)
             (not (file-exists-p metal-early--git-config-marker)))
    (call-process git-exe nil nil nil "config" "--global" "http.version" "HTTP/1.1")
    (call-process git-exe nil nil nil "config" "--global" "http.postBuffer" "524288000")
    (with-temp-file metal-early--git-config-marker
      (insert "ok\n")))
  (and (stringp git-exe) (file-exists-p git-exe)))

(defun metal-early--find-git-bin ()
  "Trouve un répertoire bin/cmd Git contenant git.exe. Retourne le répertoire ou nil."
  (let* ((home (or (getenv "HOME") (getenv "USERPROFILE") "C:/"))
         (candidates
          (list
           (expand-file-name "PortableGit/cmd" user-emacs-directory)
           (expand-file-name "PortableGit/bin" user-emacs-directory)
           (expand-file-name "scoop/apps/git/current/bin" home)
           (expand-file-name "scoop/shims" home)
           "C:/Program Files/Git/cmd"
           "C:/Program Files/Git/bin"
           "C:/Program Files (x86)/Git/bin"
           "C:/ProgramData/chocolatey/bin"
           "C:/tools/git/bin"
           "C:/Git/bin"
           (expand-file-name "AppData/Local/Programs/Git/bin" home))))
    (catch 'found
      (dolist (dir candidates)
        (when (and (stringp dir)
                   (file-exists-p (expand-file-name "git.exe" dir)))
          (throw 'found dir)))
      nil)))

(defun metal-early--windows-run-visible-powershell-wait (ps1-content)
  "Run PS1-CONTENT in a VISIBLE PowerShell window and wait; return exit code.
Implémentation : un PowerShell caché démarre un PowerShell visible (-Wait) et retourne son code de sortie."
  (let* ((ps1 (make-temp-file "metal-portablegit-" nil ".ps1"))
         (ps1-win (metal-early--win-path ps1))
         (buf (get-buffer-create "*MetalEmacs PowerShell*"))
         (cmd (format
               "$p=Start-Process powershell -WindowStyle Normal -Wait -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%s'; exit $p.ExitCode"
               ps1-win)))
    (with-temp-file ps1 (insert ps1-content))
    (with-current-buffer buf (erase-buffer))
    (unwind-protect
        (call-process "powershell" nil buf nil
                      "-NoProfile" "-ExecutionPolicy" "Bypass"
                      "-Command" cmd)
      (ignore-errors (delete-file ps1)))))

(defun metal-early--install-git-portable ()
  "Installe MinGit (PortableGit) dans `metal-early-git-portable-dir` (Windows).
Affiche une fenêtre PowerShell VISIBLE pour que l'utilisateur voie l'activité avant l'interface Emacs.

Cette version télécharge le *dernier* zip MinGit 64-bit depuis les versions Git for Windows
sur GitHub (via l'API GitHub), avec une URL de secours si l'API échoue."
  (unless (eq system-type 'windows-nt)
    (error "L'installation automatique de PortableGit n'est supportée que sur Windows"))
  (let* ((fallback-url
          "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/MinGit-2.47.1.2-64-bit.zip")
         (zip-file (expand-file-name "MinGit.zip" temporary-file-directory))
         (install-dir metal-early-git-portable-dir)
         (zip-file-win (metal-early--win-path zip-file))
         (install-dir-win (metal-early--win-path install-dir))
         (ps1 (concat
               "$ErrorActionPreference='Stop'\n"
               "Write-Host 'Un instant... installation de Git (PortableGit)...' -ForegroundColor Yellow\n"
               "Write-Host ''\n"
               "Write-Host 'Résolution de la dernière version de MinGit...'\n"
               "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12\n"
               "$headers = @{ 'User-Agent'='MetalEmacs' }\n"
               "$api = 'https://api.github.com/repos/git-for-windows/git/releases/latest'\n"
               "$url = $null\n"
               "try {\n"
               "  $rel = Invoke-RestMethod -Uri $api -Headers $headers\n"
               "  if ($rel -and $rel.assets) {\n"
               "    $asset = $rel.assets | Where-Object { $_.name -match '^MinGit-.*-64-bit\\.zip$' } | Select-Object -First 1\n"
               "    if ($asset -and $asset.browser_download_url) { $url = $asset.browser_download_url }\n"
               "  }\n"
               "} catch {\n"
               "  $url = $null\n"
               "}\n"
               "if (-not $url) {\n"
               "  Write-Host 'API GitHub échouée ; utilisation de l''URL de secours.' -ForegroundColor DarkYellow\n"
               "  $url = '" fallback-url "'\n"
               "}\n"
               "Write-Host ('Téléchargement : ' + $url)\n"
               "Invoke-WebRequest -Uri $url -OutFile '" zip-file-win "'\n"
               "Write-Host 'Extraction...'\n"
               "if (Test-Path -LiteralPath '" install-dir-win "') { Remove-Item -LiteralPath '" install-dir-win "' -Recurse -Force }\n"
               "New-Item -ItemType Directory -Path '" install-dir-win "' -Force | Out-Null\n"
               "Expand-Archive -Path '" zip-file-win "' -DestinationPath '" install-dir-win "' -Force\n"
               "Remove-Item -LiteralPath '" zip-file-win "' -Force\n"
               "Write-Host ''\n"
               "Write-Host 'Terminé.' -ForegroundColor Green\n"
               "exit 0\n")))
    (let ((code (metal-early--windows-run-visible-powershell-wait ps1)))
      (unless (and (numberp code) (= code 0))
        (error "Échec de l'installation de PortableGit (code de sortie : %s). Voir *MetalEmacs PowerShell*." code)))
    (message "MetalEmacs : PortableGit installé dans %s" install-dir)))

(defun metal-early--add-git-to-path ()
  "Assure que Git est disponible tôt (pour straight.el).
Si non trouvé, tente d'installer PortableGit.
Génère une erreur si Git ne peut pas être rendu disponible."
  (let ((git-bin (metal-early--find-git-bin)))
    
    ;; Si Git pas trouvé, tenter installation (Windows seulement)
    (unless git-bin
      (if (eq system-type 'windows-nt)
          ;; Windows : installation automatique de PortableGit
          (progn
            (message "")
            (message "════════════════════════════════════════════════════════")
            (message "MetalEmacs : Git non trouvé, installation de PortableGit...")
            (message "Une fenêtre PowerShell va apparaître - veuillez patienter.")
            (message "Cela peut prendre 2-3 minutes.")
            (message "════════════════════════════════════════════════════════")
            (message "")
            
            (condition-case err
                (progn
                  (metal-early--install-git-portable)
                  ;; MinGit utilise généralement cmd/git.exe
                  (setq git-bin (expand-file-name "cmd" metal-early-git-portable-dir))
                  
                  ;; Vérifier que git.exe existe bien
                  (unless (file-exists-p (expand-file-name "git.exe" git-bin))
                    (message "")
                    (message "✗ ERREUR : PortableGit installé mais git.exe introuvable !")
                    (message "  Attendu : %s" (expand-file-name "git.exe" git-bin))
                    (message "  Dossier d'installation : %s" metal-early-git-portable-dir)
                    (message "")
                    (error "Installation de PortableGit incomplète - git.exe manquant")))
              
              (error
               (message "")
               (message "✗ ERREUR : Échec de l'installation de PortableGit")
               (message "  Erreur : %s" (error-message-string err))
               (message "")
               (message "Solutions possibles :")
               (message "  1. Vérifiez votre connexion Internet")
               (message "  2. Installez Git manuellement depuis https://git-scm.com")
               (message "  3. Vérifiez que PowerShell n'est pas bloqué")
               (message "")
               (error "Échec de l'installation de Git - %s" (error-message-string err)))))
        
        ;; macOS/Linux : Git doit être installé manuellement
        (message "")
        (message "════════════════════════════════════════════════════════")
        (message "MetalEmacs : Git non trouvé !")
        (message "════════════════════════════════════════════════════════")
        (message "")
        (if (eq system-type 'darwin)
            (progn
              (message "Sur macOS, installez Git via l'une de ces méthodes :")
              (message "  • Xcode Command Line Tools : xcode-select --install")
              (message "  • Homebrew : brew install git")
              (message "  • Téléchargement : https://git-scm.com/download/mac"))
          (progn
            (message "Sur Linux, installez Git via votre gestionnaire de paquets :")
            (message "  • Debian/Ubuntu : sudo apt install git")
            (message "  • Fedora : sudo dnf install git")
            (message "  • Arch : sudo pacman -S git")))
        (message "")
        (message "Redémarrez Emacs après l'installation de Git.")
        (message "")
        (error "Git est requis mais non installé. Voir *Messages* pour les instructions.")))
    
    ;; Ajouter Git au PATH
    (if git-bin
        (progn
          (setenv "PATH" (concat git-bin ";" (or (getenv "PATH") "")))
          (add-to-list 'exec-path git-bin)
          (message "MetalEmacs : Git ajouté au PATH : %s" git-bin)
          
          ;; ═══════════════════════════════════════════════════════════
          ;; VÉRIFICATION CRITIQUE : Git doit être trouvable
          ;; ═══════════════════════════════════════════════════════════
          (let ((git-exe (executable-find "git")))
            (if git-exe
                (progn
                  (message "")
                  (message "✓ Git vérifié et disponible : %s" git-exe)
                  (message "")
                  ;; Appliquer la configuration Git
                  (metal-early--ensure-git-tuning git-exe))
              
              ;; ERREUR FATALE : Git installé mais pas trouvable
              (message "")
              (message "✗ ERREUR CRITIQUE : Git installé mais introuvable !")
              (message "")
              (message "Informations de débogage :")
              (message "  git-bin : %s" git-bin)
              (message "  PATH : %s" (substring (or (getenv "PATH") "") 0 
                                               (min 200 (length (or (getenv "PATH") "")))))
              (message "  exec-path[0] : %s" (car exec-path))
              (message "  git.exe existe : %s" 
                       (if (file-exists-p (expand-file-name "git.exe" git-bin)) "OUI" "NON"))
              (message "")
              (error "Git installé dans %s mais introuvable dans PATH !" git-bin))))
      
      ;; ERREUR FATALE : git-bin est nil malgré l'installation
      (message "")
      (message "✗ ERREUR CRITIQUE : Git n'a pas pu être installé")
      (message "")
      (message "Git est requis pour MetalEmacs (straight.el) mais n'a pas pu être rendu disponible.")
      (message "Consultez le buffer *Messages* pour plus de détails, ou installez Git manuellement.")
      (message "")
      (error "Git est requis mais n'a pas pu être installé"))))

;; Exécuter la configuration de git tôt pour que init.el (straight) puisse l'utiliser
;; Sur macOS/Linux, Git est généralement déjà dans le PATH (via Xcode CLT, Homebrew, apt, etc.)
(when (eq system-type 'windows-nt)
  (metal-early--add-git-to-path))

;; Corriger les permissions pdf-tools au démarrage (macOS/Linux)
;; Les bits exécutables sont perdus lors du transfert depuis Windows.
;; On cible repos/ (fichiers réels) car build/ contient des liens symboliques.
(when (memq system-type '(gnu/linux darwin))
  (let ((server-dir (expand-file-name
                     "straight/repos/pdf-tools/server/"
                     user-emacs-directory)))
    (when (file-directory-p server-dir)
      (shell-command (concat "chmod -R +x "
                             (shell-quote-argument server-dir))))))

(provide 'early-init)
;;; early-init.el ends here
