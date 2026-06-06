;;; metal-buf-deplace.el --- Déplacement de buffers entre fenêtres -*- lexical-binding: t; -*-

;; Author: Jacques Ladouceur
;; Keywords: windows, buffers, convenience

;;; Commentary:
;;
;; Déplace le buffer courant vers une fenêtre voisine (haut, bas,
;; gauche, droite) à la manière de `windmove', mais en transportant
;; réellement le buffer au lieu de seulement changer de fenêtre.
;;
;; Les side-windows (Treemacs, Dashboard…), les fenêtres dédiées et
;; le minibuffer sont exclus des cibles.  S'il n'existe pas de fenêtre
;; exploitable dans la direction demandée, une fenêtre est créée par
;; split.  Les historiques des autres fenêtres sont nettoyés du buffer
;; déplacé afin d'éviter les « onglets fantômes » avec `tab-line'.
;;
;; Raccourcis installés : S-<flèche> (haut/bas/gauche/droite).

;;; Code:

(require 'cl-lib)
(require 'windmove)

;;; Predicats sur les fenêtres

(defun metal-buf-deplace--main-window-p (window)
  "Retourne t si WINDOW est une fenêtre 'main' (ni side ni minibuffer)."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))))

(defun metal-buf-deplace--main-windows (&optional frame)
  "Liste des fenêtres main de FRAME."
  (cl-remove-if-not #'metal-buf-deplace--main-window-p
                    (window-list frame 'no-minibuf)))

(defun metal-buf-deplace--last-main-window-p (window)
  "Retourne t si WINDOW est la seule fenêtre main de sa frame.
Remplace (one-window-p) qui ne sait pas ignorer les side-windows."
  (let ((mains (metal-buf-deplace--main-windows (window-frame window))))
    (and (memq window mains)
         (null (cdr mains)))))

(defun metal-buf-deplace--usable-window (direction)
  "Fenêtre dans DIRECTION exploitable comme cible, ou nil."
  (let ((win (condition-case nil
                 (windmove-find-other-window direction)
               (error nil))))
    (and win
         (metal-buf-deplace--main-window-p win)
         (not (window-dedicated-p win))
         win)))

(defun metal-buf-deplace--pick-main-window ()
  "Retourne une fenêtre main non-dédiée, ou nil."
  (cl-find-if (lambda (w) (not (window-dedicated-p w)))
              (metal-buf-deplace--main-windows)))

;;; Manipulation des buffers et historiques

(defun metal-buf-deplace--vacate-source (source-window source-buffer)
  "Affiche un buffer autre que SOURCE-BUFFER dans SOURCE-WINDOW."
  (let* ((prev (cl-find-if (lambda (entry)
                             (let ((buf (car entry)))
                               (and (buffer-live-p buf)
                                    (not (eq buf source-buffer)))))
                           (window-prev-buffers source-window)))
         (replacement (or (and prev (car prev))
                          (other-buffer source-buffer t))))
    (when (or (null replacement)
              (not (buffer-live-p replacement))
              (eq replacement source-buffer))
      (setq replacement (get-buffer-create "*scratch*")))
    (set-window-buffer source-window replacement)))

(defun metal-buf-deplace--forget-buffer (window buffer)
  "Retire BUFFER de l'historique (prev et next) de WINDOW."
  (when (window-live-p window)
    (set-window-prev-buffers
     window
     (cl-remove-if (lambda (entry) (eq (car entry) buffer))
                   (window-prev-buffers window)))
    (set-window-next-buffers
     window
     (remq buffer (window-next-buffers window)))))

(defun metal-buf-deplace--forget-buffer-everywhere (buffer keep-window)
  "Retire BUFFER de l'historique de toutes les fenêtres sauf KEEP-WINDOW.
C'est ce qui évite qu'un buffer ayant transité par plusieurs fenêtres
laisse des onglets fantômes un peu partout."
  (dolist (win (window-list nil 'no-minibuf))
    (unless (eq win keep-window)
      (metal-buf-deplace--forget-buffer win buffer))))

(defun metal-buf-deplace--clear-history (window)
  "Efface complètement l'historique de WINDOW."
  (when (window-live-p window)
    (set-window-prev-buffers window nil)
    (set-window-next-buffers window nil)))

(defun metal-buf-deplace--safe-delete-window (window)
  "Supprime WINDOW sauf si c'est la dernière fenêtre main.
Retourne t en cas de suppression effective, nil sinon."
  (when (and (window-live-p window)
             (not (metal-buf-deplace--last-main-window-p window)))
    (condition-case nil
        (progn (delete-window window) t)
      (error nil))))

;;; Opérations composées

(defun metal-buf-deplace--split-source-and-move
    (source-window source-buffer direction-split)
  (let ((new-window (split-window source-window nil direction-split)))
    (set-window-buffer new-window source-buffer)
    (metal-buf-deplace--clear-history new-window)
    (metal-buf-deplace--vacate-source source-window source-buffer)
    (metal-buf-deplace--forget-buffer source-window source-buffer)
    (metal-buf-deplace--forget-buffer-everywhere source-buffer new-window)
    (select-window new-window)))

(defun metal-buf-deplace--split-anchor-and-move (source-buffer direction-split)
  (let* ((anchor (or (metal-buf-deplace--pick-main-window)
                     (selected-window)))
         (new-window (split-window anchor nil direction-split)))
    (set-window-buffer new-window source-buffer)
    (metal-buf-deplace--clear-history new-window)
    (metal-buf-deplace--forget-buffer-everywhere source-buffer new-window)
    (select-window new-window)))

;;; Commande principale

(defun metal-buf-deplace (direction-windmove direction-split)
  "Déplace le buffer courant vers la fenêtre en DIRECTION-WINDMOVE.

En l'absence de cible exploitable (side-windows, dédiées et
minibuffer exclus), crée une fenêtre. Si la source est la
dernière fenêtre main ou a un historique à préserver, on la
splitte ; sinon on la supprime et on splitte une autre main.

Avec cible, on déplace le buffer et ferme la source si elle
n'héberge plus rien d'autre, sauf si c'est la dernière main.

Les historiques des autres fenêtres sont nettoyés du buffer
déplacé pour éviter les onglets fantômes."
  (let* ((source-window (selected-window))
         (source-buffer (window-buffer source-window))
         (target-window (metal-buf-deplace--usable-window direction-windmove))
         (autre-buffer-dans-historique
          (cl-some (lambda (entry)
                     (let ((buf (car entry)))
                       (and (buffer-live-p buf)
                            (not (eq buf source-buffer)))))
                   (window-prev-buffers source-window)))
         (source-is-last-main
          (metal-buf-deplace--last-main-window-p source-window)))
    (cond
     ;; Cas 1 : aucune cible -> création
     ((null target-window)
      (cond
       ;; 1a : split de la source (historique riche, dernière main, ou seule)
       ((or (one-window-p)
            source-is-last-main
            autre-buffer-dans-historique)
        (metal-buf-deplace--split-source-and-move
         source-window source-buffer direction-split))
       ;; 1b : suppression de la source + split ailleurs
       (t
        (if (metal-buf-deplace--safe-delete-window source-window)
            (metal-buf-deplace--split-anchor-and-move
             source-buffer direction-split)
          ;; Fallback défensif : suppression impossible, on splitte la source
          (metal-buf-deplace--split-source-and-move
           source-window source-buffer direction-split)))))
     ;; Cas 2 : cible existante -> déplacement
     (t
      (set-window-buffer target-window source-buffer)
      (metal-buf-deplace--vacate-source source-window source-buffer)
      (metal-buf-deplace--forget-buffer source-window source-buffer)
      (metal-buf-deplace--forget-buffer-everywhere source-buffer target-window)
      (select-window target-window)
      (when (and (window-live-p source-window)
                 (not autre-buffer-dans-historique))
        (metal-buf-deplace--safe-delete-window source-window))))))

(defun metal-buf-deplace-haut ()    (interactive) (metal-buf-deplace 'up    'above))
(defun metal-buf-deplace-bas ()  (interactive) (metal-buf-deplace 'down  'below))
(defun metal-buf-deplace-gauche ()  (interactive) (metal-buf-deplace 'left  'left))
(defun metal-buf-deplace-droite () (interactive) (metal-buf-deplace 'right 'right))

(global-set-key (kbd "<S-up>")    #'metal-buf-deplace-haut)
(global-set-key (kbd "<S-down>")  #'metal-buf-deplace-bas)
(global-set-key (kbd "<S-left>")  #'metal-buf-deplace-gauche)
(global-set-key (kbd "<S-right>") #'metal-buf-deplace-droite)

;;; Raccourcis globaux

(global-set-key (kbd "<S-up>")    #'metal-buf-deplace-haut)
(global-set-key (kbd "<S-down>")  #'metal-buf-deplace-bas)
(global-set-key (kbd "<S-left>")  #'metal-buf-deplace-gauche)
(global-set-key (kbd "<S-right>") #'metal-buf-deplace-droite)

(provide 'metal-buf-deplace)

;;; metal-buf-deplace.el ends here
