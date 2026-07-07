#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
metal-secretaire-transcribe.py
==============================

Worker de transcription pour le module MetalEmacs `metal-secretaire.el`.

Transcrit un fichier audio d'assemblee deliberante via l'API Gladia v2
(asynchrone), avec diarisation des locuteurs et vocabulaire amorce a partir
de l'ordre du jour. Produit un verbatim Org-mode horodate, avec un tour de
parole par intervenant (Intervenant 1, Intervenant 2, ...).

Usage :
    metal-secretaire-transcribe.py \
        --audio   /chemin/seance.m4a \
        --sortie  /chemin/verbatim.org \
        [--vocabulaire /chemin/lexique.txt] \
        [--contexte  /chemin/contexte.txt] \
        [--langue fr] \
        [--max-locuteurs 40] \
        [--titre "Conseil de departement - 2026-06-08"]

La cle API est lue dans la variable d'environnement GLADIA_API_KEY.

Conventions de sortie (pour parsing en aval par Claude) :
    * En-tete Org avec metadonnees (#+TITLE, #+DATE, duree, locuteurs).
    * Une entree par tour de parole :
        ** [HH:MM:SS] Intervenant N
        Texte du tour de parole.
    * Les etiquettes "Intervenant N" sont stables sur tout le document, ce qui
      permet un re-etiquetage par recherche-remplacement dans Emacs.

Codes de sortie :
    0  succes
    2  erreur de configuration (cle absente, fichier introuvable)
    3  erreur reseau / API
    4  echec de transcription cote Gladia
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import mimetypes
from datetime import datetime, timezone

GLADIA_BASE = "https://api.gladia.io/v2"
POLL_INTERVAL = 4.0          # secondes entre deux interrogations
POLL_TIMEOUT = 60 * 60       # 1 h max d'attente (assemblee longue)


def journal(msg):
    """Ecrit une ligne de progression sur stderr (capturee par Emacs)."""
    horodatage = datetime.now().strftime("%H:%M:%S")
    print(f"[{horodatage}] {msg}", file=sys.stderr, flush=True)


def erreur_fatale(code, msg):
    journal(f"ERREUR : {msg}")
    sys.exit(code)


def lire_fichier_optionnel(chemin):
    if not chemin:
        return None
    if not os.path.isfile(chemin):
        journal(f"Avertissement : fichier introuvable, ignore : {chemin}")
        return None
    with open(chemin, "r", encoding="utf-8") as f:
        return f.read().strip()


def http_post_json(url, payload, cle):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("x-gladia-key", cle)
    with urllib.request.urlopen(req, timeout=120) as rep:
        return json.loads(rep.read().decode("utf-8"))


def http_get_json(url, cle):
    req = urllib.request.Request(url, method="GET")
    req.add_header("x-gladia-key", cle)
    with urllib.request.urlopen(req, timeout=120) as rep:
        return json.loads(rep.read().decode("utf-8"))


def televerser_audio(chemin_audio, cle):
    """Televerse le fichier audio vers Gladia et renvoie l'audio_url."""
    journal(f"Televersement de l'audio : {os.path.basename(chemin_audio)}")
    with open(chemin_audio, "rb") as f:
        contenu = f.read()

    type_mime, _ = mimetypes.guess_type(chemin_audio)
    if not type_mime:
        type_mime = "application/octet-stream"
    nom = os.path.basename(chemin_audio)

    frontiere = "----MetalSecretaireBoundary7e3f9a"
    corps = bytearray()
    corps.extend(f"--{frontiere}\r\n".encode())
    corps.extend(
        f'Content-Disposition: form-data; name="audio"; filename="{nom}"\r\n'.encode()
    )
    corps.extend(f"Content-Type: {type_mime}\r\n\r\n".encode())
    corps.extend(contenu)
    corps.extend(f"\r\n--{frontiere}--\r\n".encode())

    req = urllib.request.Request(f"{GLADIA_BASE}/upload", data=bytes(corps), method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={frontiere}")
    req.add_header("x-gladia-key", cle)
    with urllib.request.urlopen(req, timeout=600) as rep:
        donnees = json.loads(rep.read().decode("utf-8"))
    audio_url = donnees.get("audio_url")
    if not audio_url:
        erreur_fatale(4, f"Reponse d'upload inattendue : {donnees}")
    journal("Televersement termine.")
    return audio_url


def lancer_transcription(audio_url, args, vocabulaire, contexte, cle):
    """POST de transcription, renvoie le result_url a interroger."""
    payload = {
        "audio_url": audio_url,
        "language": args.langue,
        "detect_language": False,
        "diarization": True,
        "diarization_config": {
            "min_speakers": 2,
            "max_speakers": args.max_locuteurs,
        },
        "punctuation_enhanced": True,
    }

    if contexte:
        # Le context_prompt oriente le decodage sans imposer de mots precis :
        # ideal pour le sujet de la seance et le registre (assemblee
        # departementale universitaire).
        payload["context_prompt"] = contexte[:2000]

    if vocabulaire:
        termes = [t.strip() for t in vocabulaire.splitlines() if t.strip()]
        if termes:
            # custom_vocabulary_config : amorce les noms propres, sigles et
            # programmes tires de l'ordre du jour pour reduire les erreurs.
            payload["custom_vocabulary"] = True
            payload["custom_vocabulary_config"] = {
                "vocabulary": [{"value": t} for t in termes],
                "default_intensity": 0.55,
            }
            journal(f"Vocabulaire amorce : {len(termes)} termes.")

    journal("Envoi de la demande de transcription a Gladia...")
    rep = http_post_json(f"{GLADIA_BASE}/transcription", payload, cle)
    result_url = rep.get("result_url")
    ident = rep.get("id", "?")
    if not result_url:
        erreur_fatale(4, f"Pas de result_url dans la reponse : {rep}")
    journal(f"Transcription en file d'attente (id={ident}).")
    return result_url


def attendre_resultat(result_url, cle):
    """Interroge result_url jusqu'a status=done ou error."""
    debut = time.time()
    dernier_statut = None
    while True:
        if time.time() - debut > POLL_TIMEOUT:
            erreur_fatale(3, "Delai d'attente depasse (1 h).")
        rep = http_get_json(result_url, cle)
        statut = rep.get("status")
        if statut != dernier_statut:
            journal(f"Statut : {statut}")
            dernier_statut = statut
        if statut == "done":
            return rep
        if statut == "error":
            detail = rep.get("error_code") or rep.get("error") or rep
            erreur_fatale(4, f"Echec cote Gladia : {detail}")
        time.sleep(POLL_INTERVAL)


def fmt_horodatage(secondes):
    if secondes is None:
        return "00:00:00"
    s = int(round(secondes))
    h, reste = divmod(s, 3600)
    m, s = divmod(reste, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def construire_verbatim_org(resultat, args):
    """Transforme la reponse Gladia en Org horodate par tour de parole.

    En mode --fragment (defaut pour metal-secretaire), produit UNIQUEMENT le
    corps : des sous-titres de niveau 2 (** [HH:MM:SS] Intervenant N), sans
    en-tete #+TITLE ni titre de niveau 1.  Le module Emacs fournit lui-meme
    la ligne « * Verbatim » et insere ce corps dessous, dans le .sec.

    Sans --fragment, produit un document Org autonome avec en-tete complet.
    """
    transcription = resultat.get("result", {}).get("transcription", {})
    utterances = transcription.get("utterances", [])
    metadata = resultat.get("result", {}).get("metadata", {})
    duree = metadata.get("audio_duration")

    correspondance = {}
    compteur = 0
    lignes = []

    titre = args.titre or os.path.splitext(os.path.basename(args.audio))[0]
    fragment = getattr(args, "fragment", False)

    if not fragment:
        date_iso = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
        lignes.append(f"#+TITLE: Verbatim — {titre}")
        lignes.append(f"#+DATE: {date_iso}")
        lignes.append("#+STARTUP: showeverything")
        lignes.append("#+OPTIONS: toc:nil num:nil")
        lignes.append("")
        lignes.append("# Verbatim brut horodate produit par metal-secretaire (Gladia).")
        lignes.append("# Les etiquettes « Intervenant N » sont stables : re-etiquetez")
        lignes.append("# (bouton 🏷️ ou M-%) pour nommer les personnes.")
        lignes.append("")

    if not utterances:
        texte_plein = transcription.get("full_transcript", "").strip()
        # Sous-titre niveau 2 en mode fragment, niveau 1 sinon.
        prefixe = "**" if fragment else "*"
        lignes.append(f"{prefixe} Transcription (sans separation de locuteurs)")
        lignes.append("")
        lignes.append(texte_plein if texte_plein else "(aucun contenu transcrit)")
        return "\n".join(lignes) + "\n", 0, duree

    for u in utterances:
        brut = u.get("speaker")
        cle_loc = str(brut) if brut is not None else "?"
        if cle_loc not in correspondance:
            compteur += 1
            correspondance[cle_loc] = f"Intervenant {compteur}"
        etiquette = correspondance[cle_loc]
        debut = fmt_horodatage(u.get("start"))
        texte = (u.get("text") or "").strip()
        lignes.append(f"** [{debut}] {etiquette}")
        lignes.append(texte)
        lignes.append("")

    return "\n".join(lignes) + "\n", compteur, duree


def main():
    ap = argparse.ArgumentParser(description="Transcription Gladia pour metal-secretaire.")
    ap.add_argument("--audio", required=True)
    ap.add_argument("--sortie", required=True)
    ap.add_argument("--vocabulaire", default=None)
    ap.add_argument("--contexte", default=None)
    ap.add_argument("--langue", default="fr")
    ap.add_argument("--max-locuteurs", type=int, default=40)
    ap.add_argument("--titre", default=None)
    ap.add_argument("--fragment", action="store_true",
                    help="Produire le corps seul (sous-titres niveau 2), "
                         "sans en-tete Org ni titre de niveau 1.")
    args = ap.parse_args()

    cle = os.environ.get("GLADIA_API_KEY", "").strip()
    if not cle:
        erreur_fatale(2, "Variable d'environnement GLADIA_API_KEY absente.")
    if not os.path.isfile(args.audio):
        erreur_fatale(2, f"Fichier audio introuvable : {args.audio}")

    vocabulaire = lire_fichier_optionnel(args.vocabulaire)
    contexte = lire_fichier_optionnel(args.contexte)

    journal("=== metal-secretaire : debut de la transcription ===")
    audio_url = televerser_audio(args.audio, cle)
    result_url = lancer_transcription(audio_url, args, vocabulaire, contexte, cle)
    resultat = attendre_resultat(result_url, cle)

    verbatim, n_loc, duree = construire_verbatim_org(resultat, args)
    with open(args.sortie, "w", encoding="utf-8") as f:
        f.write(verbatim)

    duree_txt = fmt_horodatage(duree) if duree else "inconnue"
    journal(f"Verbatim ecrit : {args.sortie}")
    journal(f"Duree audio : {duree_txt} — locuteurs distincts : {n_loc}")
    journal("=== Transcription terminee avec succes ===")
    sys.exit(0)


if __name__ == "__main__":
    main()
