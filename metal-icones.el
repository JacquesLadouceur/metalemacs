;;; metal-icones.el --- Rendu d'emoji en couleur via SVG Twemoji -*- coding: utf-8; lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, faces, icons

;;; Commentary:
;;
;; Rendu des emoji en COULEUR, identique sur macOS et Windows.
;;
;; Problème résolu : Emacs sous Windows (backend d'affichage w32) ne
;; colore PAS les emoji Unicode.  Même lorsque la fonte couleur
;; (Segoe UI Emoji) est correctement sélectionnée, le moteur de rendu
;; affiche les glyphes en monochrome.  macOS, lui, les affiche en
;; couleur.  D'où un rendu incohérent entre plateformes.
;;
;; Solution : ne plus afficher les emoji comme du TEXTE, mais comme des
;; IMAGES SVG (jeu Twemoji), rendues par librsvg — présent dans les
;; builds Emacs modernes (voir RSVG dans `system-configuration-features').
;; Le rendu image est identique quelle que soit la plateforme.
;;
;; Dérivation automatique : le nom de fichier Twemoji est le codepoint
;; Unicode de l'emoji (ex. 🐍 = U+1F40D → « 1f40d.svg »).  Ce module
;; DÉDUIT ce nom directement du caractère reçu — aucune table à tenir à
;; jour.  N'importe quel emoji passé à `metal-icone' est donc résolu,
;; téléchargé au besoin, mis en cache et affiché en couleur.
;;
;; Téléchargement paresseux : les SVG absents sont récupérés au premier
;; usage, puis mis en cache localement (fonctionnement hors-ligne
;; ensuite).  En cas d'absence de réseau ou de terminal non graphique,
;; repli propre sur l'emoji Unicode — jamais de plantage.
;;
;; Graphiques Twemoji © Twitter, Inc. et contributeurs, licence CC-BY 4.0
;; (https://creativecommons.org/licenses/by/4.0/).  Fork maintenu :
;; https://github.com/jdecked/twemoji

;;; Code:

(require 'svg nil t)
(require 'url)

;;; --- Configuration -------------------------------------------------------

(defgroup metal-icones nil
  "Rendu des emoji en couleur via SVG Twemoji."
  :group 'convenience
  :prefix "metal-icones-")

(defcustom metal-icones-dir
  (expand-file-name "icones/twemoji/" user-emacs-directory)
  "Dossier de cache local des SVG Twemoji.
Cache régénérable : les fichiers manquants sont re-téléchargés au
démarrage suivant."
  :type 'directory
  :group 'metal-icones)

(defcustom metal-icones-url-base
  "https://raw.githubusercontent.com/jdecked/twemoji/master/assets/svg/"
  "URL de base du dépôt Twemoji (fork maintenu) pour les fichiers SVG."
  :type 'string
  :group 'metal-icones)

(defcustom metal-icones-activer t
  "Si non nil, afficher les emoji comme images SVG couleur.
Si nil, `metal-icone' renvoie l'emoji Unicode tel quel (comportement
d'origine).  Permet de désactiver globalement le rendu image."
  :type 'boolean
  :group 'metal-icones)

(defcustom metal-icones-taille-defaut 20
  "Taille par défaut, en pixels, des icônes SVG."
  :type 'integer
  :group 'metal-icones)

(defcustom metal-icones-locales-dir
  (expand-file-name "icones/locales/" user-emacs-directory)
  "Dossier des icônes SVG « maison » embarquées dans MetalEmacs.
Contrairement aux icônes Twemoji (téléchargées et nommées par codepoint),
ces SVG sont fournis avec la distribution et désignés par un nom logique
via `metal-icone-locale' (ex. « organigramme » → organigramme.svg)."
  :type 'directory
  :group 'metal-icones)

(defcustom metal-icones-substituts
  '(("✚" . "➕"))   ; croix grasse U+271A → heavy plus U+2795 (a un SVG Twemoji)
  "Table de substitution pour les caractères sans SVG Twemoji.
Chaque entrée (SOURCE . CIBLE) remplace le caractère SOURCE — qui n'a pas
d'image dans le dépôt — par CIBLE, un emoji visuellement équivalent qui,
lui, en possède une.  Cela permet d'obtenir une icône couleur là où le
caractère d'origine n'existe que comme glyphe de texte.

N'ajouter ici que de VRAIES icônes : les symboles typographiques (flèches
→ ⇒, filets ─ ═, triangles ▼ ▾, coches légères ✓ ✗) n'ont pas vocation à
devenir des images et doivent rester du texte."
  :type '(alist :key-type string :value-type string)
  :group 'metal-icones)

;;; --- État interne --------------------------------------------------------

(defvar metal-icones--cache (make-hash-table :test 'equal)
  "Cache mémoire des images construites.  Clé = (NOM . TAILLE-PX).")

(defvar metal-icones--echecs (make-hash-table :test 'equal)
  "Ensemble des noms de fichiers dont le téléchargement a déjà échoué.
Évite de retenter le réseau pour le même fichier à chaque rafraîchissement
d'affichage pendant la session.")

(defvar metal-icones--licence-ecrite nil
  "Non nil une fois le fichier d'attribution CC-BY créé.")

;;; --- Dérivation du nom de fichier ----------------------------------------

(defun metal-icones--nom-fichier (emoji)
  "Déduire le nom de base Twemoji (sans extension) pour EMOJI.
Le nom est la suite des codepoints hexadécimaux en minuscules, séparés
par des tirets, en OMETTANT le sélecteur de variante U+FE0F (que Twemoji
n'inclut généralement pas dans ses noms de fichiers).

Exemples :
  \"🐍\"  (U+1F40D)          → \"1f40d\"
  \"▶️\"  (U+25B6 U+FE0F)    → \"25b6\"
  \"🇫🇷\" (U+1F1EB U+1F1F7)  → \"1f1eb-1f1f7\""
  (let ((codepoints nil))
    (mapc (lambda (ch)
            (unless (= ch #xFE0F)     ; ignorer le sélecteur de variante
              (push (format "%x" ch) codepoints)))
          (append emoji nil))
    (mapconcat #'identity (nreverse codepoints) "-")))

(defun metal-icones--nom-fichier-avec-fe0f (emoji)
  "Comme `metal-icones--nom-fichier' mais en CONSERVANT U+FE0F.
Sert de variante de repli : certains emoji sont nommés avec « -fe0f »
dans le dépôt Twemoji."
  (let ((codepoints nil))
    (mapc (lambda (ch) (push (format "%x" ch) codepoints))
          (append emoji nil))
    (mapconcat #'identity (nreverse codepoints) "-")))

(defun metal-icones--chemin (nom)
  "Chemin local du SVG nommé NOM (sans extension)."
  (expand-file-name (concat nom ".svg") metal-icones-dir))

;;; --- Licence -------------------------------------------------------------

(defun metal-icones--ecrire-licence ()
  "Créer le fichier d'attribution CC-BY à côté du cache (une seule fois)."
  (unless metal-icones--licence-ecrite
    (setq metal-icones--licence-ecrite t)
    (let ((licence (expand-file-name "ICONES-LICENCE.txt" metal-icones-dir)))
      (unless (file-exists-p licence)
        (ignore-errors
          (make-directory metal-icones-dir t)
          (with-temp-file licence
            (insert
             "Icônes de MetalEmacs\n"
             "════════════════════\n\n"
             "Ces images proviennent de Twemoji, l'ensemble d'emoji ouvert\n"
             "initialement publié par Twitter, désormais maintenu par la\n"
             "communauté (fork jdecked).\n\n"
             "Graphiques Twemoji © Twitter, Inc. et contributeurs.\n"
             "Licence : Creative Commons Attribution 4.0 (CC-BY 4.0)\n"
             "https://creativecommons.org/licenses/by/4.0/\n\n"
             "Source : https://github.com/jdecked/twemoji\n")))))))

;;; --- Téléchargement ------------------------------------------------------

(defun metal-icones--telecharger (nom)
  "Télécharger le SVG NOM dans le cache s'il est absent.
Retourne le chemin local si le fichier est présent (ou a été téléchargé
avec succès), nil sinon.  N'échoue jamais bruyamment ; ne retente pas un
téléchargement déjà marqué comme échoué dans la session."
  (let ((chemin (metal-icones--chemin nom)))
    (cond
     ((file-readable-p chemin) chemin)
     ((gethash nom metal-icones--echecs) nil)  ; échec déjà connu
     (t
      (metal-icones--ecrire-licence)
      (ignore-errors (make-directory metal-icones-dir t))
      (let ((url (concat metal-icones-url-base nom ".svg"))
            (ok nil))
        (ignore-errors
          (url-copy-file url chemin t)
          (setq ok (and (file-readable-p chemin)
                        (> (file-attribute-size (file-attributes chemin)) 0))))
        (if ok
            chemin
          ;; Marquer l'échec pour ne pas boucler sur le réseau
          (puthash nom t metal-icones--echecs)
          (when (file-exists-p chemin) (ignore-errors (delete-file chemin)))
          nil))))))

(defun metal-icones--resoudre (emoji)
  "Retourner le chemin local du SVG pour EMOJI, en le téléchargeant au besoin.
Essaie d'abord le nom sans U+FE0F, puis avec, puis (pour un emoji
composé) le premier codepoint seul.  Retourne nil si rien n'aboutit."
  (or (metal-icones--telecharger (metal-icones--nom-fichier emoji))
      (let ((avec (metal-icones--nom-fichier-avec-fe0f emoji)))
        (unless (string= avec (metal-icones--nom-fichier emoji))
          (metal-icones--telecharger avec)))
      ;; Repli ultime : premier codepoint seul (emoji ZWJ non trouvé)
      (when (> (length emoji) 1)
        (metal-icones--telecharger (format "%x" (aref emoji 0))))))

;;; --- Construction de l'image ---------------------------------------------

(defun metal-icones-disponible-p ()
  "Non nil si le rendu SVG couleur est possible dans ce contexte."
  (and metal-icones-activer
       (display-graphic-p)
       (image-type-available-p 'svg)))

(defun metal-icones-image (emoji &optional taille-px)
  "Construire et renvoyer l'image SVG pour EMOJI à TAILLE-PX pixels.
Retourne un objet image, ou nil si indisponible (le rendu retombera
alors sur l'emoji Unicode).  Si EMOJI figure dans
`metal-icones-substituts', c'est son substitut qui est rendu."
  (when (metal-icones-disponible-p)
    (let* ((emoji (or (cdr (assoc emoji metal-icones-substituts)) emoji))
           (px (or taille-px metal-icones-taille-defaut))
           (nom (metal-icones--nom-fichier emoji))
           (cle (cons nom px))
           (cache (gethash cle metal-icones--cache 'absent)))
      (if (not (eq cache 'absent))
          cache
        (let* ((chemin (metal-icones--resoudre emoji))
               (image (when (and chemin (file-readable-p chemin))
                        (ignore-errors
                          (create-image chemin 'svg nil
                                        :width px :height px
                                        :ascent 'center)))))
          (puthash cle image metal-icones--cache)
          image)))))

;;; --- API publique --------------------------------------------------------

;;;###autoload
(defun metal-icone (emoji &optional taille-px)
  "Retourner une chaîne affichant EMOJI comme icône SVG couleur.
Si le SVG Twemoji est disponible, renvoie EMOJI porteur d'une propriété
`display' pointant vers l'image (couleur, identique Windows / macOS).
Sinon, renvoie EMOJI tel quel (repli sur l'emoji Unicode).

TAILLE-PX force une taille précise en pixels ; défaut
`metal-icones-taille-defaut'."
  (let ((image (metal-icones-image emoji taille-px)))
    (if image
        (propertize emoji 'display image 'rear-nonsticky t)
      emoji)))

;;;###autoload
(defun metal-icone-display (emoji &optional taille-px)
  "Retourner uniquement l'objet image `display' pour EMOJI, ou nil.
Utile pour les appelants qui composent eux-mêmes la propriété `display'
(par exemple pour y adjoindre un `raise')."
  (metal-icones-image emoji taille-px))

;;;###autoload
(defun metal-icones-vider-cache ()
  "Vider le cache mémoire des images et la liste des échecs réseau.
À appeler si les fichiers du cache disque ont changé, ou pour forcer une
nouvelle tentative de téléchargement après une coupure réseau."
  (interactive)
  (clrhash metal-icones--cache)
  (clrhash metal-icones--echecs)
  (message "Cache des icônes vidé."))

;;;###autoload
(defun metal-icones-precharger (emojis &optional taille-px)
  "Précharger (télécharger + construire) les images pour la liste EMOJIS.
Silencieux ; utile au démarrage pour éviter une latence au premier
affichage.  TAILLE-PX optionnelle."
  (dolist (e emojis)
    (ignore-errors (metal-icones-image e taille-px))))

;;;###autoload
(defun metal-icone-locale (nom &optional taille-px)
  "Retourner une chaîne affichant l'icône SVG locale NOM (sans extension).
Cherche NOM.svg dans `metal-icones-locales-dir' et le rend en image à
TAILLE-PX pixels.  Sert aux icônes « maison » de MetalEmacs qui n'ont pas
d'équivalent emoji (ex. « organigramme »).  Repli : chaîne vide si l'icône
est introuvable ou le rendu indisponible.

Renvoie une chaîne d'un caractère invisible porteur de la propriété
`display', afin de pouvoir être insérée comme un emoji dans une barre
d'outils ou le tableau de bord."
  (let ((image (metal-icones-image-locale nom taille-px)))
    (if image
        (propertize " " 'display image 'rear-nonsticky t)
      "")))

(defun metal-icones-image-locale (nom &optional taille-px)
  "Construire l'image SVG de l'icône locale NOM à TAILLE-PX pixels.
Retourne un objet image, ou nil si indisponible."
  (when (metal-icones-disponible-p)
    (let* ((px (or taille-px metal-icones-taille-defaut))
           (cle (cons (concat "locale:" nom) px))
           (cache (gethash cle metal-icones--cache 'absent)))
      (if (not (eq cache 'absent))
          cache
        (let* ((chemin (expand-file-name (concat nom ".svg")
                                         metal-icones-locales-dir))
               (image (when (file-readable-p chemin)
                        (ignore-errors
                          (create-image chemin 'svg nil
                                        :width px :height px
                                        :ascent 'center)))))
          (puthash cle image metal-icones--cache)
          image)))))

(provide 'metal-icones)

;;; metal-icones.el ends here
