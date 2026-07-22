;;; metal-agent-profils.el --- Chargement des profils Org pour metal-agent  -*- lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Maintainer: Jacques Ladouceur

;;; Commentary:
;; Ce module gère les profils de l'agent IA via des fichiers ~.org~
;; placés dans `metal-agent-profils-directory'.  Le format d'un profil
;; est documenté dans le fichier `README.org' de ce même dossier.
;;
;; Au démarrage :
;;   1. Si le dossier utilisateur n'existe pas, il est créé et les
;;      profils par défaut (livrés avec MetalEmacs) y sont copiés.
;;   2. Tous les fichiers `.org' du dossier sont lus et convertis en
;;      profils.
;;   3. Si AUCUN profil n'a pu être chargé (cas extrême), un profil
;;      minimal de fallback est utilisé pour ne pas bloquer Emacs.

;;; Code:

(require 'cl-lib)

(defcustom metal-agent-profils-directory
  (expand-file-name "~/Documents/MetalEmacs/profils-agentiques/")
  "Dossier où sont stockés les profils utilisateur (fichiers .org).
Survit aux mises à jour de MetalEmacs.  Peut être synchronisé via
Synology Drive, iCloud, Dropbox..."
  :type 'directory
  :group 'metal-agent)

(defcustom metal-agent-profils-defaut-directory
  (expand-file-name "metal-agent-profils-defaut/" user-emacs-directory)
  "Dossier des profils livrés par défaut avec MetalEmacs.
Les profils de ce dossier sont chargés à chaque démarrage et
combinés avec ceux du dossier utilisateur.  Pour un profil
présent dans les deux dossiers, le profil utilisateur l'emporte.
Ce dossier peut être écrasé aux mises à jour ; les modifications
utilisateur restent dans `metal-agent-profils-directory'."
  :type 'directory
  :group 'metal-agent)

(defvar metal-agent-profils nil
  "Liste des profils chargés en mémoire.
Chaque profil est un plist avec les clés :id, :nom, :modes,
:auto-defaut, :systeme, :options-defaut, :options-disponibles.
Cette variable est remplie par `metal-agent--charger-tous-profils'.")

;; ─────────────────────────────────────────────────────────────────
;; Profil minimal de fallback (si aucun fichier .org n'est chargé)
;; ─────────────────────────────────────────────────────────────────

(defvar metal-agent--profil-fallback
  '(:id tronc-commun
    :nom "Tronc commun (fallback)"
    :modes t
    :auto-defaut t
    :systeme
    "Tu es un assistant de programmation et de rédaction polyvalent
qui aide un chercheur en traitement automatique du langage.  Tu
réponds en français.  Tu fais le minimum de modifications nécessaires
pour accomplir la tâche."
    :options-defaut (modifications-minimales t commentaires-fr t)
    :options-disponibles
    ((:id modifications-minimales
      :nom "[Garde-fou] Modifications minimales"
      :fragment "[Garde-fou] Ne modifie que ce qui est strictement nécessaire à la tâche demandée.")
     (:id commentaires-fr
      :nom "[Préférence] Commentaires en français"
      :fragment "[Préférence] Si tu rédiges des commentaires ou des messages, privilégie le français.")))
  "Profil minimal utilisé si AUCUN fichier .org n'est trouvé.
Garantit que `metal-agent' continue à fonctionner même si la
configuration utilisateur est cassée ou absente.")

;; ─────────────────────────────────────────────────────────────────
;; Conversion : nom (chaîne) → identifiant Lisp (symbole)
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--slugify (texte)
  "Convertit TEXTE en symbole utilisable comme identifiant.
Conserve les lettres, chiffres et tirets ; remplace tout le reste
par des tirets ; supprime les tirets multiples consécutifs.
Exemple : « [Préférence] Code Python idiomatique » →
`prefer-code-python-idiomatique' (en pratique : tronqué et nettoyé)."
  (let* ((s (downcase texte))
         ;; Supprimer les accents (translittération basique)
         (s (replace-regexp-in-string "[àâäáã]" "a" s))
         (s (replace-regexp-in-string "[éèêë]" "e" s))
         (s (replace-regexp-in-string "[îï]" "i" s))
         (s (replace-regexp-in-string "[ôö]" "o" s))
         (s (replace-regexp-in-string "[ùûü]" "u" s))
         (s (replace-regexp-in-string "[ç]" "c" s))
         ;; Supprimer les crochets et parenthèses
         (s (replace-regexp-in-string "\\[[^]]*\\]" "" s))
         (s (replace-regexp-in-string "([^)]*)" "" s))
         ;; Tout caractère non alphanumérique → tiret
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         ;; Tirets en début / fin
         (s (replace-regexp-in-string "^-+\\|-+$" "" s))
         ;; Tirets multiples
         (s (replace-regexp-in-string "-+" "-" s)))
    (intern (if (string-empty-p s) "option" s))))

;; ─────────────────────────────────────────────────────────────────
;; Parser d'un fichier .org de profil
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--lire-metadonnees (contenu)
  "Extrait les métadonnées #+CLE: valeur en tête de CONTENU.
Retourne un alist ((CLE . VALEUR) ...) avec les clés en majuscules
sans le #+ ni les deux-points."
  (let ((meta nil)
        (pos 0))
    (while (string-match "^#\\+\\([A-Z_]+\\):[ \t]*\\(.*\\)$" contenu pos)
      (push (cons (match-string 1 contenu)
                  (string-trim (match-string 2 contenu)))
            meta)
      (setq pos (match-end 0)))
    (nreverse meta)))

(defun metal-agent--parser-modes (valeur)
  "Convertit la VALEUR de #+MODES: en liste de symboles ou `t'."
  (cond
   ((or (string= valeur "t") (string= valeur "T")) t)
   ((string-empty-p valeur) nil)
   (t (mapcar #'intern (split-string valeur "[ \t]+" t)))))

(defun metal-agent--parser-bool (valeur)
  "Convertit une VALEUR textuelle en booléen Lisp.
~t~/~true~/~oui~ → t ; ~f~/~nil~/~false~/~non~ → nil."
  (let ((v (downcase (string-trim (or valeur "")))))
    (not (member v '("f" "nil" "false" "non" "" "no")))))

(defun metal-agent--parser-titre-option (titre)
  "Extrait (NOM-AFFICHAGE . DEFAUT) d'un titre d'option Org.
Format attendu : « * Nom de l'option :: t-ou-f ».
Retourne nil si le format n'est pas reconnu."
  (when (string-match "\\(.*?\\)[ \t]*::[ \t]*\\([a-zA-Z]+\\)[ \t]*$" titre)
    (cons (string-trim (match-string 1 titre))
          (metal-agent--parser-bool (match-string 2 titre)))))

(defun metal-agent--parser-fichier-profil (chemin &optional origine)
  "Lit le fichier .org CHEMIN et retourne un plist de profil.
ORIGINE est un symbole indiquant la provenance (`defaut' ou
`personnel'), conservé dans la clé :origine du plist.
Retourne nil si le fichier ne peut pas être parsé."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents chemin)
        (let* ((contenu (buffer-string))
               (meta (metal-agent--lire-metadonnees contenu))
               (nom (file-name-base chemin))
               (id (metal-agent--slugify nom))
               (modes (metal-agent--parser-modes
                       (or (cdr (assoc "MODES" meta)) "t")))
               ;; AUTO_DEFAUT absent → « f » : un profil n'est
               ;; auto-sélectionnable QUE s'il déclare explicitement
               ;; #+AUTO_DEFAUT: t.  Réservé de fait aux profils système
               ;; livrés ; les profils personnels créés par
               ;; `metal-agent-creer-profil' n'ont pas la clé (donc neutres,
               ;; activables à la main via la barre d'outils).
               (auto-defaut (metal-agent--parser-bool
                             (or (cdr (assoc "AUTO_DEFAUT" meta)) "f")))
               ;; Trouver la première option (titre niveau 1)
               (debut-options
                (string-match "^\\*[ \t]+" contenu))
               ;; Préambule = entre fin des #+METADATA et début des options
               (debut-preambule
                (or (let ((p 0) (last 0))
                      (while (string-match "^#\\+[A-Z_]+:.*$" contenu p)
                        (setq last (match-end 0)
                              p (match-end 0)))
                      last)
                    0))
               (preambule
                (string-trim
                 (substring contenu
                            debut-preambule
                            (or debut-options (length contenu)))))
               ;; Options : on extrait chaque titre niveau 1 + son corps
               (options-disponibles nil)
               (options-defaut nil))

          ;; Parcours des options
          (when debut-options
            (let ((reste (substring contenu debut-options))
                  (start 0))
              (while (string-match "^\\*[ \t]+\\(.*\\)$" reste start)
                (let* ((titre-ligne (match-string 1 reste))
                       (debut-corps (match-end 0))
                       ;; Trouver le prochain titre (ou la fin)
                       (fin-corps
                        (or (string-match "^\\*[ \t]+" reste debut-corps)
                            (length reste)))
                       (corps (string-trim
                               (substring reste debut-corps fin-corps)))
                       (parsed (metal-agent--parser-titre-option titre-ligne)))
                  (when parsed
                    (let* ((nom-opt (car parsed))
                           (defaut (cdr parsed))
                           (id-opt (metal-agent--slugify nom-opt)))
                      (push (list :id id-opt
                                  :nom nom-opt
                                  :fragment corps)
                            options-disponibles)
                      (when defaut
                        (setq options-defaut
                              (plist-put options-defaut id-opt t)))))
                  (setq start fin-corps)))))

          ;; Construire le plist final
          (list :id id
                :nom nom
                :modes modes
                :auto-defaut auto-defaut
                :systeme preambule
                :options-defaut options-defaut
                :options-disponibles (nreverse options-disponibles)
                :origine (or origine 'personnel)
                :chemin chemin)))
    (error
     (message "metal-agent : erreur de lecture de %s : %s"
              (file-name-nondirectory chemin)
              (error-message-string err))
     nil)))

;; ─────────────────────────────────────────────────────────────────
;; Initialisation : copie des profils par défaut au premier lancement
;; ─────────────────────────────────────────────────────────────────

;; ─────────────────────────────────────────────────────────────────
;; Migration de l'ancien emplacement ~/Documents/MetalEmacs/profils/
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--migrer-ancien-dossier ()
  "Si l'ancien dossier ~/Documents/MetalEmacs/profils/ existe avec
des profils .org, en déplacer le contenu vers le nouveau dossier
`metal-agent-profils-directory'.  Migration unique au démarrage."
  (let ((ancien (expand-file-name "~/Documents/MetalEmacs/profils/"))
        (nouveau metal-agent-profils-directory))
    (when (and (file-directory-p ancien)
               (not (file-equal-p ancien nouveau))
               (directory-files ancien nil "\\.org\\'"))
      (make-directory nouveau t)
      (let ((deplaces 0))
        (dolist (fichier (directory-files ancien t "\\.org\\'"))
          (let ((dest (expand-file-name (file-name-nondirectory fichier)
                                        nouveau)))
            (unless (file-exists-p dest)
              (rename-file fichier dest)
              (cl-incf deplaces))))
        (when (> deplaces 0)
          (message "metal-agent : %d profil(s) migré(s) de %s vers %s"
                   deplaces ancien nouveau))
        ;; Si l'ancien dossier est désormais vide, le supprimer
        (when (null (directory-files ancien nil "\\.org\\'"))
          (ignore-errors (delete-directory ancien)))))))

;; ─────────────────────────────────────────────────────────────────
;; Initialisation : création du dossier personnel
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--initialiser-dossier-utilisateur ()
  "Crée `metal-agent-profils-directory' s'il n'existe pas.
La copie initiale des profils par défaut n'est plus nécessaire :
les deux dossiers sont consultés à chaque chargement."
  (metal-agent--migrer-ancien-dossier)
  (unless (file-directory-p metal-agent-profils-directory)
    (make-directory metal-agent-profils-directory t)))

;; ─────────────────────────────────────────────────────────────────
;; Chargement de tous les profils (fusion défaut + personnel)
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--lister-profils-dossier (dossier origine)
  "Liste les profils .org du DOSSIER, en marquant leur ORIGINE.
Retourne une liste de plists.  Ignore les README."
  (let ((profils nil))
    (when (file-directory-p dossier)
      (dolist (fichier (directory-files dossier t "\\.org\\'"))
        (unless (string-match-p "README" (file-name-nondirectory fichier))
          (let ((profil (metal-agent--parser-fichier-profil fichier origine)))
            (when profil
              (push profil profils))))))
    (nreverse profils)))

(defun metal-agent--charger-tous-profils ()
  "Charge les profils des deux dossiers et les fusionne.
Les profils du dossier utilisateur l'emportent sur ceux portant
le même nom de fichier dans le dossier par défaut.  Met à jour
`metal-agent-profils'.  Si aucun profil n'est chargé, utilise le
profil de fallback pour ne pas bloquer Emacs."
  (metal-agent--initialiser-dossier-utilisateur)
  (let* ((profils-defaut (metal-agent--lister-profils-dossier
                          metal-agent-profils-defaut-directory 'defaut))
         (profils-perso (metal-agent--lister-profils-dossier
                         metal-agent-profils-directory 'personnel))
         ;; Index des ids personnels pour détecter les collisions
         (ids-perso (mapcar (lambda (p) (plist-get p :id)) profils-perso))
         ;; On garde les profils par défaut dont l'id n'est pas pris
         ;; par un profil personnel
         (defaut-non-eclipses
          (cl-remove-if (lambda (p)
                          (member (plist-get p :id) ids-perso))
                        profils-defaut))
         (profils (append profils-perso defaut-non-eclipses)))
    (setq metal-agent-profils
          (or profils (list metal-agent--profil-fallback)))
    (length metal-agent-profils)))

(defun metal-agent-recharger-profils ()
  "Recharge les profils depuis les deux dossiers (défaut + personnel).
À appeler après avoir édité un fichier .org de profil."
  (interactive)
  (let* ((n (metal-agent--charger-tous-profils))
         (n-perso (length (cl-remove-if-not
                           (lambda (p)
                             (eq (plist-get p :origine) 'personnel))
                           metal-agent-profils)))
         (n-defaut (- n n-perso)))
    (message "metal-agent : %d profil(s) chargé(s) (%d personnel(s), %d défaut)"
             n n-perso n-defaut)))

(defun metal-agent-ouvrir-dossier-profils ()
  "Ouvre `metal-agent-profils-directory' dans Dired."
  (interactive)
  (metal-agent--initialiser-dossier-utilisateur)
  (dired metal-agent-profils-directory))

;; ─────────────────────────────────────────────────────────────────
;; Création interactive d'un nouveau profil
;; ─────────────────────────────────────────────────────────────────

(defun metal-agent--valider-nom-profil (nom)
  "Vérifie que NOM est utilisable comme nom de fichier de profil.
Signale une `user-error' explicite si le nom est vide ou contient
un séparateur de chemin.  Retourne le nom nettoyé de ses blancs."
  (let ((n (string-trim (or nom ""))))
    (when (string-empty-p n)
      (user-error "Le nom du profil ne peut pas être vide"))
    (when (string-match-p "[/\\\\]" n)
      (user-error "Le nom du profil ne peut pas contenir « / » ni « \\ »"))
    (when (string-prefix-p "." n)
      (user-error "Le nom du profil ne peut pas commencer par un point"))
    (when (string-match-p "README" n)
      (user-error "« README » est réservé — les fichiers README sont ignorés au chargement"))
    n))

(defun metal-agent-creer-profil (nom modes-str)
  "Crée un nouveau profil dans `metal-agent-profils-directory'.
NOM est le nom du profil (et le nom du fichier).
MODES-STR est la liste des modes séparés par des espaces, ou ~t~
pour tous les modes."
  (interactive
   (list (read-string "Nom du profil : ")
         (read-string "Modes (séparés par espaces, ou « t » pour tous) : "
                      "t")))
  (setq nom (metal-agent--valider-nom-profil nom))
  (metal-agent--initialiser-dossier-utilisateur)
  (let ((chemin (expand-file-name (concat nom ".org")
                                  metal-agent-profils-directory)))
    (when (file-exists-p chemin)
      (unless (yes-or-no-p (format "Le fichier %s existe déjà.  Écraser ? "
                                   (file-name-nondirectory chemin)))
        (user-error "Création annulée")))
    (with-temp-file chemin
      (insert (format "#+MODES: %s\n\n"
                      (string-trim modes-str)))
      (insert "Décris ici le rôle de l'agent pour ce profil.\n")
      (insert "Ce préambule est envoyé à l'agent à chaque appel quand\n")
      (insert "ce profil est actif.\n\n")
      (insert "* [Préférence] Première option :: t\n")
      (insert "Ce texte explique l'effet de l'option et sera ajouté au\n")
      (insert "prompt envoyé à l'agent quand l'option est cochée.\n\n")
      (insert "* [Permission] Deuxième option :: f\n")
      (insert "Une option décochée par défaut.  L'utilisateur peut la\n")
      (insert "cocher dans le panneau de configuration pour activer\n")
      (insert "cette permission.\n"))
    (find-file chemin)
    (message "Profil créé : %s.  Édite, sauvegarde, puis M-x metal-agent-recharger-profils"
             (file-name-nondirectory chemin))))

;; ─────────────────────────────────────────────────────────────────
;; Création d'un profil à partir du profil actuel
;; ─────────────────────────────────────────────────────────────────

;; `metal-agent--profil' est défini dans metal-agent.el, qui charge ce
;; module.  Déclaration pour éviter un avertissement à la compilation.
(declare-function metal-agent--profil "metal-agent" (&optional id))
(declare-function metal-agent--profil-est-defaut-p "metal-agent" (profil))

(defun metal-agent-copier-profil (nouveau-nom)
  "Créer un nouveau profil personnel à partir du profil actuel.
NOUVEAU-NOM est le nom du profil créé (et de son fichier, sans
l'extension).  Le profil actuel sert de point de départ : son
fichier .org est recopié tel quel dans `metal-agent-profils-directory',
avec ses commentaires et sa mise en forme, prêt à être remanié.

Le nom donné détermine l'identifiant du profil créé.  Reprendre le
nom du profil actuel n'est pas le geste attendu ici : la copie
éclipserait alors l'original au lieu de s'y ajouter.  Pour
personnaliser un profil livré en gardant son nom, utiliser plutôt
`metal-agent-sauvegarder-etat'."
  (interactive
   (let* ((profil (metal-agent--profil))
          (nom (and profil (plist-get profil :nom))))
     (unless profil
       (user-error "Aucun profil actif"))
     (unless (plist-get profil :chemin)
       (user-error "Le profil « %s » n'a pas de fichier source" nom))
     (list (read-string
            (format "Nom du nouveau profil (à partir de « %s ») : " nom)))))
  (let* ((profil (metal-agent--profil))
         (source (plist-get profil :chemin))
         (nom-source (plist-get profil :nom))
         (est-defaut (metal-agent--profil-est-defaut-p profil)))
    (unless (and source (file-exists-p source))
      (user-error "Fichier source introuvable pour le profil « %s »" nom-source))
    (setq nouveau-nom (metal-agent--valider-nom-profil nouveau-nom))
    (metal-agent--initialiser-dossier-utilisateur)
    (let ((dest (expand-file-name (concat nouveau-nom ".org")
                                  metal-agent-profils-directory)))
      ;; `file-equal-p' n'est fiable que si les deux fichiers existent ;
      ;; on ne teste donc l'identité source/destination que dans ce cas.
      (when (and (file-exists-p dest) (file-equal-p source dest))
        (user-error "Le profil « %s » est déjà ce fichier personnel" nom-source))
      (when (file-exists-p dest)
        (unless (yes-or-no-p
                 (format "Le fichier %s existe déjà dans le dossier personnel.  Écraser ? "
                         (file-name-nondirectory dest)))
          (user-error "Création annulée")))
      (copy-file source dest t)
      (metal-agent-recharger-profils)
      (find-file dest)
      (if (and est-defaut (string= nouveau-nom nom-source))
          (message
           "Profil créé : %s — portant le nom du profil livré, il l'éclipse désormais."
           (abbreviate-file-name dest))
        (message "Profil « %s » créé à partir de « %s » : %s"
                 nouveau-nom nom-source (abbreviate-file-name dest))))))

;; ─────────────────────────────────────────────────────────────────
;; Chargement automatique au require
;; ─────────────────────────────────────────────────────────────────

(metal-agent--charger-tous-profils)

(provide 'metal-agent-profils)
;;; metal-agent-profils.el ends here
