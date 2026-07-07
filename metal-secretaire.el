;;; metal-secretaire.el --- Agent secretaire d'assemblee deliberante -*- lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, convenience, ai, transcription
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; metal-secretaire.el fournit un « agent secretaire d'assemblee » pour
;; MetalEmacs.  Il transcrit l'enregistrement audio d'une assemblee
;; deliberante (conseil/assemblee de departement universitaire) et produit un
;; proces-verbal synthetique, le tout DANS UN SEUL DOCUMENT .sec.
;;
;; MODELE DU DOCUMENT .sec
;; -----------------------
;; Un fichier .sec est un document Org ordinaire (il s'ouvre en `org-mode',
;; avec la barre Org habituelle).  Il sert de support unique a toute la
;; seance et s'organise ainsi :
;;
;;     #+TITLE: Assemblee departementale — 8 juin 2026
;;     #+LEXIQUE: Universite Laval, LNG-3108, ...
;;     * Ordre du jour
;;     ** 1. Adoption de l'ordre du jour
;;        :PROPERTIES: :LEXIQUE: huis clos, varia :END:
;;     ** 2. ...
;;     * Proces-verbal          <- insere par 📋, APRES l'ordre du jour
;;     ** 1. ...
;;     * Verbatim               <- insere par 🎙️, en FIN de document
;;     ** [00:00:12] Intervenant 1
;;
;; L'utilisateur part d'un .sec contenant l'ordre du jour.  La transcription
;; ajoute la section « Verbatim » en fin ; la redaction ajoute la section
;; « Proces-verbal » juste apres l'ordre du jour.  Les deux operations
;; modifient le buffer courant ; rien n'est ecrit dans des fichiers separes.
;;
;; AUDIO
;; -----
;; Le fichier audio est cherche dans le dossier du .sec : d'abord un fichier
;; de meme nom de base (seance.sec -> seance.m4a/.wav/.mp3/...), sinon le seul
;; fichier audio present, sinon le plus recent.  S'il n'y en a aucun, le
;; module invite a enregistrer en ouvrant une app native (QuickTime /
;; Dictaphone sur macOS) : la capture directe par Emacs est bloquee par
;; macOS (autorisations micro non heritees par les sous-processus).
;;
;; BARRE D'OUTILS
;; --------------
;; Pas de mode derive ni de header-line propre : le .sec reste en `org-mode'.
;; La barre Org (cf. `metal-org.el') greffe, pour les .sec uniquement, le
;; segment Secretaire via `metal-toolbar-build' :secretaire t.  Le bouton 🗒️
;; bascule `metal-secretaire-active' : barre Org normale <-> barre secretaire
;; (qui remplace alors les boutons Org, comme le fait l'agent 🤖).  On garde
;; ainsi les outils Org pour l'edition manuelle.
;;
;; CLE API
;; -------
;; Jamais dans le code : variable d'environnement GLADIA_API_KEY, ou
;; auth-source (machine api.gladia.io).  La commande
;; `metal-secretaire-configurer-cle' ecrit la cle dans ~/.zshrc et l'active
;; immediatement dans la session courante.

;;; Code:

(require 'subr-x)
(eval-when-compile (require 'cl-lib))
;; metal-toolbar fournit les primitives de barre ; chargement souple.
(require 'metal-toolbar nil t)

;;;; ------------------------------------------------------------------
;;;; Groupe de personnalisation
;;;; ------------------------------------------------------------------

(defgroup metal-secretaire nil
  "Agent secretaire d'assemblee deliberante pour MetalEmacs."
  :group 'tools
  :prefix "metal-secretaire-")

(defcustom metal-secretaire-python nil
  "Interpreteur Python pour le worker de transcription.
Si nil (defaut), il est resolu dynamiquement par
`metal-secretaire--python' : d'abord le Python de l'installation Conda
detectee par le module conda (`conda-env-home-directory'), puis
`executable-find', puis \"python3\".  Mettez ici un chemin absolu pour
forcer un interpreteur precis."
  :type '(choice (const :tag "Detection automatique" nil) (file :tag "Chemin"))
  :group 'metal-secretaire)

(defun metal-secretaire--python ()
  "Renvoie le chemin de l'interpreteur Python a utiliser.
Priorite : `metal-secretaire-python' s'il est defini ; sinon le Python de
l'installation Conda (`conda-env-home-directory' + bin/python3|python) ;
sinon `executable-find' ; sinon \"python3\".  Emacs lance depuis le Dock
n'heritant pas du PATH du shell, on s'appuie sur la detection Conda du
module python plutot que sur le seul PATH."
  (or
   ;; 1. Valeur explicite de l'utilisateur.
   (and metal-secretaire-python
        (file-exists-p metal-secretaire-python)
        metal-secretaire-python)
   ;; 2. Python de l'installation Conda detectee par metal-python.
   (and (boundp 'conda-env-home-directory)
        conda-env-home-directory
        (let* ((base conda-env-home-directory)
               (p3 (expand-file-name "bin/python3" base))
               (p  (expand-file-name "bin/python" base)))
          (cond ((file-executable-p p3) p3)
                ((file-executable-p p) p))))
   ;; 3. PATH d'Emacs.
   (executable-find "python3")
   ;; 4. Dernier recours.
   "python3"))

(defcustom metal-secretaire-worker
  (expand-file-name "metal-secretaire-transcribe.py"
                    (file-name-directory (or load-file-name buffer-file-name "")))
  "Chemin du worker Python de transcription."
  :type 'file
  :group 'metal-secretaire)

(defcustom metal-secretaire-langue "fr"
  "Code de langue principal de l'assemblee (ISO 639-1)."
  :type 'string
  :group 'metal-secretaire)

(defcustom metal-secretaire-max-locuteurs 40
  "Borne superieure du nombre de locuteurs pour la diarisation."
  :type 'integer
  :group 'metal-secretaire)

(defcustom metal-secretaire-agent-pv "claude"
  "Agent IA utilise pour la redaction du PV synthetique.
Valeurs reconnues : \"claude\", \"gemini\", \"codex\".  La generation
delegue a `metal-agent' si ce module est charge."
  :type '(choice (const "claude") (const "gemini") (const "codex"))
  :group 'metal-secretaire)

(defcustom metal-secretaire-extensions-audio
  '("m4a" "wav" "mp3" "aac" "flac" "ogg" "opus" "mp4" "mov")
  "Extensions reconnues comme fichiers audio dans le dossier d'un .sec."
  :type '(repeat string)
  :group 'metal-secretaire)

(defcustom metal-secretaire-titre-ordre-du-jour "Ordre du jour"
  "Intitule de la section (niveau 1) contenant l'ordre du jour."
  :type 'string
  :group 'metal-secretaire)

(defcustom metal-secretaire-titre-pv "Procès-verbal"
  "Intitule de la section (niveau 1) du proces-verbal insere."
  :type 'string
  :group 'metal-secretaire)

(defcustom metal-secretaire-titre-verbatim "Verbatim"
  "Intitule de la section (niveau 1) du verbatim insere."
  :type 'string
  :group 'metal-secretaire)

(defcustom metal-secretaire-couleur "#16a085"
  "Couleur de l'icone 🗒️ du segment secretaire dans la barre."
  :type 'color
  :group 'metal-secretaire)

;;;; ------------------------------------------------------------------
;;;; Etat du module
;;;; ------------------------------------------------------------------

(defvar-local metal-secretaire-active nil
  "Quand non nil, la barre secretaire remplace les boutons Org du buffer.
Buffer-local, sur le modele de `metal-agent-active'.")

(defvar metal-secretaire--process-courant nil
  "Processus de transcription en cours, ou nil.")

(defvar metal-secretaire--interruption-volontaire nil
  "Drapeau : t lorsque l'arret du processus est demande par l'utilisateur.")

(defvar metal-secretaire--debut-traitement nil
  "Horodatage (float-time) du debut du traitement courant.")

(defvar metal-secretaire--derniere-duree nil
  "Duree (secondes) du dernier traitement termine, pour affichage persistant.")

(defvar metal-secretaire--buffer-cible nil
  "Buffer .sec destinataire de la transcription en cours.")

(defconst metal-secretaire--tampon-transcription "*Secretaire — transcription*"
  "Nom du tampon de progression de la transcription.")

;;;; ------------------------------------------------------------------
;;;; Gestion de la cle API
;;;; ------------------------------------------------------------------

(defun metal-secretaire-cle-gladia ()
  "Renvoie la cle API Gladia, ou nil.
Cherche dans l'ordre : la variable d'environnement GLADIA_API_KEY, puis
auth-source (machine api.gladia.io), puis une lecture directe du fichier
`metal-secretaire-fichier-authinfo' (utile si ce fichier n'est pas dans
`auth-sources')."
  (or
   ;; 1. Variable d'environnement.
   (let ((v (getenv "GLADIA_API_KEY")))
     (and v (not (string-empty-p (string-trim v))) (string-trim v)))
   ;; 2. auth-source standard.
   (ignore-errors
     (require 'auth-source)
     (when-let* ((found (car (auth-source-search :host "api.gladia.io"
                                                 :max 1 :require '(:secret))))
                 (secret (plist-get found :secret)))
       (if (functionp secret) (funcall secret) secret)))
   ;; 3. Lecture directe du fichier authinfo configure (repli robuste).
   (ignore-errors
     (let ((f (expand-file-name metal-secretaire-fichier-authinfo)))
       (when (and (file-readable-p f) (not (string-suffix-p ".gpg" f)))
         (with-temp-buffer
           (insert-file-contents f)
           (goto-char (point-min))
           (when (re-search-forward
                  "machine[ \t]+api\\.gladia\\.io.*password[ \t]+\\([^ \t\n]+\\)"
                  nil t)
             (match-string 1))))))))

(defcustom metal-secretaire-fichier-authinfo "~/.authinfo"
  "Fichier auth-source ou enregistrer la cle Gladia.
Par defaut ~/.authinfo (non chiffre), avec permissions 600 (lecture pour
le proprietaire seul).  Fonctionne quel que soit le mode de lancement
d'Emacs (Dock ou terminal), contrairement a ~/.zshrc qui n'est lu que par
les shells interactifs.  Pour un fichier chiffre, utilisez
\"~/.authinfo.gpg\" — mais cela exige une configuration GnuPG/pinentry
fonctionnelle sous Emacs (sur macOS, pinentry-mac via Homebrew)."
  :type 'file
  :group 'metal-secretaire)

(defun metal-secretaire--valider-cle (cle)
  "Verifie sommairement que CLE ressemble a une cle API plausible."
  (let ((c (string-trim (or cle ""))))
    (cond
     ((string-empty-p c)
      (user-error "Cle vide : configuration annulee"))
     ((string-match-p "[ \t\"\n]" c)
      (user-error "La cle contient une espace ou un guillemet : verifiez le collage"))
     (t c))))

;;;###autoload
(defun metal-secretaire-configurer-cle (cle)
  "Enregistre CLE comme cle API Gladia.
Ecrit (ou remplace) une ligne pour la machine \"api.gladia.io\" dans
`metal-secretaire-fichier-authinfo' (defaut ~/.authinfo), avec permissions
600.  Fonctionne meme si Emacs est lance depuis le Dock.  Pose aussi
GLADIA_API_KEY dans la session courante pour un usage immediat, sans
redemarrage.  La cle est saisie de facon masquee.

L'ecriture se fait directement (write-region), sans passer par un buffer
visitant le fichier — ce qui evite les deboires de chiffrement EPG/pinentry.
Si vous configurez un fichier .gpg, assurez-vous d'avoir pinentry-mac
installe et fonctionnel."
  (interactive
   (list (read-passwd "Cle API Gladia (collez puis Entree) : ")))
  (let* ((cle (metal-secretaire--valider-cle cle))
         (fichier (expand-file-name metal-secretaire-fichier-authinfo))
         (ligne (format "machine api.gladia.io login gladia password %s" cle))
         (motif "^.*machine[ \t]+api\\.gladia\\.io.*$")
         (chiffre (string-suffix-p ".gpg" fichier))
         (contenu (if (file-readable-p fichier)
                      (with-temp-buffer
                        (insert-file-contents fichier)
                        (buffer-string))
                    "")))
    (when (file-exists-p fichier)
      (copy-file fichier (concat fichier ".metal-secretaire-bak") t))
    ;; Construire le nouveau contenu dans un buffer temporaire, puis ecrire
    ;; d'un coup.  Pour un .gpg, write-region declenche le chiffrement EPG ;
    ;; pour un fichier simple, ecriture directe sans interaction.
    (let ((nouveau
           (with-temp-buffer
             (insert contenu)
             (goto-char (point-min))
             (if (re-search-forward motif nil t)
                 (replace-match ligne t t)
               (goto-char (point-max))
               (unless (or (bobp) (eq (char-before) ?\n)) (insert "\n"))
               (insert ligne "\n"))
             (buffer-string))))
      (with-temp-buffer
        (insert nouveau)
        (write-region (point-min) (point-max) fichier)))
    ;; Restreindre les permissions a 600 pour un fichier non chiffre.
    (unless chiffre
      (ignore-errors (set-file-modes fichier #o600)))
    ;; Forcer auth-source a relire le fichier au prochain acces.
    (when (fboundp 'auth-source-forget-all-cached)
      (auth-source-forget-all-cached))
    ;; Session courante : utilisable immediatement.
    (setenv "GLADIA_API_KEY" cle)
    (message "Cle Gladia enregistree dans %s (permissions 600) et active."
             (abbreviate-file-name fichier))))

;;;; ------------------------------------------------------------------
;;;; Lecture de l'ordre du jour DEPUIS le buffer .sec courant
;;;; ------------------------------------------------------------------
;;
;; L'ordre du jour vit dans le document .sec, sous la section de niveau 1
;; nommee `metal-secretaire-titre-ordre-du-jour'.  On en extrait :
;;   * le lexique : #+LEXIQUE: global + toutes les proprietes :LEXIQUE: ;
;;   * le contexte : titre du document + intitules des points.

(defun metal-secretaire--buffer-sec-p (&optional buffer)
  "Renvoie non nil si BUFFER (defaut courant) visite un fichier .sec."
  (with-current-buffer (or buffer (current-buffer))
    (and buffer-file-name (string-suffix-p ".sec" buffer-file-name))))

(defun metal-secretaire--assert-sec ()
  "Erreur si le buffer courant n'est pas un fichier .sec."
  (unless (metal-secretaire--buffer-sec-p)
    (user-error "Cette commande s'utilise dans un fichier .sec")))

(defun metal-secretaire--extraire-lexique ()
  "Extrait la liste dedupliquee des termes de lexique du buffer courant.
Lit #+LEXIQUE: (global) et toutes les proprietes :LEXIQUE:."
  (let ((termes '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*#\\+LEXIQUE:[ \t]*\\(.*\\)$" nil t)
        (dolist (terme (split-string (match-string 1) "[,;]" t "[ \t]+"))
          (push terme termes))))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*:LEXIQUE:[ \t]*\\(.*\\)$" nil t)
        (dolist (terme (split-string (match-string 1) "[,;]" t "[ \t]+"))
          (push terme termes))))
    (let ((vus (make-hash-table :test 'equal))
          (resultat '()))
      (dolist (terme (nreverse termes))
        (let ((cle (downcase (string-trim terme))))
          (unless (or (string-empty-p cle) (gethash cle vus))
            (puthash cle t vus)
            (push (string-trim terme) resultat))))
      (nreverse resultat))))

(defun metal-secretaire--titre-document ()
  "Renvoie le #+TITLE du buffer courant, ou le nom de base du fichier."
  (or (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^[ \t]*#\\+TITLE:[ \t]*\\(.*\\)$" nil t)
          (string-trim (match-string 1))))
      (and buffer-file-name (file-name-base buffer-file-name))
      "Seance sans titre"))

(defun metal-secretaire--region-section (titre)
  "Renvoie (DEBUT . FIN) de la section de niveau 1 intitulee TITRE, ou nil.
DEBUT est le debut de la ligne de titre ; FIN est le debut du prochain
titre de niveau 1 (ou `point-max')."
  (save-excursion
    (goto-char (point-min))
    (let ((motif (format "^\\*[ \t]+%s[ \t]*$"
                         (regexp-quote (string-trim titre)))))
      (when (re-search-forward motif nil t)
        (let ((debut (line-beginning-position))
              (fin (if (re-search-forward "^\\*[ \t]+" nil t)
                       (line-beginning-position)
                     (point-max))))
          (cons debut fin))))))

(defun metal-secretaire--texte-ordre-du-jour ()
  "Renvoie le texte de la section ordre du jour, ou tout le buffer en repli."
  (let ((region (metal-secretaire--region-section
                 metal-secretaire-titre-ordre-du-jour)))
    (if region
        (buffer-substring-no-properties (car region) (cdr region))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun metal-secretaire--contexte ()
  "Construit une chaine de contexte (sujet/registre) pour amorcer Gladia."
  (let ((titre (metal-secretaire--titre-document))
        (points '()))
    (let ((region (metal-secretaire--region-section
                   metal-secretaire-titre-ordre-du-jour)))
      (when region
        (save-excursion
          (goto-char (car region))
          (forward-line 1)
          (while (re-search-forward "^\\*\\*+[ \t]+\\(.*\\)$" (cdr region) t)
            (let ((intitule (string-trim (match-string 1))))
              (unless (string-empty-p intitule)
                (push intitule points)))))))
    (string-join
     (delq nil
           (list
            "Reunion : assemblee departementale universitaire."
            (unless (string-empty-p titre) (format "Sujet : %s." titre))
            (when points
              (format "Points a l'ordre du jour : %s."
                      (string-join (nreverse points) " ; ")))))
     " ")))

;;;; ------------------------------------------------------------------
;;;; Detection du fichier audio dans le dossier du .sec
;;;; ------------------------------------------------------------------

(defun metal-secretaire--trouver-audio ()
  "Cherche un fichier audio dans le dossier du .sec courant.
Priorite : meme nom de base que le .sec ; sinon, s'il n'y en a qu'un, ce
fichier ; sinon le plus recent.  Renvoie le chemin, ou nil si aucun."
  (let* ((dossier (file-name-directory buffer-file-name))
         (base (file-name-base buffer-file-name))
         (regexp (concat "\\." (regexp-opt metal-secretaire-extensions-audio)
                         "\\'"))
         (candidats (directory-files dossier t regexp t)))
    (cond
     ((null candidats) nil)
     ((seq-find (lambda (f) (string= (file-name-base f) base)) candidats))
     ((= (length candidats) 1) (car candidats))
     (t (car (sort candidats
                   (lambda (a b)
                     (time-less-p (file-attribute-modification-time
                                   (file-attributes b))
                                  (file-attribute-modification-time
                                   (file-attributes a))))))))))

;;;; ------------------------------------------------------------------
;;;; Enregistrement : ouverture d'une app native d'enregistrement
;;;; ------------------------------------------------------------------
;;
;; La capture directe depuis Emacs via ffmpeg est impossible de maniere
;; fiable sur macOS : un sous-processus (ffmpeg) lance par Emacs n'herite
;; pas des autorisations « Microphone » (mecanisme TCC / ports Mach), et
;; capte donc du silence sans jamais declencher la demande d'autorisation.
;;
;; On confie donc l'enregistrement a une APP NATIVE qui, elle, detient la
;; permission micro : QuickTime Player (defaut) ou Dictaphone sur macOS.
;; L'utilisateur enregistre la seance, puis depose le fichier audio dans le
;; dossier du .sec (au nom de base du .sec, de preference) ; la transcription
;; 📝 le detectera automatiquement.

(defcustom metal-secretaire-app-enregistrement
  (cond
   ((eq system-type 'darwin) 'quicktime)
   (t nil))
  "Application d'enregistrement ouverte par le bouton ⏺️.
Sur macOS : `quicktime' (defaut, permet de choisir l'emplacement de
sauvegarde) ou `dictaphone' (Voice Memos, plus simple mais fichiers ranges
dans la bibliotheque de l'app).  Sur Linux, definissez plutot
`metal-secretaire-commande-enregistrement'.  nil = aucune app connue."
  :type '(choice (const :tag "QuickTime Player (macOS)" quicktime)
                 (const :tag "Dictaphone / Voice Memos (macOS)" dictaphone)
                 (const :tag "Aucune (voir commande personnalisee)" nil))
  :group 'metal-secretaire)

(defcustom metal-secretaire-commande-enregistrement nil
  "Commande shell lancant un enregistreur audio (prioritaire si non nil).
Utile sous Linux/ChromeOS : par exemple \"gnome-sound-recorder\" ou
\"audacity\".  Sur macOS, laisser nil et utiliser
`metal-secretaire-app-enregistrement'.  La commande est lancee de maniere
asynchrone, sans argument."
  :type '(choice (const :tag "Aucune" nil) (string :tag "Commande"))
  :group 'metal-secretaire)

;;;###autoload
(defun metal-secretaire-enregistrer ()
  "Ouvre une application d'enregistrement audio pour capter la seance.
N'enregistre pas directement (macOS bloque la capture par sous-processus) :
ouvre QuickTime/Dictaphone (macOS) ou la commande configuree (Linux), puis
rappelle ou deposer le fichier ensuite."
  (interactive)
  (metal-secretaire--assert-sec)
  (let* ((dossier (file-name-directory buffer-file-name))
         (base (file-name-base buffer-file-name))
         (cible (expand-file-name (concat base ".m4a") dossier)))
    (cond
     ;; 1. Commande personnalisee (Linux/ChromeOS, ou override macOS).
     (metal-secretaire-commande-enregistrement
      (start-process-shell-command
       "metal-secretaire-enregistreur" nil
       metal-secretaire-commande-enregistrement)
      (metal-secretaire--rappel-depot cible
       (format "Enregistreur lance (%s)."
               metal-secretaire-commande-enregistrement)))
     ;; 2. macOS : ouvrir l'app native choisie.
     ((eq system-type 'darwin)
      (pcase metal-secretaire-app-enregistrement
        ('quicktime
         ;; AppleScript : ouvrir QuickTime ET creer une fenetre « Nouvel
         ;; enregistrement audio » prete (sans demarrer : l'utilisateur
         ;; verifie le micro et le niveau, puis clique le bouton rouge).
         ;; `new audio recording' est un Apple Event : la 1re fois, macOS
         ;; demande l'autorisation « Emacs souhaite controler QuickTime » —
         ;; a accorder.  En cas d'echec, repli sur une simple ouverture.
         (let ((script (concat
                        "tell application \"QuickTime Player\"\n"
                        "  activate\n"
                        "  if not (exists document 1) then new audio recording\n"
                        "end tell")))
           (unless (zerop (call-process "osascript" nil nil nil "-e" script))
             ;; Repli : ouverture simple si l'Apple Event echoue.
             (start-process "metal-secretaire-enregistreur" nil
                            "open" "-a" "QuickTime Player")))
         (metal-secretaire--rappel-depot cible
          "QuickTime : fenêtre d'enregistrement prête. Vérifiez le micro (▾ à côté du bouton rouge), puis cliquez ⏺ pour démarrer."))
        ('dictaphone
         (start-process "metal-secretaire-enregistreur" nil
                        "open" "-a" "Dictaphone")
         (metal-secretaire--rappel-depot cible
          "Dictaphone ouvert : enregistrez, puis exportez le fichier."))
        (_
         (user-error
          "Aucune app d'enregistrement configuree (voir metal-secretaire-app-enregistrement)"))))
     ;; 3. Autres systemes sans configuration.
     (t
      (user-error
       "Configurez metal-secretaire-commande-enregistrement pour votre systeme")))))

(defun metal-secretaire--rappel-depot (cible message-prefixe)
  "Affiche un rappel indiquant ou deposer le fichier audio (CIBLE).
MESSAGE-PREFIXE precede le rappel.  Le message reste affiche dans un
tampon d'aide pour que l'utilisateur retienne le chemin attendu."
  (let ((buf (get-buffer-create "*Secretaire — enregistrement*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert message-prefixe "\n\n")
        (insert "Quand l'enregistrement est terminé, sauvegardez (ou exportez)\n")
        (insert "le fichier audio dans le dossier de la séance.\n\n")
        (insert "Emplacement idéal (même nom que le .sec) :\n")
        (insert "    " cible "\n\n")
        (insert "N'importe quel nom dans ce dossier convient aussi :\n")
        (insert "    " (file-name-directory cible) "\n\n")
        (insert "Puis cliquez 📝 (ou C-c é t) pour transcrire.\n")
        (goto-char (point-min))))
    (display-buffer buf)
    (message "%s  Déposez l'audio dans le dossier du .sec, puis 📝." message-prefixe)))

;;;; ------------------------------------------------------------------
;;;; Transcription asynchrone (worker Gladia) -> section Verbatim
;;;; ------------------------------------------------------------------

(defun metal-secretaire--suffixe-duree ()
  "Renvoie un suffixe lisible avec la derniere duree mesuree, ou \"\"."
  (if metal-secretaire--derniere-duree
      (let* ((s (round metal-secretaire--derniere-duree))
             (m (/ s 60)) (r (% s 60)))
        (format " (%d min %02d s)" m r))
    ""))

(defun metal-secretaire--ecrire-fichier-temp (contenu suffixe)
  "Ecrit CONTENU dans un fichier temporaire avec SUFFIXE, renvoie son chemin."
  (let ((f (make-temp-file "metal-secretaire-" nil suffixe)))
    (with-temp-file f (insert (or contenu "")))
    f))

;;;###autoload
(defun metal-secretaire-transcrire ()
  "Transcrit l'audio de la seance et insere le verbatim en fin du .sec.
L'audio est cherche dans le dossier du fichier .sec courant."
  (interactive)
  (metal-secretaire--assert-sec)
  (when (process-live-p metal-secretaire--process-courant)
    (user-error "Une transcription est deja en cours (interrompez-la d'abord)"))
  (unless (metal-secretaire-cle-gladia)
    (user-error "Cle API Gladia introuvable (lancez metal-secretaire-configurer-cle)"))
  (unless (file-readable-p metal-secretaire-worker)
    (user-error "Worker Python introuvable : %s" metal-secretaire-worker))
  (let ((audio (metal-secretaire--trouver-audio)))
    (if (not audio)
        ;; Pas d'audio : proposer d'enregistrer, puis s'arreter (l'utilisateur
        ;; relancera la transcription apres l'arret de l'enregistrement).
        (if (y-or-n-p
             (format "Aucun audio dans %s. Enregistrer la seance maintenant ? "
                     (file-name-directory buffer-file-name)))
            (metal-secretaire-enregistrer)
          (message "Transcription annulee (aucun fichier audio)."))
      ;; Audio present : derouler la transcription.
      (metal-secretaire--lancer-transcription audio))))

(defun metal-secretaire--lancer-transcription (audio)
  "Lance la transcription Gladia sur le fichier AUDIO (deja localise)."
    (when (and (buffer-modified-p)
               (y-or-n-p "Enregistrer le .sec avant de transcrire ? "))
      (save-buffer))
    (let* ((titre (metal-secretaire--titre-document))
           (lexique (metal-secretaire--extraire-lexique))
           (contexte (metal-secretaire--contexte))
           (sortie (metal-secretaire--ecrire-fichier-temp "" ".org"))
           (f-vocab (and lexique
                         (metal-secretaire--ecrire-fichier-temp
                          (string-join lexique "\n") ".txt")))
           (f-ctx (and contexte
                       (metal-secretaire--ecrire-fichier-temp contexte ".txt")))
           (tampon (get-buffer-create metal-secretaire--tampon-transcription))
           (process-environment
            (cons (format "GLADIA_API_KEY=%s" (metal-secretaire-cle-gladia))
                  process-environment))
           (args (append
                  (list metal-secretaire-worker
                        "--audio" audio
                        "--sortie" sortie
                        "--fragment"
                        "--langue" metal-secretaire-langue
                        "--max-locuteurs"
                        (number-to-string metal-secretaire-max-locuteurs)
                        "--titre" titre)
                  (when f-vocab (list "--vocabulaire" f-vocab))
                  (when f-ctx (list "--contexte" f-ctx)))))
      (setq metal-secretaire--buffer-cible (current-buffer))
      (with-current-buffer tampon
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Transcription de « %s »\nAudio : %s\n" titre audio))
          (insert (format "Lexique amorce : %d termes\nSortie : %s\n\n"
                          (length lexique) sortie))))
      (display-buffer tampon)
      (setq metal-secretaire--interruption-volontaire nil
            metal-secretaire--debut-traitement (float-time))
      (setq metal-secretaire--process-courant
            (make-process
             :name "metal-secretaire-transcription"
             :buffer tampon
             :command (cons (metal-secretaire--python) args)
             :connection-type 'pipe
             :stderr tampon
             :sentinel (metal-secretaire--faire-sentinelle sortie)))
      (metal-secretaire--rafraichir-toolbar)
      (message "Transcription lancee — suivez %s"
               metal-secretaire--tampon-transcription)))

(defun metal-secretaire--faire-sentinelle (fichier-sortie)
  "Renvoie une sentinelle qui inserera FICHIER-SORTIE dans le .sec a la fin."
  (lambda (proc _evenement)
    (when (memq (process-status proc) '(exit signal))
      (let* ((code (process-exit-status proc))
             (duree (when metal-secretaire--debut-traitement
                      (- (float-time) metal-secretaire--debut-traitement))))
        (setq metal-secretaire--derniere-duree duree
              metal-secretaire--process-courant nil
              metal-secretaire--debut-traitement nil)
        (cond
         (metal-secretaire--interruption-volontaire
          (setq metal-secretaire--interruption-volontaire nil)
          (message "Transcription interrompue%s" (metal-secretaire--suffixe-duree)))
         ((eq code 0)
          (metal-secretaire--inserer-verbatim fichier-sortie)
          (message "Verbatim insere%s" (metal-secretaire--suffixe-duree)))
         (t
          (message "Echec de la transcription (code %d)%s — voir %s"
                   code (metal-secretaire--suffixe-duree)
                   metal-secretaire--tampon-transcription)
          (display-buffer metal-secretaire--tampon-transcription)))
        (metal-secretaire--rafraichir-toolbar)))))

(defun metal-secretaire--inserer-section-fin (titre contenu)
  "Insere une section niveau 1 TITRE avec CONTENU en fin de buffer.
Si une section TITRE existe deja, son corps est remplace."
  (let ((region (metal-secretaire--region-section titre)))
    (save-excursion
      (if region
          (progn
            (delete-region (car region) (cdr region))
            (goto-char (car region)))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (unless (eq (char-before) ?\n) (insert "\n")))
      (insert (format "* %s\n%s" titre contenu))
      (unless (string-suffix-p "\n" contenu) (insert "\n")))))

(defun metal-secretaire--inserer-verbatim (fichier)
  "Insere le contenu de FICHIER comme section Verbatim du buffer cible."
  (when (and metal-secretaire--buffer-cible
             (buffer-live-p metal-secretaire--buffer-cible)
             (file-readable-p fichier))
    (let ((contenu (with-temp-buffer
                     (insert-file-contents fichier)
                     (buffer-string))))
      (with-current-buffer metal-secretaire--buffer-cible
        (metal-secretaire--inserer-section-fin
         metal-secretaire-titre-verbatim contenu)
        (when buffer-file-name (save-buffer)))
      (pop-to-buffer metal-secretaire--buffer-cible))))

;;;###autoload
(defun metal-secretaire-interrompre ()
  "Interrompt la transcription en cours, le cas echeant."
  (interactive)
  (if (process-live-p metal-secretaire--process-courant)
      (progn
        (setq metal-secretaire--interruption-volontaire t)
        (interrupt-process metal-secretaire--process-courant)
        (message "Interruption demandee..."))
    (message "Aucune transcription en cours.")))

;;;; ------------------------------------------------------------------
;;;; Redaction du PV -> insertion APRES la section ordre du jour
;;;; ------------------------------------------------------------------

(defun metal-secretaire--prompt-pv (titre odj-texte verbatim-texte)
  "Construit le prompt de redaction du PV."
  (concat
   "Tu es secretaire d'une assemblee departementale universitaire. "
   "A partir du verbatim horodate ci-dessous et de l'ordre du jour fourni, "
   "redige un proces-verbal en francais, formel et concis, au format Org-mode.\n\n"
   "REGLES DE REDACTION :\n"
   "- Structure le PV selon les points de l'ordre du jour (memes numeros, memes intitules), en sous-titres de niveau 2 (**).\n"
   "- Pour chaque point : resume les deliberations en style indirect, sans verbatim.\n"
   "- Identifie les PROPOSITIONS : « Proposition de X, appuyee par Y ».\n"
   "- Indique l'issue des votes : « Adoptee a l'unanimite », « Adoptee sur division », ou le decompte.\n"
   "- Termine par un sous-titre « ** Mandats confies » listant qui fait quoi et pour quand.\n"
   "- N'invente jamais de nom, de chiffre ni de decision : si le verbatim est ambigu, ecris « [a preciser] ».\n"
   "- Conserve les etiquettes « Intervenant N » si aucun nom n'est dit.\n"
   "- Ne reproduis pas le verbatim ; produis une synthese deliberative.\n"
   "- NE PRODUIS PAS le titre de niveau 1 (la section « Proces-verbal » est deja en place) : commence directement aux sous-titres de niveau 2.\n\n"
   "=== ORDRE DU JOUR ===\n" odj-texte "\n\n"
   "=== VERBATIM ===\n" verbatim-texte "\n\n"
   "=== FIN ===\n"
   "Rends UNIQUEMENT le corps du proces-verbal Org-mode (sous-titres niveau 2), sans commentaire."))

;;;###autoload
(defun metal-secretaire-rediger-pv ()
  "Genere le PV a partir de l'ordre du jour et du verbatim du .sec courant.
Insere le resultat sous une section « Proces-verbal » placee juste apres
la section ordre du jour.  Delegue a `metal-agent' si disponible."
  (interactive)
  (metal-secretaire--assert-sec)
  (let ((verbatim-region (metal-secretaire--region-section
                          metal-secretaire-titre-verbatim)))
    (unless verbatim-region
      (user-error "Aucune section « %s » : transcrivez d'abord la seance"
                  metal-secretaire-titre-verbatim))
    (let* ((titre (metal-secretaire--titre-document))
           (odj-texte (metal-secretaire--texte-ordre-du-jour))
           (verbatim-texte (buffer-substring-no-properties
                            (car verbatim-region) (cdr verbatim-region)))
           (prompt (metal-secretaire--prompt-pv titre odj-texte verbatim-texte))
           (cible (current-buffer)))
      (cond
       ((fboundp 'metal-agent-requete-libre)
        (metal-agent-requete-libre
         prompt
         :agent metal-secretaire-agent-pv
         :callback (lambda (reponse)
                     (when (buffer-live-p cible)
                       (with-current-buffer cible
                         (metal-secretaire--inserer-pv reponse)))))
        (message "Redaction du PV deleguee a %s..." metal-secretaire-agent-pv))
       (t
        (let ((buf (get-buffer-create (format "*PV a soumettre — %s*" titre))))
          (with-current-buffer buf
            (erase-buffer) (insert prompt) (goto-char (point-min)))
          (display-buffer buf)
          (message "metal-agent absent : prompt depose dans %s."
                   (buffer-name buf))))))))

(defun metal-secretaire--inserer-pv (corps)
  "Insere CORPS comme section « Proces-verbal » apres l'ordre du jour."
  (let* ((odj (metal-secretaire--region-section
               metal-secretaire-titre-ordre-du-jour))
         (pv-existant (metal-secretaire--region-section
                       metal-secretaire-titre-pv))
         (bloc (format "* %s\n%s%s"
                       metal-secretaire-titre-pv
                       corps
                       (if (string-suffix-p "\n" corps) "" "\n"))))
    (save-excursion
      (cond
       (pv-existant
        (delete-region (car pv-existant) (cdr pv-existant))
        (goto-char (car pv-existant))
        (insert bloc "\n"))
       (odj
        (goto-char (cdr odj))
        (insert bloc "\n"))
       (t
        (goto-char (point-min))
        (forward-line 0)
        (insert bloc "\n"))))
    (when buffer-file-name (save-buffer))))

;;;; ------------------------------------------------------------------
;;;; Re-etiquetage des intervenants
;;;; ------------------------------------------------------------------

;;;###autoload
(defun metal-secretaire-renommer-intervenant (ancien nouveau)
  "Remplace toutes les occurrences d'ANCIEN par NOUVEAU dans le buffer."
  (interactive
   (list (read-string "Etiquette a remplacer (ex. Intervenant 1) : "
                      "Intervenant ")
         (read-string "Nouveau nom : ")))
  (when (string-empty-p (string-trim ancien))
    (user-error "Etiquette source vide"))
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (search-forward ancien nil t)
        (replace-match nouveau t t)
        (setq n (1+ n)))
      (message "%d occurrence(s) de « %s » remplacee(s) par « %s »"
               n ancien nouveau))))

;;;; ------------------------------------------------------------------
;;;; Barre d'outils : bouton 🗒️ (bascule) + barre secretaire etendue
;;;; ------------------------------------------------------------------
;;
;; Pattern calque sur metal-agent : `metal-secretaire-toolbar-buttons' renvoie
;; soit le bouton compact (🗒️ seul) quand `metal-secretaire-active' est nil,
;; soit la barre etendue quand il est non nil.  C'est `metal-toolbar-build'
;; (avec :secretaire t) qui masque les boutons Org quand la barre est active.

(defun metal-secretaire--bouton (icon tooltip command)
  "Bouton header-line via la primitive publique `metal-toolbar-button'."
  (metal-toolbar-button
   (metal-toolbar-emoji icon) tooltip command 'header-line))

(defun metal-secretaire-toolbar-compact ()
  "Segment compact : bouton 🗒️ seul, qui active la barre secretaire."
  (concat
   (metal-toolbar-separator)
   (metal-toolbar-button
    (metal-toolbar-emoji "🗒️" :color metal-secretaire-couleur)
    "Activer la barre du secrétaire d'assemblée"
    #'metal-secretaire-toggle-active
    'header-line)))

(defun metal-secretaire-toolbar-expanded ()
  "Barre secretaire complete (quand `metal-secretaire-active')."
  (let ((transcription (process-live-p metal-secretaire--process-courant)))
    (concat
     (metal-toolbar-separator)
     (metal-toolbar-button
      (metal-toolbar-emoji "🗒️" :color metal-secretaire-couleur)
      "Réduire la barre du secrétaire (revenir aux boutons Org)"
      #'metal-secretaire-toggle-active
      'header-line)
     "   "
     ;; Enregistrement : ouvre une app native (QuickTime/Dictaphone).
     (metal-secretaire--bouton "⏺️" "Ouvrir l'enregistreur audio"
                               #'metal-secretaire-enregistrer)
     " "
     ;; Transcription (audio -> texte) : 📝 plutot que 🎙️ (qui evoque la
     ;; captation, pas la mise en texte).
     (metal-secretaire--bouton "📝" "Transcrire l'audio de la séance (Gladia)"
                               #'metal-secretaire-transcrire)
     " "
     (metal-secretaire--bouton "🏷️" "Renommer un intervenant"
                               #'metal-secretaire-renommer-intervenant)
     " "
     (metal-secretaire--bouton "📋" "Rédiger le procès-verbal"
                               #'metal-secretaire-rediger-pv)
     (if transcription
         (concat
          " " (metal-toolbar-separator) " "
          (metal-secretaire--bouton "❌" "Interrompre la transcription"
                                    #'metal-secretaire-interrompre))
       ""))))

(defun metal-secretaire-toolbar-buttons ()
  "Segment secretaire a greffer dans la barre Org (via :secretaire t).
Compact (🗒️) si inactif, etendu si `metal-secretaire-active'."
  (if metal-secretaire-active
      (metal-secretaire-toolbar-expanded)
    (metal-secretaire-toolbar-compact)))

;;;###autoload
(defun metal-secretaire-toggle-active ()
  "Basculer entre la barre Org et la barre du secrétaire."
  (interactive)
  (setq metal-secretaire-active (not metal-secretaire-active))
  (force-mode-line-update t)
  (redraw-display))

(defun metal-secretaire--rafraichir-toolbar ()
  "Force le rafraichissement des header-lines des buffers .sec."
  (force-mode-line-update t)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and header-line-format (metal-secretaire--buffer-sec-p))
        (setq header-line-format header-line-format)))))

;;;; ------------------------------------------------------------------
;;;; Association .sec -> org-mode
;;;; ------------------------------------------------------------------
;;
;; Les fichiers .sec ne sont pas un mode derive : ils s'ouvrent en `org-mode'
;; ordinaire (la barre Org, qui greffe le segment secretaire 🗒️ pour les .sec
;; via `metal-org.el', s'affiche alors normalement).  Sans cette ligne, un
;; .sec s'ouvrirait en `fundamental-mode' et n'aurait AUCUNE barre.

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.sec\\'" . org-mode))

(provide 'metal-secretaire)
;;; metal-secretaire.el ends here
