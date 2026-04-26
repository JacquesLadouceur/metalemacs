;; -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jacques Ladouceur
;; Auteur: Jacques Ladouceur
;; Version: 1.1

;; Configuration de calfw (Calendar Framework) pour Emacs
;; Compatible avec use-package + straight.el
;; Tous les calendriers dans ~/.emacs.d/calendriers/
;; ========================================================

;; --- DOSSIER CENTRALISÉ POUR TOUS LES CALENDRIERS ---
(defvar metal-calendrier-directory (expand-file-name "calendriers" user-emacs-directory)
  "Dossier contenant tous les fichiers de calendrier")

;; Créer le dossier s'il n'existe pas
(unless (file-directory-p metal-calendrier-directory)
  (make-directory metal-calendrier-directory t))

;; Fichiers de calendrier - UN SEUL FICHIER pour tout
(defvar metal-calendrier-fichier-org (expand-file-name "calendrier.org" metal-calendrier-directory)
  "Fichier Org unique pour tous les événements (personnels et Google Calendar)")

;; --- DÉSACTIVATION DU CHIFFREMENT GPG (avant tout chargement) ---
(setq plstore-encrypt-to nil)
(setq plstore-select-keys nil)

;; Hack pour contourner complètement GPG si nécessaire
(advice-add 'epg-encrypt-string :override
            (lambda (context plain recipients &optional sign always-trust)
              plain))
(advice-add 'epg-decrypt-string :override
            (lambda (context cipher)
              cipher))

;; Fermer automatiquement le buffer *Keys* s'il apparaît
(add-hook 'epa-key-list-mode-hook
          (lambda ()
            (run-with-timer 0.1 nil
                            (lambda ()
                              (when (get-buffer "*Keys*")
                                (kill-buffer "*Keys*"))))))

;; --- INSTALLATION ET CHARGEMENT DE CALFW ---
(use-package calfw
  :straight (calfw :type git :host github :repo "kiwanami/emacs-calfw"
                   :files ("*.el"))
  :demand t
  :commands (calfw-open-calendar-buffer)
  :init
  (require 'calfw nil t)
  :config
  (require 'calfw-org nil t)
  (require 'calfw-cal nil t)
  (require 'calfw-ical nil t)
  
  ;; Configuration de la langue française
  (setq calendar-week-start-day 1) ; Lundi comme premier jour
  
  ;; Noms des jours et mois en français
  (setq calendar-day-name-array
        ["Dimanche" "Lundi" "Mardi" "Mercredi" "Jeudi" "Vendredi" "Samedi"])
  (setq calendar-day-abbrev-array
        ["Dim" "Lun" "Mar" "Mer" "Jeu" "Ven" "Sam"])
  (setq calendar-month-name-array
        ["Janvier" "Février" "Mars" "Avril" "Mai" "Juin"
         "Juillet" "Août" "Septembre" "Octobre" "Novembre" "Décembre"])
  (setq calendar-month-abbrev-array
        ["Jan" "Fév" "Mar" "Avr" "Mai" "Jun"
         "Jul" "Aoû" "Sep" "Oct" "Nov" "Déc"])
  
  ;; Style du calendrier
  (setq calfw-fchar-junction ?╬
        calfw-fchar-vertical-line ?║
        calfw-fchar-horizontal-line ?═
        calfw-fchar-left-junction ?╠
        calfw-fchar-right-junction ?╣
        calfw-fchar-top-junction ?╦
        calfw-fchar-top-left-corner ?╔
        calfw-fchar-top-right-corner ?╗)
  
  ;; Personnalisation des couleurs
  (custom-set-faces
   '(calfw-face-title ((t (:weight bold :height 2.0 :inherit default))))
   '(calfw-face-header ((t (:weight bold :inherit default))))
   '(calfw-face-sunday ((t :foreground "#cc9393" :weight bold)))
   '(calfw-face-saturday ((t :foreground "#8cd0d3" :weight bold)))
   '(calfw-face-holiday ((t :foreground "#8c5353" :weight bold)))
   '(calfw-face-grid ((t :foreground "#5f5f5f")))
   '(calfw-face-default-content ((t :foreground "black" :background "#d0e8ff")))
   '(calfw-face-periods ((t :foreground "black" :background "#d0e8ff")))
   '(calfw-face-day-title ((t :inherit default)))
   '(calfw-face-default-day ((t :weight bold :inherit default)))
   '(calfw-face-annotation ((t :foreground "black" :background "#d0e8ff")))
   '(calfw-face-disable ((t :foreground "#708090")))
   '(calfw-face-today-title ((t :background "#7f9f7f" :weight bold)))
   '(calfw-face-today ((t :background "#2f4f4f" :weight bold)))
   '(calfw-face-select ((t :background "#2f3f2f")))
   '(calfw-face-toolbar ((t :inherit default)))
   '(calfw-face-toolbar-button-off ((t :weight bold :inherit default)))
   '(calfw-face-toolbar-button-on ((t :weight bold :inherit default)))))

;; Configuration des holidays français
(setq calendar-holidays
      '((holiday-fixed 1 1 "Jour de l'an")
        (holiday-fixed 5 1 "Fête du travail")
        (holiday-fixed 5 8 "Victoire 1945")
        (holiday-fixed 7 14 "Fête nationale")
        (holiday-fixed 8 15 "Assomption")
        (holiday-fixed 11 1 "Toussaint")
        (holiday-fixed 11 11 "Armistice 1918")
        (holiday-fixed 12 25 "Noël")
        (holiday-easter-etc 1 "Lundi de Pâques")
        (holiday-easter-etc 39 "Ascension")
        (holiday-easter-etc 50 "Lundi de Pentecôte")))

;; Créer le fichier calendrier.org s'il n'existe pas
(unless (file-exists-p metal-calendrier-fichier-org)
  (with-temp-file metal-calendrier-fichier-org
    (insert "#+TITLE: Mon Calendrier\n")
    (insert "#+STARTUP: overview\n\n")
    (insert "* Événements personnels\n\n")
    (insert "* Événements importés\n\n")))

;; Ajouter le dossier calendriers à org-agenda-files
(with-eval-after-load 'org
  (setq org-agenda-files (list metal-calendrier-directory)))

;; Variable pour stocker la dernière URL utilisée
(defcustom metal-calendrier-derniere-url-ics ""
  "Dernière URL de calendrier ICS importée"
  :type 'string
  :group 'calendar)

;; Fonction pour importer un calendrier ICS dans calendrier.org
(defun metal-calendrier-importer-ics ()
  "Importe un calendrier ICS dans le fichier calendrier.org"
  (interactive)
  (require 'icalendar)
  (let* ((url (read-string "URL du calendrier ICS à importer: "))
         (temp-ics (make-temp-file "calfw-ics" nil ".ics"))
         (coding-system-for-read 'utf-8)
         (coding-system-for-write 'utf-8))
    (message "Téléchargement du calendrier...")
    (condition-case err
        (progn
          ;; Sauvegarder l'URL pour la synchronisation
          (customize-save-variable 'metal-calendrier-derniere-url-ics url)
          
          (url-copy-file url temp-ics t)
          (message "✓ Calendrier téléchargé")
          
          ;; Parser le fichier ICS
          (let ((events '())
                (org-icalendar-timezone "America/New_York"))
            (with-temp-buffer
              (let ((coding-system-for-read 'utf-8))
                (insert-file-contents temp-ics))
              (decode-coding-region (point-min) (point-max) 'utf-8)
              
              ;; Déplier les lignes de continuation ICS (RFC 5545)
              ;; Les lignes longues sont pliées avec \r\n suivi d'un espace ou tab
              (goto-char (point-min))
              (while (re-search-forward "\r?\n[ \t]" nil t)
                (replace-match ""))
              
              (goto-char (point-min))
              
              ;; Extraire tous les événements
              (while (re-search-forward "BEGIN:VEVENT" nil t)
                (let ((event-start (match-beginning 0))
                      event-end summary dtstart dtend description)
                  (when (re-search-forward "END:VEVENT" nil t)
                    (setq event-end (match-end 0))
                    (save-excursion
                      (goto-char event-start)
                      (when (re-search-forward "SUMMARY:\\(.*\\)" event-end t)
                        (setq summary (match-string 1)))
                      (goto-char event-start)
                      (when (re-search-forward "DESCRIPTION:\\(.*\\)" event-end t)
                        (setq description (match-string 1)))
                      (goto-char event-start)
                      (when (re-search-forward "DTSTART[;:]\\([^\n]+\\)" event-end t)
                        (setq dtstart (match-string 1)))
                      (goto-char event-start)
                      (when (re-search-forward "DTEND[;:]\\([^\n]+\\)" event-end t)
                        (setq dtend (match-string 1))))
                    (when (and summary dtstart)
                      (push (list summary dtstart dtend description) events))))))
            
            ;; Ajouter les événements à calendrier.org
            (with-current-buffer (find-file-noselect metal-calendrier-fichier-org)
              (goto-char (point-max))
              (insert "\n* Importation " (format-time-string "%Y-%m-%d %H:%M") "\n")
              (insert "  Source: " url "\n\n")
              (dolist (event (nreverse events))
                (let* ((summary (car event))
                       (dtstart-raw (cadr event))
                       (description (cadddr event))
                       (date-str (if (string-match "^\\([0-9]\\{8\\}\\)T?\\([0-9]*\\)" dtstart-raw)
                                    (let ((d (match-string 1 dtstart-raw))
                                          (time (match-string 2 dtstart-raw)))
                                      (if (and time (> (length time) 0))
                                          (format "%s-%s-%s %s:%s"
                                                  (substring d 0 4)
                                                  (substring d 4 6)
                                                  (substring d 6 8)
                                                  (substring time 0 2)
                                                  (substring time 2 4))
                                        (format "%s-%s-%s"
                                                (substring d 0 4)
                                                (substring d 4 6)
                                                (substring d 6 8))))
                                  nil)))
                  (when date-str
                    (insert (format "** %s\n" summary))
                    (insert (format "   SCHEDULED: <%s>\n" date-str))
                    (when description
                      (insert (format "   %s\n" description)))
                    (insert "\n"))))
              (save-buffer))
            
            (message "✓ %d événements importés dans %s" 
                     (length events) 
                     metal-calendrier-fichier-org)
            (when (y-or-n-p "Ouvrir le calendrier maintenant ? ")
              (metal-calendrier-ouvrir))))
      (error (message "✗ Erreur lors de l'importation: %s" err)))))

;; Fonction pour synchroniser (ré-importer) le calendrier ICS
(defun metal-calendrier-synchroniser ()
  "Synchronise le calendrier en ré-important le ICS (écrase l'importation précédente)"
  (interactive)
  (if (string-empty-p metal-calendrier-derniere-url-ics)
      (message "Aucune URL sauvegardée. Utilise d'abord M-x metal-calendrier-importer-ics")
    (when (y-or-n-p "Cela va remplacer les événements importés. Continuer ? ")
      ;; Supprimer les anciennes importations
      (with-current-buffer (find-file-noselect metal-calendrier-fichier-org)
        (goto-char (point-min))
        (while (re-search-forward "^\\* Importation [0-9]\\{4\\}" nil t)
          (org-cut-subtree))
        (save-buffer))
      ;; Ré-importer
      (metal-calendrier-importer-ics-avec-url metal-calendrier-derniere-url-ics))))

;; Version interne qui utilise une URL fournie
(defun metal-calendrier-importer-ics-avec-url (url)
  "Importe un calendrier ICS depuis une URL vers calendrier.org"
  (let ((temp-ics (make-temp-file "calfw-ics" nil ".ics"))
        (coding-system-for-read 'utf-8))
    (url-copy-file url temp-ics t)
    (require 'icalendar)
    (let ((events '()))
      (with-temp-buffer
        (insert-file-contents temp-ics)
        (decode-coding-region (point-min) (point-max) 'utf-8)
        
        ;; Déplier les lignes de continuation ICS (RFC 5545)
        (goto-char (point-min))
        (while (re-search-forward "\r?\n[ \t]" nil t)
          (replace-match ""))
        
        (goto-char (point-min))
        (while (re-search-forward "BEGIN:VEVENT" nil t)
          (let ((event-start (match-beginning 0))
                event-end summary dtstart description)
            (when (re-search-forward "END:VEVENT" nil t)
              (setq event-end (match-end 0))
              (save-excursion
                (goto-char event-start)
                (when (re-search-forward "SUMMARY:\\(.*\\)" event-end t)
                  (setq summary (match-string 1)))
                (goto-char event-start)
                (when (re-search-forward "DESCRIPTION:\\(.*\\)" event-end t)
                  (setq description (match-string 1)))
                (goto-char event-start)
                (when (re-search-forward "DTSTART[;:]\\([^\n]+\\)" event-end t)
                  (setq dtstart (match-string 1))))
              (when (and summary dtstart)
                (push (list summary dtstart description) events))))))
      
      (with-current-buffer (find-file-noselect metal-calendrier-fichier-org)
        (goto-char (point-max))
        (insert "\n* Importation " (format-time-string "%Y-%m-%d %H:%M") "\n\n")
        (dolist (event (nreverse events))
          (let* ((summary (car event))
                 (dtstart-raw (cadr event))
                 (description (caddr event))
                 (date-str (if (string-match "^\\([0-9]\\{8\\}\\)T?\\([0-9]*\\)" dtstart-raw)
                              (let ((d (match-string 1 dtstart-raw))
                                    (time (match-string 2 dtstart-raw)))
                                (if (and time (> (length time) 0))
                                    (format "%s-%s-%s %s:%s"
                                            (substring d 0 4)
                                            (substring d 4 6)
                                            (substring d 6 8)
                                            (substring time 0 2)
                                            (substring time 2 4))
                                  (format "%s-%s-%s"
                                          (substring d 0 4)
                                          (substring d 4 6)
                                          (substring d 6 8))))
                            nil)))
            (when date-str
              (insert (format "** %s\n" summary))
              (insert (format "   SCHEDULED: <%s>\n" date-str))
              (when description
                (insert (format "   %s\n" description)))
              (insert "\n"))))
        (save-buffer))
      (message "✓ %d événements importés" (length events))
      (metal-calendrier-ouvrir))))

;; Configuration pour Org-mode
(with-eval-after-load 'org
  (setq calfw-org-agenda-schedule-args
        '(:deadline :scheduled :timestamp)))

;; Fonction pour ajouter un événement dans le calendrier
(defun metal-calendrier-ajouter-evenement ()
  "Ajoute un événement Org à la date sélectionnée et le synchronise avec Google"
  (interactive)
  (let* ((mdy (calfw-cursor-to-nearest-date))
         (month (calendar-extract-month mdy))
         (day (calendar-extract-day mdy))
         (year (calendar-extract-year mdy))
         (title (read-string "Titre de l'événement: "))
         (time-start (read-string "Heure début (HH:MM, vide pour journée entière): "))
         (time-end (if (and time-start (not (string-empty-p time-start)))
                       (read-string "Heure fin (HH:MM): ")
                     ""))
         (date-str (format "%04d-%02d-%02d" year month day))
         ;; Jour en anglais (requis par org-gcal)
         (day-name (let ((calendar-day-name-array
                          ["Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"]))
                     (calendar-day-name (list month day year) t)))
         ;; org-gcal changed variable names over time. Be robust.
         (calendar-id
          (or (caar (bound-and-true-p org-gcal-file-alist))
              (caar (bound-and-true-p org-gcal-fetch-file-alist))
              (read-string "Calendar-id (email Google): ")))
         (timestamp ""))
    ;; Construire le timestamp
    (if (and time-start (not (string-empty-p time-start)))
        (if (and time-end (not (string-empty-p time-end)))
            (setq timestamp (format "<%s %s %s-%s>" date-str day-name time-start time-end))
          ;; Si pas d'heure de fin, ajouter 1h
          (let* ((h (string-to-number (substring time-start 0 2)))
                 (m (substring time-start 3 5))
                 (end-time (format "%02d:%s" (1+ h) m)))
            (setq timestamp (format "<%s %s %s-%s>" date-str day-name time-start end-time))))
      ;; Journée entière
      (setq timestamp (format "<%s %s>" date-str day-name)))
    
    (when (and mdy title (not (string-empty-p title)))
      (with-current-buffer (find-file-noselect metal-calendrier-fichier-org)
        (goto-char (point-max))
        (insert "\n* " title "\n")
        (insert ":PROPERTIES:\n")
        (insert ":calendar-id: " calendar-id "\n")
        (insert ":END:\n")
        ;; Bloc :org-gcal: avec le timestamp (format requis par org-gcal)
        (insert ":org-gcal:\n")
        (insert timestamp "\n")
        (insert ":END:\n")
        (save-buffer))
      (message "Événement '%s' créé. Synchronisation..." title)
      ;; Publier vers Google Calendar
      (with-current-buffer (find-file-noselect metal-calendrier-fichier-org)
        (goto-char (point-max))
        (re-search-backward (concat "^\\* " (regexp-quote title)) nil t)
        ;; Désactiver temporairement le calendrier popup
        (let ((org-read-date-popup-calendar nil))
          (ignore-errors (org-gcal-post-at-point t nil))))
      (when (get-buffer "*Calendrier*")
        (switch-to-buffer "*Calendrier*")
        (calfw-refresh-calendar-buffer nil)))))

;; Fonction pour ajouter une tâche TODO
(defun metal-calendrier-ajouter-todo ()
  "Ajoute une tâche TODO à la date sélectionnée dans le calendrier"
  (interactive)
  (let* ((mdy (calfw-cursor-to-nearest-date))
         (month (calendar-extract-month mdy))
         (day (calendar-extract-day mdy))
         (year (calendar-extract-year mdy))
         (title (read-string "Tâche TODO: "))
         (date-str (format "%04d-%02d-%02d" year month day)))
    (when (and mdy title (not (string-empty-p title)))
      (with-current-buffer (find-file-noselect metal-calendrier-fichier-org)
        (goto-char (point-min))
        ;; Chercher la section "Événements personnels"
        (if (re-search-forward "^\\* Événements personnels" nil t)
            (progn
              (org-end-of-subtree)
              (insert "\n"))
          (goto-char (point-max)))
        (insert "** TODO " title "\n")
        (insert "   DEADLINE: <" date-str ">\n")
        (save-buffer))
      (message "TODO '%s' ajouté avec échéance le %s" title date-str)
      (calfw-refresh-calendar-buffer nil))))

;; Fonction pour synchroniser et rafraîchir le calendrier
(defun metal-calendrier-sync-et-rafraichir ()
  "Synchronise Google Calendar et rafraîchit l'affichage du calendrier"
  (interactive)
  (message "Synchronisation avec Google Calendar...")
  (org-gcal-sync)
  (run-with-timer 2 nil
                  (lambda ()
                    (when (get-buffer "*Calendrier*")
                      (with-current-buffer "*Calendrier*"
                        (calfw-refresh-calendar-buffer nil)))
                    (message "✓ Calendrier synchronisé"))))

;; Fonction pour modifier un événement
(defun metal-calendrier-modifier-evenement ()
  "Ouvre l'événement sous le curseur pour le modifier, puis synchronise avec Google"
  (interactive)
  (let ((date (calfw-cursor-to-nearest-date)))
    (when date
      (find-file metal-calendrier-fichier-org)
      (goto-char (point-min))
      (let ((date-str (format "%04d-%02d-%02d"
                              (calendar-extract-year date)
                              (calendar-extract-month date)
                              (calendar-extract-day date))))
        (if (re-search-forward (concat "<" date-str) nil t)
            (progn
              (org-back-to-heading)
              (org-show-subtree)
              (message "Modifie l'événement, puis 'C-c g p' pour synchroniser avec Google"))
          (message "Aucun événement trouvé à cette date"))))))

;; Fonction pour supprimer un événement
(defun metal-calendrier-supprimer-evenement ()
  "Supprime l'événement sous le curseur et le retire de Google Calendar"
  (interactive)
  (let ((date (calfw-cursor-to-nearest-date)))
    (when date
      (find-file metal-calendrier-fichier-org)
      (goto-char (point-min))
      (let ((date-str (format "%04d-%02d-%02d"
                              (calendar-extract-year date)
                              (calendar-extract-month date)
                              (calendar-extract-day date))))
        (if (re-search-forward (concat "<" date-str) nil t)
            (progn
              ;; Aller au début de la ligne avec le timestamp
              (beginning-of-line)
              ;; Chercher l'en-tête de cet événement (peut être * ou **)
              (if (re-search-backward "^\\*+ " nil t)
                  (let* ((heading-pos (point))
                         (level (org-current-level))
                         (heading-text (org-get-heading t t t t)))
                    (org-show-subtree)
                    (when (y-or-n-p (format "Supprimer '%s' ?" heading-text))
                      ;; Vérifier si l'événement a un entry-id (synchronisé avec Google)
                      (let ((entry-id (org-entry-get nil "entry-id")))
                        (when entry-id
                          ;; Supprimer de Google Calendar (sans confirmation)
                          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                            (ignore-errors (org-gcal-delete-at-point)))))
                      ;; Supprimer seulement ce sous-arbre
                      (org-cut-subtree)
                      (save-buffer)
                      (message "Événement supprimé")
                      (when (get-buffer "*Calendrier*")
                        (switch-to-buffer "*Calendrier*")
                        (calfw-refresh-calendar-buffer nil))))
                (message "En-tête non trouvé")))
          (message "Aucun événement trouvé à cette date"))))))

;; Fonction pour quitter et tuer le buffer calendrier
(defun metal-calendrier-quitter ()
  "Ferme le calendrier et tue le buffer"
  (interactive)
  (let ((buf (current-buffer)))
    (when buf
      (kill-buffer buf))))

;; Hook pour activer tab-line et raccourcis dans le calendrier
(add-hook 'calfw-calendar-mode-hook
          (lambda ()
            (tab-line-mode 1)
            (local-set-key (kbd "i") 'metal-calendrier-ajouter-evenement)
            (local-set-key (kbd "e") 'metal-calendrier-modifier-evenement)
            (local-set-key (kbd "d") 'metal-calendrier-supprimer-evenement)
            (local-set-key (kbd "t") 'metal-calendrier-ajouter-todo)
            (local-set-key (kbd "s") 'metal-calendrier-sync-et-rafraichir)
            (local-set-key (kbd "g") 'calfw-org-goto-date)
            (local-set-key (kbd "q") 'metal-calendrier-quitter)
            (local-set-key (kbd "RET") 'calfw-show-details-command)
            ;; Ajouter la légende après un court délai
            (run-with-timer 0.1 nil #'metal-calendrier-ajouter-legende)))

;; Fonction principale pour ouvrir le calendrier (avec tous les calendriers)
(require 'calfw nil t)
(require 'calfw-org nil t)

;; Fonction pour ajouter la légende au calendrier
(defun metal-calendrier-ajouter-legende ()
  "Ajoute la légende des commandes en bas du calendrier"
  (when (get-buffer "*Calendrier*")
    (with-current-buffer "*Calendrier*"
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        ;; Vérifier si la légende est déjà présente à la fin du buffer
        (unless (save-excursion
                  (forward-line -2)
                  (looking-at ".*Commandes:"))
          (insert "\n")
          (insert "──────────────────────────────────────────────────────────────-----------──────────────\n")
          (insert " Commandes: ")
          (insert (propertize "[i]" 'face '(:weight bold)))
          (insert " Ajouter  ")
          (insert (propertize "[e]" 'face '(:weight bold)))
          (insert " Modifier  ")
          (insert (propertize "[d]" 'face '(:weight bold)))
          (insert " Supprimer  ")
          (insert (propertize "[s]" 'face '(:weight bold)))
          (insert " Sync  ")
          (insert (propertize "[t]" 'face '(:weight bold)))
          (insert " TODO  ")
          (insert (propertize "[g]" 'face '(:weight bold)))
          (insert " Aller à\n")
          (insert "──────────────────────────────────────────────────────────────-----------──────────────\n"))
        (goto-char (point-min))))))

(defun metal-calendrier-ouvrir ()
  "Ouvre le calendrier calfw avec tous les calendriers (personnel + Google)"
  (interactive)
  ;; Tuer l'ancien buffer s'il existe pour éviter les doublons
  (when (get-buffer "*Calendrier*")
    (kill-buffer "*Calendrier*"))
  (calfw-open-calendar-buffer
   :contents-sources
   (list
    (calfw-org-create-source (org-agenda-files) "Agenda" "DarkOrange")))
  (when (get-buffer "*cfw-calendar*")
    (with-current-buffer "*cfw-calendar*"
      (rename-buffer "*Calendrier*" t)))
  ;; Ajouter la légende après un court délai pour s'assurer que le buffer est prêt
  (run-with-timer 0.1 nil #'metal-calendrier-ajouter-legende))

;; Réafficher la légende après chaque rafraîchissement du calendrier
(advice-add 'calfw-refresh-calendar-buffer :after
            (lambda (&rest _) (metal-calendrier-ajouter-legende)))

;; Raccourcis clavier
(global-set-key (kbd "C-c c") 'metal-calendrier-ouvrir)         ; Ouvrir le calendrier
(global-set-key (kbd "C-c C-i") 'metal-calendrier-importer-ics) ; Importer un ICS
(global-set-key (kbd "C-c C-s") 'metal-calendrier-synchroniser) ; Synchroniser le ICS

;; =====================================================
;; CONFIGURATION ORG-GCAL (Google Calendar)
;; =====================================================

(defun metal-calendrier-google-config ()
  "Demande les identifiants org-gcal à l'utilisateur et les enregistre dans un fichier."
  (interactive)
  
  (let* ((config-file (expand-file-name "org-gcal-config.el" user-emacs-directory))
         (client-id (read-string "Votre ID Client Google (client-id) : "))
         (client-secret (read-string "Votre Secret Client Google (client-secret) : "))
         (calendar-id (read-string "ID du calendrier Google (adresse email) : "))
         (content (format
                   ";; -*- lexical-binding: t; -*-
;; Fichier de configuration généré automatiquement pour org-gcal
;; Calendrier unique dans: %s

;; --- 1. Identifiants OAuth 2.0 ---
(setq org-gcal-client-id \"%s\")
(setq org-gcal-client-secret \"%s\")

;; --- 2. Configuration - UN SEUL FICHIER pour tout ---
(setq org-gcal-file-alist
      '((\"%s\" . \"%s\")))

;; Compat ancien org-gcal (si jamais)
(unless (boundp 'org-gcal-fetch-file-alist)
  (setq org-gcal-fetch-file-alist org-gcal-file-alist))
"
                   metal-calendrier-fichier-org
                   client-id client-secret calendar-id metal-calendrier-fichier-org)))
    
    (with-temp-file config-file
      (insert content))
    
    (load-file config-file)
    
    (message "Configuration org-gcal enregistrée. Fichier calendrier: %s"
             metal-calendrier-fichier-org)))

;; --- GESTION DU PACKAGE ORG-GCAL ---
(use-package org-gcal
  :straight t
  :after org
  
  :config
  ;; Charger la config org-gcal si elle existe (apres chargement du paquet)
  (let ((gcal-config-file (expand-file-name "org-gcal-config.el" user-emacs-directory)))
    (when (file-exists-p gcal-config-file)
      (load gcal-config-file nil 'nomessage)))

  ;; Supprimer automatiquement les événements annulés sans demander
  (setq org-gcal-remove-cancelled-events t)
  
  :bind
  (("C-c g s" . org-gcal-sync)          ; Synchronisation bidirectionnelle complète
   ("C-c g f" . org-gcal-fetch)         ; Télécharge les événements de Google
   ("C-c g p" . org-gcal-post-at-point)))

;; Ne PAS synchroniser au démarrage automatiquement (évite les problèmes d'auth)
;; Utilise 's' dans le calendrier pour synchroniser manuellement
;; (add-hook 'emacs-startup-hook
;;           (lambda ()
;;             (run-with-idle-timer 5 nil
;;                                  (lambda ()
;;                                    (ignore-errors (org-gcal-fetch))))))

;; Synchroniser à la fermeture (sans délai)
(add-hook 'kill-emacs-hook
          (lambda ()
            (when (fboundp 'org-gcal-sync)
              (ignore-errors (org-gcal-sync)))))

(with-eval-after-load 'calfw
  (defun calfw--render-truncate (org limit-width &optional ellipsis)
    "Truncate string ORG with ASCII ellipsis."
    (when (and org (> (length org) 0))
      (if (< limit-width (string-width org))
          (concat (truncate-string-to-width
                   (substring org 0) (max 0 (- limit-width 3)) 0 nil nil)
                  "...")
        org))))


;; =====================================================
;; RACCOURCIS DANS LE CALENDRIER
;; =====================================================
;; Navigation :
;;   n / p       : jour suivant / précédent
;;   f / b       : semaine suivante / précédente
;;   N / P       : mois suivant / précédent
;;   g           : aller à une date spécifique
;;
;; Vues :
;;   D           : vue jour
;;   W           : vue semaine
;;   M           : vue mois
;;   T           : vue deux semaines
;;
;; Actions :
;;   i           : ajouter un événement
;;   e           : modifier un événement
;;   d           : supprimer un événement
;;   t           : ajouter une tâche TODO
;;   s           : synchroniser avec Google Calendar
;;   SPC / RET   : voir les détails de l'événement
;;   r           : rafraîchir
;;   q           : quitter
;;   ?           : aide
;;
;; Google Calendar (global) :
;;   C-c g s     : synchroniser avec Google
;;   C-c g f     : récupérer de Google
;;   C-c g p     : publier vers Google
;;
;; =====================================================

(message "Configuration Metal-Calendrier chargée!")
(message "Dossier calendriers: %s" metal-calendrier-directory)
(message "Raccourcis: C-c c (calendrier) | C-c g s (sync Google)")

(provide 'Metal-Calendrier)
