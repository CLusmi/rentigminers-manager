# Image de minage pour GPU loues (vast.ai, SaladCloud, Clore.ai...) :
#   - GPU NVIDIA : SRBMiner-MULTI, ForgeMiner, krig, PeakMiner ou RGminer
#                  (GPU_MINER, GPU_ARGS)
#   - CPU        : XMRig ou SRBMiner-MULTI (CPU_MINER, CPU_ARGS)
# Un cote ne demarre que si son mineur ET ses arguments sont renseignes.
# Sur SaladCloud, un chien de garde facultatif (SALAD_WATCHDOG, SRBMiner
# seulement pour l'instant) demande une autre machine quand la carte est trop
# lente (voir entrypoint.sh).
#
# Les versions, URL et empreintes sont fournies par le workflow GitHub
# (scripts/resolve-versions.sh). Chaque fichier est telecharge depuis la page
# GitHub officielle du mineur et verifie avant installation.

# ---------------------------------------------------------------------------
# Etape 1 : telechargement et verification des mineurs
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS fetch

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ARG SRB_VERSION
ARG SRB_URL
ARG SRB_SHA256
ARG XMRIG_VERSION
ARG XMRIG_URL
ARG XMRIG_SHA256
ARG FORGE_VERSION
ARG FORGE_URL
ARG FORGE_SHA256
ARG KRIG_VERSION
ARG KRIG_URL
ARG KRIG_SHA256
ARG PEAK_VERSION
ARG PEAK_URL
ARG PEAK_SHA256
ARG RG_VERSION
ARG RG_URL
ARG RG_SHA256

COPY scripts/fetch-miner.sh /usr/local/bin/fetch-miner
RUN chmod +x /usr/local/bin/fetch-miner \
    && mkdir -p /opt/miners \
    && fetch-miner srbminer   "$SRB_VERSION"   "$SRB_URL"   "$SRB_SHA256"   SRBMiner-MULTI \
    && fetch-miner xmrig      "$XMRIG_VERSION" "$XMRIG_URL" "$XMRIG_SHA256" xmrig \
    && fetch-miner forgeminer "$FORGE_VERSION" "$FORGE_URL" "$FORGE_SHA256" forge \
    && fetch-miner krigminer  "$KRIG_VERSION"  "$KRIG_URL"  "$KRIG_SHA256"  krig-miner \
    && fetch-miner peakminer  "$PEAK_VERSION"  "$PEAK_URL"  "$PEAK_SHA256"  peakminer \
    && fetch-miner rgminer    "$RG_VERSION"    "$RG_URL"    "$RG_SHA256"    rgminer

# ---------------------------------------------------------------------------
# Etape 2 : image finale, sans outils de telechargement
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# ca-certificates : connexions TLS aux pools.
# ocl-icd-libopencl1 : chargeur OpenCL, que SRBMiner ouvre au demarrage.
# wget : demande par SRBMiner (il s'arrete sans lui si sa connexion directe a
# ses serveurs de frais echoue) ; sert aussi a lire l'API de stats des autres
# mineurs (rapport de hashrate dans les logs).
# jq : lecture des reponses JSON de ces API.
# Le pilote NVIDIA (libcuda, NVML, nvidia-smi) n'est PAS dans l'image : l'hote
# l'injecte au lancement (vast.ai, Salad, docker --gpus all). XMRig est autonome.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ocl-icd-libopencl1 wget jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /opt/miners /opt/miners
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && mkdir -p /opt/miners/work

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    RESTART_DELAY=10

LABEL org.opencontainers.image.title="rentingminers" \
      org.opencontainers.image.description="GPU NVIDIA : SRBMiner-MULTI, ForgeMiner, krig, PeakMiner ou RGminer (GPU_MINER, GPU_ARGS) ; CPU : XMRig ou SRBMiner-MULTI (CPU_MINER, CPU_ARGS)"

WORKDIR /opt/miners/work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
