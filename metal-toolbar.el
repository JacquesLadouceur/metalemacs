;;; metal-toolbar.el --- Primitives pour barres d'outils header-line -*- coding: utf-8; lexical-binding: t; -*-

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
;;   (metal-toolbar-emoji EMOJI &key HEIGHT COLOR RAISE)
;;       Emoji Unicode dimensionné et aligné pour la barre.
;;
;;   (metal-toolbar-char TEXTE &key STYLE COLOR HEIGHT RAISE)
;;       Lettre portant son style (G gras, I italique, S souligné, B barré),
;;       quand aucun emoji ne convient (formatage typographique).
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
;;       (metal-toolbar-emoji "▶️")
;;       "Démarrer" #'demarrer)
;;      (metal-toolbar-separator)
;;      (metal-toolbar-button
;;       (metal-toolbar-emoji "⏹️")
;;       "Arrêter" #'arreter)
;;      " " (metal-toolbar-vpadding)))

;;; Code:

(require 'cl-lib)

(defgroup metal-toolbar nil
  "Primitives partagées pour barres d'outils header-line."
  :group 'convenience
  :prefix "metal-toolbar-")

;;; --- Variables de configuration ------------------------------------------

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
base que les lettres (police texte) : à `:height' égal,
ils « flottent » par rapport aux autres boutons.  Ce décalage les recale.
Négatif = vers le bas.  Appliqué automatiquement par `metal-toolbar-emoji'
sauf si un :raise explicite est fourni à l'appel.  Ajustez si le rendu
diffère sur votre système (macOS, Linux, ...)."
  :type 'number
  :group 'metal-toolbar)

(defcustom metal-toolbar-char-raise 0.25
  "Décalage vertical par défaut des lettres stylées (`metal-toolbar-char').
Les lettres (police texte) et les emoji (police emoji) n'ont pas la même
ligne de base ; sans ajustement, les boutons-lettres (G, I, S, B, </>)
« flottent » par rapport aux boutons-emoji voisins.  Ce décalage les
recale sur la même ligne.  Par défaut identique à `metal-toolbar-emoji-raise'
pour que lettres et emoji s'alignent.  Négatif = vers le bas.  Ajustez
finement si le rendu diffère sur votre système."
  :type 'number
  :group 'metal-toolbar)

(defun metal-toolbar-emoji-increase ()
  "Augmente la taille des emojis de 10 (= +0.1 du multiplicateur).
Le changement prend effet immédiatement dans toutes les header-lines
qui utilisent `metal-toolbar-emoji' (Python, Prolog, Agent/Codex, ...)
et est persisté via `metal-prefs-save-all'."
  (interactive)
  (setq metal-toolbar-emoji-size-offset (+ metal-toolbar-emoji-size-offset 10))
  (metal-toolbar-rafraichir)
  (when (fboundp 'metal-prefs-save-all)
    (metal-prefs-save-all))
  (message "Taille icônes : %d" (metal-toolbar-emoji-size)))

(defun metal-toolbar-emoji-decrease ()
  "Diminue la taille des emojis de 10 (= -0.1 du multiplicateur)."
  (interactive)
  (setq metal-toolbar-emoji-size-offset (- metal-toolbar-emoji-size-offset 10))
  (metal-toolbar-rafraichir)
  (when (fboundp 'metal-prefs-save-all)
    (metal-prefs-save-all))
  (message "Taille icônes : %d" (metal-toolbar-emoji-size)))

(defun metal-toolbar-emoji-reset ()
  "Réinitialise la taille des emojis à la base (`metal-toolbar-emoji-base')."
  (interactive)
  (setq metal-toolbar-emoji-size-offset 0)
  (metal-toolbar-rafraichir)
  (when (fboundp 'metal-prefs-save-all)
    (metal-prefs-save-all))
  (message "Taille icônes réinitialisée : %d" (metal-toolbar-emoji-size)))

(defun metal-toolbar-rafraichir ()
  "Forcer le redessin des barres dans tous les buffers concernés.
Les header-lines ne se rafraîchissent pas toujours sur un simple
`force-mode-line-update'.  On parcourt les buffers et on retouche leur
état d'affichage pour déclencher la réévaluation des `:eval' de barre."
  ;; Mettre à jour mode-lines et header-lines de toutes les fenêtres.
  (force-mode-line-update t)
  ;; Pour chaque buffer affichant une barre, forcer une réévaluation.
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and header-line-format
                 (derived-mode-p 'python-mode 'python-ts-mode
                                 'prolog-mode 'emacs-lisp-mode 'fundamental-mode))
        ;; Toucher header-line-format (le re-set force le redessin).
        (setq header-line-format header-line-format))))
  (redraw-display))

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
CHAR peut surcharger le caractère utilisé (défaut : \"|\").
Le séparateur reçoit la même hauteur (taille des icônes) et le même
décalage vertical que les lettres (`metal-toolbar-char-raise'), afin de
rester aligné avec les boutons voisins (lettres et emoji)."
  (let* ((h (/ (metal-toolbar-emoji-size) 100.0))
         (r metal-toolbar-char-raise)
         (s (propertize (format " %s " (or char "|"))
                        'face `(:weight bold :foreground "gray" :height ,h))))
    (if (and r (not (zerop r)))
        (propertize s 'display `((raise ,r)))
      s)))

(cl-defun metal-toolbar-emoji (emoji &key height color raise)
  "Retourne un EMOJI Unicode propertize pour la header-line.
Convient aux emojis colorés natifs (▶️ 🐛 🔄 📋 💬 🪄 ✅ ❌ etc.).

Utilise le mécanisme `:height' standard d'Emacs.  Toutes les toolbars qui
l'utilisent (Python, Prolog, Agent/Codex, ...) partagent donc la même
taille, modifiable par l'utilisateur via `metal-toolbar-emoji-increase'
et amis.

Mots-clés :
  :height   multiplicateur de taille (float).  Si nil (défaut), calculé
            depuis `(metal-toolbar-emoji-size)' divisé par 100.
  :color    couleur :foreground (souvent ignorée par les emojis colorés).
  :raise    décalage vertical (négatif = vers le bas).  Si nil (défaut),
            utilise `metal-toolbar-emoji-raise' pour aligner l'emoji sur
            les autres boutons voisins."
  (let* ((h (or height (/ (metal-toolbar-emoji-size) 100.0)))
         (r (or raise metal-toolbar-emoji-raise))
         (face `(:height ,h ,@(when color `(:foreground ,color))))
         (s (propertize emoji 'face face)))
    (if (and r (not (zerop r)))
        (propertize s 'display `((raise ,r)))
      s)))

(cl-defun metal-toolbar-char (texte &key style color height raise)
  "Rendre TEXTE (souvent une lettre) comme bouton, avec un STYLE de format.
Sert quand aucun emoji ne convient (formatage typographique : gras,
italique, etc.).  La lettre PORTE le style qu'elle déclenche, pour être
auto-explicative : « G » en gras, « I » en italique, etc.

STYLE : un symbole parmi `bold', `italic', `underline', `strike', ou nil.
COLOR : couleur de premier plan optionnelle.
HEIGHT : multiplicateur de taille (défaut : taille emoji courante, pour
         rester cohérent avec les autres boutons de la barre).
RAISE : décalage vertical ; si nil, `metal-toolbar-char-raise' (pour
        aligner la lettre sur les emoji voisins)."
  (let* ((h (or height (/ (metal-toolbar-emoji-size) 100.0)))
         (r (or raise metal-toolbar-char-raise))
         (attrs (pcase style
                  ('bold      '(:weight bold))
                  ('italic    '(:slant italic))
                  ('underline '(:underline t))
                  ('strike    '(:strike-through t))
                  (_          nil)))
         (face `(:height ,h
                 ,@(when color `(:foreground ,color))
                 ,@attrs))
         (s (propertize texte 'face face)))
    (if (and r (not (zerop r)))
        (propertize s 'display `((raise ,r)))
      s)))

(defun metal-toolbar-button (icon tooltip command &optional context)
  "Construit un bouton cliquable pour une header-line ou une mode-line.
ICON est une chaîne (idéalement obtenue via `metal-toolbar-emoji' ou
`metal-toolbar-emoji').
TOOLTIP s'affiche au survol.
COMMAND est la commande appelée au clic-gauche.
CONTEXT détermine le ou les pseudo-événements de clic câblés :
- nil (défaut) : `header-line' seul ;
- un symbole (`header-line', `mode-line' ou `nil-event') : ce contexte seul,
  où `nil-event' câble `[mouse-1]' sans préfixe ;
- une liste de tels symboles : tous câblés (utile quand un même bouton peut
  apparaître en header-line ET en mode-line).
Un clic dans la header-line arrive comme `[header-line mouse-1]', dans la
mode-line comme `[mode-line mouse-1]', et un `[mouse-1]' nu couvre les
autres affichages (overlay, texte de buffer).

L'espacement horizontal autour de l'icône est contrôlé par
`metal-toolbar-button-padding'.

Note : `mouse-face' utilise un cons frais via `list' (et non un littéral
quoté).  Sans ça, des boutons adjacents avec une valeur `eq' identique
fusionneraient en une seule région de surbrillance."
  (let* ((ctxs (cond ((null context) '(header-line))
                     ((listp context) context)
                     (t (list context))))
         (spc (make-string metal-toolbar-button-padding ?\s))
         (map (make-sparse-keymap)))
    (dolist (ctx ctxs)
      (define-key map
                  (if (eq ctx 'nil-event)
                      [mouse-1]
                    (vector ctx 'mouse-1))
                  command))
    (propertize (concat spc icon spc)
                'mouse-face (list :background metal-toolbar-hover-background)
                'help-echo tooltip
                'keymap map)))

;;; --- Assemblage déclaratif d'une barre -----------------------------------

(defun metal-toolbar--resoudre (v)
  "Résoudre V : si c'est une fonction (symbole fboundp ou lambda), l'appeler.
Permet aux champs :icon, :color, :tooltip d'être dynamiques (évalués au
rendu) aussi bien que statiques."
  (cond
   ((functionp v) (funcall v))
   ((and (symbolp v) v (fboundp v)) (funcall v))
   (t v)))

(cl-defun metal-toolbar-build (items &key agent secretaire (context 'header-line))
  "Construire une chaîne de header-line à partir d'ITEMS déclaratifs.

Chaque élément d'ITEMS est une plist décrivant un bouton ou un séparateur.
Le module appelant ne décrit QUE le contenu ; la taille, le padding,
l'alignement, le style et l'espacement sont appliqués uniformément ici,
de façon identique pour tous les modules (Python, Prolog, Agent, et tout
futur module : R, etc.).

Formes reconnues dans ITEMS :
  (:emoji \"▶️\" [:color C] [:tooltip TIP] [:command CMD])
      Un bouton emoji.  :emoji, :color et :tooltip peuvent être une valeur
      OU une fonction (évaluée au rendu, pour les libellés dynamiques).
  (:char \"G\" [:style bold] [:color C] [:tooltip TIP] [:command CMD])
      Un bouton-lettre, quand aucun emoji ne convient (formatage
      typographique).  La lettre porte son :style (bold, italic,
      underline, strike) : « G » en gras, « I » en italique, etc.
  (:sep [CHAR])
      Un séparateur vertical (CHAR optionnel surcharge le \"|\").

Mots-clés de BUILD :
  :agent      si non nil, greffe l'extension Metal-Agent à la fin (protégée
              par `ignore-errors' : la barre survit si metal-agent est absent).
  :secretaire si non nil, greffe l'extension Metal-Secrétaire (bouton 🗒️
              compact, ou barre secrétaire complète si active).  Parallèle
              exact de :agent.
  :context    contexte de clic transmis à `metal-toolbar-button'
              (défaut `header-line').

La barre est encadrée par `metal-toolbar-vpadding' aux deux extrémités.

Lorsque la toolbar Agent complète est active (`metal-agent-active'), ou la
toolbar Secrétaire (`metal-secretaire-active'), elle REMPLACE les boutons
spécifiques au mode : ces derniers ne sont alors pas rendus, seul le segment
spécialisé (étendu) apparaît.  À la fermeture, les boutons du mode reviennent
automatiquement."
  (let* ((parts (list (metal-toolbar-vpadding) " "))
         ;; L'agent « prend la barre » uniquement si ce module a demandé
         ;; l'intégration agent (:agent t) ET que l'agent est actif dans le
         ;; buffer courant.  On protège l'accès à la variable au cas où
         ;; metal-agent n'est pas chargé.
         (agent-prend-la-barre
          (and agent
               (boundp 'metal-agent-active)
               metal-agent-active))
         ;; Le secrétaire « prend la barre » selon la même logique.
         (secretaire-prend-la-barre
          (and secretaire
               (boundp 'metal-secretaire-active)
               metal-secretaire-active))
         ;; Une barre spécialisée prend le dessus → on masque les boutons mode.
         (mode-masque (or agent-prend-la-barre secretaire-prend-la-barre)))
    ;; Boutons spécifiques au mode : masqués quand une barre spécialisée
    ;; prend la barre (agent ou secrétaire).
    (unless mode-masque
      (dolist (item items)
        (let ((kind (car item)))
          (cond
           ((eq kind :sep)
            (push (metal-toolbar-separator (cadr item)) parts))
           ((eq kind :emoji)
            (let* ((glyphe  (metal-toolbar--resoudre (plist-get item :emoji)))
                   (color   (metal-toolbar--resoudre (plist-get item :color)))
                   (tooltip (metal-toolbar--resoudre (plist-get item :tooltip)))
                   (command (plist-get item :command))
                   (icon    (metal-toolbar-emoji glyphe :color color)))
              (push (metal-toolbar-button icon tooltip command context) parts)
              (push " " parts)))
           ((eq kind :char)
            (let* ((texte   (metal-toolbar--resoudre (plist-get item :char)))
                   (style   (plist-get item :style))
                   (color   (metal-toolbar--resoudre (plist-get item :color)))
                   (tooltip (metal-toolbar--resoudre (plist-get item :tooltip)))
                   (command (plist-get item :command))
                   (icon    (metal-toolbar-char texte :style style :color color)))
              (push (metal-toolbar-button icon tooltip command context) parts)
              (push " " parts)))
           (t nil)))))
    ;; Segment Secrétaire : compact (🗒️ seul) si inactif, étendu si actif.
    ;; Affiché seulement si l'agent n'a pas pris la barre (priorité simple :
    ;; deux barres spécialisées ne s'affichent jamais en même temps).
    (when (and secretaire (not agent-prend-la-barre))
      (push (or (and (fboundp 'metal-secretaire-toolbar-buttons)
                     (ignore-errors (metal-secretaire-toolbar-buttons)))
                "")
            parts))
    ;; Segment Agent : compact (🤖 seul) si inactif, étendu si actif.
    ;; Masqué si le secrétaire a pris la barre.
    (when (and agent (not secretaire-prend-la-barre))
      (push (or (and (fboundp 'metal-agent-toolbar-buttons)
                     (ignore-errors (metal-agent-toolbar-buttons)))
                "")
            parts))
    (push " " parts)
    (push (metal-toolbar-vpadding) parts)
    (apply #'concat (nreverse parts))))

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
