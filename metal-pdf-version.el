;;; metal-pdf-version.el --- Version pdf-tools -*- lexical-binding: t -*-
;;; -*- coding: utf-8 -*-

;; Author: Jacques Ladouceur
;; Keywords: tools, pdf

;;; Commentary:
;;
;; Source unique de vérité pour la version de pdf-tools retenue par
;; MetalEmacs.  Lue par init.el (le `:commit' de la recette
;; straight.el), par metal-deps.el (affichage) et par
;; metal-pdf-serveur.el (comparaison).
;;
;; FICHIER GÉNÉRÉ — réécrit par `M-x metal-pdfinfo-mise-a-jour'.

;;; Code:

(defconst metal-pdf-version-attendue "1.3.0"
  "Version de pdf-tools épinglée pour toute la distribution.
Le serveur `epdfinfo' installé doit porter cette version, sinon le
Lisp et le binaire se désaccordent.")

(defconst metal-pdf-commit-attendu "5245f092e35712df6559a7782a93bb61896175dd"
  "Commit git correspondant à la balise v`metal-pdf-version-attendue'.
Utilisé comme `:commit' dans la recette straight.el de pdf-tools.")

(provide 'metal-pdf-version)
;;; metal-pdf-version.el ends here
