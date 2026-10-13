;;; metal-revision.el --- Révision interactive Ediff, hunk par hunk  -*- lexical-binding: t; -*-

;; Auteur : Jacques Ladouceur
;; Fait partie de MetalEmacs.

;;; Commentary:
;;
;; Moteur de révision commun à MetalEmacs.  Ouvre un frame séparé :
;; texte d'origine à gauche, proposition à droite, panneau Ediff natif
;; en bas, et une barre de boutons dans la header-line de droite :
;;
;;   ⬅️ / ➡️      différence précédente / suivante
;;   ✅           accepter le bloc de droite
;;   ↩️           annuler l'acceptation du bloc
;;   ✔️ Terminer  appliquer les blocs acceptés à la cible
;;   🚫 Annuler   fermer sans rien modifier
;;
;; Ediff ne travaille que sur deux tampons temporaires ; la cible n'est
;; touchée qu'au moment de « Terminer ».
;;
;; Interface publique :
;;
;;   (metal-revision-lancer ORIGINAL PROPOSE :cible TAMPON ...)
;;   (metal-revision-active-p)
;;   (metal-revision-prose-p TAMPON)
;;   `metal-revision-fin-functions'
;;
;; Clients : metal-agent (corrections de l'agent), metal-algo (programme
;; produit depuis un algorithme), et les deux commandes de comparaison
;; définies plus bas :
;;
;;   M-x metal-comparer-documents   fichier courant (ou choisi) ← autre fichier
;;   M-x metal-comparer-tampons     tampon ← autre tampon

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'metal-toolbar)

;; Déclarée spéciale pour que le `let' de `metal-revision--preparer-buffer'
;; la lie dynamiquement même si Org n'est pas encore chargé.
(defvar org-startup-folded)

(defgroup metal-revision nil
  "Révision interactive Ediff de MetalEmacs."
  :group 'tools
  :prefix "metal-revision-")

;; Anciens noms (avant l'extraction hors de metal-agent.el), pour que les
;; réglages enregistrés restent valides.
(dolist (paire '((metal-agent-ediff-frame-name        . metal-revision-frame-name)
                 (metal-agent-ediff-frame-width       . metal-revision-frame-width)
                 (metal-agent-ediff-frame-height      . metal-revision-frame-height)
                 (metal-agent-ediff-auto-refine-limit . metal-revision-auto-refine-limit)
                 (metal-agent-ediff-afficher-espaces  . metal-revision-afficher-espaces)
                 (metal-agent-ediff-control-height    . metal-revision-control-height)))
  (define-obsolete-variable-alias (car paire) (cdr paire) "MetalEmacs 2026-10"))
(dolist (paire '((metal-agent-ediff-region-A . metal-revision-region-A)
                 (metal-agent-ediff-region-B . metal-revision-region-B)
                 (metal-agent-ediff-fine-A   . metal-revision-fine-A)
                 (metal-agent-ediff-fine-B   . metal-revision-fine-B)))
  (put (car paire) 'face-alias (cdr paire)))

(defcustom metal-revision-etiquettes-defaut '("ORIGINAL" . "CORRECTION(S)")
  "Titres par défaut des colonnes gauche et droite de la révision."
  :type '(cons string string)
  :group 'metal-revision)

(defvar metal-revision--etiquettes metal-revision-etiquettes-defaut
  "Titres (GAUCHE . DROITE) de la session courante.")

(defvar metal-revision--apres nil
  "Rappel du client pour la session courante, appelé avec (APPLIQUER RÉSULTAT).")

(defvar metal-revision-fin-functions nil
  "Fonctions appelées à la fin de chaque révision, avec (APPLIQUER RÉSULTAT).
APPLIQUER est non-nil si l'utilisateur a cliqué « Terminer » ; RÉSULTAT
est alors le texte appliqué à la cible, sinon nil.")

;;; --- Moteur de révision ------------------------------------------------

(defcustom metal-revision-frame-name "MetalEmacs — Révision"
  "Nom du frame séparé utilisé pour la révision Ediff."
  :type 'string
  :group 'metal-revision)

(defcustom metal-revision-frame-width 180
  "Largeur du frame séparé utilisé pour la révision Ediff."
  :type 'integer
  :group 'metal-revision)

(defcustom metal-revision-frame-height 48
  "Hauteur du frame séparé utilisé pour la révision Ediff."
  :type 'integer
  :group 'metal-revision)

(defvar metal-revision--target-buffer nil)
(defvar metal-revision--target-kind   nil)
(defvar metal-revision--target-beg    nil)
(defvar metal-revision--target-end    nil)
(defvar metal-revision--avant-buf     nil)
(defvar metal-revision--apres-buf     nil)
(defvar metal-revision--original-text nil)
(defvar metal-revision--window-config nil)
(defvar metal-revision--source-frame nil)
(defvar metal-revision--frame nil)
(defvar metal-revision--control-buffer nil
  "Buffer de controle Ediff de la session MetalEmacs courante.")
(defvar metal-revision--originaux-blocs nil
  "Alist (NUMÉRO-DIFF . TEXTE-ORIGINAL) des blocs A acceptés.
Permet à `metal-revision-annuler-bloc' de restaurer la version d'origine
d'un bloc, indépendamment du mécanisme interne d'Ediff `ediff-restore-diff'
qui, dans notre configuration, n'enregistre pas de façon fiable la version
tuée du bloc.")
(defvar metal-revision--nettoyage-fait-p nil
  "Non-nil quand le nettoyage d'une session a déjà eu lieu.
Évite un double nettoyage quand la fermeture passe à la fois par le bouton
Terminer/Annuler et par `delete-frame-functions' (bouton X de macOS).")
(defvar metal-revision--frame-en-suppression nil
  "Frame de révision en cours de suppression, le temps du garde.
Renseigné par `metal-revision--frame-supprime-garde' pour éviter que
`metal-revision--quit-hook' ne tente de re-supprimer ce frame.")

;; ─────────────────────────────────────────────────────────────────
;; Contraste et raffinage fin des différences (lisibilité de la révision)
;; ─────────────────────────────────────────────────────────────────
;; Ediff distingue la RÉGION (tout le hunk, fond doux) du RAFFINAGE FIN
;; (les mots réellement modifiés, fond saturé).  Par défaut le raffinage
;; ne s'applique pas aux grandes régions, d'où des paragraphes entiers
;; colorés en bloc dans lesquels la vraie correction est invisible.  On
;; force le raffinage et on sature les faces `*-fine-diff-*'.

(defcustom metal-revision-auto-refine-limit 40000
  "Taille maximale (en octets) d'une région encore raffinée mot-à-mot.
Au-delà, Ediff ne surligne plus que la région entière.  Relevée par
rapport au défaut d'Ediff (~14000) pour couvrir de gros paragraphes."
  :type 'integer
  :group 'metal-revision)

(defface metal-revision-region-A
  '((((class color) (background dark))  (:background "#3a1f1f" :extend t))
    (((class color) (background light)) (:background "#ffe2e2" :extend t)))
  "Région différente dans le buffer AVANT (fond doux)."
  :group 'metal-revision)

(defface metal-revision-region-B
  '((((class color) (background dark))  (:background "#1c361f" :extend t))
    (((class color) (background light)) (:background "#dcf5dc" :extend t)))
  "Région différente dans le buffer APRÈS (fond doux)."
  :group 'metal-revision)

(defface metal-revision-fine-A
  '((((class color) (background dark))  (:background "#a31515" :foreground "white" :weight bold))
    (((class color) (background light)) (:background "#ff9b9b" :foreground "#5a0000" :weight bold)))
  "Mots réellement modifiés dans le buffer AVANT (fond saturé)."
  :group 'metal-revision)

(defface metal-revision-fine-B
  '((((class color) (background dark))  (:background "#1f8b3a" :foreground "white" :weight bold))
    (((class color) (background light)) (:background "#86e09a" :foreground "#003d11" :weight bold)))
  "Mots réellement modifiés dans le buffer APRÈS (fond saturé)."
  :group 'metal-revision)

(defvar metal-revision--faces-saved nil
  "Sauvegarde des faces Ediff originales, restaurées en fin de session.")
(defvar metal-revision--refine-saved nil
  "Sauvegarde de `ediff-auto-refine' / `-limit' originaux.")
(defcustom metal-revision-afficher-espaces t
  "Si non-nil, affiche les espaces insécables et fins de ligne dans la
révision, pour rendre visibles les changements purement typographiques.
Les espaces insécables (U+00A0, U+202F) que l'agent ajoute pour la
typographie française (devant « : ; ? ! ») sont ainsi distinguables d'une
espace normale, ce qui évite de confondre un changement de fond avec un
simple changement typographique.  Le texte n'est jamais modifié : les
insécables proposées par l'agent sont conservées dans le résultat."
  :type 'boolean
  :group 'metal-revision)

(defun metal-revision--appliquer-contraste ()
  "Rediriger les faces Ediff vers les faces contrastées MetalEmacs.
Sauvegarde les `:inherit' (ou attributs) d'origine pour restauration.
À appeler une fois la session établie."
  (unless metal-revision--faces-saved
    (setq metal-revision--faces-saved
          (mapcar (lambda (f) (cons f (face-attribute f :inherit nil 'default)))
                  '(ediff-current-diff-A ediff-current-diff-B
                    ediff-fine-diff-A ediff-fine-diff-B))))
  (set-face-attribute 'ediff-current-diff-A nil :inherit 'metal-revision-region-A)
  (set-face-attribute 'ediff-current-diff-B nil :inherit 'metal-revision-region-B)
  (set-face-attribute 'ediff-fine-diff-A nil :inherit 'metal-revision-fine-A)
  (set-face-attribute 'ediff-fine-diff-B nil :inherit 'metal-revision-fine-B)
  ;; Forcer le raffinage fin systématique, en sauvegardant l'état.
  (unless metal-revision--refine-saved
    (setq metal-revision--refine-saved
          (list (and (boundp 'ediff-auto-refine) ediff-auto-refine)
                (and (boundp 'ediff-auto-refine-limit) ediff-auto-refine-limit))))
  (setq ediff-auto-refine 'on
        ediff-auto-refine-limit metal-revision-auto-refine-limit))

(defun metal-revision--restaurer-contraste ()
  "Restaurer les faces et le raffinage Ediff modifiés par MetalEmacs."
  (when metal-revision--faces-saved
    (dolist (pair metal-revision--faces-saved)
      (set-face-attribute (car pair) nil :inherit (or (cdr pair) 'unspecified)))
    (setq metal-revision--faces-saved nil))
  (when metal-revision--refine-saved
    (when (boundp 'ediff-auto-refine)
      (setq ediff-auto-refine (or (nth 0 metal-revision--refine-saved) 'on)))
    (when (boundp 'ediff-auto-refine-limit)
      (setq ediff-auto-refine-limit (or (nth 1 metal-revision--refine-saved) 14000)))
    (setq metal-revision--refine-saved nil)))
(defvar metal-revision--cleanup-en-cours nil
  "Non-nil pendant le nettoyage manuel de la session Ediff MetalEmacs.")
(defvar-local metal-revision--temp-buffer-p nil
  "Non-nil si le buffer est un buffer temporaire Ediff MetalEmacs.")
(defvar metal-revision--saved-setup-fn nil
  "Valeur précédente de `ediff-window-setup-function' à restaurer en sortie.")
(defvar metal-revision--saved-split-fn nil
  "Valeur précédente de `ediff-split-window-function' à restaurer en sortie.")
(defvar metal-revision--saved-control-frame-parameters nil
  "Valeur précédente de `ediff-control-frame-parameters' à restaurer en sortie.")
(defvar metal-revision--saved-use-long-help-message nil
  "Valeur précédente de `ediff-use-long-help-message' à restaurer en sortie.")
(defvar metal-revision--saved-verbose-help-p nil
  "Valeur précédente de `ediff-verbose-help-p' à restaurer en sortie.")
(defvar metal-revision--saved-diff-options nil
  "Valeur précédente de `ediff-diff-options' à restaurer en sortie.")
(defvar metal-revision--saved-tab-line-mode nil
  "Valeur précédente de `global-tab-line-mode', si disponible.")
(defvar metal-revision--variables-saved-p nil
  "Non-nil si les variables Ediff globales ont été sauvegardées.")

(defun metal-revision--make-wide-control-buffer-id-autour (orig-fn &rest args)
  "Protéger Ediff contre un bug interne de `format' dans son panneau wide.

`ediff-make-wide-control-buffer-id' construit l'identifiant « A: … B: … »
du panneau de contrôle.  Dans certaines versions d'Ediff, son `format'
interne lève « Format specifier doesn't match argument type » lorsque le
panneau est rafraîchi en continu (ce qui est le cas chez nous depuis que
le panneau natif est AFFICHÉ).  Le bug est interne à Ediff et indépendant
de l'interface MetalEmacs.  On renvoie alors un identifiant neutre plutôt
que de laisser l'erreur remonter dans le process sentinel du diff."
  (condition-case nil
      (apply orig-fn args)
    (error "   *Ediff Control Panel*")))

(defun metal-revision--installer-protection-wide ()
  "Installer la protection contre le bug du panneau de contrôle wide d'Ediff."
  (when (fboundp 'ediff-make-wide-control-buffer-id)
    (advice-add 'ediff-make-wide-control-buffer-id
                :around #'metal-revision--make-wide-control-buffer-id-autour)))

(defun metal-revision--retirer-protection-wide ()
  "Retirer la protection contre le bug du panneau de contrôle wide d'Ediff."
  (when (fboundp 'ediff-make-wide-control-buffer-id)
    (advice-remove 'ediff-make-wide-control-buffer-id
                   #'metal-revision--make-wide-control-buffer-id-autour)))

(defun metal-revision--refresh-mode-lines-autour (orig-fn &rest args)
  "Neutraliser le faux positif « vital Ediff buffer » des mode-lines.

Quand une seconde session démarre alors que les buffers AVANT/APRÈS de la
précédente survivent (enterrés ; Ediff conserve les variantes par défaut),
le rafraîchissement des mode-lines d'Ediff repasse sur des restes de
session dont le panneau est mort et lève à tort
« You have killed a vital Ediff buffer---you must leave Ediff now! ».

Cette protection, présente dans la conception d'origine de MetalEmacs et
validée empiriquement, ne filtre QUE cette erreur précise ; toute autre
erreur continue de remonter normalement."
  (condition-case err
      (apply orig-fn args)
    (error
     (let ((msg (error-message-string err)))
       (unless (string-match-p "vital Ediff buffer" msg)
         (signal (car err) (cdr err)))))))

(defun metal-revision--installer-protection-refresh ()
  "Installer la protection contre les faux positifs de refresh Ediff."
  (when (fboundp 'ediff-refresh-mode-lines)
    (advice-add 'ediff-refresh-mode-lines
                :around #'metal-revision--refresh-mode-lines-autour)))

(defun metal-revision--retirer-protection-refresh ()
  "Retirer la protection contre les faux positifs de refresh Ediff."
  (when (fboundp 'ediff-refresh-mode-lines)
    (advice-remove 'ediff-refresh-mode-lines
                   #'metal-revision--refresh-mode-lines-autour)))

(defun metal-revision--tuer-buffers-temporaires ()
  "Nettoyer doucement les anciens buffers temporaires MetalEmacs.

On évite ici TOUT `kill-buffer' et toute manipulation des buffers ou
panneaux de contrôle Ediff : Ediff veut être seul maître de ses buffers,
et toute intervention programmée (kill-buffer, ediff-cleanup-mess hors
session) déclenche « You have killed a vital Ediff buffer ».  On se
contente donc d'enterrer nos propres buffers temporaires AVANT/APRÈS d'une
session antérieure ; Ediff nettoie les siens à la fermeture normale via
`ediff-quit'."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (not (eq buf metal-revision--avant-buf))
               (not (eq buf metal-revision--apres-buf))
               (buffer-local-value 'metal-revision--temp-buffer-p buf))
      (ignore-errors (bury-buffer buf)))))

(defun metal-revision--commande-native (commande)
  "Exécuter COMMANDE Ediff depuis le buffer de contrôle natif.
On bascule dans le buffer de contrôle avant l'appel : c'est le contexte
qu'Ediff exige (`ediff-barf-if-not-control-buffer').  On laisse Ediff
gérer son propre état — bornes, marqueurs, raffinage — sans intervention.
Aucun ajustement manuel de `ediff-current-difference' : c'est ce
bidouillage qui causait `number-or-marker-p, nil'."
  (let ((control metal-revision--control-buffer))
    (if (not (buffer-live-p control))
        (message "Aucune session Ediff active.")
      (let ((win (get-buffer-window control t)))
        (if win
            (with-selected-window win
              (call-interactively commande))
          ;; Le panneau n'est pas affiché dans une fenêtre : on exécute
          ;; tout de même la commande dans le buffer de contrôle.
          (with-current-buffer control
            (call-interactively commande)))))))

(defun metal-revision-suivant ()
  "Aller à la différence suivante (commande native `ediff-next-difference')."
  (interactive)
  (metal-revision--commande-native #'ediff-next-difference))

(defun metal-revision-precedent ()
  "Aller à la différence précédente (commande native `ediff-previous-difference')."
  (interactive)
  (metal-revision--commande-native #'ediff-previous-difference))

(defun metal-revision--bornes-bloc-A ()
  "Retourne (DEBUT . FIN) du bloc courant dans le buffer A, ou nil.
À appeler depuis le buffer de contrôle Ediff."
  (let ((n ediff-current-difference))
    (when (and n (>= n 0))
      (let ((beg (ediff-get-diff-posn 'A 'beg n))
            (end (ediff-get-diff-posn 'A 'end n)))
        (when (and beg end)
          (cons beg end))))))

(defun metal-revision-accepter ()
  "Accepter la modification courante : copie B (APRÈS) vers A (AVANT).
Avant la copie, mémorise le texte d'origine du bloc dans A afin de pouvoir
l'annuler ensuite (`metal-revision-annuler-bloc'), sans dépendre du
mécanisme interne d'Ediff."
  (interactive)
  (let ((control metal-revision--control-buffer))
    (when (buffer-live-p control)
      (with-current-buffer control
        (let ((n ediff-current-difference)
              (bornes (metal-revision--bornes-bloc-A)))
          (when (and n (>= n 0) bornes
                     ;; Ne pas écraser un original déjà mémorisé (si on
                     ;; ré-accepte après avoir annulé, on garde le tout
                     ;; premier original).
                     (not (assq n metal-revision--originaux-blocs)))
            (let ((texte (with-current-buffer ediff-buffer-A
                           (buffer-substring-no-properties
                            (car bornes) (cdr bornes)))))
              (push (cons n texte) metal-revision--originaux-blocs)))))))
  (metal-revision--commande-native #'ediff-copy-B-to-A))

(defun metal-revision-annuler-bloc ()
  "Annuler l'acceptation du bloc courant : restaurer sa version d'origine.
Réinsère dans A le texte d'origine mémorisé lors de l'acceptation
(`metal-revision-accepter').  Fonctionne à tout moment, y compris
après être passé à d'autres blocs puis revenu.  Si le bloc n'a pas été
accepté, informe l'utilisateur sans rien changer."
  (interactive)
  (let ((control metal-revision--control-buffer))
    (if (not (buffer-live-p control))
        (message "Aucune session Ediff active.")
      (with-current-buffer control
        (let* ((n ediff-current-difference)
               (entree (and n (assq n metal-revision--originaux-blocs))))
          (cond
           ((not (and n (>= n 0)))
            (message "Aucun bloc courant."))
           ((null entree)
            (message "Ce bloc n'a pas été accepté — rien à annuler."))
           (t
            (let ((bornes (metal-revision--bornes-bloc-A)))
              (if (not bornes)
                  (message "Bornes du bloc introuvables.")
                (with-current-buffer ediff-buffer-A
                  (let ((inhibit-read-only t))
                    (goto-char (car bornes))
                    (delete-region (car bornes) (cdr bornes))
                    (insert (cdr entree))))
                ;; Oublier l'original : le bloc est revenu à son état initial.
                (setq metal-revision--originaux-blocs
                      (assq-delete-all n metal-revision--originaux-blocs))
                ;; Recalculer les différences pour rafraîchir l'affichage.
                (ignore-errors (ediff-recenter))
                (message "Correction annulée pour ce bloc."))))))))))

(defun metal-revision--quit-natif-sans-confirmation (control)
  "Clore la session Ediff du buffer CONTROL via `ediff-quit', sans confirmer.
On neutralise la question « quitter ? » en forçant les fonctions de
confirmation à répondre oui le temps de l'appel.  Plus robuste que
d'appeler une fonction interne d'Ediff dont la signature varie selon les
versions.

Sous Windows, un clic sur un bouton de header-line fait de
`last-nonmenu-event' un événement souris : toute question posée pendant la
fermeture passerait alors par une boîte de dialogue native, qui peut
s'ouvrir derrière le frame et figer Emacs en boucle modale.  On force donc
le minibuffer (`use-dialog-box' nil, `last-nonmenu-event' t)."
  (when (buffer-live-p control)
    (with-current-buffer control
      (let ((use-dialog-box nil)
            (last-nonmenu-event t))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (with-demoted-errors "Révision (ediff-quit) : %S"
            (ediff-quit nil)))))))

(defun metal-revision-quitter ()
  "Terminer la session Ediff et appliquer les corrections acceptées.
On capture d'abord le résultat (le buffer AVANT), PUIS on clôt la session
Ediff native — car `ediff-cleanup-mess' tue les buffers A/B — et enfin on
applique le résultat capturé via le hook (APPLIQUER non-nil).  C'est le
seul chemin qui applique."
  (interactive)
  (let ((control metal-revision--control-buffer)
        (use-dialog-box nil)
        (last-nonmenu-event t))
    (if (not (buffer-live-p control))
        (progn
          ;; Session à moitié fermée (erreur antérieure) : on nettoie quand
          ;; même, pour ne pas laisser le frame et les variables en plan.
          (when (or metal-revision--frame metal-revision--target-buffer)
            (metal-revision--quit-hook nil))
          (message "Aucune session Ediff active."))
      ;; 1. Capturer le résultat AVANT toute fermeture native.
      (let ((resultat (metal-revision--texte-buffer
                       metal-revision--avant-buf))
            (termine nil))
        (unwind-protect
            (progn
              ;; 2. Détacher notre hook, clore la session Ediff nativement.
              (with-current-buffer control
                (remove-hook 'ediff-quit-hook #'metal-revision--quit-hook t))
              (metal-revision--quit-natif-sans-confirmation control)
              ;; 3. Appliquer le résultat capturé et nettoyer.
              (metal-revision--quit-hook t resultat)
              (setq termine t))
          ;; Erreur ou C-g en cours de route : le hook n'a pas pu finir.
          ;; On force le nettoyage (sans réappliquer) pour rendre la main.
          (unless termine
            (setq metal-revision--nettoyage-fait-p nil)
            (metal-revision--quit-hook nil)))))))

(defun metal-revision-annuler ()
  "Fermer la révision sans appliquer aucune correction.
On clôt la session Ediff native puis on nettoie en appelant le hook avec
APPLIQUER nil : la cible reste inchangée.  C'est le pendant explicite du
bouton X de macOS, mais déclenché depuis la barre."
  (interactive)
  (let ((control metal-revision--control-buffer))
    (if (not (buffer-live-p control))
        (message "Aucune session Ediff active.")
      (with-current-buffer control
        (remove-hook 'ediff-quit-hook #'metal-revision--quit-hook t))
      (metal-revision--quit-natif-sans-confirmation control)
      (metal-revision--quit-hook nil))))

(defun metal-revision--button (label command help)
  "Créer un bouton de header-line Ediff via `metal-toolbar-button'.
Conserve le fond permanent (`mode-line-highlight') propre aux boutons
Ediff et câble header-line + mode-line.  COMMAND est enveloppée pour
rester appelable interactivement."
  (let* ((cmd (lambda ()
                (interactive)
                (call-interactively command)))
         (bouton (metal-toolbar-button label help cmd
                                       '(header-line mode-line))))
    ;; Ajouter le fond permanent caractéristique des boutons Ediff,
    ;; sans écraser les autres propriétés posées par metal-toolbar-button.
    (propertize bouton 'face 'mode-line-highlight)))

(defun metal-revision--alignement-code ()
  "Retourner un préfixe de header-line aligné sur le début du code.

On aligne le libellé après la zone des numéros de ligne, avec un petit
écart supplémentaire pour que ORIGINAL et CORRECTION(S) commencent au
même endroit visuel que le code Python."
  (let* ((cols (cond
                ((fboundp 'line-number-display-width)
                 (line-number-display-width))
                ((and (boundp 'display-line-numbers-width)
                      (integerp display-line-numbers-width))
                 display-line-numbers-width)
                (t 3)))
         ;; largeur des numéros + séparateur + petit décalage visuel
         (offset (+ cols 2)))
    (propertize " " 'display `(space :align-to ,offset))))

(defun metal-revision--apres-header-line ()
  "Header-line compacte du buffer APRÈS avec actions Ediff en icônes."
  (concat
   (metal-revision--alignement-code)
   (cdr metal-revision--etiquettes) "  "
   (metal-revision--button
    (metal-toolbar-emoji "⬅️" :color "#7f8c8d")
    #'metal-revision-precedent "Différence précédente")
   " "
   (metal-revision--button
    (metal-toolbar-emoji "➡️" :color "#7f8c8d")
    #'metal-revision-suivant "Différence suivante")
   " "
   (metal-revision--button
    (metal-toolbar-emoji "✅" :color "#27ae60")
    #'metal-revision-accepter "Accepter cette correction")
   " "
   (metal-revision--button
    (metal-toolbar-emoji "↩️" :color "#e67e22")
    #'metal-revision-annuler-bloc
    "Annuler cette correction (restaurer l'original de ce bloc)")
   " "
   (metal-revision--button
    (concat (metal-toolbar-emoji "✔️" :color "#27ae60") " Terminer")
    #'metal-revision-quitter
    "Terminer et appliquer les corrections acceptées")
   " "
   (metal-revision--button
    (concat (metal-toolbar-emoji "🚫" :color "#c0392b") " Annuler")
    #'metal-revision-annuler
    "Fermer sans appliquer aucune correction")
   "  "))

(defun metal-revision--frame-supprime-garde (frame)
  "Garde appelé via `delete-frame-functions' quand FRAME est supprimé.
Si FRAME est le frame de révision MetalEmacs (fermé par le bouton X de
macOS, `C-x 5 0', etc.), on annule proprement la session : nettoyage,
restauration des header-lines et des variables Ediff, SANS appliquer la
moindre correction dans la cible."
  (when (and (eq frame metal-revision--frame)
             (not metal-revision--nettoyage-fait-p))
    (let ((metal-revision--frame-en-suppression frame)
          (control metal-revision--control-buffer))
      ;; On NE rappelle PAS `ediff-quit' ici : le frame est déjà en cours de
      ;; suppression (nous sommes dans `delete-frame-functions'), et toucher
      ;; aux fenêtres/frame à ce moment est instable.  On se contente de
      ;; demander à Ediff de nettoyer ses buffers internes, puis on annule.
      (when (buffer-live-p control)
        (with-current-buffer control
          (remove-hook 'ediff-quit-hook #'metal-revision--quit-hook t)
          (when (fboundp 'ediff-cleanup-mess)
            (ignore-errors (ediff-cleanup-mess)))))
      ;; Annulation : on n'applique rien (appliquer = nil).
      (ignore-errors (metal-revision--quit-hook nil)))))

(defun metal-revision--creer-frame ()
  "Créer et sélectionner le frame séparé de révision Ediff.
On greffe un garde sur `delete-frame-functions' afin qu'une fermeture par
le bouton X de macOS annule la session proprement (header-lines et
variables restaurées) au lieu de laisser Emacs dans un état incohérent."
  (let ((frame (make-frame `((name . ,metal-revision-frame-name)
                             (width . ,metal-revision-frame-width)
                             (height . ,metal-revision-frame-height)
                             (minibuffer . t)))))
    (select-frame-set-input-focus frame)
    (delete-other-windows)
    (add-hook 'delete-frame-functions
              #'metal-revision--frame-supprime-garde)
    frame))

(defun metal-revision--preparer-buffer (buffer texte mode)
  "Remplir BUFFER avec TEXTE et activer MODE si possible."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert texte)
      (goto-char (point-min)))
    (when (and mode (fboundp mode))
      ;; Org replie les titres à l'ouverture (`org-startup-folded' ou
      ;; #+STARTUP) : les différences situées dans le texte replié seraient
      ;; sélectionnées par Ediff mais invisibles.
      (let ((org-startup-folded 'showeverything))
        (ignore-errors (funcall mode))))
    ;; Tout déplier, au cas où un #+STARTUP local aurait replié malgré tout.
    (cond
     ((derived-mode-p 'org-mode)
      (ignore-errors
        (if (fboundp 'org-fold-show-all) (org-fold-show-all) (org-show-all))))
     ((bound-and-true-p outline-minor-mode)
      (ignore-errors (outline-show-all))))
    ;; Dans le frame de révision, on veut uniquement deux fenêtres :
    ;; AVANT à gauche et APRÈS à droite.  Si `tab-line-mode' est actif
    ;; globalement, il peut afficher des onglets de buffers inutiles
    ;; (*Python*, fichier source, doublons, etc.).  On masque donc la
    ;; tab-line dans les buffers temporaires de révision.
    (setq-local tab-line-format nil)
    (setq-local metal-revision--temp-buffer-p t)
    ;; Rendre visibles les espaces insécables et les fins de ligne, afin de
    ;; repérer un changement purement typographique (insécable devant « : »).
    (when metal-revision-afficher-espaces
      (setq-local whitespace-style '(face nbsp trailing tabs))
      (ignore-errors (whitespace-mode 1)))
    buffer))

(cl-defun metal-revision-lancer (original propose
                                 &key cible (type 'buffer) debut fin
                                 (prose nil prose-fourni)
                                 etiquettes titre ((:apres rappel)))
  "Réviser ORIGINAL contre PROPOSE dans un frame Ediff séparé.
ORIGINAL s'affiche à gauche, PROPOSE à droite, chacun dans un tampon
temporaire : Ediff ne touche jamais au tampon CIBLE.  Les boutons de
navigation et de validation sont dans la header-line de droite.

Mots-clés :
  :cible       tampon qui reçoit le résultat (« Terminer »).
  :type        `buffer' (défaut) : le résultat remplace tout CIBLE ;
               `region' : il remplace la portion DEBUT–FIN de CIBLE.
  :debut :fin  bornes de la région (type `region').
  :prose       non-nil pour ignorer les écarts d'espaces (diff -w).  Par
               défaut, déduit du mode de CIBLE (`metal-revision-prose-p').
  :etiquettes  paire (GAUCHE . DROITE) des titres de colonnes ; défaut
               `metal-revision-etiquettes-defaut'.
  :titre       nom du frame ; défaut `metal-revision-frame-name'.
  :apres       fonction appelée à la fermeture avec (APPLIQUER RÉSULTAT),
               après le nettoyage ; RÉSULTAT est le texte appliqué, ou nil.

Le hook `metal-revision-fin-functions' reçoit les mêmes arguments."
  (when (metal-revision-active-p)
    (user-error "Une révision est déjà ouverte — terminez-la d'abord"))
  (unless (memq type '(buffer region))
    (error "metal-revision-lancer : :type inconnu %S" type))
  (when (and (eq type 'region) (not (and debut fin)))
    (error "metal-revision-lancer : :debut et :fin requis pour une région"))
  (metal-revision--tuer-buffers-temporaires)
  (require 'ediff)
  (metal-revision--installer-protection-wide)
  (metal-revision--installer-protection-refresh)
  (setq metal-revision--saved-setup-fn ediff-window-setup-function
        metal-revision--saved-split-fn ediff-split-window-function
        metal-revision--saved-control-frame-parameters ediff-control-frame-parameters
        metal-revision--saved-use-long-help-message (and (boundp 'ediff-use-long-help-message)
                                                         ediff-use-long-help-message)
        metal-revision--saved-verbose-help-p (and (boundp 'ediff-verbose-help-p)
                                                  ediff-verbose-help-p)
        metal-revision--saved-diff-options (and (boundp 'ediff-diff-options)
                                                ediff-diff-options)
        metal-revision--saved-tab-line-mode (and (boundp 'global-tab-line-mode)
                                                 global-tab-line-mode)
        metal-revision--variables-saved-p t
        ;; Ediff reste dans le frame courant, qui sera notre frame séparé.
        ediff-window-setup-function #'ediff-setup-windows-plain
        ;; A gauche / B droite.
        ediff-split-window-function #'split-window-horizontally
        ;; Le panneau de contrôle natif est VISIBLE dans une bande basse du
        ;; frame (cf. `metal-revision--imposer-layout').  On garde l'aide
        ;; courte pour que le panneau affiche les raccourcis n/p/a/b/q.
        ediff-use-long-help-message nil
        ediff-verbose-help-p nil
        ;; Pour la prose, on ignore les différences d'espaces (-w) afin de
        ;; ne pas signaler des modifications purement typographiques. Pour le
        ;; code on garde la comparaison stricte (chaîne vide), l'indentation
        ;; — Python notamment — étant sémantiquement significative.
        ediff-diff-options (if (if prose-fourni prose (metal-revision-prose-p cible))
                               "-w" ""))
  (let* ((mode (and (buffer-live-p cible)
                    (with-current-buffer cible major-mode)))
         (source-frame (selected-frame))
         (source-config (current-window-configuration))
         (avant (generate-new-buffer " *metal-revision-gauche*"))
         (apres (generate-new-buffer " *metal-revision-droite*"))
         (frame (let ((metal-revision-frame-name
                       (or titre metal-revision-frame-name)))
                  (metal-revision--creer-frame))))
    ;; Évite que les onglets de buffers du frame source polluent le frame Ediff.
    ;; On restaure l'état global à la sortie.
    (when (and (boundp 'global-tab-line-mode) global-tab-line-mode)
      (global-tab-line-mode -1))
    (setq metal-revision--etiquettes (or etiquettes metal-revision-etiquettes-defaut)
          metal-revision--apres rappel)
    (metal-revision--preparer-buffer avant original mode)
    (metal-revision--preparer-buffer apres propose mode)
    (with-current-buffer apres
      (setq-local header-line-format '(:eval (metal-revision--apres-header-line))))
    ;; Réarmer le drapeau : s'il était resté à t (C-g pendant un nettoyage
    ;; antérieur), le hook de fermeture de cette session ne ferait rien.
    (setq metal-revision--nettoyage-fait-p nil)
    (setq metal-revision--target-buffer cible
          metal-revision--target-kind   type
          metal-revision--target-beg    debut
          metal-revision--target-end    fin
          metal-revision--avant-buf     avant
          metal-revision--apres-buf     apres
          metal-revision--original-text original
          metal-revision--source-frame  source-frame
          metal-revision--frame         frame
          metal-revision--window-config source-config)
    ;; Important : le frame Ediff ne contient qu'une fenêtre avant l'appel.
    ;; `ediff-setup-windows-plain' crée ensuite lui-même la disposition A/B.
    (switch-to-buffer avant)
    (ediff-buffers avant apres '(metal-revision--setup-hook))))

(defcustom metal-revision-control-height 4
  "Hauteur en lignes de la bande du panneau de contrôle Ediff natif.
Affiché sous la fenêtre AVANT, ce panneau reste pilotable au clavier
(n/p/a/b/q) en complément des boutons de la header-line APRÈS."
  :type 'integer
  :group 'metal-revision)

(defvar-local metal-revision--header-style-applique-p nil
  "Non-nil si le style de header-line a déjà été appliqué dans ce buffer.
`metal-revision--imposer-layout' est rejouée (run-at-time), et
`metal-toolbar-setup-header-line-style' empile un `face-remap' à chaque
appel.  Ce drapeau garantit une seule application par buffer.")

(defun metal-revision--styliser-header-line ()
  "Appliquer le style de header-line MetalEmacs au buffer courant, une fois.
S'appuie sur `metal-toolbar-setup-header-line-style' pour éclaircir le
fond, afin que la barre de boutons Ediff soit cohérente avec les autres
barres d'outils MetalEmacs."
  (unless metal-revision--header-style-applique-p
    (when (fboundp 'metal-toolbar-setup-header-line-style)
      (ignore-errors (metal-toolbar-setup-header-line-style))
      (setq metal-revision--header-style-applique-p t))))

(defun metal-revision--imposer-layout ()
  "Imposer le layout visuel MetalEmacs dans le frame Ediff.

Cette fonction ne tue pas la session Ediff.  Elle reconstruit le frame de
revision avec trois fenetres : AVANT a gauche, APRES a droite, et le
panneau de controle Ediff natif dans une bande basse a gauche."
  (when (and (frame-live-p metal-revision--frame)
             (buffer-live-p metal-revision--avant-buf)
             (buffer-live-p metal-revision--apres-buf))
    (select-frame-set-input-focus metal-revision--frame)
    (let ((ignore-window-parameters t)
          (window-min-height 1)
          (window-min-width 1))
      ;; Tres important : le *Ediff Control Panel* est souvent affiche dans
      ;; une fenetre dediee.  Il faut enlever la dedication AVANT tout appel a
      ;; `delete-other-windows' ou `set-window-buffer', sinon Emacs signale :
      ;; "Window is dedicated to '*Ediff Control Panel*'".
      (walk-windows
       (lambda (win)
         (set-window-dedicated-p win nil))
       nil metal-revision--frame)
      ;; Choisir explicitement une fenetre du frame Ediff, puis reconstruire
      ;; le frame a partir de cette fenetre.
      (let ((base (frame-selected-window metal-revision--frame)))
        (select-window base)
        (delete-other-windows base)
        (set-window-dedicated-p base nil)
        (set-window-buffer base metal-revision--avant-buf)
        (let ((droite (split-window base nil 'right)))
          (set-window-dedicated-p droite nil)
          (set-window-buffer droite metal-revision--apres-buf)
          (with-current-buffer metal-revision--avant-buf
            (setq-local header-line-format '(:eval (concat (metal-revision--alignement-code) (car metal-revision--etiquettes))))
            (setq-local tab-line-format nil)
            (metal-revision--styliser-header-line))
          (with-current-buffer metal-revision--apres-buf
            (setq-local header-line-format '(:eval (metal-revision--apres-header-line)))
            (setq-local tab-line-format nil)
            (metal-revision--styliser-header-line))
          ;; Bande basse pour le panneau de controle Ediff natif : on le rend
          ;; VISIBLE plutot que de le cacher.  Il reste pilotable au clavier
          ;; (n/p/a/b/q) en complement des boutons de la header-line.  C'est
          ;; le panneau natif qui pilote la session, gage de robustesse.
          (when (buffer-live-p metal-revision--control-buffer)
            (let ((bas (split-window base
                                     (- (window-total-height base)
                                        metal-revision-control-height)
                                     'below)))
              (set-window-dedicated-p bas nil)
              (set-window-buffer bas metal-revision--control-buffer)
              (set-window-dedicated-p bas t)))
          (select-window droite))))))

(defun metal-revision--setup-hook ()
  "Finaliser l'interface apres la creation officielle des fenetres Ediff.

On laisse d'abord Ediff initialiser completement sa session, puis on impose
le layout visuel souhaite : uniquement AVANT a gauche et APRES a droite dans
le frame separe.  Le buffer de controle Ediff reste vivant, mais il n'est
pas affiche ; les commandes utiles sont dans la header-line du buffer APRES."
  ;; Ce hook est execute depuis le buffer de controle Ediff.  On le garde
  ;; explicitement, car les clics dans la header-line du buffer APRES ne
  ;; voient pas toujours la variable globale `ediff-control-buffer'.
  (setq metal-revision--control-buffer (current-buffer))
  ;; Nouvelle session : oublier les originaux de blocs d'une session passée.
  (setq metal-revision--originaux-blocs nil)
  (message nil)
  (add-hook 'ediff-quit-hook #'metal-revision--quit-hook nil t)
  ;; Contraste + raffinage fin : rediriger les faces vers les versions
  ;; saturées et forcer le calcul mot-à-mot pour chaque hunk affiché, afin
  ;; que la correction réelle ressorte au lieu d'un paragraphe coloré en bloc.
  (metal-revision--appliquer-contraste)
  (add-hook 'ediff-select-hook #'ediff-make-fine-diffs nil t)
  (ignore-errors (ediff-make-fine-diffs))
  ;; Ediff reorganise parfois les fenetres juste apres son hook de setup.
  ;; On applique donc le nettoyage une premiere fois tout de suite, puis une
  ;; deuxieme fois au prochain tour de boucle, ce qui evite les buffers
  ;; parasites (*Python*, *Messages*, fichier source, doublons, Control Panel).
  (ignore-errors (metal-revision--imposer-layout))
  (run-at-time 0.05 nil #'metal-revision--imposer-layout))

(defun metal-revision--restaurer-variables ()
  "Restaurer les variables Ediff modifiées par MetalEmacs."
  (metal-revision--retirer-protection-wide)
  (metal-revision--retirer-protection-refresh)
  (metal-revision--restaurer-contraste)
  (when metal-revision--variables-saved-p
    (setq ediff-window-setup-function metal-revision--saved-setup-fn
          ediff-split-window-function metal-revision--saved-split-fn
          ediff-control-frame-parameters metal-revision--saved-control-frame-parameters
          ediff-use-long-help-message metal-revision--saved-use-long-help-message
          ediff-verbose-help-p metal-revision--saved-verbose-help-p
          ediff-diff-options metal-revision--saved-diff-options
          metal-revision--saved-setup-fn nil
          metal-revision--saved-split-fn nil
          metal-revision--saved-control-frame-parameters nil
          metal-revision--saved-use-long-help-message nil
          metal-revision--saved-verbose-help-p nil
          metal-revision--saved-diff-options nil
          metal-revision--variables-saved-p nil)
    (when (and (boundp 'global-tab-line-mode)
               metal-revision--saved-tab-line-mode
               (not global-tab-line-mode))
      (global-tab-line-mode 1))
    (setq metal-revision--saved-tab-line-mode nil)))

(defun metal-revision--texte-buffer (buffer)
  "Retourner le texte complet de BUFFER, sans propriétés."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (buffer-substring-no-properties (point-min) (point-max)))))

;; Sous Windows, la suppression différée du frame de révision pouvait
;; échouer en silence (ancien `ignore-errors') après « Annuler » : le frame
;; survivait et masquait le frame principal, avec le buffer ORIGINAL affiché.
(defun metal-revision--supprimer-frame (frame buffers &optional essai)
  "Supprimer FRAME de révision, puis tuer les BUFFERS temporaires.
Réessaie deux fois (à 0,2 s d'intervalle) si la suppression échoue — sous
Windows, un clic de header-line peut encore être en traitement.  En dernier
recours, rend FRAME invisible pour qu'il ne masque jamais le frame
principal.  Les erreurs sont journalisées dans *Messages*, pas avalées."
  (let ((essai (or essai 0)))
    (when (frame-live-p frame)
      (condition-case err
          (delete-frame frame t)
        (error (message "Révision (suppression du frame, essai %d) : %S"
                        essai err))))
    (cond
     ((and (frame-live-p frame) (< essai 2))
      (run-at-time 0.2 nil #'metal-revision--supprimer-frame
                   frame buffers (1+ essai)))
     ((frame-live-p frame)
      (message "Révision : frame de révision non supprimé, masqué.")
      (ignore-errors (make-frame-invisible frame t)))
     (t
      ;; Frame disparu et session Ediff close : les buffers temporaires
      ;; peuvent être tués sans risque.
      (dolist (b buffers)
        (when (buffer-live-p b)
          (with-current-buffer b (set-buffer-modified-p nil))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer b))))))))

(defun metal-revision--quit-hook (&optional appliquer texte-resultat)
  "Nettoyer après Ediff et, si APPLIQUER est non-nil, appliquer le résultat.
Le buffer AVANT temporaire contient le résultat final de la révision.
Quand APPLIQUER est non-nil (bouton « Terminer »), ce résultat est appliqué
au buffer cible complet ou à la région cible.  Quand APPLIQUER est nil
(bouton « Annuler » ou bouton X de macOS), on annule sans rien appliquer :
seul le nettoyage a lieu.

TEXTE-RESULTAT, s'il est fourni, est le contenu du buffer AVANT capturé
AVANT la fermeture native d'Ediff.  C'est indispensable : `ediff-quit'
natif appelle `ediff-cleanup-mess', qui TUE les buffers A/B.  Lire le
buffer AVANT après coup donnerait nil.  Le bouton « Terminer » capture
donc le texte en amont et le passe ici.

Idempotent : un second appel (p. ex. `delete-frame-functions' après
`ediff-quit') ne refait pas le travail."
  (unless metal-revision--nettoyage-fait-p
    (setq metal-revision--nettoyage-fait-p t)
    (let* ((avant   metal-revision--avant-buf)
           (target  metal-revision--target-buffer)
           (kind    metal-revision--target-kind)
           (beg     metal-revision--target-beg)
           (end     metal-revision--target-end)
           (orig    metal-revision--original-text)
           (config  metal-revision--window-config)
           (source-frame metal-revision--source-frame)
           (ediff-frame  metal-revision--frame)
           ;; Priorité au texte pré-capturé ; repli sur le buffer s'il vit
           ;; encore (cas où aucune fermeture native n'a précédé).
           (nouveau (or texte-resultat
                        (metal-revision--texte-buffer avant))))
      (unwind-protect
      (condition-case err
      (if (not appliquer)
          (message "Révision annulée (frame fermé) — aucune modification appliquée.")
        (pcase kind
          ('buffer
           (cond
            ((not (buffer-live-p target))
             (message "Révision annulée — buffer cible disparu."))
            ((or (null nouveau) (string= nouveau orig))
             (message "Aucun hunk accepté — buffer inchangé."))
            (t
             (with-current-buffer target
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert nouveau))
               (set-buffer-modified-p t))
             (message "Modifications appliquées dans le buffer cible."))))
          ('region
           (cond
            ((or (null nouveau) (not (buffer-live-p target)))
             (message "Révision annulée."))
            ((string= nouveau orig)
             (message "Aucun hunk accepté — région inchangée."))
            (t
             (with-current-buffer target
               (save-excursion
                 (when (and beg end)
                   (let ((inhibit-read-only t))
                     (delete-region beg end)
                     (goto-char beg)
                     (insert nouveau))))
               (set-buffer-modified-p t))
             (message "Modifications appliquées dans la région cible."))))
          (_
           (message "Révision terminée, mais la cible est inconnue."))))
        ;; Échec de l'application (p. ex. hook de modification Org) : on ne
        ;; perd pas le travail de révision — le résultat est mis de côté.
        ((debug error)
         (metal-revision--sauver-resultat-non-applique nouveau err)))
      ;; ── Nettoyage : TOUJOURS exécuté, chaque étape isolée ──────────
      ;; Ne pas tuer ici les buffers ORIGINAL/CORRECTION(S) : Ediff peut encore
      ;; tenter de rafraîchir leurs mode-lines au prochain tour de boucle.
      ;; On les enterre simplement ; ils seront réutilisés ou nettoyés au
      ;; lancement suivant sans déclencher l'erreur de buffer vital tué.
      (with-demoted-errors "Révision (nettoyage buffers) : %S"
        (dolist (buf (list avant metal-revision--apres-buf))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq-local header-line-format nil)
              ;; Avec argument : ne touche pas aux fenêtres (sans argument,
              ;; `bury-buffer' remplace le buffer dans la fenêtre sélectionnée).
              (bury-buffer buf)))))
      (with-demoted-errors "Révision (variables Ediff) : %S"
        (metal-revision--restaurer-variables))
      ;; Retirer le garde global de fermeture de frame : il ne doit pas
      ;; survivre à la session ni se déclencher pour d'autres frames.
      (remove-hook 'delete-frame-functions
                   #'metal-revision--frame-supprime-garde)
      (with-demoted-errors "Révision (retour au frame source) : %S"
        (when (and (frame-live-p source-frame) config)
          (select-frame-set-input-focus source-frame)
          (set-window-configuration config)))
      ;; Ne supprimer le frame de révision que s'il est encore vivant ET que
      ;; ce n'est pas lui qui est déjà en cours de suppression (cas du bouton
      ;; X, où `delete-frame-functions' nous appelle PENDANT la suppression :
      ;; re-supprimer lèverait une erreur).  La suppression est DIFFÉRÉE au
      ;; prochain tour de boucle : quand on vient d'un clic dans la
      ;; header-line de ce frame, le supprimer pendant le traitement de
      ;; l'événement souris est instable sous Windows.
      (when (and (frame-live-p ediff-frame)
                 (not (eq ediff-frame source-frame))
                 (not (eq ediff-frame metal-revision--frame-en-suppression)))
        (run-at-time 0 nil #'metal-revision--supprimer-frame
                     ediff-frame
                     (list avant metal-revision--apres-buf)))
      ;; Rappels des clients (agent, algo, comparaison) : APRÈS le nettoyage,
      ;; pour qu'ils trouvent Emacs dans son état normal.
      (let ((rappel metal-revision--apres)
            (resultat (and appliquer nouveau)))
        (setq metal-revision--apres nil)
        (when rappel
          (with-demoted-errors "Révision (rappel du client) : %S"
            (funcall rappel appliquer resultat)))
        (with-demoted-errors "Révision (metal-revision-fin-functions) : %S"
          (run-hook-with-args 'metal-revision-fin-functions appliquer resultat)))
      (setq metal-revision--target-buffer nil
            metal-revision--target-kind nil
            metal-revision--target-beg nil
            metal-revision--target-end nil
            metal-revision--avant-buf nil
            metal-revision--apres-buf nil
            metal-revision--original-text nil
            metal-revision--window-config nil
            metal-revision--source-frame nil
            metal-revision--frame nil
            metal-revision--control-buffer nil
            metal-revision--cleanup-en-cours nil
            metal-revision--etiquettes metal-revision-etiquettes-defaut
            ;; Réarmer pour la prochaine session.
            metal-revision--nettoyage-fait-p nil)))))

(defun metal-revision--sauver-resultat-non-applique (texte err)
  "Mettre TEXTE de côté quand son application a échoué avec ERR.
Le résultat de la révision est copié dans le kill-ring et dans un buffer
dédié, pour que les corrections acceptées ne soient jamais perdues."
  (when (and texte (not (string-empty-p texte)))
    (kill-new texte)
    (with-current-buffer
        (get-buffer-create "*Révision : résultat non appliqué*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert texte)
        (goto-char (point-min)))))
  (display-warning
   'metal-revision
   (format (concat "Échec de l'application des corrections : %s\n"
                   "Le résultat est dans le kill-ring et dans le buffer "
                   "*Révision : résultat non appliqué*.")
           (error-message-string err))
   :error))

;;; --- Interface publique -------------------------------------------------

(defun metal-revision-active-p ()
  "Non-nil si une session de révision est ouverte."
  (or (buffer-live-p metal-revision--control-buffer)
      (frame-live-p metal-revision--frame)))

(defun metal-revision-prose-p (&optional buffer)
  "Non-nil si BUFFER (défaut : courant) est un document de prose.
Couvre Org, Markdown, Quarto, LaTeX et `text-mode'.  Sert à choisir les
options de diff : on ignore les écarts d'espaces pour la prose, pas pour
le code."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (or (derived-mode-p 'org-mode 'markdown-mode 'text-mode
                               'latex-mode 'tex-mode)
               (memq major-mode '(poly-quarto-mode quarto-mode))
               (and buffer-file-name
                    (string-match-p "\\.\\(org\\|md\\|markdown\\|qmd\\|tex\\|txt\\)\\'"
                                    buffer-file-name))
               nil)))))

;;; --- Comparaison de deux documents -------------------------------------
;;
;; Même frame et mêmes boutons, mais la colonne de droite est un document
;; choisi par l'utilisateur.  Le document de GAUCHE reçoit les blocs
;; acceptés ; il est modifié dans son tampon sans être enregistré.  Le
;; document de droite n'est jamais modifié.

(defun metal-revision--comparer (cible autre)
  "Réviser le tampon CIBLE (gauche) à partir du tampon AUTRE (droite)."
  (when (eq cible autre)
    (user-error "Les deux documents sont identiques"))
  ;; L'application finale remplace le tampon entier : un tampon restreint
  ;; (narrowing) verrait son texte dupliqué.
  (when (with-current-buffer cible (buffer-narrowed-p))
    (user-error "Le tampon %s est restreint — élargissez-le d'abord (C-x n w)"
                (buffer-name cible)))
  (let ((original (with-current-buffer cible
                    (buffer-substring-no-properties (point-min) (point-max))))
        (propose  (with-current-buffer autre
                    (save-restriction
                      (widen)
                      (buffer-substring-no-properties (point-min) (point-max))))))
    (if (string= original propose)
        (message "Les deux documents sont identiques — rien à comparer.")
      (metal-revision-lancer
       original propose
       :cible cible
       :titre "MetalEmacs — Comparaison"
       :etiquettes (cons (buffer-name cible) (buffer-name autre))
       :apres (lambda (appliquer resultat)
                (when (and appliquer resultat)
                  (message "Blocs acceptés appliqués à %s (non enregistré)."
                           (buffer-name cible))))))))

;;;###autoload
(defun metal-comparer-documents (fichier-a fichier-b)
  "Comparer FICHIER-A et FICHIER-B dans le frame de révision MetalEmacs.
FICHIER-A (à gauche) reçoit les blocs acceptés de FICHIER-B (à droite).
Depuis un tampon qui visite un fichier, celui-ci est pris comme
FICHIER-A et seul FICHIER-B est demandé ; avec `C-u', les deux sont
demandés."
  (interactive
   (let* ((courant (and (not current-prefix-arg) buffer-file-name))
          (a (or courant
                 (read-file-name "Document à réviser (gauche) : " nil nil t)))
          (b (read-file-name
              (format "Comparer %s avec (droite) : " (file-name-nondirectory a))
              (file-name-directory a) nil t)))
     (list a b)))
  (when (file-equal-p fichier-a fichier-b)
    (user-error "Les deux documents sont identiques"))
  (metal-revision--comparer (find-file-noselect fichier-a)
                            (find-file-noselect fichier-b)))

;;;###autoload
(defun metal-comparer-tampons (tampon-a tampon-b)
  "Comparer TAMPON-A et TAMPON-B dans le frame de révision MetalEmacs.
TAMPON-A (à gauche, par défaut le tampon courant) reçoit les blocs
acceptés de TAMPON-B (à droite)."
  (interactive
   (let* ((a (read-buffer "Tampon à réviser (gauche) : "
                          (current-buffer) t))
          (b (read-buffer (format "Comparer %s avec (droite) : " a)
                          (other-buffer (get-buffer a) t) t)))
     (list a b)))
  (metal-revision--comparer (get-buffer tampon-a) (get-buffer tampon-b)))

(provide 'metal-revision)
;;; metal-revision.el ends here
