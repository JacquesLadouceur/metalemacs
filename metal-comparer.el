;;; metal-comparer.el --- Comparer deux documents avec la révision Ediff de MetalEmacs  -*- lexical-binding: t; -*-

;; Auteur : Jacques Ladouceur
;; Fait partie de MetalEmacs.

;;; Commentary:
;;
;; Réutilise tel quel le frame de révision de metal-agent (ORIGINAL à
;; gauche, CORRECTION(S) à droite, panneau Ediff natif en bas) et sa barre
;; de boutons :
;;
;;   ⬅️ / ➡️      différence précédente / suivante
;;   ✅           accepter le bloc de droite
;;   ↩️           annuler l'acceptation du bloc
;;   ✔️ Terminer  appliquer les blocs acceptés au document de gauche
;;   🚫 Annuler   fermer sans rien modifier
;;
;; Mais au lieu d'une réponse d'agent, la colonne de droite est un autre
;; document choisi par l'utilisateur (version d'un collègue, d'un étudiant,
;; ancienne version, etc.).
;;
;; Commandes :
;;
;;   M-x metal-comparer-documents   fichier courant (ou choisi) ← autre fichier
;;   M-x metal-comparer-tampons     tampon ← autre tampon
;;
;; Le document de GAUCHE est celui qui reçoit les corrections acceptées.
;; Il est modifié dans son tampon, sans être enregistré : `C-x C-s' (ou
;; `undo') reste à la discrétion de l'utilisateur.  Le document de droite
;; n'est jamais modifié.

;;; Code:

(require 'metal-agent)

(defvar metal-comparer--etat-sauve nil
  "Valeurs de metal-agent mises de côté pendant une comparaison.
Liste (SOURCE TARGET TARGET-BUFFER BEG END), restaurée à la fermeture
pour ne pas perturber le contexte de l'agent.")

(defun metal-comparer--restaurer-etat (&rest _)
  "Restaurer le contexte de metal-agent après la fermeture de la révision."
  (advice-remove 'metal-agent--ediff-quit-hook #'metal-comparer--restaurer-etat)
  (when metal-comparer--etat-sauve
    (pcase-let ((`(,src ,kind ,buf ,beg ,end) metal-comparer--etat-sauve))
      (setq metal-agent--source-buffer      src
            metal-agent--last-target        kind
            metal-agent--last-target-buffer buf
            metal-agent--last-target-beg    beg
            metal-agent--last-target-end    end))
    (setq metal-comparer--etat-sauve nil)))

(defun metal-comparer--texte (buffer)
  "Texte complet de BUFFER, sans propriétés."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun metal-comparer--lancer (cible autre)
  "Réviser le tampon CIBLE à partir du tampon AUTRE.
CIBLE s'affiche à gauche (ORIGINAL) et reçoit les blocs acceptés ;
AUTRE s'affiche à droite (CORRECTION(S))."
  (when (eq cible autre)
    (user-error "Les deux documents sont identiques"))
  ;; L'application finale remplace le tampon entier : un tampon restreint
  ;; (narrowing) verrait son texte dupliqué.
  (when (with-current-buffer cible (buffer-narrowed-p))
    (user-error "Le tampon %s est restreint — élargissez-le d'abord (C-x n w)"
                (buffer-name cible)))
  (when (and (boundp 'metal-agent--ediff-control-buffer)
             (buffer-live-p metal-agent--ediff-control-buffer))
    (user-error "Une révision est déjà ouverte — terminez-la d'abord"))
  (let ((original (metal-comparer--texte cible))
        (propose  (metal-comparer--texte autre)))
    (if (string= original propose)
        (message "Les deux documents sont identiques — rien à comparer.")
      ;; Mettre de côté le contexte de l'agent, puis le pointer sur CIBLE :
      ;; c'est ce que lit `metal-agent--reviser-via-ediff' pour savoir où
      ;; appliquer le résultat, et `metal-agent--texte-p' pour choisir les
      ;; options de diff (-w pour la prose, stricte pour le code).
      (setq metal-comparer--etat-sauve
            (list metal-agent--source-buffer
                  metal-agent--last-target
                  metal-agent--last-target-buffer
                  metal-agent--last-target-beg
                  metal-agent--last-target-end))
      (setq metal-agent--source-buffer      cible
            metal-agent--last-target        'buffer
            metal-agent--last-target-buffer cible
            metal-agent--last-target-beg    nil
            metal-agent--last-target-end    nil)
      (advice-add 'metal-agent--ediff-quit-hook :after
                  #'metal-comparer--restaurer-etat)
      (condition-case err
          (metal-agent--reviser-via-ediff original propose)
        (error
         (metal-comparer--restaurer-etat)
         (signal (car err) (cdr err)))))))

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
  (let ((cible (find-file-noselect fichier-a))
        (autre (find-file-noselect fichier-b)))
    (metal-comparer--lancer cible autre)))

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
  (metal-comparer--lancer (get-buffer tampon-a) (get-buffer tampon-b)))

(provide 'metal-comparer)
;;; metal-comparer.el ends here
