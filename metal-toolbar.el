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

(cl-defun metal-toolbar-icon (name &key color
                                   (height metal-toolbar-icon-height)
                                   fallback)
  "Retourne une icône nerd-icons NAME, colorisée.
La famille est détectée automatiquement à partir du préfixe (nf-md-,
nf-fa-, nf-oct-, nf-cod-, etc.).

Mots-clés :
  :color    couleur de premier plan (chaîne hex ou nom).
  :height   multiplicateur de taille (défaut `metal-toolbar-icon-height').
  :fallback caractère de repli si nerd-icons est absent."
  (let ((face `(,@(when color `(:foreground ,color)) :height ,height)))
    (if (and (featurep 'nerd-icons) (fboundp 'nerd-icons-mdicon))
        (funcall (metal-toolbar--icon-fn name) name :face face)
      (propertize (or fallback "•") 'face face))))

(defun metal-toolbar-button (icon tooltip command)
  "Construit un bouton cliquable pour la header-line.
ICON est une chaîne (idéalement obtenue via `metal-toolbar-icon').
TOOLTIP s'affiche au survol.
COMMAND est la commande appelée au clic-gauche.

L'espacement horizontal autour de l'icône est contrôlé par
`metal-toolbar-button-padding'.

Note : `mouse-face' utilise un cons frais via `list' (et non un littéral
quoté).  Sans ça, des boutons adjacents avec une valeur `eq' identique
fusionneraient en une seule région de surbrillance."
  (let ((spc (make-string metal-toolbar-button-padding ?\s)))
    (propertize (concat spc icon spc)
                'mouse-face (list :background metal-toolbar-hover-background)
                'help-echo tooltip
                'keymap (let ((map (make-sparse-keymap)))
                          (define-key map [header-line mouse-1] command)
                          map))))

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
