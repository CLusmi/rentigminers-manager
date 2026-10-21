#!/usr/bin/env bash
# Lance un mineur sur les GPU (SRBMiner-MULTI, ForgeMiner, krig, PeakMiner ou RGminer)
# et/ou un mineur sur le CPU (XMRig ou SRBMiner-MULTI). Les arguments sont passes aux
# mineurs tels quels.
#
# Rien n'est lance par defaut : un cote demarre seulement si SON mineur ET SES
# arguments sont renseignes. GPU seul, CPU seul ou les deux, au choix.
#
# Variables :
#   GPU_MINER      srbminer | forgeminer | krigminer | peakminer | rgminer
#   GPU_ARGS       arguments du mineur GPU, dans SA syntaxe (voir README.md) :
#                  srbminer   --algorithm pearlhash --pool POOL:PORT --wallet ADRESSE --worker NOM
#                  forgeminer --algorithm pearlhash --pool POOL:PORT --wallet ADRESSE --worker NOM
#                  krigminer  --url POOL:PORT --user ADRESSE.NOM
#                  peakminer  --coin pearl -o POOL:PORT -u ADRESSE -w NOM
#                  rgminer    --algo pearl --proto herominers --stratum POOL:PORT --wallet ADRESSE --worker NOM
#   CPU_MINER      xmrig | srbminer
#   CPU_ARGS       arguments du mineur CPU
#                  ex. --coin monero -o xmr.kryptex.network:7029 -u ADRESSE/RENT -t 184 -k
#   RESTART_DELAY  secondes avant relance d'un mineur qui s'arrete (defaut 10)
#   DRY_RUN=1      affiche les commandes finales sans lancer les mineurs
#
# Hashrate dans les logs : SRBMiner ecrit lui-meme une ligne « GPU0 RTX 5090: 342.10 TH/s ».
# Pour les autres mineurs, ce script lit leur API de statistiques (HTTP, locale) toutes
# les 30 s et ecrit la meme ligne, au meme format, pour que les outils (Salad-Switch-Log,
# Vast-Switch-Log) lisent le hashrate de la meme facon quel que soit le mineur.
# RGminer : lecture complete (API documentee). ForgeMiner, krig, PeakMiner : la premiere
# reponse de l'API est recopiee telle quelle dans les logs, en attendant leur lecture.
#
# Chien de garde SaladCloud (actif seulement sur Salad, c'est-a-dire si Salad a
# injecte SALAD_MACHINE_ID, seulement si SALAD_WATCHDOG est renseigne, et pour
# l'instant seulement avec GPU_MINER=srbminer) :
#   SALAD_WATCHDOG      observe   : surveille et ecrit ses verdicts dans le log, sans agir
#                       reallocate: demande a Salad de deplacer le conteneur sur une
#                                   autre machine quand une regle se declenche
#   SALAD_MIN_HASHRATE  seuils par modele de carte, ex. 5090=300T,4090=250T,3090=100T
#                       (K, M, G, T = kilo/mega/giga/tera hash par seconde) ; une carte
#                       dont le modele n'est pas dans la liste n'est pas surveillee
#   SALAD_GRACE         secondes de repit apres chaque (re)demarrage du mineur GPU (defaut 300)
#   SALAD_BAD_READINGS  lectures consecutives sous le seuil avant verdict (defaut 3)
#   SALAD_MAX_RESTARTS  verdict si le mineur GPU redemarre au moins N fois en 10 min (defaut : inactif)
#   SALAD_ZERO_READINGS verdict apres N lectures consecutives a 0 H/s (defaut 2 ; 0 = inactif)
#   SALAD_STALE_MINUTES verdict apres N minutes sans nouvelle statistique du mineur GPU
#                       (defaut 2, ou deux fois l'intervalle entre deux statistiques si plus long ; 0 = inactif)
#
# Options ajoutees automatiquement, sauf si elles sont deja dans tes arguments :
#   SRBMiner GPU : --disable-cpu --log-file
#   ForgeMiner   : --no-color --api-bind 127.0.0.1:7777
#   krig         : --no-tui --no-rocm --api-port 12000
#   PeakMiner    : --no-color   (son API est deja active sur 127.0.0.1:4068)
#   RGminer      : --plain-console --api-host 127.0.0.1 --api-port 9200 --watchdog=off
#   SRBMiner CPU : --disable-gpu --disable-numa-binding --log-file (dans un dossier a part)
#   XMRig        : --randomx-no-numa --no-color
#
# Avec des arguments (docker run image --help), le mineur GPU est lance directement
# avec ces arguments (MINER=forgeminer pour en choisir un autre que SRBMiner) ; une
# commande (bash, nvidia-smi) est executee.
set -uo pipefail

MINERS_DIR=/opt/miners
srb="$MINERS_DIR/srbminer/SRBMiner-MULTI"
xmrig="$MINERS_DIR/xmrig/xmrig"
forge="$MINERS_DIR/forgeminer/forge"
krig="$MINERS_DIR/krigminer/krig-miner"
peak="$MINERS_DIR/peakminer/peakminer"
rg="$MINERS_DIR/rgminer/rgminer"

log() { echo "[rentingminers] $*"; }
die() { echo "[rentingminers] ERREUR: $*" >&2; exit 1; }

# Nom canonique d'un mineur GPU (accepte quelques raccourcis), ou vide s'il est inconnu.
gpu_miner_name() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    srb|srbminer|srbminer-multi) echo srbminer ;;
    forge|forgeminer)            echo forgeminer ;;
    krig|krigminer|krig-miner)   echo krigminer ;;
    peak|peakminer)              echo peakminer ;;
    rg|rgminer)                  echo rgminer ;;
    *) echo "" ;;
  esac
}

# Chemin du binaire d'un mineur GPU (nom canonique).
gpu_miner_binary() {
  case "$1" in
    srbminer)   echo "$srb" ;;
    forgeminer) echo "$forge" ;;
    krigminer)  echo "$krig" ;;
    peakminer)  echo "$peak" ;;
    rgminer)    echo "$rg" ;;
  esac
}

# Mode direct : arguments passes au conteneur.
if [[ $# -gt 0 ]]; then
  if [[ "$1" != -* ]] && command -v "$1" >/dev/null 2>&1; then
    exec "$@"
  fi
  direct=$(gpu_miner_name "${MINER:-srbminer}")
  [[ -n "$direct" ]] || die "MINER=${MINER} inconnu. Valeurs possibles : srbminer, forgeminer, krigminer, peakminer, rgminer."
  exec "$(gpu_miner_binary "$direct")" "$@"
fi

log "Versions installees : $(tr '\n' ' ' < "$MINERS_DIR/VERSIONS")"

# --- Variables recues ------------------------------------------------------------
# Vast.ai peut injecter, en plus du template, les variables du template d'origine
# de la location. Les anciens noms sont donc ignores (avec un avertissement),
# seuls GPU_MINER, GPU_ARGS, CPU_MINER et CPU_ARGS comptent.
present=()
absent=()
for name in GPU_MINER GPU_ARGS CPU_MINER CPU_ARGS; do
  if [[ -n "${!name:-}" ]]; then present+=("$name"); else absent+=("$name"); fi
done
log "Variables recues : ${present[*]:-aucune}${absent[*]:+ ; absentes : ${absent[*]}}"
old_vars=()
for name in MINER COIN ALGO POOL WALLET WORKER PASS EXTRA_ARGS \
            CPU_POOL CPU_WALLET CPU_WORKER CPU_THREADS CPU_ALGO CPU_COIN CPU_EXTRA_ARGS; do
  [[ -n "${!name:-}" ]] && old_vars+=("$name")
done
if [[ ${#old_vars[@]} -gt 0 ]]; then
  log "ATTENTION : variables d'une ancienne version ignorees : ${old_vars[*]} (cette version n'utilise que GPU_MINER, GPU_ARGS, CPU_MINER et CPU_ARGS)."
fi

# --- Outils ----------------------------------------------------------------------

# Decoupe une chaine d'arguments en tableau, en respectant les guillemets
# ("mot de passe avec espace"). Resultat dans le tableau nomme par $2.
split_args() {
  local text="$1" target="$2" out
  local -a parsed=()
  # Guillemets autour de toute la valeur (l'interface de vast.ai peut les garder
  # quand la variable vient du champ Docker Options) : retires.
  if [[ "$text" =~ ^[[:space:]]*\"([^\"]*)\"[[:space:]]*$ || "$text" =~ ^[[:space:]]*\'([^\']*)\'[[:space:]]*$ ]]; then
    text="${BASH_REMATCH[1]}"
  fi
  if [[ -n "${text// /}" ]]; then
    out=$(printf '%s' "$text" | xargs printf '%s\n' 2>/dev/null) \
      || die "impossible de lire les arguments : guillemet non ferme ? ($text)"
    mapfile -t parsed <<< "$out"
  fi
  eval "$target=(\"\${parsed[@]}\")"
}

# Affiche une commande, en remettant des guillemets autour des valeurs qui en ont besoin.
show_cmd() {
  local out="" arg
  for arg in "$@"; do
    if [[ "$arg" == *[[:space:]\"\'\$]* || -z "$arg" ]]; then out+=" \"${arg//\"/\\\"}\""; else out+=" $arg"; fi
  done
  echo "${out# }"
}

# Vrai si l'option $1 figure deja dans les arguments ($2...), seule ou en --opt=valeur.
has_opt() {
  local opt="$1" arg
  shift
  for arg in "$@"; do
    [[ "$arg" == "$opt" || "$arg" == "$opt="* ]] && return 0
  done
  return 1
}

# Valeur qui suit l'option $1 dans les arguments ($2...), ou vide.
opt_value() {
  local opt="$1" prev="" arg
  shift
  for arg in "$@"; do
    [[ "$prev" == "$opt" ]] && { echo "$arg"; return; }
    [[ "$arg" == "$opt="* ]] && { echo "${arg#*=}"; return; }
    prev="$arg"
  done
}

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# --- Chien de garde Salad : outils ----------------------------------------------
wlog() { echo "[salad] $*"; }

# Retire les codes couleur et d'eventuels guillemets autour de la ligne.
strip_ansi() { sed -e $'s/\e\\[[0-9;]*[A-Za-z]//g' -e 's/^"//' -e 's/"$//'; }

# Convertit une valeur et son unite (K, M, G, T ou vide) en hash par seconde (entier).
hs_value() {
  awk -v v="$1" -v u="$2" 'BEGIN {
    m = 1; u = toupper(u)
    if (u == "K") m = 1e3; else if (u == "M") m = 1e6; else if (u == "G") m = 1e9; else if (u == "T") m = 1e12
    printf "%.0f", v * m
  }'
}

# Vrai si $1 < $2 (grands entiers).
hs_less() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

# Lit un seuil ecrit « 300T », « 250 TH/s », « 100T » ; affiche la valeur en H/s.
parse_threshold() {
  local spec="$1"
  if [[ "$spec" =~ ^([0-9]+(\.[0-9]+)?)[[:space:]]*([KkMmGgTt]?)([Hh](/[Ss])?)?$ ]]; then
    hs_value "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# Derniere ligne de statistiques GPU de SRBMiner dans le log ($1), nettoyee.
# Formats reconnus :  GPU0 RTX 5090: 342.10 TH/s [T:71C ...]   (ligne compacte)
#                     #0 RTX 5090 342.10 TH/s 400.0W ...         (ligne du tableau)
wd_last_reading() {
  tail -n 300 "$1" 2>/dev/null | strip_ansi \
    | grep -aE '(GPU[0-9]+[[:space:]]+[^:]+:|#[0-9]+[[:space:]]+[^[:space:]]).*[0-9][[:space:]]*[KkMmGgTt]?[Hh]/s' \
    | tail -n 1
}

# Decoupe une ligne de statistiques en modele / valeur / unite (variables wd_model,
# wd_value, wd_unit). Vrai si la ligne est comprise.
wd_parse_reading() {
  local line="$1"
  if [[ "$line" =~ GPU[0-9]+[[:space:]]+([^:]+):[[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]*([KkMmGgTt]?)[Hh]/s ]] \
     || [[ "$line" =~ \#[0-9]+[[:space:]]+(.+[^[:space:]])[[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]*([KkMmGgTt]?)[Hh]/s ]]; then
    wd_model="${BASH_REMATCH[1]}"
    wd_value="${BASH_REMATCH[2]}"
    wd_unit="${BASH_REMATCH[4]}"
    wd_model="${wd_model#"${wd_model%%[![:space:]]*}"}"
    wd_model="${wd_model%"${wd_model##*[![:space:]]}"}"
    return 0
  fi
  return 1
}

# Seuil (tel qu'ecrit par l'utilisateur) pour un modele de carte, premiere cle qui
# apparait dans le nom du modele ; rien si le modele n'est pas dans la liste.
wd_threshold_for() {
  local model i
  model=$(lower "$1")
  for i in "${!wd_keys[@]}"; do
    if [[ "$model" == *"${wd_keys[$i]}"* ]]; then
      echo "${wd_specs[$i]}"
      return 0
    fi
  done
  return 1
}

# Demande a Salad de deplacer ce conteneur (IMDS). Vrai si Salad a accepte (204).
# La variable wd_http recoit la ligne de statut HTTP ou l'erreur.
wd_request_reallocate() {
  local reason body out rc
  reason=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | cut -c1-900)
  body="{\"reason\":\"$reason\"}"
  out=$(wget -q -S -O /dev/null --timeout=10 --tries=1 --method=POST \
          --header='Metadata: true' --header='Content-Type: application/json' \
          --body-data="$body" "${SALAD_IMDS_URL:-http://169.254.169.254}/v1/reallocate" 2>&1)
  rc=$?
  wd_http=$(printf '%s\n' "$out" | grep -m1 -oE 'HTTP/[0-9.]+ [0-9]{3}.*' | sed 's/[[:space:]]*$//')
  [[ -z "$wd_http" ]] && wd_http="pas de reponse (code wget $rc)"
  [[ $rc -eq 0 ]]
}

# --- Qu'est-ce qui doit tourner ? -----------------------------------------------
# Un cote est actif seulement si son mineur ET ses arguments sont renseignes.
# Une variable seule est refusee : rien ne demarre sans choix explicite.
gpu_on=0
cpu_on=0
if [[ -n "${GPU_MINER:-}" && -n "${GPU_ARGS:-}" ]]; then gpu_on=1
elif [[ -n "${GPU_MINER:-}" ]]; then die "GPU_MINER est renseigne mais GPU_ARGS manque (ou vide)."
elif [[ -n "${GPU_ARGS:-}" ]]; then die "GPU_ARGS est renseigne mais GPU_MINER manque (GPU_MINER=srbminer, forgeminer, krigminer, peakminer ou rgminer)."
fi
if [[ -n "${CPU_MINER:-}" && -n "${CPU_ARGS:-}" ]]; then cpu_on=1
elif [[ -n "${CPU_MINER:-}" ]]; then die "CPU_MINER est renseigne mais CPU_ARGS manque (ou vide)."
elif [[ -n "${CPU_ARGS:-}" ]]; then die "CPU_ARGS est renseigne mais CPU_MINER manque (CPU_MINER=xmrig ou srbminer)."
fi
if [[ $gpu_on -eq 0 && $cpu_on -eq 0 ]]; then
  die "rien a miner : renseigne GPU_MINER + GPU_ARGS (GPU), CPU_MINER + CPU_ARGS (CPU), ou les deux."
fi

# --- GPU : SRBMiner, ForgeMiner, krig, PeakMiner ou RGminer -----------------------
gpu_cmd=()
gpu_log=""
gpu_miner=""
# API de statistiques du mineur GPU (rapport de hashrate, voir plus bas) : URL(s) locales
# a interroger, dans l'ordre. Vide pour SRBMiner (il ecrit lui-meme son hashrate).
gpu_api_urls=()
if [[ $gpu_on -eq 1 ]]; then
  [[ "$(lower "$GPU_MINER")" == xmrig ]] && die "GPU_MINER=xmrig : XMRig ne mine que sur CPU. Pour le GPU : srbminer, forgeminer, krigminer, peakminer ou rgminer."
  gpu_miner=$(gpu_miner_name "$GPU_MINER")
  [[ -n "$gpu_miner" ]] || die "GPU_MINER=${GPU_MINER} inconnu. Valeurs possibles : srbminer, forgeminer, krigminer, peakminer, rgminer."
  gpu_bin=$(gpu_miner_binary "$gpu_miner")
  [[ -x "$gpu_bin" ]] || die "binaire introuvable : $gpu_bin"
  split_args "$GPU_ARGS" gpu_user
  gpu_cmd=("$gpu_bin")
  case "$gpu_miner" in
    srbminer)
      has_opt --disable-cpu "${gpu_user[@]}" || gpu_cmd+=(--disable-cpu)
      # SRBMiner n'ecrit rien sur la sortie standard hors terminal : on passe par son
      # fichier de log, recopie dans les logs du conteneur plus bas.
      gpu_log=$(opt_value --log-file "${gpu_user[@]}")
      if [[ -z "$gpu_log" ]]; then
        gpu_log="$PWD/srbminer-gpu.log"
        gpu_cmd+=(--log-file "$gpu_log")
      elif [[ "$gpu_log" != /* ]]; then
        gpu_log="$PWD/$gpu_log"
      fi
      ;;
    forgeminer)
      # Sans console, ForgeMiner passe de lui-meme en texte brut ; --no-color le garantit.
      has_opt --no-color "${gpu_user[@]}" || has_opt --plain "${gpu_user[@]}" || gpu_cmd+=(--no-color)
      # API de stats : --api (127.0.0.1:7777) ou --api-bind HOTE:PORT.
      api_port=7777
      if has_opt --api-bind "${gpu_user[@]}"; then
        api_port=$(opt_value --api-bind "${gpu_user[@]}"); api_port="${api_port##*:}"
      elif ! has_opt --api "${gpu_user[@]}"; then
        gpu_cmd+=(--api-bind 127.0.0.1:7777)
      fi
      gpu_api_urls=("http://127.0.0.1:${api_port}/summary" "http://127.0.0.1:${api_port}/metrics")
      ;;
    krigminer)
      # --no-tui : logs ligne par ligne. --no-rocm : pas de carte AMD sur ces machines,
      # inutile de chercher la bibliotheque HIP.
      has_opt --no-tui "${gpu_user[@]}"  || gpu_cmd+=(--no-tui)
      has_opt --no-rocm "${gpu_user[@]}" || gpu_cmd+=(--no-rocm)
      api_port=$(opt_value --api-port "${gpu_user[@]}")
      if [[ -z "$api_port" ]]; then api_port=12000; gpu_cmd+=(--api-port 12000); fi
      gpu_api_urls=("http://127.0.0.1:${api_port}/metrics" "http://127.0.0.1:${api_port}/")
      ;;
    peakminer)
      has_opt --no-color "${gpu_user[@]}" || gpu_cmd+=(--no-color)
      # API de stats deja active par defaut sur 127.0.0.1:4068 (-a / --api-port [HOTE:]PORT, 0 = coupee).
      api_port=$(opt_value --api-port "${gpu_user[@]}")
      [[ -z "$api_port" ]] && api_port=$(opt_value -a "${gpu_user[@]}")
      [[ -z "$api_port" ]] && api_port=4068
      api_port="${api_port##*:}"
      [[ "$api_port" != 0 ]] && gpu_api_urls=("http://127.0.0.1:${api_port}/summary")
      ;;
    rgminer)
      has_opt --plain-console "${gpu_user[@]}" || gpu_cmd+=(--plain-console)
      has_opt --api-host "${gpu_user[@]}"      || gpu_cmd+=(--api-host 127.0.0.1)
      api_port=$(opt_value --api-port "${gpu_user[@]}")
      if [[ -z "$api_port" ]]; then api_port=9200; gpu_cmd+=(--api-port 9200); fi
      # Le redemarrage interne de RGminer ferait doublon avec la relance de ce script.
      has_opt --watchdog "${gpu_user[@]}" || gpu_cmd+=(--watchdog=off)
      gpu_api_urls=("http://127.0.0.1:${api_port}/metrics")
      ;;
  esac
  gpu_cmd+=("${gpu_user[@]}")
  log "GPU ($gpu_miner) : $(show_cmd "${gpu_cmd[@]}")"
  if [[ ${#gpu_api_urls[@]} -gt 0 ]]; then
    if [[ "$gpu_miner" == rgminer ]]; then
      log "Hashrate : lu sur l'API $gpu_miner (${gpu_api_urls[0]}) toutes les ${REPORT_INTERVAL:-30} s et ecrit dans les logs (« GPU0 modele: valeur TH/s »)."
    else
      log "Hashrate : l'API $gpu_miner (${gpu_api_urls[0]}) n'est pas encore lue par cette image ; sa premiere reponse sera recopiee dans les logs."
    fi
  elif [[ "$gpu_miner" != srbminer ]]; then
    log "Hashrate : API $gpu_miner coupee par tes arguments, pas de hashrate dans les logs."
  fi
else
  log "GPU : desactive (GPU_MINER et GPU_ARGS vides)."
fi

# --- CPU : XMRig ou SRBMiner --------------------------------------------------
cpu_cmd=()
cpu_dir=""
cpu_log=""
if [[ $cpu_on -eq 1 ]]; then
  cpu_miner=$(lower "$CPU_MINER")
  split_args "$CPU_ARGS" cpu_user
  case "$cpu_miner" in
    xmrig)
      [[ -x "$xmrig" ]] || die "binaire introuvable : $xmrig"
      cpu_cmd=("$xmrig")
      # --randomx-no-numa : dans un conteneur, XMRig ne peut pas placer sa memoire
      # par processeur ; sans cette option il passe en mode lent sur les machines
      # a plusieurs processeurs (environ 10 fois moins de hashrate).
      has_opt --randomx-no-numa "${cpu_user[@]}" || cpu_cmd+=(--randomx-no-numa)
      has_opt --no-color "${cpu_user[@]}"        || cpu_cmd+=(--no-color)
      ;;
    srb|srbminer|srbminer-multi)
      cpu_miner=srbminer
      # Dossier a part : SRBMiner y cree ses dossiers Cache et Autotune, separes
      # de ceux du SRBMiner GPU.
      cpu_dir="$PWD/cpu"
      cpu_cmd=("$srb")
      has_opt --disable-gpu "${cpu_user[@]}"          || cpu_cmd+=(--disable-gpu)
      # --disable-numa-binding : meme raison que --randomx-no-numa pour XMRig.
      has_opt --disable-numa-binding "${cpu_user[@]}" || cpu_cmd+=(--disable-numa-binding)
      cpu_log=$(opt_value --log-file "${cpu_user[@]}")
      if [[ -z "$cpu_log" ]]; then
        cpu_log="$cpu_dir/srbminer-cpu.log"
        cpu_cmd+=(--log-file "$cpu_log")
      elif [[ "$cpu_log" != /* ]]; then
        cpu_log="$cpu_dir/$cpu_log"
      fi
      ;;
    *) die "CPU_MINER=${CPU_MINER} inconnu. Valeurs possibles : xmrig, srbminer." ;;
  esac
  cpu_cmd+=("${cpu_user[@]}")
  log "CPU ($cpu_miner) : $(show_cmd "${cpu_cmd[@]}")"
else
  log "CPU : desactive (CPU_MINER et CPU_ARGS vides)."
fi

# --- Chien de garde Salad : configuration ---------------------------------------
# Actif seulement sur SaladCloud (SALAD_MACHINE_ID injecte par Salad) et si
# SALAD_WATCHDOG est renseigne. Ailleurs (vast.ai...), rien ne change.
wd_on=0
wd_mode=""
wd_keys=()
wd_specs=()
wd_grace="${SALAD_GRACE:-300}"
wd_bad_max="${SALAD_BAD_READINGS:-3}"
wd_max_restarts="${SALAD_MAX_RESTARTS:-}"
# Hashrate a 0 : verdict apres N lectures consecutives a 0 (0 = regle desactivee).
wd_zero_max="${SALAD_ZERO_READINGS:-2}"
# Plus aucune statistique : verdict apres N minutes sans nouvelle lecture (0 = desactivee).
wd_stale_min="${SALAD_STALE_MINUTES:-2}"
wd_restart_file="$PWD/.gpu-restarts"
if [[ -n "${SALAD_WATCHDOG:-}" ]]; then
  wd_mode=$(lower "$SALAD_WATCHDOG")
  case "$wd_mode" in
    observe|reallocate) ;;
    *) die "SALAD_WATCHDOG=${SALAD_WATCHDOG} inconnu. Valeurs possibles : observe, reallocate." ;;
  esac
  if [[ -z "${SALAD_MACHINE_ID:-}" ]]; then
    log "Chien de garde Salad : SALAD_WATCHDOG est renseigne mais ce conteneur ne tourne pas sur Salad (SALAD_MACHINE_ID absent) : ignore."
  elif [[ $gpu_on -eq 0 ]]; then
    log "Chien de garde Salad : pas de mineur GPU a surveiller : ignore."
  elif [[ "$gpu_miner" != srbminer ]]; then
    # Les regles lisent le format de log de SRBMiner ; pour les autres mineurs, rien
    # n'est surveille pour l'instant (le mineur est quand meme relance s'il s'arrete).
    log "Chien de garde Salad : disponible seulement avec GPU_MINER=srbminer pour l'instant (ici $gpu_miner) : ignore."
  else
    if [[ -n "${SALAD_MIN_HASHRATE:-}" ]]; then
      IFS=',; ' read -r -a wd_entries <<< "${SALAD_MIN_HASHRATE//[$'\t\n']/ }"
      for entry in "${wd_entries[@]}"; do
        [[ -z "$entry" ]] && continue
        [[ "$entry" == *=* ]] || die "SALAD_MIN_HASHRATE : « $entry » n'est pas de la forme MODELE=SEUIL (ex. 5090=300T)."
        key=$(lower "${entry%%=*}")
        spec="${entry#*=}"
        [[ -n "$key" ]] || die "SALAD_MIN_HASHRATE : modele vide dans « $entry »."
        parse_threshold "$spec" >/dev/null || die "SALAD_MIN_HASHRATE : seuil « $spec » illisible dans « $entry » (ex. 300T, 250T, 100T)."
        wd_keys+=("$key")
        wd_specs+=("$spec")
      done
    fi
    [[ "$wd_grace" =~ ^[0-9]+$ ]]   || die "SALAD_GRACE=${wd_grace} : nombre de secondes attendu."
    [[ "$wd_bad_max" =~ ^[1-9][0-9]*$ ]] || die "SALAD_BAD_READINGS=${wd_bad_max} : nombre entier (1 ou plus) attendu."
    [[ -z "$wd_max_restarts" || "$wd_max_restarts" =~ ^[1-9][0-9]*$ ]] || die "SALAD_MAX_RESTARTS=${wd_max_restarts} : nombre entier (1 ou plus) attendu."
    [[ "$wd_zero_max" =~ ^[0-9]+$ ]]  || die "SALAD_ZERO_READINGS=${wd_zero_max} : nombre entier attendu (0 = desactive)."
    [[ "$wd_stale_min" =~ ^[0-9]+$ ]] || die "SALAD_STALE_MINUTES=${wd_stale_min} : nombre de minutes attendu (0 = desactive)."
    if [[ ${#wd_keys[@]} -eq 0 && -z "$wd_max_restarts" && $wd_zero_max -eq 0 && $wd_stale_min -eq 0 ]]; then
      die "SALAD_WATCHDOG=${wd_mode} mais aucune regle active (SALAD_MIN_HASHRATE, SALAD_MAX_RESTARTS, SALAD_ZERO_READINGS, SALAD_STALE_MINUTES) : rien a surveiller."
    fi
    wd_on=1
    wd_desc="mode $wd_mode"
    if [[ ${#wd_keys[@]} -gt 0 ]]; then
      wd_desc+=" ; seuils : ${SALAD_MIN_HASHRATE} ($wd_bad_max lectures consecutives sous le seuil, repit ${wd_grace}s apres chaque demarrage du mineur GPU)"
    fi
    [[ -n "$wd_max_restarts" ]] && wd_desc+=" ; verdict si le mineur GPU redemarre $wd_max_restarts fois en 10 min"
    [[ $wd_zero_max -gt 0 ]] && wd_desc+=" ; verdict apres $wd_zero_max lectures a 0"
    [[ $wd_stale_min -gt 0 ]] && wd_desc+=" ; verdict sans statistiques pendant $wd_stale_min min"
    log "Chien de garde Salad : $wd_desc."
    [[ "$wd_mode" == observe ]] && log "Chien de garde Salad : mode observe, les verdicts sont seulement ecrits dans le log (SALAD_WATCHDOG=reallocate pour agir)."
  fi
elif [[ -n "${SALAD_MACHINE_ID:-}" ]]; then
  log "Chien de garde Salad : desactive (SALAD_WATCHDOG vide)."
fi

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  exit 0
fi

if [[ $gpu_on -eq 1 ]] && ! ls /dev/nvidia* >/dev/null 2>&1 && [[ ! -e /usr/lib/x86_64-linux-gnu/libcuda.so.1 ]]; then
  log "ATTENTION : aucun GPU NVIDIA visible dans le conteneur (lancer avec --gpus all)."
fi

# --- Lancement et surveillance -------------------------------------------------
gpu_pid=0
cpu_pid=0
gpu_tailer=0
cpu_tailer=0
delay="${RESTART_DELAY:-10}"

# Journaux SRBMiner recopies dans les logs du conteneur (lignes CPU prefixees [cpu]).
if [[ -n "$gpu_log" && ! -t 1 ]]; then
  : > "$gpu_log"
  tail -n0 -F "$gpu_log" 2>/dev/null &
  gpu_tailer=$!
fi
if [[ -n "$cpu_dir" ]]; then
  mkdir -p "$cpu_dir"
  if [[ ! -t 1 ]]; then
    : > "$cpu_log"
    tail -n0 -F "$cpu_log" 2>/dev/null > >(sed -u 's/^/[cpu] /') &
    cpu_tailer=$!
  fi
fi

start_gpu() {
  "${gpu_cmd[@]}" &
  gpu_pid=$!
}

start_cpu() {
  # Les lignes du mineur CPU sont prefixees par [cpu] pour les distinguer du GPU.
  if [[ -n "$cpu_dir" ]]; then
    ( cd "$cpu_dir" && exec "${cpu_cmd[@]}" ) > >(sed -u 's/^/[cpu] /') 2>&1 &
  else
    "${cpu_cmd[@]}" > >(sed -u 's/^/[cpu] /') 2>&1 &
  fi
  cpu_pid=$!
}

# --- Chien de garde Salad : boucle ---------------------------------------------
# Tourne en tache de fond. Toutes les 30 s, lit la derniere ligne de statistiques
# du log SRBMiner GPU. Apres le repit (SALAD_GRACE) qui suit chaque demarrage du
# mineur GPU, SALAD_BAD_READINGS lectures consecutives sous le seuil du modele
# donnent un verdict ; de meme si le mineur GPU redemarre trop souvent. Verdict :
# ligne dans le log (observe) ou demande de reallocation a Salad (reallocate).
# Une lecture a 0 n'est pas comptee (pool injoignable plutot que carte en panne).
wd_pid=0
wd_verdict() {
  local reason_fr="$1" reason_en="$2"
  if [[ "$wd_mode" == observe ]]; then
    wlog "VERDICT (mode observe, rien fait) : $reason_fr. En mode reallocate, la reallocation serait demandee a Salad."
    return 0
  fi
  wlog "VERDICT : $reason_fr. Demande de reallocation a Salad..."
  if wd_request_reallocate "rentingminers watchdog: $reason_en"; then
    wlog "Reallocation acceptee par Salad ($wd_http) : ce conteneur va etre arrete et relance sur une autre machine."
    return 0
  fi
  wlog "Demande de reallocation refusee ou sans reponse ($wd_http) ; nouvelle tentative au prochain verdict."
  return 1
}

salad_watchdog() {
  local started now since last_restart bad=0 last_line="" line thr thr_hs hr_hs
  local unknown_model="" zero_streak=0 ok_logged=0 cooldown_until=0 restarts
  local since_seen="" fresh last_reading_at=0 prev_reading_at=0 ref limit gap
  # SALAD_WD_INTERVAL et SALAD_IMDS_URL ne servent qu'aux tests de l'image.
  local interval="${SALAD_WD_INTERVAL:-30}"
  started=$(date +%s)
  while true; do
    sleep "$interval"
    now=$(date +%s)
    [[ $now -lt $cooldown_until ]] && continue

    since=$started
    if [[ -s "$wd_restart_file" ]]; then
      last_restart=$(tail -n 1 "$wd_restart_file")
      [[ "$last_restart" =~ ^[0-9]+$ && $last_restart -gt $since ]] && since=$last_restart
      if [[ -n "$wd_max_restarts" ]]; then
        restarts=$(awk -v t=$((now - 600)) '$1 >= t' "$wd_restart_file" | wc -l)
        if [[ $restarts -ge $wd_max_restarts ]]; then
          if wd_verdict "le mineur GPU a redemarre $restarts fois en 10 min (seuil $wd_max_restarts)" \
                        "GPU miner restarted $restarts times in 10 minutes (limit $wd_max_restarts)"; then
            cooldown_until=$((now + 600))
          else
            cooldown_until=$((now + 120))
          fi
          : > "$wd_restart_file"
          bad=0
          continue
        fi
      fi
    fi

    [[ $((now - since)) -lt $wd_grace ]] && continue

    # Nouveau demarrage du mineur GPU : les compteurs repartent de zero.
    if [[ "$since" != "$since_seen" ]]; then
      since_seen=$since; last_line=""; last_reading_at=0; prev_reading_at=0; zero_streak=0; bad=0
    fi

    line=$(wd_last_reading "$gpu_log")
    fresh=0
    if [[ -n "$line" && "$line" != "$last_line" ]]; then
      last_line="$line"
      fresh=1
      prev_reading_at=$last_reading_at
      last_reading_at=$now
    fi

    # Plus aucune statistique : SALAD_STALE_MINUTES, ou deux fois l'intervalle habituel
    # entre deux statistiques si c'est plus long (pour ne pas juger entre deux lignes).
    if [[ $wd_stale_min -gt 0 && $fresh -eq 0 ]]; then
      ref=$last_reading_at
      [[ $ref -eq 0 ]] && ref=$((since + wd_grace))
      limit=$((wd_stale_min * 60))
      if [[ $prev_reading_at -gt 0 ]]; then
        gap=$((last_reading_at - prev_reading_at))
        [[ $((2 * gap + 15)) -gt $limit ]] && limit=$((2 * gap + 15))
      fi
      if [[ $((now - ref)) -ge $limit ]]; then
        if wd_verdict "plus aucune statistique du mineur GPU depuis $(((now - ref) / 60)) min (limite $((limit / 60)) min)" \
                      "no GPU miner statistics for $(((now - ref) / 60)) minutes (limit $((limit / 60)) minutes)"; then
          cooldown_until=$((now + 600))
        else
          cooldown_until=$((now + 120))
        fi
        last_reading_at=$now; prev_reading_at=0
        continue
      fi
    fi
    [[ $fresh -eq 0 ]] && continue

    wd_parse_reading "$line" || continue
    hr_hs=$(hs_value "$wd_value" "$wd_unit")

    # Hashrate a 0 : SALAD_ZERO_READINGS lectures consecutives.
    if [[ "$hr_hs" == 0 ]]; then
      zero_streak=$((zero_streak + 1))
      if [[ $wd_zero_max -gt 0 ]]; then
        wlog "Hashrate a 0 sur $wd_model : ${zero_streak}/${wd_zero_max}."
        if [[ $zero_streak -ge $wd_zero_max ]]; then
          if wd_verdict "hashrate a 0 sur $wd_model pendant ${zero_streak} lectures" \
                        "GPU hashrate at 0 on ${wd_model} during ${zero_streak} consecutive readings"; then
            cooldown_until=$((now + 600))
          else
            cooldown_until=$((now + 120))
          fi
          zero_streak=0
        fi
      else
        [[ $zero_streak -eq 1 ]] && wlog "Hashrate a 0 sur $wd_model : lecture ignoree (SALAD_ZERO_READINGS=0)."
      fi
      continue
    fi
    [[ $zero_streak -gt 0 ]] && wlog "Hashrate revenu a ${wd_value} ${wd_unit}H/s apres ${zero_streak} lecture(s) a 0."
    zero_streak=0

    [[ ${#wd_keys[@]} -eq 0 ]] && continue
    thr=$(wd_threshold_for "$wd_model") || {
      if [[ "$unknown_model" != "$wd_model" ]]; then
        unknown_model="$wd_model"
        wlog "Pas de seuil pour « $wd_model » dans SALAD_MIN_HASHRATE (${SALAD_MIN_HASHRATE}) : hashrate non surveille sur cette carte."
      fi
      continue
    }
    thr_hs=$(parse_threshold "$thr")

    if hs_less "$hr_hs" "$thr_hs"; then
      bad=$((bad + 1))
      wlog "Hashrate ${wd_value} ${wd_unit}H/s < seuil ${thr} ($wd_model) : ${bad}/${wd_bad_max}."
      if [[ $bad -ge $wd_bad_max ]]; then
        if wd_verdict "hashrate ${wd_value} ${wd_unit}H/s sous le seuil ${thr} ($wd_model) pendant ${bad} lectures" \
                      "GPU hashrate ${wd_value} ${wd_unit}H/s below threshold ${thr} for ${wd_model} during ${bad} consecutive readings"; then
          cooldown_until=$((now + 600))
        else
          cooldown_until=$((now + 120))
        fi
        bad=0
      fi
    elif [[ $bad -gt 0 ]]; then
      wlog "Hashrate revenu a ${wd_value} ${wd_unit}H/s (seuil ${thr}, $wd_model) : compteur remis a zero."
      bad=0
      ok_logged=$now
    elif [[ "$wd_mode" == observe || $((now - ok_logged)) -ge 600 ]]; then
      # En mode observe chaque lecture est ecrite ; en mode reallocate, une ligne
      # de controle toutes les 10 min suffit.
      wlog "Hashrate ${wd_value} ${wd_unit}H/s >= seuil ${thr} ($wd_model) : OK."
      ok_logged=$now
    fi
  done
}

# --- Rapport de hashrate (mineurs GPU autres que SRBMiner) ----------------------
# Toutes les REPORT_INTERVAL secondes (30), lit l'API locale du mineur et ecrit une
# ligne par carte au format de SRBMiner, « GPU0 NVIDIA GeForce RTX 5090: 385.20 TH/s »,
# que Salad-Switch-Log et Vast-Switch-Log savent lire.
#   RGminer    : /metrics documente (miners[].deviceId, gpuName, emaRate en H/s).
#   ForgeMiner, krig, PeakMiner : format non documente ; la premiere reponse de chaque
#   URL est recopiee telle quelle dans les logs, pour ecrire leur lecture ensuite.
report_pid=0

# H/s -> « 385.20 TH/s » (unite choisie selon la grandeur).
format_hashrate() {
  awk -v v="$1" 'BEGIN {
    if (v >= 1e12) printf "%.2f TH/s", v / 1e12
    else if (v >= 1e9) printf "%.2f GH/s", v / 1e9
    else if (v >= 1e6) printf "%.2f MH/s", v / 1e6
    else if (v >= 1e3) printf "%.2f KH/s", v / 1e3
    else printf "%.2f H/s", v }'
}

# Lignes de hashrate a partir de la reponse /metrics de RGminer ($1).
report_rgminer() {
  local id name rate
  printf '%s' "$1" \
    | jq -r '.miners[]? | "\(.deviceId // 0)\t\(.gpuName // "GPU")\t\(.emaRate // 0)"' 2>/dev/null \
    | while IFS=$'\t' read -r id name rate; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        echo "GPU${id} ${name}: $(format_hashrate "$rate")"
      done
}

hashrate_reporter() {
  local interval="${REPORT_INTERVAL:-30}" url body lines down=0
  local -A dumped=()
  while true; do
    sleep "$interval"
    if [[ "$gpu_miner" == rgminer ]]; then
      body=$(wget -qO- --timeout=5 --tries=1 "${gpu_api_urls[0]}" 2>/dev/null) || body=""
      if [[ -z "$body" ]]; then
        down=$((down + 1))
        [[ $down -eq 4 ]] && log "API $gpu_miner injoignable (${gpu_api_urls[0]}) : pas de hashrate dans les logs tant qu'elle ne repond pas."
        continue
      fi
      [[ $down -ge 4 ]] && log "API $gpu_miner de nouveau joignable."
      down=0
      lines=$(report_rgminer "$body")
      if [[ -n "$lines" ]]; then
        printf '%s\n' "$lines"
      elif [[ -z "${dumped[nocard]:-}" ]]; then
        dumped[nocard]=1
        log "API $gpu_miner : reponse sans carte (${gpu_api_urls[0]}) : ${body:0:1500}"
      fi
      continue
    fi
    # Mineurs dont l'API n'est pas encore lue : une recopie brute par URL, une seule fois.
    [[ ${#dumped[@]} -ge ${#gpu_api_urls[@]} ]] && continue
    for url in "${gpu_api_urls[@]}"; do
      [[ -n "${dumped[$url]:-}" ]] && continue
      body=$(wget -qO- --timeout=5 --tries=1 "$url" 2>/dev/null) || body=""
      [[ -z "$body" ]] && continue
      dumped[$url]=1
      log "API $gpu_miner, reponse brute de $url (pour ecrire sa lecture) : ${body:0:2000}"
    done
    if [[ ${#dumped[@]} -eq 0 ]]; then
      down=$((down + 1))
      [[ $down -eq 10 ]] && log "API $gpu_miner injoignable (${gpu_api_urls[0]}) apres $down essais : verifie que le mineur a bien demarre (ses lignes ci-dessus)."
    fi
  done
}

stop() {
  log "Arret demande, fermeture des mineurs..."
  [[ $wd_pid -ne 0 ]] && kill "$wd_pid" 2>/dev/null
  [[ $report_pid -ne 0 ]] && kill "$report_pid" 2>/dev/null
  for pid in "$gpu_pid" "$cpu_pid"; do
    [[ $pid -ne 0 ]] && kill -TERM "$pid" 2>/dev/null
  done
  for pid in "$gpu_pid" "$cpu_pid"; do
    [[ $pid -ne 0 ]] && wait "$pid" 2>/dev/null
  done
  for pid in "$gpu_tailer" "$cpu_tailer"; do
    [[ $pid -ne 0 ]] && kill "$pid" 2>/dev/null
  done
  exit 0
}
trap stop TERM INT

[[ $gpu_on -eq 1 ]] && start_gpu
[[ $cpu_on -eq 1 ]] && start_cpu
if [[ $wd_on -eq 1 ]]; then
  : > "$wd_restart_file"
  salad_watchdog &
  wd_pid=$!
fi
if [[ $gpu_on -eq 1 && "$gpu_miner" != srbminer && ${#gpu_api_urls[@]} -gt 0 ]]; then
  hashrate_reporter &
  report_pid=$!
fi

# Surveillance toutes les 2 s : un mineur arrete est relance apres le delai,
# sans bloquer l'autre, qui continue de miner.
gpu_restart_at=0
cpu_restart_at=0
while true; do
  sleep 2 & wait $!
  now=$(date +%s)

  if [[ $gpu_pid -ne 0 ]]; then
    if [[ $gpu_restart_at -eq 0 ]] && ! kill -0 "$gpu_pid" 2>/dev/null; then
      wait "$gpu_pid"; code=$?
      log "Le mineur GPU s'est arrete (code $code). Relance dans ${delay}s."
      gpu_restart_at=$((now + delay))
    fi
    if [[ $gpu_restart_at -ne 0 && $now -ge $gpu_restart_at ]]; then
      start_gpu
      gpu_restart_at=0
      # Le chien de garde Salad s'en sert : repit apres redemarrage, compte des redemarrages.
      [[ $wd_on -eq 1 ]] && echo "$now" >> "$wd_restart_file"
    fi
  fi

  if [[ $cpu_pid -ne 0 ]]; then
    if [[ $cpu_restart_at -eq 0 ]] && ! kill -0 "$cpu_pid" 2>/dev/null; then
      wait "$cpu_pid"; code=$?
      log "Le mineur CPU s'est arrete (code $code). Relance dans ${delay}s."
      cpu_restart_at=$((now + delay))
    fi
    if [[ $cpu_restart_at -ne 0 && $now -ge $cpu_restart_at ]]; then
      start_cpu
      cpu_restart_at=0
    fi
  fi
done
