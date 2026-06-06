;;; metal-toolbar.el --- Primitives pour barres d'outils header-line -*- lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, header-line, gui

;;; Commentary:
;;
;; Primitives réutilisables pour construire des barres d'outils en
;; header-line dans MetalEmacs.  Les modules `metal-pdf', `metal-python',
;; etc. composent ces primitives avec leurs boutons spécifiques.
;;
;; API publique :
;;
;;   (metal-toolbar-vpadding)
;;       Caractère invisible créant le padding vertical de la barre.
;;       À placer au début ET à la fin de la chaîne header-line.
;;
;;   (metal-toolbar-separator [CHAR])
;;       Séparateur visuel entre groupes de boutons (défaut "|").
;;
;;   (metal-toolbar-icon NAME &key COLOR HEIGHT FALLBACK)
;;       Icône nerd-icons colorée.  La famille est détectée à partir du
;;       préfixe (nf-md-, nf-fa-, nf-oct-, etc.).
;;
;;   (metal-toolbar-button ICON TOOLTIP COMMAND)
;;       Bouton cliquable, infobulle au survol, action au clic-gauche.
;;
;; Exemple :
;;
;;   (defun ma-barre ()
;;     (concat
;;      (metal-toolbar-vpadding) " "
;;      (metal-toolbar-button
;;       (metal-toolbar-icon "nf-fa-play" :color "#34C759")
;;       "Démarrer" #'demarrer)
;;      (metal-toolbar-separator)
;;      (metal-toolbar-button
;;       (metal-toolbar-icon "nf-fa-stop" :color "#FF3B30")
;;       "Arrêter" #'arreter)
;;      " " (metal-toolbar-vpadding)))

;;; Code:

(require 'cl-lib)
(require 'nerd-icons nil t)

(defgroup metal-toolbar nil
  "Primitives partagées pour barres d'outils header-line."
  :group 'convenience
  :prefix "metal-toolbar-")

;;; --- Variables de configuration ------------------------------------------

(defcustom metal-toolbar-icon-height 1.3
  "Hauteur des icônes par défaut (multiplicateur de la taille de police)."
  :type 'number
  :group 'metal-toolbar)

;;; --- Emojis Unicode (parallèle au pattern metal-font) ---

(defconst metal-toolbar-emoji-base 160
  "Hauteur de base des emojis (× 100).  160 = multiplicateur 1.60.
Cohérent avec `metal-font-base' : on travaille en entiers, et la fonction
`metal-toolbar-emoji-size' divise par 100 pour produire le multiplicateur
`:height' attendu par Emacs.")

(defcustom metal-toolbar-emoji-size-offset 0
  "Correction utilisateur ajoutée à `metal-toolbar-emoji-base'.
Incréments de 10, parallèle à `metal-font-size-offset'.  La valeur est
persistée dans `metal-prefs.el' via `metal-prefs-save'."
  :type 'integer
  :group 'metal-toolbar)

(defun metal-toolbar-emoji-size ()
  "Retourne la taille effective des emojis : base + offset (entier × 100).
160 par défaut ; modifiable via `metal-toolbar-emoji-increase' et amis."
  (+ metal-toolbar-emoji-base metal-toolbar-emoji-size-offset))

(defcustom metal-toolbar-emoji-raise 0.25
  "Décalage vertical par défaut des emojis dans les header-lines.
Les emojis (Apple Color Emoji, Noto, ...) n'ont pas la même ligne de
base que les icônes nerd-icons (Hack Nerd Font Mono) : à `:height' égal,
ils « flottent » par rapport aux autres boutons.  Ce décalage les recale.
Négatif = vers le bas.  Appliqué automatiquement par `metal-toolbar-emoji'
sauf si un :raise explicite est fourni à l'appel.  Ajustez si le rendu
diffère sur votre système (macOS, Linux, ...)."
  :type 'number
  :group 'metal-toolbar)

(defun metal-toolbar-emoji-increase ()
  "Augmente la taille des emojis de 10 (= +0.1 du multiplicateur).
Le changement prend effet immédiatement dans toutes les header-lines
qui utilisent `metal-toolbar-emoji' (Python, Prolog, Agent/Codex, ...)
et est persisté via `metal-prefs-save-all'."
  (interactive)
  (setq metal-toolbar-emoji-size-offset (+ metal-toolbar-emoji-size-offset 10))
  (force-mode-line-update t)
  (when (fboundp 'metal-prefs-save-all)
    (metal-prefs-save-all))
  (message "Taille icônes : %d" (metal-toolbar-emoji-size)))

(defun metal-toolbar-emoji-decrease ()
  "Diminue la taille des emojis de 10 (= -0.1 du multiplicateur)."
  (interactive)
  (setq metal-toolbar-emoji-size-offset (- metal-toolbar-emoji-size-offset 10))
  (force-mode-line-update t)
  (when (fboundp 'metal-prefs-save-all)
    (metal-prefs-save-all))
  (message "Taille icônes : %d" (metal-toolbar-emoji-size)))

(defun metal-toolbar-emoji-reset ()
  "Réinitialise la taille des emojis à la base (`metal-toolbar-emoji-base')."
  (interactive)
  (setq metal-toolbar-emoji-size-offset 0)
  (force-mode-line-update t)
  (when (fboundp 'metal-prefs-save-all)
    (metal-prefs-save-all))
  (message "Taille icônes réinitialisée : %d" (metal-toolbar-emoji-size)))

(defcustom metal-toolbar-vpadding-height 1.7
  "Hauteur du caractère de padding vertical (multiplicateur)."
  :type 'number
  :group 'metal-toolbar)

(defcustom metal-toolbar-vpadding-raise -0.2
  "Décalage vertical du padding (négatif = vers le bas).
Permet de répartir l'espacement de manière symétrique haut/bas."
  :type 'number
  :group 'metal-toolbar)

(defcustom metal-toolbar-hover-background "#e0e0e0"
  "Couleur de fond appliquée aux boutons au survol de la souris."
  :type 'color
  :group 'metal-toolbar)

(defcustom metal-toolbar-button-padding 2
  "Nombre d'espaces ajoutés de chaque côté de l'icône dans un bouton.
Augmenter pour aérer la barre d'outils horizontalement."
  :type 'integer
  :group 'metal-toolbar)

(defface metal-toolbar-separator-face
  '((t :weight bold :foreground "gray"))
  "Visage du séparateur entre groupes de boutons."
  :group 'metal-toolbar)

;;; --- Helpers internes -----------------------------------------------------

(defun metal-toolbar--icon-fn (name)
  "Retourne la fonction nerd-icons appropriée selon le préfixe de NAME."
  (cond
   ((string-prefix-p "nf-md-"      name) #'nerd-icons-mdicon)
   ((string-prefix-p "nf-fa-"      name) #'nerd-icons-faicon)
   ((string-prefix-p "nf-oct-"     name) #'nerd-icons-octicon)
   ((string-prefix-p "nf-cod-"     name) #'nerd-icons-codicon)
   ((string-prefix-p "nf-dev-"     name) #'nerd-icons-devicon)
   ((string-prefix-p "nf-seti-"    name) #'nerd-icons-sucicon)
   ((string-prefix-p "nf-weather-" name) #'nerd-icons-wicon)
   ((string-prefix-p "nf-pom-"     name) #'nerd-icons-pomicon)
   (t                                    #'nerd-icons-mdicon)))

;;; --- API publique ---------------------------------------------------------

(defun metal-toolbar-vpadding ()
  "Caractère invisible de padding vertical pour la header-line.
Reproduit le mécanisme du toolbar Python : un espace doté d'une `:height'
supérieure et décalé via `display' pour donner de la hauteur à la ligne
sans étirer les glyphes des icônes.  À placer au début ET à la fin de la
chaîne `header-line-format'."
  (propertize " "
              'face `(:height ,metal-toolbar-vpadding-height)
              'display `((raise ,metal-toolbar-vpadding-raise))))

(defun metal-toolbar-separator (&optional char)
  "Séparateur vertical entre groupes de boutons.
CHAR peut surcharger le caractère utilisé (défaut : \"|\")."
  (propertize (format " %s " (or char "|"))
              'face 'metal-toolbar-separator-face))

;; (cl-defun metal-toolbar-icon (name &key color
;;                                    (height metal-toolbar-icon-height)
;;                                    fallback)
;;   "Retourne une icône nerd-icons NAME, colorisée.
;; La famille est détectée automatiquement à partir du préfixe (nf-md-,
;; nf-fa-, nf-oct-, nf-cod-, etc.).

;; Mots-clés :
;;   :color    couleur de premier plan (chaîne hex ou nom).
;;   :height   multiplicateur de taille (défaut `metal-toolbar-icon-height').
;;   :fallback caractère de repli si nerd-icons est absent."
;;   (let ((face `(,@(when color `(:foreground ,color)) :height ,height)))
;;     (if (and (featurep 'nerd-icons) (fboundp 'nerd-icons-mdicon))
;;         (funcall (metal-toolbar--icon-fn name) name :face face)
;;       (propertize (or fallback "•") 'face face))))

(cl-defun metal-toolbar-icon (name &key color
                                   (height metal-toolbar-icon-height)
                                   raise
                                   fallback)
  "Retourne une icône nerd-icons NAME, colorisée.
La famille est détectée automatiquement à partir du préfixe (nf-md-,
nf-fa-, nf-oct-, nf-cod-, etc.).

Mots-clés :
  :color    couleur de premier plan (chaîne hex ou nom).
  :height   multiplicateur de taille (défaut `metal-toolbar-icon-height').
  :raise    décalage vertical (négatif = vers le bas, défaut nil).
  :fallback caractère de repli si nerd-icons est absent."
  (let* ((face `(,@(when color `(:foreground ,color)) :height ,height))
         (icon (if (and (featurep 'nerd-icons) (fboundp 'nerd-icons-mdicon))
                   (funcall (metal-toolbar--icon-fn name) name :face face)
                 (propertize (or fallback "•") 'face face))))
    (if raise
        (propertize icon 'display `((raise ,raise)))
      icon)))

(cl-defun metal-toolbar-emoji (emoji &key height color raise)
  "Retourne un EMOJI Unicode propertize pour la header-line.
Convient aux emojis colorés natifs (▶️ 🐛 🔄 📋 💬 🪄 ✅ ❌ etc.).

Contrairement à `metal-toolbar-icon' qui passe par nerd-icons (rendu via
Hack Nerd Font Mono à taille fixe en pixels), cette fonction utilise le
mécanisme `:height' standard d'Emacs.  Toutes les toolbars qui l'utilisent
(Python, Prolog, Agent/Codex, ...) partagent donc la même taille, modifiable
par l'utilisateur via `metal-toolbar-emoji-increase' et amis.

Mots-clés :
  :height   multiplicateur de taille (float).  Si nil (défaut), calculé
            depuis `(metal-toolbar-emoji-size)' divisé par 100.
  :color    couleur :foreground (souvent ignorée par les emojis colorés).
  :raise    décalage vertical (négatif = vers le bas).  Si nil (défaut),
            utilise `metal-toolbar-emoji-raise' pour aligner l'emoji sur
            les icônes nerd-icons voisines."
  (let* ((h (or height (/ (metal-toolbar-emoji-size) 100.0)))
         (r (or raise metal-toolbar-emoji-raise))
         (face `(:height ,h ,@(when color `(:foreground ,color))))
         (s (propertize emoji 'face face)))
    (if (and r (not (zerop r)))
        (propertize s 'display `((raise ,r)))
      s)))

(defun metal-toolbar-button (icon tooltip command &optional context)
  "Construit un bouton cliquable pour une header-line ou une mode-line.
ICON est une chaîne (idéalement obtenue via `metal-toolbar-icon' ou
`metal-toolbar-emoji').
TOOLTIP s'affiche au survol.
COMMAND est la commande appelée au clic-gauche.
CONTEXT est le symbole `header-line' (défaut) ou `mode-line' : il
détermine le pseudo-événement de clic, car un clic dans la header-line
arrive comme `[header-line mouse-1]' et un clic dans la mode-line comme
`[mode-line mouse-1]'.

L'espacement horizontal autour de l'icône est contrôlé par
`metal-toolbar-button-padding'.

Note : `mouse-face' utilise un cons frais via `list' (et non un littéral
quoté).  Sans ça, des boutons adjacents avec une valeur `eq' identique
fusionneraient en une seule région de surbrillance."
  (let* ((ctx (or context 'header-line))
         (evt (vector ctx 'mouse-1))
         (spc (make-string metal-toolbar-button-padding ?\s)))
    (propertize (concat spc icon spc)
                'mouse-face (list :background metal-toolbar-hover-background)
                'help-echo tooltip
                'keymap (let ((map (make-sparse-keymap)))
                          (define-key map evt command)
                          map))))

;;; --- Bouton système (mode-line) ------------------------------------------

(declare-function ouvrir-emacs-d-dired "init" ())

(defun metal-toolbar-bouton-systeme ()
  "Bouton « SYS » pour la mode-line : ouvre `.emacs.d' dans Dired.
Construit via `metal-toolbar-button' avec le contexte `mode-line', donc
cohérent avec les boutons des header-lines.  La commande `ouvrir-emacs-d-dired'
est résolue au moment du clic."
  (metal-toolbar-button " SYS " "Ouvrir .emacs.d dans Dired"
                        #'ouvrir-emacs-d-dired 'mode-line))

;;; --- Style de la header-line ---------------------------------------------

(defun metal-toolbar--lighten-color (color percent)
  "Éclaircit COLOR de PERCENT pourcent.
Retourne COLOR inchangé si la conversion échoue."
  (let ((rgb (color-values color)))
    (if (not rgb)
        color
      (let ((factor (/ percent 100.0)))
        (format "#%02x%02x%02x"
                (min 255 (truncate (+ (/ (nth 0 rgb) 256.0)
                                      (* (- 255 (/ (nth 0 rgb) 256.0)) factor))))
                (min 255 (truncate (+ (/ (nth 1 rgb) 256.0)
                                      (* (- 255 (/ (nth 1 rgb) 256.0)) factor))))
                (min 255 (truncate (+ (/ (nth 2 rgb) 256.0)
                                      (* (- 255 (/ (nth 2 rgb) 256.0)) factor)))))))))

(defun metal-toolbar-setup-header-line-style ()
  "Éclaircit le fond de la header-line dans le tampon courant.
À appeler depuis un hook de mode quand on souhaite distinguer
visuellement la barre d'outils du reste du tampon (utile pour Org,
Quarto, Markdown).  Le PDF n'en a généralement pas besoin."
  (let* ((raw-color (face-background 'mode-line nil t))
         (base-color (if (and raw-color (color-values raw-color))
                         raw-color
                       "#d0d0d0"))
         (bg-color (metal-toolbar--lighten-color base-color 70)))
    (face-remap-add-relative 'header-line
                             :underline nil
                             :overline nil
                             :background bg-color)))

(provide 'metal-toolbar)
;;; metal-toolbar.el ends here
