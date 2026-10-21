;;; metal-capture.el --- Capture PNG d'une fenêtre Emacs -*- lexical-binding: t; -*-

;; Auteur : Jacques Ladouceur
;; Fait partie de MetalEmacs — github.com/JacquesLadouceur/metalemacs

;;; Commentaire :

;; Capture une fenêtre Emacs (assistant, treemacs, tampon quelconque) en PNG
;; et l'enregistre dans le dossier de son choix.
;;
;; M-x metal-capture-fenetre       capture la fenêtre courante
;; C-u M-x metal-capture-fenetre   choisit la fenêtre par le nom de son tampon
;;
;; Le rectangle de la fenêtre est obtenu par `window-absolute-pixel-edges',
;; puis transmis à l'outil de capture du système :
;;   macOS   : screencapture (autoriser Emacs dans Réglages Système →
;;             Confidentialité et sécurité → Enregistrement de l'écran)
;;   Windows : PowerShell + System.Drawing (exact à une mise à l'échelle de 100 %)
;;   Linux   : import (ImageMagick) sous X11, grim sous Wayland (wlroots
;;             seulement ; sous Wayland, la position des fenêtres n'est pas
;;             fiable)

;;; Code :

(defgroup metal-capture nil
  "Capture PNG des fenêtres Emacs."
  :group 'convenience
  :prefix "metal-capture-")

(defcustom metal-capture-dossier nil
  "Dossier proposé par défaut au premier choix de la session.
Si nil, le dossier du tampon courant est proposé. Ensuite, le
dialogue s'ouvre sur le dernier dossier choisi."
  :type '(choice (const :tag "Dossier du tampon courant" nil)
                 (directory :tag "Dossier"))
  :group 'metal-capture)

(defcustom metal-capture-delai 0.3
  "Délai en secondes avant la capture, le temps que le minibuffer se referme."
  :type 'number
  :group 'metal-capture)

(defun metal-capture--choisir-fenetre ()
  "Choisir une fenêtre visible par le nom de son tampon."
  (let ((choix (mapcar (lambda (w) (cons (buffer-name (window-buffer w)) w))
                       (window-list nil 'no-minibuf))))
    (cdr (assoc (completing-read "Fenêtre à capturer : " choix nil t) choix))))

(defvar metal-capture--dernier-dossier nil
  "Dernier dossier choisi pendant la session.")

(defun metal-capture--dialogue-natif-p ()
  "Non-nil si le dialogue « Enregistrer sous » natif est disponible."
  (and (display-graphic-p) (fboundp 'x-file-dialog)))

(defun metal-capture--choisir-fichier ()
  "Choisir le dossier et le nom de la capture.
Utilise le dialogue « Enregistrer sous » natif du système, avec le
nom horodaté prérempli ; se replie sur le minibuffer hors d'un
affichage graphique."
  (let* ((depart (file-name-as-directory
                  (expand-file-name (or metal-capture--dernier-dossier
                                        metal-capture-dossier
                                        default-directory))))
         (defaut (metal-capture--nom-par-defaut))
         (fichier
          (if (metal-capture--dialogue-natif-p)
              ;; MUSTMATCH nil → dialogue d'enregistrement avec champ de nom
              (x-file-dialog "Enregistrer la capture sous" depart defaut nil nil)
            (read-file-name "Enregistrer la capture sous : "
                            depart nil nil defaut))))
    (when (or (null fichier) (string-empty-p fichier))
      (user-error "Capture annulée"))
    (setq fichier (expand-file-name fichier depart))
    (setq metal-capture--dernier-dossier (file-name-directory fichier))
    fichier))

(defun metal-capture--nom-par-defaut ()
  "Nom de fichier proposé pour une nouvelle capture."
  (format-time-string "capture-%Y%m%d-%H%M%S.png"))

(defun metal-capture--executer (x y l h fichier)
  "Capturer le rectangle X Y L H de l'écran dans FICHIER (PNG)."
  (pcase system-type
    ('darwin
     (call-process "screencapture" nil nil nil "-x"
                   "-R" (format "%d,%d,%d,%d" x y l h) fichier))
    ('windows-nt
     (call-process
      "powershell" nil nil nil "-NoProfile" "-Command"
      (format (concat "Add-Type -AssemblyName System.Drawing;"
                      "$b=New-Object System.Drawing.Bitmap %d,%d;"
                      "$g=[System.Drawing.Graphics]::FromImage($b);"
                      "$g.CopyFromScreen(%d,%d,0,0,$b.Size);"
                      "$b.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png)")
              l h x y
              ;; Échapper l'apostrophe pour la chaîne PowerShell
              (replace-regexp-in-string "'" "''" fichier))))
    (_
     (if (getenv "WAYLAND_DISPLAY")
         (call-process "grim" nil nil nil
                       "-g" (format "%d,%d %dx%d" x y l h) fichier)
       (call-process "import" nil nil nil "-window" "root"
                     "-crop" (format "%dx%d+%d+%d" l h x y) fichier)))))

;;;###autoload
(defun metal-capture-fenetre (window fichier &optional remplacer)
  "Enregistrer une capture PNG de WINDOW dans FICHIER.
Sans argument : la fenêtre courante. Avec \\[universal-argument] :
choisir la fenêtre (assistant, treemacs, etc.).
Si REMPLACER est non-nil, un fichier existant est remplacé sans
confirmation (le dialogue natif l'a déjà demandée)."
  (interactive
   (let ((w (if current-prefix-arg
                (metal-capture--choisir-fenetre)
              (selected-window))))
     (list w
           (metal-capture--choisir-fichier)
           (metal-capture--dialogue-natif-p))))
  (unless (window-live-p window)
    (user-error "Fenêtre invalide"))
  (setq fichier (expand-file-name fichier))
  (when (directory-name-p fichier)
    (setq fichier (expand-file-name (metal-capture--nom-par-defaut) fichier)))
  (unless (string-suffix-p ".png" fichier t)
    (setq fichier (concat fichier ".png")))
  (make-directory (file-name-directory fichier) t)
  (when (file-exists-p fichier)
    (if (or remplacer
            (y-or-n-p (format "%s existe déjà. Le remplacer ? "
                              (file-name-nondirectory fichier))))
        (delete-file fichier)
      (user-error "Capture annulée")))
  ;; Laisser le minibuffer disparaître avant de capturer
  (redisplay t)
  (sleep-for metal-capture-delai)
  (pcase-let ((`(,x ,y ,droite ,bas) (window-absolute-pixel-edges window)))
    (metal-capture--executer x y (- droite x) (- bas y) fichier))
  (if (file-exists-p fichier)
      (message "Capture enregistrée : %s" (abbreviate-file-name fichier))
    (user-error "Échec de la capture (outil absent ou permission refusée)")))

(provide 'metal-capture)

;;; metal-capture.el ends here
