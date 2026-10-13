;;; metal-apparence.el --- Apparence de MetalEmacs (thème, espacements, onglets) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.2

;;; Commentaires:
;;
;; Ce module regroupe tout ce qui touche l'apparence générale :
;;
;; - thème Modus clair ou sombre (ou celui du système), avec une palette
;;   retouchée : mode-line et onglets plats, franges invisibles ;
;; - barre de titre macOS aux couleurs du thème ;
;; - onglets plats (remplacent les vagues powerline, qui ne suivaient
;;   pas le thème) ;
;; - mode-line épurée : modes mineurs masqués, nom du mode en français ;
;; - explorateur : panneau teinté, dossiers système et de synchronisation
;;   masqués ;
;; - prénom de l'utilisateur pour l'accueil du tableau de bord.
;;
;; Aucun paquet externe : tout repose sur Modus (intégré à Emacs ≥ 28)
;; et sur les faces natives.  Les choix (thème, prénom) sont persistés
;; dans metal-prefs.el par `metal-prefs-save'.
;;
;; Commandes :
;;   M-x metal-apparence-basculer          clair ⇄ sombre
;;   M-x metal-apparence-choisir           Clair / Sombre / Système
;;   M-x metal-utilisateur-definir-prenom  prénom affiché à l'accueil

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup metal-apparence nil
  "Apparence de MetalEmacs."
  :group 'faces
  :prefix "metal-apparence-")

;;; ═══════════════════════════════════════════════════════════════════
;;; Réglages
;;; ═══════════════════════════════════════════════════════════════════

(defcustom metal-apparence-theme 'clair
  "Thème de MetalEmacs : `clair', `sombre' ou `systeme'.
Avec `systeme', le thème suit le réglage clair/sombre du système
d'exploitation (détecté au démarrage ; suivi en direct sur macOS
quand Emacs le permet)."
  :type '(choice (const :tag "Clair" clair)
                 (const :tag "Sombre" sombre)
                 (const :tag "Système" systeme))
  :group 'metal-apparence)

(defcustom metal-utilisateur-prenom nil
  "Prénom affiché dans l'accueil du tableau de bord.
Si nil, le premier mot de `user-full-name' est utilisé quand ce nom
ressemble à un vrai nom (au moins deux mots) ; sinon l'accueil se
limite à « Bonjour »."
  :type '(choice (const :tag "Automatique" nil) string)
  :group 'metal-apparence)

(defcustom metal-apparence-mode-line-epuree t
  "Si non nil, la mode-line n'affiche que le mode majeur (en français)."
  :type 'boolean
  :group 'metal-apparence)

(defcustom metal-apparence-explorateur-masques
  '("\\`\\$RECYCLE\\.BIN\\'"
    "\\`System Volume Information\\'"
    "\\`\\.stfolder"
    "\\`\\.stversions\\'"
    "\\`\\.stignore\\'"
    "\\`#SyncVersion"
    "\\`IISExpress\\'"
    "\\`\\.DS_Store\\'"
    "\\`\\.localized\\'"
    "\\`desktop\\.ini\\'"
    "\\`Thumbs\\.db\\'"
    "\\`~\\$")
  "Expressions régulières des noms à masquer dans l'explorateur."
  :type '(repeat regexp)
  :group 'metal-apparence)

(defvar metal-apparence-apres-changement-hook nil
  "Hook exécuté après chaque application du thème.")

(defvar metal-apparence--mode-courant nil
  "Thème effectivement appliqué : `clair' ou `sombre'.")

;;; ═══════════════════════════════════════════════════════════════════
;;; Palette Modus
;;; ═══════════════════════════════════════════════════════════════════

(defconst metal-apparence--palette
  '((fringe unspecified)
    (border-mode-line-active unspecified)
    (border-mode-line-inactive unspecified)
    (bg-mode-line-active bg-dim)
    (fg-mode-line-active fg-main)
    (bg-mode-line-inactive bg-main)
    (fg-mode-line-inactive fg-dim)
    (bg-tab-bar bg-dim)
    (bg-tab-current bg-main)
    (bg-tab-other bg-dim))
  "Retouches de palette appliquées aux deux thèmes Modus.")

(defun metal-apparence-couleur (nom repli)
  "Retourner la couleur NOM de la palette Modus active, ou REPLI."
  (let ((c (and (fboundp 'modus-themes-get-color-value)
                (ignore-errors (modus-themes-get-color-value nom)))))
    (if (and (stringp c) (string-prefix-p "#" c)) c repli)))

(defun metal-apparence-sombre-p ()
  "Retourner non nil si le thème appliqué est sombre."
  (if metal-apparence--mode-courant
      (eq metal-apparence--mode-courant 'sombre)
    (eq (frame-parameter nil 'background-mode) 'dark)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Détection du réglage système
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-apparence--systeme-sombre-p ()
  "Retourner non nil si le système d'exploitation est en mode sombre."
  (ignore-errors
    (pcase system-type
      ('darwin
       (if (boundp 'ns-system-appearance)
           (eq (symbol-value 'ns-system-appearance) 'dark)
         (string-match-p
          "Dark"
          (with-output-to-string
            (call-process "defaults" nil standard-output nil
                          "read" "-g" "AppleInterfaceStyle")))))
      ('windows-nt
       (and (fboundp 'w32-read-registry)
            (eql 0 (w32-read-registry
                    'HKCU
                    "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
                    "AppsUseLightTheme"))))
      (_
       (and (executable-find "gsettings")
            (string-match-p
             "dark"
             (shell-command-to-string
              "gsettings get org.gnome.desktop.interface color-scheme")))))))

(defun metal-apparence--mode-effectif ()
  "Traduire `metal-apparence-theme' en `clair' ou `sombre'."
  (pcase metal-apparence-theme
    ('sombre 'sombre)
    ('systeme (if (metal-apparence--systeme-sombre-p) 'sombre 'clair))
    (_ 'clair)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Retouches de faces (après chaque chargement de thème)
;;; ═══════════════════════════════════════════════════════════════════

(defface metal-apparence-panneau
  '((t :inherit default))
  "Fond des panneaux latéraux (explorateur).
Sa couleur est fixée par `metal-apparence--retoucher' selon le thème."
  :group 'metal-apparence)

(defun metal-apparence--retoucher ()
  "Ajuster les faces qui ne dépendent pas de la palette seule."
  (let* ((sombre  (metal-apparence-sombre-p))
         (bg-main (metal-apparence-couleur 'bg-main (if sombre "#000000" "#ffffff")))
         (bg-dim  (metal-apparence-couleur 'bg-dim  (if sombre "#1e1e1e" "#f2f2f2")))
         (border  (metal-apparence-couleur 'border  (if sombre "#646464" "#9f9f9f")))
         (fg-main (metal-apparence-couleur 'fg-main (if sombre "#ffffff" "#000000")))
         (fg-dim  (metal-apparence-couleur 'fg-dim  (if sombre "#989898" "#595959"))))
    ;; Mode-line : bande plate, rembourrée verticalement.
    (set-face-attribute 'mode-line nil
                        :background bg-dim :foreground fg-main
                        :box `(:line-width (8 . 5) :color ,bg-dim)
                        :overline nil :underline nil)
    (set-face-attribute 'mode-line-inactive nil
                        :background bg-main :foreground fg-dim
                        :box `(:line-width (8 . 5) :color ,bg-main)
                        :overline nil :underline nil)
    ;; Onglets plats (si tab-line est déjà chargé ; sinon voir plus bas).
    (when (featurep 'tab-line)
      (metal-apparence--retoucher-onglets))
    ;; Séparateurs de fenêtres : couleur du panneau, filet d'un pixel.
    (when (facep 'window-divider)
      (set-face-attribute 'window-divider nil :foreground bg-dim)
      (set-face-attribute 'window-divider-first-pixel nil :foreground bg-dim)
      (set-face-attribute 'window-divider-last-pixel nil :foreground border))
    (set-face-attribute 'vertical-border nil :foreground border)
    ;; Panneau latéral teinté (Treemacs remappe déjà `default' sur sa
    ;; propre face de fond : c'est elle qu'il faut colorer).
    (set-face-attribute 'metal-apparence-panneau nil :background bg-dim)
    (when (facep 'treemacs-window-background-face)
      (set-face-attribute 'treemacs-window-background-face nil :background bg-dim))))

(defun metal-apparence--retoucher-onglets ()
  "Donner aux onglets un aspect plat aux couleurs du thème."
  (let* ((sombre  (metal-apparence-sombre-p))
         (bg-main (metal-apparence-couleur 'bg-main (if sombre "#000000" "#ffffff")))
         (bg-dim  (metal-apparence-couleur 'bg-dim  (if sombre "#1e1e1e" "#f2f2f2")))
         (fg-main (metal-apparence-couleur 'fg-main (if sombre "#ffffff" "#000000")))
         (fg-dim  (metal-apparence-couleur 'fg-dim  (if sombre "#989898" "#595959"))))
    (set-face-attribute 'tab-line nil
                        :background bg-dim :foreground fg-dim
                        :box nil :overline nil :underline nil)
    ;; `tab-line-tab-special' met en italique les tampons sans fichier.
    (when (facep 'tab-line-tab-special)
      (set-face-attribute 'tab-line-tab-special nil :slant 'normal :weight 'unspecified))
    (dolist (face '(tab-line-tab tab-line-tab-inactive
                    tab-line-tab-inactive-alternate))
      (when (facep face)
        (set-face-attribute face nil
                            :background bg-dim :foreground fg-dim
                            :weight 'normal :slant 'normal
                            :box `(:line-width (1 . 6) :color ,bg-dim)
                            :overline nil :underline nil)))
    (dolist (face '(tab-line-tab-current))
      (when (facep face)
        (set-face-attribute face nil
                            :background bg-main :foreground fg-main
                            :weight 'medium :slant 'normal
                            :box `(:line-width (1 . 6) :color ,bg-main)
                            :overline nil :underline nil)))
    (when (facep 'tab-line-tab-modified)
      (set-face-attribute 'tab-line-tab-modified nil :slant 'normal))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Barre de titre macOS
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-apparence--titre-macos (&optional frame)
  "Accorder la barre de titre macOS de FRAME (ou de tous les frames) au thème."
  (when (eq system-type 'darwin)
    (let ((apparence (if (metal-apparence-sombre-p) 'dark 'light)))
      (setf (alist-get 'ns-transparent-titlebar default-frame-alist) t
            (alist-get 'ns-appearance default-frame-alist) apparence)
      (dolist (f (if frame (list frame) (frame-list)))
        (when (frame-live-p f)
          (set-frame-parameter f 'ns-transparent-titlebar t)
          (set-frame-parameter f 'ns-appearance apparence))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Application du thème
;;; ═══════════════════════════════════════════════════════════════════

(defvar modus-themes-common-palette-overrides)

(defun metal-apparence-appliquer (&optional mode)
  "Charger le thème MODE (`clair' ou `sombre'; défaut : les préférences)."
  (interactive)
  (let* ((mode  (or mode (metal-apparence--mode-effectif)))
         (theme (if (eq mode 'sombre) 'modus-vivendi 'modus-operandi)))
    (setq modus-themes-common-palette-overrides metal-apparence--palette)
    (dolist (th '(modus-operandi modus-vivendi))
      (when (memq th custom-enabled-themes)
        (disable-theme th)))
    (load-theme theme t)
    (setq metal-apparence--mode-courant mode)
    (metal-apparence--retoucher)
    (metal-apparence--titre-macos)
    ;; Les familles de polices sont posées par init.el ; les réappliquer
    ;; après le thème garantit mode-line et onglets en police d'interface.
    (when (fboundp 'metal-setup-fonts)
      (let ((inhibit-message t))
        (metal-setup-fonts)))
    (run-hooks 'metal-apparence-apres-changement-hook)
    mode))

(defun metal-apparence--sauver ()
  "Persister les préférences d'apparence."
  (when (fboundp 'metal-prefs-save)
    (metal-prefs-save)))

(defun metal-apparence-basculer ()
  "Basculer entre le thème clair et le thème sombre."
  (interactive)
  (setq metal-apparence-theme (if (metal-apparence-sombre-p) 'clair 'sombre))
  (metal-apparence-appliquer)
  (metal-apparence--sauver)
  (message "Thème %s" (if (metal-apparence-sombre-p) "sombre" "clair")))

(defun metal-apparence-choisir ()
  "Choisir le thème : Clair, Sombre ou Système."
  (interactive)
  (let* ((choix '(("Clair" . clair) ("Sombre" . sombre) ("Système" . systeme)))
         (nom (completing-read "Thème : " (mapcar #'car choix) nil t)))
    (setq metal-apparence-theme (cdr (assoc nom choix)))
    (metal-apparence-appliquer)
    (metal-apparence--sauver)))

(defun metal-apparence-nom-theme ()
  "Retourner le nom lisible du réglage de thème."
  (pcase metal-apparence-theme
    ('sombre "Sombre")
    ('systeme "Système")
    (_ "Clair")))

;; Suivi en direct du réglage système (builds macOS qui l'exposent).
(when (boundp 'ns-system-appearance-change-functions)
  (add-hook 'ns-system-appearance-change-functions
            (lambda (apparence)
              (when (eq metal-apparence-theme 'systeme)
                (metal-apparence-appliquer
                 (if (eq apparence 'dark) 'sombre 'clair))))))

(add-hook 'after-make-frame-functions #'metal-apparence--titre-macos)

(with-eval-after-load 'tab-line
  (metal-apparence--retoucher-onglets))

;;; ═══════════════════════════════════════════════════════════════════
;;; Prénom de l'utilisateur
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-utilisateur-prenom-affiche ()
  "Retourner le prénom à afficher, ou nil."
  (cond
   ((and (stringp metal-utilisateur-prenom)
         (not (string-blank-p metal-utilisateur-prenom)))
    (string-trim metal-utilisateur-prenom))
   ;; Un nom complet d'au moins deux mots ressemble à un vrai nom ;
   ;; un identifiant de session (« jacqu ») ne doit pas servir d'accueil.
   ((and (stringp user-full-name)
         (string-match-p "[[:alpha:]]+[[:space:]]+[[:alpha:]]" user-full-name))
    (car (split-string user-full-name)))))

(defun metal-utilisateur-definir-prenom (prenom)
  "Définir le PRENOM affiché à l'accueil (vide = automatique)."
  (interactive
   (list (read-string "Prénom à afficher (vide = automatique) : "
                      (or metal-utilisateur-prenom ""))))
  (setq metal-utilisateur-prenom
        (if (string-blank-p prenom) nil (string-trim prenom)))
  (metal-apparence--sauver)
  (when (and (fboundp 'metal-dashboard-open)
             (get-buffer "*Tableau-de-bord*"))
    (metal-dashboard-open)))

;;; ═══════════════════════════════════════════════════════════════════
;;; Onglets plats
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-apparence--nom-onglet (buffer &optional _buffers)
  "Nom d'onglet de BUFFER : sans astérisques, avec pastille si modifié."
  (let* ((nom (buffer-name buffer))
         (nom (if (string-match "\\`\\*\\(.+\\)\\*\\'" nom)
                  (match-string 1 nom)
                nom))
         (nom (if (equal nom "Tableau-de-bord") "Tableau de bord" nom))
         (modifie (and (buffer-file-name buffer)
                       (buffer-modified-p buffer))))
    (concat "   " nom (if modifie " •" "") "  ")))

;;; ═══════════════════════════════════════════════════════════════════
;;; Mode-line épurée
;;; ═══════════════════════════════════════════════════════════════════

(defconst metal-apparence--noms-modes
  '(("Fundamental" . "Fondamental")
    ("Text" . "Texte")
    ("Lisp Interaction" . "Lisp interactif")
    ("Messages" . "Messages")
    ("Help" . "Aide")
    ("Dired by name" . "Dossier")
    ("Dired by date" . "Dossier"))
  "Traductions des noms de modes majeurs affichés dans la mode-line.")

(defun metal-apparence--nom-mode ()
  "Nom du mode majeur courant, traduit si possible."
  (let ((nom (if (stringp mode-name) mode-name (format-mode-line mode-name))))
    (or (cdr (assoc nom metal-apparence--noms-modes)) nom)))

(defun metal-apparence--installer-mode-line ()
  "Remplacer la liste des modes par le seul mode majeur."
  (when metal-apparence-mode-line-epuree
    (setq-default mode-line-modes
                  `("   "
                    (:eval (propertize (metal-apparence--nom-mode)
                                       'help-echo "Mode majeur — clic : menu"
                                       'mouse-face 'mode-line-highlight
                                       'local-map mode-line-major-mode-keymap))
                    mode-line-process
                    "   "))))

(metal-apparence--installer-mode-line)

;;; ═══════════════════════════════════════════════════════════════════
;;; Explorateur (Treemacs)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-apparence--masquer-p (nom _chemin)
  "Retourner non nil si NOM doit être masqué dans l'explorateur."
  (cl-some (lambda (re) (string-match-p re nom))
           metal-apparence-explorateur-masques))

(defun metal-apparence--panneau ()
  "Teinter le fond du buffer courant (panneau latéral)."
  (face-remap-add-relative 'default 'metal-apparence-panneau)
  (face-remap-add-relative 'fringe 'metal-apparence-panneau))

(defvar treemacs-ignored-file-predicates)

(with-eval-after-load 'treemacs
  (add-to-list 'treemacs-ignored-file-predicates #'metal-apparence--masquer-p)
  (metal-apparence--retoucher))

(provide 'metal-apparence)

;;; metal-apparence.el ends here
