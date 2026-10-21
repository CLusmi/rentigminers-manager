#!/usr/bin/env bash
# Trouve la derniere version stable de chaque mineur sur sa page GitHub
# officielle et affiche les build-args du Dockerfile (une ligne CLE=VALEUR).
#
# Pour chaque mineur : URL de l'archive Linux + empreinte SHA-256 calculee par
# GitHub au moment ou l'auteur a publie le fichier (champ "digest" de l'API).
# Le Dockerfile refuse toute archive dont l'empreinte ne correspond pas.
#
# Necessite : gh (CLI GitHub, authentifie via GH_TOKEN) et jq.
set -euo pipefail

# cle | depot GitHub officiel | nom du fichier Linux (regex) : archive .tar.gz, ou
# binaire nu (PeakMiner et RGminer publient le binaire Linux tel quel).
MINERS=(
  "SRB|doktor83/SRBMiner-Multi|^SRBMiner-Multi-.*-Linux\\.tar\\.gz$"
  "XMRIG|xmrig/xmrig|^xmrig-[0-9.]+-linux-static-x64\\.tar\\.gz$"
  "FORGE|0xHashRaptor/ForgeMiner|^ForgeMiner-[0-9.]+-linux\\.tar\\.gz$"
  "KRIG|kryptex/krig-miner|^krig-miner-[0-9.]+-linux-x64\\.tar\\.gz$"
  "PEAK|peakminer/peakminer|^peakminer-[0-9.]+-linux-x86_64$"
  "RG|Printscan/rgminer|^rgminer-[0-9.]+$"
)

for entry in "${MINERS[@]}"; do
  IFS='|' read -r key repo pattern <<< "$entry"

  # /releases/latest ignore les pre-releases et les brouillons.
  json=$(gh api "repos/${repo}/releases/latest")

  tag=$(jq -r '.tag_name' <<< "$json")
  matches=$(jq -c --arg re "$pattern" '[.assets[] | select(.name | test($re))]' <<< "$json")
  count=$(jq 'length' <<< "$matches")
  if [[ "$count" -ne 1 ]]; then
    echo "ERREUR: ${repo} ${tag} : ${count} fichier(s) Linux trouve(s) au lieu d'un seul (motif : ${pattern})." >&2
    jq -r '.assets[].name' <<< "$json" >&2
    exit 1
  fi

  url=$(jq -r '.[0].browser_download_url' <<< "$matches")
  digest=$(jq -r '.[0].digest // empty' <<< "$matches")

  if [[ "$url" != "https://github.com/${repo}/releases/download/"* ]]; then
    echo "ERREUR: ${repo} : URL inattendue : ${url}" >&2
    exit 1
  fi
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERREUR: ${repo} ${tag} : pas d'empreinte SHA-256 publiee par GitHub pour $(basename "$url")." >&2
    exit 1
  fi

  echo "${key}_VERSION=${tag}"
  echo "${key}_URL=${url}"
  echo "${key}_SHA256=${digest#sha256:}"
done
