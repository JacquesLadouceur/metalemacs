;;; metal-utile.el --- Utilitaires partagés pour MetalEmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;;; Commentary:
;; Module de fonctions utilitaires partagées entre les différents modules
;; MetalEmacs. Ce module ne doit dépendre d'aucun autre module `metal-*'
;; pour pouvoir être chargé le plus tôt possible.
;;
;; Fonctions exposées :
;; - `metal-util-run-in-eat' : exécuter une commande shell dans un buffer
;;   adapté au système (Eat sur macOS/Linux, async-shell-command sur Windows
;;   puisque Eat ne supporte pas Windows nativement).

;;; Code:

(require 'cl-lib)

;;; ═══════════════════════════════════════════════════════════════════
;;; Installation et configuration de Eat (émulateur de terminal)
;;; ═══════════════════════════════════════════════════════════════════
;; Eat est utilisé par `metal-util-run-in-eat' pour exécuter les commandes
;; shell qui ont besoin d'un vrai TTY (progress bars, confirmations y/n,
;; couleurs ANSI). Également accessible via `C-c t' pour ouvrir un shell
;; interactif à la main.
;;
;; Eat ne supporte PAS Windows nativement (voir issue #35 du dépôt
;; emacs-eat). Sur Windows, on ne l'installe pas et `metal-util-run-in-eat'
;; utilise `async-shell-command' comme fallback automatique.

(unless (eq system-type 'windows-nt)
  (use-package eat
    :ensure t
    :bind ("C-c t" . eat)
    :hook (eat-mode . (lambda () (setq-local buffer-file-coding-system 'utf-8)))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Variables d'environnement pour améliorer l'affichage TTY
;;; ═══════════════════════════════════════════════════════════════════

(defconst metal-util--tty-env-vars
  '("FORCE_COLOR=1"         ; npm, et beaucoup d'outils
    "CLICOLOR_FORCE=1"      ; outils macOS (ls, grep...)
    "PY_COLORS=1"           ; pip
    "PIP_PROGRESS_BAR=on"   ; pip progress bar visible
    "PYTHONUNBUFFERED=1")   ; flush stdout immédiatement
  "Variables d'environnement à injecter pour que les commandes affichent
couleurs, progress bars, et lignes bien formatées, même quand elles ne
tournent pas sur un vrai TTY.")

;;; ═══════════════════════════════════════════════════════════════════
;;; Sentinel de fermeture automatique (partagé Unix/Windows)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-util--installer-sentinel-fermeture (proc)
  "Chaîner un sentinel sur PROC qui ferme le buffer et sa fenêtre à la fin.

Préserve le sentinel existant (utile pour Eat qui met à jour sa modeline).
Après terminaison du processus, supprime la fenêtre si elle a été créée
spécifiquement pour ce buffer, sinon restaure le buffer précédent."
  (when proc
    (let ((ancien-sentinel (process-sentinel proc)))
      (set-process-sentinel
       proc
       (lambda (process event)
         ;; Laisser le sentinel précédent faire son cleanup d'abord
         (when ancien-sentinel
           (funcall ancien-sentinel process event))
         ;; Puis fermer le buffer (et sa fenêtre) si le processus est terminé
         (when (memq (process-status process) '(exit signal))
           (let ((pbuf (process-buffer process)))
             (run-at-time
              0.1 nil
              (lambda ()
                (when (buffer-live-p pbuf)
                  (let ((kill-buffer-query-functions nil))
                    ;; quit-window : supprime la fenêtre si créée pour ce
                    ;; buffer, sinon restaure le buffer précédent.
                    ;; L'argument t demande aussi de tuer le buffer.
                    (dolist (win (get-buffer-window-list pbuf nil t))
                      (with-selected-window win
                        (quit-window t)))
                    ;; Fallback si le buffer n'était affiché nulle part
                    (when (buffer-live-p pbuf)
                      (kill-buffer pbuf)))))))))))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Implémentation Unix (macOS / Linux) : via Eat
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-util--run-in-eat-unix (cmd buf-name auto-close)
  "Exécuter CMD dans un buffer Eat (macOS / Linux)."
  ;; `require' nécessaire : use-package charge Eat en deferred (via :bind),
  ;; donc `eat-exec' / `eat-mode' ne sont pas autoloadés tant que
  ;; l'utilisateur n'a pas tapé C-c t. `require' est idempotent.
  (require 'eat)
  (let* ((shell (or explicit-shell-file-name
                    (getenv "ESHELL")
                    (getenv "SHELL")
                    "/bin/bash"))
         (wrapped-cmd
          (if auto-close
              ;; printf + read : syntaxe POSIX qui marche en bash, zsh, sh, dash.
              ;; `read -p' est spécifique à bash et casse sous zsh.
              (format "%s; echo; printf 'Appuyez sur Entrée pour fermer...'; read _" cmd)
            ;; Sans auto-close : shell interactif après la commande pour
            ;; permettre à l'utilisateur d'inspecter/rejouer.
            (format "%s; echo; echo '--- Commande terminée. Tapez exit ou fermez le buffer. ---'; exec %s -i"
                    cmd shell)))
         (buf (get-buffer-create buf-name))
         (process-environment (append metal-util--tty-env-vars process-environment)))
    (with-current-buffer buf
      ;; Si un processus Eat tourne déjà dans ce buffer, le tuer proprement
      (when (and (eq major-mode 'eat-mode)
                 (bound-and-true-p eat-terminal)
                 (eat-term-live-p eat-terminal))
        (eat--kill-process))
      (unless (eq major-mode 'eat-mode)
        (eat-mode))
      ;; eat-exec : (BUFFER NAME PROGRAM STARTFILE SWITCHES)
      (eat-exec buf buf-name shell nil (list "-c" wrapped-cmd))
      ;; Si auto-close, chaîner un sentinel pour fermer le buffer/fenêtre
      (when auto-close
        (metal-util--installer-sentinel-fermeture (get-buffer-process buf))))
    (pop-to-buffer buf)
    buf))

;;; ═══════════════════════════════════════════════════════════════════
;;; Implémentation Windows : via async-shell-command (Eat non supporté)
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-util--run-in-shell-windows (cmd buf-name auto-close)
  "Exécuter CMD via `async-shell-command' (fallback pour Windows).

Eat ne supporte pas Windows nativement (voir issue #35 du dépôt
emacs-eat). On utilise donc le mécanisme standard d'Emacs. Ça
fonctionne pour la plupart des commandes non interactives. Les
couleurs et progress bars de pip/conda sont activées via les
variables d'environnement (`metal-util--tty-env-vars')."
  (let* ((buf (get-buffer-create buf-name))
         (process-environment (append metal-util--tty-env-vars process-environment))
         ;; Si auto-close, ajouter `pause' pour que l'utilisateur voie la
         ;; sortie avant fermeture. Sinon, laisser la commande se terminer
         ;; normalement ; le buffer restera lisible après coup.
         (cmd-final (if auto-close
                        (format "%s & echo. & pause" cmd)
                      cmd)))
    (async-shell-command cmd-final buf)
    (when auto-close
      ;; Installer le sentinel de fermeture sur le process async
      (let ((proc (get-buffer-process buf)))
        (when proc
          (metal-util--installer-sentinel-fermeture proc))))
    buf))

;;; ═══════════════════════════════════════════════════════════════════
;;; API publique : dispatch selon le système
;;; ═══════════════════════════════════════════════════════════════════

(defun metal-util-run-in-eat (cmd &optional buf-name auto-close)
  "Exécuter CMD dans un terminal adapté au système.

CMD est une commande shell (string).

BUF-NAME est le nom du buffer d'affichage (défaut : \"*Metal Eat*\").

AUTO-CLOSE contrôle le comportement à la fin de la commande :
- nil (défaut) : le buffer reste ouvert. Sur Unix, un shell interactif
  prend le relais pour permettre inspection/rejouer. Sur Windows, le
  buffer reste ouvert en lecture seule. Convient pour les commandes
  d'installation longues où on veut pouvoir revoir ce qui s'est passé.
- t : invite « Appuyez sur Entrée pour fermer... » puis fermeture
  automatique du buffer et de sa fenêtre. Convient pour les commandes
  courtes et simples.

Variables d'environnement injectées automatiquement :
FORCE_COLOR, CLICOLOR_FORCE, PY_COLORS, PIP_PROGRESS_BAR, PYTHONUNBUFFERED.
Ces variables activent les couleurs et améliorent l'affichage pour pip,
conda, et de nombreux outils CLI.

Implémentation :
- macOS/Linux : utilise Eat (émule un vrai terminal, confirmations y/n,
  shell utilisateur invoqué avec initialisation Conda).
- Windows : Eat n'étant pas supporté, utilise `async-shell-command'.

Retourne le buffer créé."
  (let ((buf-name (or buf-name "*Metal Eat*")))
    (if (eq system-type 'windows-nt)
        (metal-util--run-in-shell-windows cmd buf-name auto-close)
      (metal-util--run-in-eat-unix cmd buf-name auto-close))))

;;; ═══════════════════════════════════════════════════════════════════
;;; Correctif : clic fermer onglet dans shell-mode
;;; ═══════════════════════════════════════════════════════════════════
;; Dans `shell-mode' (utilisé par async-shell-command, donc par
;; metal-conda-shell sur Windows), le clic sur le `×' de tab-line
;; génère `<tab-line> S-<mouse-1>' qui n'est pas lié par défaut —
;; résultat : erreur « S-<mouse-1> is undefined » et rien ne se
;; passe. On ajoute le binding standard `tab-line-close-tab' qui
;; demande confirmation si un process tourne (comportement attendu).

(with-eval-after-load 'shell
  (define-key shell-mode-map [tab-line S-mouse-1] #'tab-line-close-tab))

(provide 'metal-utile)

;;; metal-utile.el ends here
