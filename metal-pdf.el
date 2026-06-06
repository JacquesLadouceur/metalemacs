;;; metal-pdf.el --- Barre d'outils PDF pour MetalEmacs -*- lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: pdf, annotations, tools

;;; Commentary:
;;
;; Ajoute une barre d'outils cliquable dans la header-line lorsqu'on
;; visualise un PDF avec `pdf-tools'.  Les primitives (vpadding, button,
;; séparateur, icône colorée) sont fournies par `metal-toolbar' ; ce
;; module ne fait que composer la barre PDF.
;;
;; Outils disponibles :
;;   • Annotations : surligner, souligner, biffer, ondulé, note collante
;;   • Gestion    : lister, supprimer
;;   • Navigation : première / précédente / suivante / dernière
;;   • Zoom       : +, −, ajuster page, ajuster largeur
;;   • Recherche  : isearch, occurrences
;;   • Fichier    : sauvegarder, imprimer
;;
;; Activation : automatique dans `pdf-view-mode' (configurable).
;; Bascule manuelle : C-c t

;;; Code:

;; pdf-tools (et ses sous-modules) nécessitent le binaire natif `epdfinfo',
;; compilé via poppler/Homebrew.  Sur une machine où pdf-tools n'est pas
;; encore installé (ex. macOS sans Homebrew), ces require échoueraient et
;; interrompraient le chargement de tout le fichier — et donc des modules
;; chargés après metal-pdf dans init.el.  On les rend donc optionnels
;; (3e argument NOERROR de `require').  La barre PDF s'activera
;; automatiquement dès que pdf-tools sera disponible (voir le hook plus bas,
;; protégé par `featurep').
(require 'pdf-tools nil t)
(require 'pdf-view nil t)
(require 'pdf-annot nil t)
(require 'pdf-occur nil t)
(require 'pdf-misc nil t)
(require 'metal-toolbar)

(defgroup metal-pdf nil
  "Barre d'outils PDF pour MetalEmacs."
  :group 'pdf-tools
  :prefix "metal-pdf-")

(defcustom metal-pdf-toolbar-auto-enable t
  "Si non-nil, active automatiquement la barre d'outils dans `pdf-view-mode'."
  :type 'boolean
  :group 'metal-pdf)

(defcustom metal-pdf-icon-height 1.8
  "Hauteur des icônes de la barre PDF."
  :type 'number
  :group 'metal-pdf)

(defcustom metal-pdf-colors
  '((highlight . "#d4a017")    ; jaune surligneur
    (underline . "#2980b9")    ; bleu
    (strikeout . "#c0392b")    ; rouge
    (squiggly  . "#8e44ad")    ; violet
    (note      . "#d68910")    ; orange
    (list      . "#5d6d7e")    ; gris ardoise
    (delete    . "#a93226")    ; rouge sombre
    (nav       . "#2c3e50")    ; bleu nuit
    (zoom      . "#16a085")    ; sarcelle
    (search    . "#5b3a8e")    ; indigo
    (save      . "#1e8449")    ; vert
    (print     . "#34495e"))   ; gris bleuté
  "Couleurs des icônes par groupe d'outils."
  :type '(alist :key-type symbol :value-type color)
  :group 'metal-pdf)

;;; --- Helpers --------------------------------------------------------------

(defun metal-pdf--icon (name color-key &optional fallback raise)
  "Icône nerd-icons NAME colorée selon COLOR-KEY (clé de `metal-pdf-colors')."
  (metal-toolbar-icon name
                      :color (or (alist-get color-key metal-pdf-colors)
                                 "gray40")
                      :height metal-pdf-icon-height
                      :raise -0.1
                      :fallback fallback))

;;; --- Impression -----------------------------------------------------------

(defun metal-pdf--sumatra-executable ()
  "Retourne le chemin de SumatraPDF s'il est dans le PATH, sinon nil."
  (or (executable-find "SumatraPDF")
      (executable-find "sumatrapdf")))

(defun metal-pdf--default-print-strategy ()
  "Calcule la stratégie d'impression par défaut selon la plateforme.
Sur Windows, bascule sur `shell-open' avec un avertissement si
SumatraPDF n'est pas installé."
  (cond
   ((eq system-type 'darwin) 'preview)
   ((eq system-type 'windows-nt)
    (if (metal-pdf--sumatra-executable)
        'sumatra
      (lwarn 'metal-pdf :warning
             "SumatraPDF introuvable — l'impression utilisera l'application PDF \
par défaut (résultat variable).
Pour une meilleure expérience (dialogue d'impression natif Windows, \
fermeture automatique), installer SumatraPDF :
    M-x metal-deps-installer-sumatrapdf
ou via l'assistant : M-x metal-deps-afficher-etat
puis redémarrer Emacs.")
      'shell-open))
   (t 'lpr)))

(defcustom metal-pdf-print-strategy
  (metal-pdf--default-print-strategy)
  "Stratégie d'impression utilisée par `metal-pdf-imprimer'.

Valeurs possibles :
  `preview'    : ouvre le PDF dans Aperçu (macOS) qui affiche son
                 propre dialogue d'impression natif.  Recommandé sur
                 macOS pour choisir l'imprimante, le recto-verso, etc.
  `sumatra'    : (Windows) lance SumatraPDF avec `-print-dialog
                 -exit-when-done' : affiche immédiatement le dialogue
                 d'impression natif Windows et SumatraPDF se ferme
                 automatiquement.  Nécessite SumatraPDF dans le PATH
                 (ex: scoop install sumatrapdf).
  `shell-open' : ouvre le PDF dans l'application PDF par défaut via
                 le verbe Shell « Print » (Windows) ou xdg-open
                 (Linux).  Comportement variable selon l'app.
  `lpr'        : envoie directement à l'imprimante par défaut via
                 `lpr' (silencieux, sans dialogue).  Linux/macOS.
  `pdf-tools'  : utilise `pdf-misc-print-document' (peut demander le
                 programme d'impression au premier appel)."
  :type '(choice (const :tag "Aperçu macOS"             preview)
                 (const :tag "SumatraPDF (Windows)"     sumatra)
                 (const :tag "Application système"      shell-open)
                 (const :tag "lpr (impression directe)" lpr)
                 (const :tag "pdf-tools natif"          pdf-tools))
  :group 'metal-pdf)

(defun metal-pdf-imprimer ()
  "Imprime le PDF courant selon `metal-pdf-print-strategy'."
  (interactive)
  (unless (and buffer-file-name (file-exists-p buffer-file-name))
    (user-error "Le tampon n'est pas associé à un fichier PDF"))
  (pcase metal-pdf-print-strategy
    ('preview
     (let* ((file (expand-file-name buffer-file-name))
            (script (format "tell application \"Preview\"
                                activate
                                open POSIX file \"%s\"
                                tell application \"System Events\"
                                    tell process \"Preview\"
                                        keystroke \"p\" using {command down}
                                    end tell
                                end tell
                             end tell"
                            file)))
       (start-process "metal-pdf-preview-print" nil
                      "osascript" "-e" script))
     (message "Aperçu : dialogue d'impression…"))
    ('sumatra
     (let ((sumatra (metal-pdf--sumatra-executable)))
       (cond
        (sumatra
         (let ((file (convert-standard-filename
                      (expand-file-name buffer-file-name))))
           ;; Utilise l'API Win32 Wide (UTF-16) pour préserver les
           ;; caractères accentués dans le chemin.  `start-process'
           ;; les corromprait en CP1252 (é → Ã©).
           (w32-shell-execute
            "open" sumatra
            (format "-print-dialog -exit-when-done \"%s\"" file))
           (message "Dialogue d'impression Windows…")))
        ((and (eq system-type 'windows-nt)
              (fboundp 'metal-deps-installer-sumatrapdf)
              (yes-or-no-p
               "SumatraPDF n'est pas installé.  L'installer maintenant via Scoop ? "))
         (call-interactively #'metal-deps-installer-sumatrapdf)
         (message "Une fois l'installation terminée, relancez l'impression."))
        (t
         (user-error
          "SumatraPDF introuvable.  M-x metal-deps-installer-sumatrapdf")))))
    ('shell-open
     (cond
      ;; Windows : verbe Shell « print » — fonctionne avec Edge,
      ;; SumatraPDF, Foxit, mais PAS avec Adobe Acrobat Reader.
      ((eq system-type 'windows-nt)
       (condition-case _err
           (progn
             (w32-shell-execute "print" buffer-file-name)
             (message "Dialogue d'impression Windows…"))
         (error
          ;; ShellExecute « print » a échoué (ex: Acrobat Reader installé
          ;; comme visionneuse par défaut).  On ne tente pas de fallback
          ;; sur « open » : ça ouvrirait l'app pour rien et brouillerait
          ;; l'expérience.  La vraie solution est SumatraPDF.
          (cond
           ((and (fboundp 'metal-deps-installer-sumatrapdf)
                 (not (metal-pdf--sumatra-executable))
                 (yes-or-no-p
                  "Votre visionneuse PDF par défaut (probablement Acrobat) ne permet \
pas d'impression directe depuis Emacs.
Installer SumatraPDF (~12 Mo) pour résoudre le problème ? "))
            (call-interactively #'metal-deps-installer-sumatrapdf)
            (message "Une fois l'installation terminée, relancez l'impression."))
           (t
            (user-error
             "Impression impossible.  Solutions :
  • Installer SumatraPDF : M-x metal-deps-installer-sumatrapdf
  • Ou définir Edge/Foxit comme visionneuse PDF par défaut dans Windows
  • Ou ouvrir le PDF manuellement et imprimer depuis l'application"))))))
      ;; Linux : pas de dialogue universel — on essaye d'invoquer
      ;; l'app PDF par défaut via xdg-open ; l'utilisateur lance
      ;; l'impression depuis là.  Pour un envoi silencieux direct,
      ;; configurer plutôt `metal-pdf-print-strategy' à `lpr'.
      (t
       (start-process "metal-pdf-open" nil "xdg-open" buffer-file-name)
       (message "Ouverture dans l'application système — utiliser Ctrl-P"))))
    ('lpr
     (let ((rc (call-process "lpr" nil nil nil buffer-file-name)))
       (if (zerop rc)
           (message "Envoyé à l'imprimante par défaut")
         (user-error "Échec de l'envoi (lpr a retourné %d)" rc))))
    ('pdf-tools
     (call-interactively #'pdf-misc-print-document))
    (_ (user-error "Stratégie inconnue : %s" metal-pdf-print-strategy))))

;;; --- Construction de la barre --------------------------------------------

(defun metal-pdf-toolbar-format ()
  "Construit dynamiquement la barre d'outils PDF."
  (concat
   (metal-toolbar-vpadding) " "

   ;; ----- Annotations de surface -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-marker" 'highlight "✎")
                         "Surligner la sélection"
                         'pdf-annot-add-highlight-markup-annotation)
   (metal-toolbar-button (metal-pdf--icon "nf-md-format_underline" 'underline "U")
                         "Souligner la sélection"
                         'pdf-annot-add-underline-markup-annotation)
   (metal-toolbar-button (metal-pdf--icon "nf-md-format_strikethrough" 'strikeout "S")
                         "Biffer la sélection"
                         'pdf-annot-add-strikeout-markup-annotation)
   (metal-toolbar-button (metal-pdf--icon "nf-md-vector_curve" 'squiggly "~")
                         "Souligner en ondulé"
                         'pdf-annot-add-squiggly-markup-annotation)
   (metal-toolbar-separator)

   ;; ----- Note collante -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-note_edit_outline" 'note "✉" -0.1)
                         "Ajouter une note"
                         'pdf-annot-add-text-annotation)
   (metal-toolbar-separator)

   ;; ----- Gestion des annotations -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-format_list_bulleted" 'list "≡" -0.1)
                         "Lister toutes les annotations"
                         'pdf-annot-list-annotations)
   (metal-toolbar-button (metal-pdf--icon "nf-md-delete_outline" 'delete "✗" -0.1)
                         "Supprimer une annotation (cliquer dessus)"
                         'pdf-annot-delete)
   (metal-toolbar-separator)

   ;; ----- Navigation -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-page_first" 'nav "⏮" -0.1)
                         "Première page"
                         'pdf-view-first-page)
   (metal-toolbar-button (metal-pdf--icon "nf-md-arrow_left" 'nav "◀" -0.1)
                         "Page précédente"
                         'pdf-view-previous-page-command)
   (metal-toolbar-button (metal-pdf--icon "nf-md-arrow_right" 'nav "▶")
                         "Page suivante"
                         'pdf-view-next-page-command)
   (metal-toolbar-button (metal-pdf--icon "nf-md-page_last" 'nav "⏭")
                         "Dernière page"
                         'pdf-view-last-page)
   (metal-toolbar-separator)

   ;; ----- Zoom -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-magnify_plus_outline" 'zoom "+")
                         "Zoom avant"
                         'pdf-view-enlarge)
   (metal-toolbar-button (metal-pdf--icon "nf-md-magnify_minus_outline" 'zoom "−")
                         "Zoom arrière"
                         'pdf-view-shrink)
   (metal-toolbar-button (metal-pdf--icon "nf-md-fit_to_page_outline" 'zoom "▢")
                         "Ajuster à la page"
                         'pdf-view-fit-page-to-window)
   (metal-toolbar-button (metal-pdf--icon "nf-md-arrow_expand_horizontal" 'zoom "↔")
                         "Ajuster à la largeur"
                         'pdf-view-fit-width-to-window)
   (metal-toolbar-separator)

   ;; ----- Recherche -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-magnify" 'search "🔍")
                         "Rechercher dans le PDF"
                         'isearch-forward)
   (metal-toolbar-button (metal-pdf--icon "nf-md-text_search" 'search "⌕")
                         "Occurrences (pdf-occur)"
                         'pdf-occur)
   (metal-toolbar-separator)

   ;; ----- Fichier -----
   (metal-toolbar-button (metal-pdf--icon "nf-md-content_save_outline" 'save "💾")
                         "Sauvegarder le PDF avec annotations"
                         'save-buffer)
   (metal-toolbar-button (metal-pdf--icon "nf-md-printer" 'print "⎙")
                         "Imprimer"
                         'metal-pdf-imprimer)

   " " (metal-toolbar-vpadding)))

;;; --- Mode mineur ---------------------------------------------------------

;;;###autoload
(define-minor-mode metal-pdf-toolbar-mode
  "Mode mineur affichant une barre d'outils dans `pdf-view-mode'."
  :lighter " 📑"
  :group 'metal-pdf
  (if metal-pdf-toolbar-mode
      (setq header-line-format '(:eval (metal-pdf-toolbar-format)))
    (setq header-line-format nil)))

(defun metal-pdf--maybe-enable ()
  "Active la barre dans pdf-view-mode si l'option est activée."
  (when metal-pdf-toolbar-auto-enable
    (metal-pdf-toolbar-mode 1)))

(add-hook 'pdf-view-mode-hook #'metal-pdf--maybe-enable)

;; Raccourci pour basculer la barre
(with-eval-after-load 'pdf-view
  (define-key pdf-view-mode-map (kbd "C-c t") #'metal-pdf-toolbar-mode))

;;; --- Synchronisation des couleurs avec le thème ------------------

(defun metal-pdf-sync-colors (&rest _)
  "Calquer les couleurs PDF (mode nuit) sur le thème actif."
  (setq pdf-view-midnight-colors
        (cons (face-foreground 'default nil t)
              (face-background 'default nil t))))

(add-hook 'pdf-view-mode-hook
          (lambda ()
            (metal-pdf-sync-colors)
            (pdf-view-midnight-minor-mode 1)   ; recoloriage actif
            (pdf-view-redisplay t)))

(advice-add 'load-theme :after #'metal-pdf-sync-colors)

;; Auto-revert dans les PDF (recharge si le fichier change sur disque).
(add-hook 'pdf-view-mode-hook (lambda () (auto-revert-mode 1)))

;;; --- Choix du moteur d'ouverture (pdf-tools ou doc-view) ---------

(defun metal-pdf-epdfinfo-disponible-p ()
  "Retourne non-nil si le binaire epdfinfo de pdf-tools est exécutable."
  (or (executable-find "epdfinfo")
      (file-executable-p
       (expand-file-name "straight/build/pdf-tools/epdfinfo"
                         user-emacs-directory))
      ;; Windows : binaire portable fourni avec MetalEmacs
      (and (eq system-type 'windows-nt)
           (file-executable-p
            (expand-file-name "pdf-tools/epdfinfo.exe" user-emacs-directory)))))

(defun metal-pdf-ouvrir ()
  "Ouvre le PDF courant avec pdf-tools si disponible, sinon doc-view.
Utilisé comme valeur dans `auto-mode-alist' ; évalué à chaque ouverture."
  (cond
   ((and (metal-pdf-epdfinfo-disponible-p) (fboundp 'pdf-view-mode))
    (pdf-view-mode))
   ((fboundp 'doc-view-mode)
    (doc-view-mode))
   (t (fundamental-mode))))

(add-to-list 'auto-mode-alist (cons "\\.pdf\\'" #'metal-pdf-ouvrir))

;;; --- Qualité de rendu doc-view (Mac < 14, sans pdf-tools) --------

;; doc-view rasterise chaque page en PNG via Ghostscript à une
;; résolution fixe (100 DPI par défaut) — d'où un rendu plus flou que
;; pdf-tools, qui rendait à la résolution de l'écran.  On monte à 200 DPI :
;; bon compromis netteté / performance sur un écran standard (non-Retina).
;;
;; IMPORTANT : on règle la résolution AVANT le chargement de doc-view, via
;; `custom-set-variables'.  Un `with-eval-after-load' s'exécuterait trop
;; tard — doc-view a déjà rendu et mis en cache la première page à 100 DPI,
;; donc la nouvelle valeur n'aurait aucun effet tant que le cache n'est pas
;; vidé.  `custom-set-variables' fixe la valeur dès la définition de la
;; variable, avant tout rendu.  `doc-view-scale-internally' laisse Emacs
;; mettre à l'échelle l'image déjà rendue lors des zooms.
(custom-set-variables
 '(doc-view-resolution 200)
 '(doc-view-scale-internally t))

(defun metal-pdf-doc-view-rafraichir ()
  "Vide le cache doc-view et reconvertit le document courant.
À utiliser dans un buffer `doc-view-mode' si le rendu paraît flou."
  (interactive)
  (when (derived-mode-p 'doc-view-mode)
    (doc-view-clear-cache)
    (doc-view-reconvert-doc)
    (message "doc-view : document reconverti à %d DPI" doc-view-resolution)))

;; Navigation par page avec les flèches haut/bas (pratique pour présenter
;; des diapositives).  Par défaut, haut/bas font défiler l'image dans la
;; page ; on les remappe sur page précédente / suivante, comme le remap
;; gauche/droite déjà en place pour pdf-view.
(with-eval-after-load 'doc-view
  (define-key doc-view-mode-map (kbd "<up>")   #'doc-view-previous-page)
  (define-key doc-view-mode-map (kbd "<down>") #'doc-view-next-page))

(provide 'metal-pdf)
;;; metal-pdf.el ends here
