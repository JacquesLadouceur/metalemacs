;;; Intégration de metal-secretaire dans MetalEmacs -*- lexical-binding: t; -*-
;;
;; IMPORTANT : cette version modifie aussi metal-toolbar.el et metal-org.el.
;; Remplacez vos fichiers existants par les versions fournies (elles ajoutent
;; le support :secretaire à metal-toolbar-build et greffent le bouton 🗒️ dans
;; la barre Org pour les fichiers .sec). Le reste de votre config est intact.
;; ------------------------------------------------------------------------

;; 1. Charger le module. metal-secretaire.el et metal-secretaire-transcribe.py
;;    sont côte à côte dans ~/.emacs.d/, donc le worker est trouvé tout seul.
;;    (metal-toolbar et metal-org sont déjà chargés par votre init habituel ;
;;    assurez-vous d'avoir mis à jour ces deux fichiers.)
(require 'metal-secretaire)

;; 2. Clé API Gladia : M-x metal-secretaire-configurer-cle (C-c é c).

;; 3. Barre d'outils : RIEN à configurer.
;;    Dans un fichier .sec, la barre Org affiche en plus un bouton 🗒️ (à côté
;;    de 🤖). Cliquer 🗒️ remplace les boutons Org par la barre du secrétaire
;;    (🎙️ transcrire, 🏷️ renommer, 📋 PV, ❌ interrompre) ; re-cliquer revient
;;    aux boutons Org. On garde donc les outils Org pour l'édition manuelle.

;; 4. Raccourcis (préfixe « C-c é » pour éviter les collisions Org).
(with-eval-after-load 'metal-secretaire
  (define-key global-map (kbd "C-c é c") #'metal-secretaire-configurer-cle)
  (define-key global-map (kbd "C-c é t") #'metal-secretaire-transcrire)
  (define-key global-map (kbd "C-c é p") #'metal-secretaire-rediger-pv)
  (define-key global-map (kbd "C-c é r") #'metal-secretaire-renommer-intervenant)
  (define-key global-map (kbd "C-c é k") #'metal-secretaire-interrompre)
  (define-key global-map (kbd "C-c é b") #'metal-secretaire-toggle-active))
