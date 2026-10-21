# rentingminers

Image Docker pour miner sur des machines louées (vast.ai, SaladCloud, Clore.ai…) :

- **GPU NVIDIA** : SRBMiner-MULTI, ForgeMiner, krig (Kryptex), PeakMiner ou RGminer, au choix ;
- **CPU** : XMRig ou SRBMiner-MULTI.

GPU seul, CPU seul ou les deux : **rien ne démarre sans choix explicite**. Les arguments
des mineurs sont donnés **tels quels**, dans leur syntaxe d'origine. Sur SaladCloud, un
chien de garde facultatif peut demander une autre machine quand la carte est trop lente
(SRBMiner seulement pour l'instant, voir plus bas).
Image publiée : `clusmi/rentingminers:latest` (publique).

## Comment l'image est construite

Le workflow GitHub (`.github/workflows/build.yml`) :

1. cherche la **dernière version stable** de chaque mineur sur sa page GitHub officielle
   (`doktor83/SRBMiner-Multi`, `xmrig/xmrig`, `0xHashRaptor/ForgeMiner`,
   `kryptex/krig-miner`, `peakminer/peakminer`, `Printscan/rgminer`) ;
2. télécharge le fichier Linux (archive `.tar.gz`, ou binaire nu pour PeakMiner et
   RGminer) et **vérifie son empreinte SHA-256** (celle que GitHub a enregistrée quand
   l'auteur a publié le fichier) ; il vérifie aussi que c'est bien un exécutable Linux :
   si quelque chose ne correspond pas, la construction échoue ;
3. construit l'image et l'envoie sur Docker Hub sous **deux étiquettes** :
   `clusmi/rentingminers:latest` et une étiquette datée, par exemple
   `clusmi/rentingminers:2026-10-03-2145`.

Les versions incluses et l'étiquette datée s'affichent dans le résumé du workflow ; les
versions aussi au démarrage du conteneur. Pour récupérer de nouvelles versions des mineurs,
relance simplement le workflow.

- **vast.ai** : garde `latest` ; après un build, `recycle` (menu 2 de Vast-Switch-Log)
  re-télécharge l'image.
- **SaladCloud** : Salad copie l'image dans son registre à la création du groupe et ne la
  re-télécharge pas tant que l'étiquette ne change pas, même si `latest` a bougé. Mets donc
  l'**étiquette datée** dans le groupe (Edit → Image Source) ; pour passer à un nouveau
  build, remplace-la par la nouvelle : Salad télécharge la nouvelle image et redéploie
  les replicas.

## Mise en place (une seule fois)

1. **Docker Hub** : dépôt `rentingminers` (public).
2. **GitHub** : les fichiers **à la racine** du dépôt, dossiers `.github` et `scripts`
   compris.
3. *Settings → Secrets and variables → Actions* : `DOCKERHUB_USERNAME` (`clusmi`) et
   `DOCKERHUB_TOKEN`.
4. Onglet **Actions** → *Construire et publier l'image* → **Run workflow**.

## Variables

| Variable | Valeurs | Rôle |
|---|---|---|
| `GPU_MINER` | `srbminer`, `forgeminer`, `krigminer`, `peakminer` ou `rgminer` | mineur GPU |
| `GPU_ARGS` | | arguments du mineur GPU, tels quels, **dans sa syntaxe** (voir [Mineurs GPU](#mineurs-gpu--arguments-mineur-par-mineur)) |
| `CPU_MINER` | `xmrig` ou `srbminer` | mineur CPU |
| `CPU_ARGS` | | arguments du mineur CPU, tels quels |
| `RESTART_DELAY` | `10` | secondes avant relance d'un mineur qui s'arrête |
| `DRY_RUN` | | `1` : affiche les commandes finales sans miner |
| `SALAD_WATCHDOG`, `SALAD_MIN_HASHRATE`, … | | chien de garde SaladCloud, voir [plus bas](#saladcloud--chien-de-garde) |

Aucun mineur n'est prérempli. Un côté démarre seulement si **son mineur et ses arguments**
sont renseignés tous les deux :

| `GPU_MINER` + `GPU_ARGS` | `CPU_MINER` + `CPU_ARGS` | Résultat |
|---|---|---|
| renseignés | vides | GPU seul |
| vides | renseignés | CPU seul |
| renseignés | renseignés | GPU + CPU |
| vides | vides | erreur « rien a miner » |
| l'un sans l'autre | | erreur, rien ne démarre |

Dans le template vast.ai, le plus simple est la section **Environment Variables** : une
case pour le nom, une pour la valeur, **sans guillemets**. Dans le champ « Docker
Options », la syntaxe est `-e GPU_ARGS="--algorithm pearlhash --pool ... --wallet ..."`,
avec le `-e` et des guillemets autour de la valeur. Si vast.ai garde ces guillemets dans
la valeur, l'image les retire. Des guillemets à l'intérieur de la valeur marchent aussi
(`--password "mot de passe"`).

## Mineurs GPU : arguments, mineur par mineur

Chaque mineur a **sa** syntaxe : les arguments de l'un ne marchent pas avec l'autre.
Dans tous les exemples, `POOL:PORT` est l'adresse de ta pool, `ADRESSE` ton adresse
Pearl (`prl1p…`) et `NOM` le nom du worker ; le format exact du worker (`--worker`,
`ADRESSE.NOM` ou `ADRESSE/NOM`) est celui qu'attend ta pool. Pour vérifier un
`GPU_ARGS` sans miner : `DRY_RUN=1`, la commande complète s'affiche dans les logs.

| | `srbminer` | `forgeminer` | `krigminer` | `peakminer` | `rgminer` |
|---|---|---|---|---|---|
| Projet | doktor83/SRBMiner-Multi | 0xHashRaptor/ForgeMiner | kryptex/krig-miner | peakminer/peakminer | Printscan/rgminer |
| Frais Pearl | 2 % | 2 % | 0 % | 2 % | 2 % |
| Pilote NVIDIA | — | 5090 : **580 ou plus** | CUDA (version non documentée) | compatible CUDA 12 | non documenté |
| Hashrate dans les logs | écrit par le mineur | lu sur son API (pas encore) | lu sur son API (pas encore) | lu sur son API (pas encore) | **lu sur son API** |
| Chien de garde Salad | **oui** | non (pour l'instant) | non | non | non |

Tous ces mineurs sont des binaires fermés publiés par leurs auteurs ; l'image les
télécharge depuis leur page GitHub et vérifie leur empreinte, rien de plus.

### `srbminer` — SRBMiner-MULTI

| Rôle | Option |
|---|---|
| Algorithme | `--algorithm pearlhash` |
| Pool | `--pool POOL:PORT` ; `--tls true` pour TLS |
| Wallet | `--wallet ADRESSE` |
| Worker | `--worker NOM` |
| Mot de passe | `--password x` |
| Cartes | `--gpu-id 0,1` |
| Ajouté par l'image | `--disable-cpu`, `--log-file` |

```
GPU_MINER=srbminer
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE --worker NOM
```

Avec TLS et le mot de passe :

```
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --tls true --wallet ADRESSE --worker NOM --password x
```

### `forgeminer` — ForgeMiner

| Rôle | Option |
|---|---|
| Algorithme | `--algorithm pearlhash` |
| Pool | `--pool POOL:PORT` ; TLS détecté tout seul (`ssl://POOL:PORT` pour le forcer) ; plusieurs adresses séparées par des virgules = secours |
| Wallet | `--wallet ADRESSE` |
| Worker | `--worker NOM` |
| Mot de passe | `--password x` |
| Cartes | `--gpu 0,1` |
| API de stats | `--api` (127.0.0.1:7777) ou `--api-bind HOTE:PORT` |
| Ajouté par l'image | `--no-color`, `--api-bind 127.0.0.1:7777` |

```
GPU_MINER=forgeminer
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE --worker NOM
```

Avec une pool de secours (virgule) et TLS forcé sur la première :

```
GPU_ARGS=--algorithm pearlhash --pool ssl://POOL:PORT,POOL2:PORT2 --wallet ADRESSE --worker NOM --password x
```

Sur une RTX 5090, ForgeMiner exige un **pilote 580 ou plus** : sur un hôte plus ancien il
s'arrête au démarrage et l'image le relance toutes les `RESTART_DELAY` secondes (les logs
le montrent). Sur Salad, réalloue alors la machine à la main (menu 4 de Salad-Switch-Log).

### `krigminer` — krig (Kryptex)

| Rôle | Option |
|---|---|
| Algorithme | `--coin pearl` (c'est le défaut, l'option est facultative) |
| Pool | `--url POOL:PORT` (`-o`) ; `stratum+ssl://POOL:PORT` pour TLS ; plusieurs `--url` = secours |
| Wallet | `--user ADRESSE` (`-u`) |
| Worker | **pas d'option** : dans le wallet, `--user ADRESSE.NOM` ou `--user ADRESSE/NOM` selon la pool |
| Mot de passe | `-p x` |
| Cartes | `-d 0,1` |
| API de stats | `--api-port PORT` (`--api-host` pour l'adresse, 127.0.0.1 par défaut) |
| Ajouté par l'image | `--no-tui`, `--no-rocm`, `--api-port 12000` |

```
GPU_MINER=krigminer
GPU_ARGS=--url POOL:PORT --user ADRESSE.NOM
```

Avec TLS, une pool de secours et le mot de passe :

```
GPU_ARGS=--url stratum+ssl://POOL:PORT --url POOL2:PORT2 --user ADRESSE.NOM -p x
```

krig est le mineur de la pool Kryptex ; son auteur ne documente que cette pool. Sur une
autre, teste d'abord sur une machine.

### `peakminer` — PeakMiner

| Rôle | Option |
|---|---|
| Algorithme | `--coin pearl` (**obligatoire**) |
| Pool | `-o POOL:PORT` (`--url`) ; TLS détecté tout seul (`stratum+ssl://POOL:PORT` pour le forcer) ; plusieurs `-o` = secours |
| Wallet | `-u ADRESSE` (`--user`), envoyé tel quel |
| Worker | `-w NOM` (`--worker`), ou dans le wallet `-u ADRESSE.NOM` |
| Mot de passe | `-p x` |
| Cartes | `-d 0,1` |
| API de stats | active par défaut sur 127.0.0.1:4068 ; `-a [HOTE:]PORT` pour changer, `-a 0` pour la couper |
| Ajouté par l'image | `--no-color` |

```
GPU_MINER=peakminer
GPU_ARGS=--coin pearl -o POOL:PORT -u ADRESSE -w NOM
```

Avec une pool de secours et le worker dans le wallet :

```
GPU_ARGS=--coin pearl -o POOL:PORT -o POOL2:PORT2 -u ADRESSE.NOM -p x
```

### `rgminer` — RGminer

| Rôle | Option |
|---|---|
| Algorithme | `--algo pearl` |
| Protocole de la pool | `--proto herominers`, `kryptex`, `f2pool`, `alphapool`, `pearlfortune` ou `suprnova` ; **sans `--proto`, RGminer parle son propre protocole**, qui n'est pas celui de ces pools |
| Pool | `--stratum POOL:PORT` ; `stratum+tls://POOL:PORT` ou `--stratum-tls` pour TLS ; `POOL:PORT,POOL2:PORT2` = secours |
| Wallet | `--wallet ADRESSE` |
| Worker | `--worker NOM` |
| Mot de passe | `--stratum-pass x` |
| Cartes | `-d 0,1` |
| API de stats | `--api-host HOTE --api-port PORT` (127.0.0.1:9200 par défaut) |
| Ajouté par l'image | `--plain-console`, `--api-host 127.0.0.1`, `--api-port 9200`, `--watchdog=off` |

```
GPU_MINER=rgminer
GPU_ARGS=--algo pearl --proto herominers --stratum POOL:PORT --wallet ADRESSE --worker NOM
```

Avec TLS et une pool de secours :

```
GPU_ARGS=--algo pearl --proto kryptex --stratum stratum+tls://POOL:PORT,POOL2:PORT2 --wallet ADRESSE --worker NOM --stratum-pass x
```

`--watchdog=off` : le redémarrage interne de RGminer ferait doublon avec la relance de
l'image. Les pools absentes de la liste `--proto` (unMineable par exemple) ne sont pas
documentées par l'auteur : à tester.

### Ce que l'image ajoute automatiquement

Les arguments partent tels quels, l'image ajoute seulement ce qu'il faut pour tourner
dans un conteneur. **Une option déjà présente dans tes arguments n'est pas ajoutée.**

| Processus | Options ajoutées | Pourquoi |
|---|---|---|
| SRBMiner GPU | `--disable-cpu`, `--log-file` | GPU seulement ; SRBMiner n'écrit rien dans les logs sans fichier |
| ForgeMiner | `--no-color`, `--api-bind 127.0.0.1:7777` | logs lisibles ; API de stats pour le hashrate |
| krig | `--no-tui`, `--no-rocm`, `--api-port 12000` | logs ligne par ligne ; pas de carte AMD ici ; API de stats |
| PeakMiner | `--no-color` | logs lisibles (son API est déjà active) |
| RGminer | `--plain-console`, `--api-host 127.0.0.1`, `--api-port 9200`, `--watchdog=off` | logs lisibles ; API de stats ; pas de double redémarrage |
| SRBMiner CPU | `--disable-gpu`, `--disable-numa-binding`, `--log-file` | CPU seulement ; voir « machines à plusieurs processeurs » |
| XMRig | `--randomx-no-numa`, `--no-color` | idem ; logs lisibles |

Le SRBMiner CPU tourne dans son propre dossier (`/opt/miners/work/cpu`), à côté du
mineur GPU, sans se mélanger avec lui. Chaque mineur est relancé seul s'il s'arrête :
un plantage du mineur CPU n'interrompt pas le GPU, et inversement. Les lignes du mineur
CPU sont préfixées par `[cpu]` dans les logs.

**Machines à plusieurs processeurs** : dans un conteneur, les mineurs ne peuvent pas
placer leur mémoire par processeur (« can't bind memory »). Sans `--randomx-no-numa`,
XMRig passe en mode lent, environ 10 fois moins de hashrate sur un bi-EPYC. D'où ces
options ajoutées d'office.

### Hashrate dans les logs

Salad-Switch-Log et Vast-Switch-Log lisent le hashrate dans les logs du conteneur, sur
la ligne que SRBMiner écrit : `GPU0 RTX 5090: 342.10 TH/s`. Les autres mineurs écrivent
autre chose ; l'image interroge donc leur **API de statistiques** (locale, HTTP) toutes
les 30 s et écrit elle-même la même ligne, au même format :
`GPU0 NVIDIA GeForce RTX 5090: 385.20 TH/s`.

- **RGminer** : fait (API documentée par l'auteur).
- **ForgeMiner, krig, PeakMiner** : le format de leur API n'est pas documenté. L'image
  recopie **une fois** la première réponse de chaque URL dans les logs (ligne
  `[rentingminers] API forgeminer, reponse brute de …`) ; envoie ces lignes pour que la
  lecture soit écrite. En attendant, pas de hashrate dans les outils pour ces mineurs.
- Si l'API ne répond pas après dix essais, une ligne `API … injoignable` le dit : le
  mineur n'a sans doute pas démarré (ses propres lignes, juste au-dessus, disent pourquoi).

## Exemples de templates

**Pearl (GPU, SRBMiner) + Monero (CPU, XMRig)** :

```
GPU_MINER=srbminer
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE_PEARL --worker FARM
CPU_MINER=xmrig
CPU_ARGS=--coin monero -o xmr.kryptex.network:7029 -u ADRESSE_MONERO/RENT -t 184 -k
```

**Pearl seul (GPU), un template par mineur** :

```
GPU_MINER=srbminer
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE_PEARL --worker FARM
```
```
GPU_MINER=forgeminer
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE_PEARL --worker FARM
```
```
GPU_MINER=krigminer
GPU_ARGS=--url POOL:PORT --user ADRESSE_PEARL.FARM
```
```
GPU_MINER=peakminer
GPU_ARGS=--coin pearl -o POOL:PORT -u ADRESSE_PEARL -w FARM
```
```
GPU_MINER=rgminer
GPU_ARGS=--algo pearl --proto herominers --stratum POOL:PORT --wallet ADRESSE_PEARL --worker FARM
```

**DragonX seul (CPU, SRBMiner)** :

```
CPU_MINER=srbminer
CPU_ARGS=--algorithm randomdrgx --pool POOL:PORT --wallet ADRESSE_DRAGONX.RENT --cpu-threads 180
```

**Pearl (GPU) + DragonX (CPU, SRBMiner)** :

```
GPU_MINER=srbminer
GPU_ARGS=--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE_PEARL --worker FARM
CPU_MINER=srbminer
CPU_ARGS=--algorithm randomdrgx --pool POOL:PORT --wallet ADRESSE_DRAGONX.RENT --cpu-threads 180
```

Le nom du worker suit le format attendu par la pool : `--worker` (SRBMiner, ForgeMiner,
PeakMiner, RGminer), `wallet.worker` ou `wallet/worker` (krig, Kryptex pour Monero). Sans
worker, ça mine quand même.

Quelques algorithmes CPU de SRBMiner (liste complète sur sa page GitHub) : `randomdrgx`
(DragonX), `verushash` (Verus), `randomepic` (Epic Cash), `randomx` (Monero).

## Template vast.ai

- **Image Path:Tag** : `clusmi/rentingminers`, version `latest`
- **Launch mode** : **Docker ENTRYPOINT**
- **Champ des arguments** : **vide**
- **Environment Variables** : `GPU_MINER` + `GPU_ARGS` pour le GPU, `CPU_MINER` + `CPU_ARGS`
  pour le CPU (l'un, l'autre ou les deux)
- **Un template par mineur GPU** : sur vast.ai, les variables vivent dans le template ;
  pour changer de mineur sur une location, choisis l'autre template avec le menu 2 de
  Vast-Switch-Log (changement de template + recycle).
- **Après une reconstruction de l'image** : une location ne prend la nouvelle version que
  si son conteneur est recréé (`recycle`, ou le menu 2 de Vast-Switch-Log) ; un simple
  `reboot` garde l'ancienne.

Sur SaladCloud, le menu 3 de Salad-Switch-Log (« Mineur GPU et ses arguments ») change
`GPU_MINER` et `GPU_ARGS` d'un groupe ; Salad redéploie alors toutes ses machines.

## SaladCloud : chien de garde

Sur Salad, chaque replica tourne sur le PC d'un particulier, avec une carte parfois bridée
ou utilisée en même temps. Le chien de garde lit le hashrate dans le log SRBMiner et, si la
carte est trop lente, demande à Salad de déplacer le conteneur sur une autre machine (via
le service de métadonnées de Salad, `169.254.169.254/v1/reallocate`). Il n'est actif que
sur Salad (variable `SALAD_MACHINE_ID` injectée par Salad) **et** si `SALAD_WATCHDOG` est
renseigné : sur vast.ai, rien ne change.

**Pour l'instant, seulement avec `GPU_MINER=srbminer`** : ses règles lisent le format de
log de SRBMiner. Avec un autre mineur, `SALAD_WATCHDOG` est ignoré (ligne `Chien de garde
Salad : disponible seulement avec GPU_MINER=srbminer` dans les logs) ; le mineur est
quand même relancé s'il s'arrête, mais aucune réallocation n'est demandée.

| Variable | Exemple | Rôle |
|---|---|---|
| `SALAD_WATCHDOG` | `observe` ou `reallocate` | `observe` : surveille et écrit ses verdicts dans le log sans agir ; `reallocate` : demande la réallocation |
| `SALAD_MIN_HASHRATE` | `5090=300T,4090=250T,3090=100T` | seuil par modèle de carte (K, M, G, T = kilo/méga/giga/téra H/s) ; la première clé contenue dans le nom du modèle s'applique (`3090` couvre aussi la 3090 Ti) ; un modèle absent n'est pas surveillé |
| `SALAD_GRACE` | `300` | secondes de répit après chaque (re)démarrage du mineur GPU |
| `SALAD_BAD_READINGS` | `3` | lectures consécutives sous le seuil avant verdict |
| `SALAD_MAX_RESTARTS` | `5` | verdict si le mineur GPU redémarre au moins N fois en 10 min (inactif si absent) |
| `SALAD_ZERO_READINGS` | `2` | verdict après N lectures consécutives à 0 H/s (2 par défaut ; `0` = règle désactivée) |
| `SALAD_STALE_MINUTES` | `2` | verdict après N minutes sans nouvelle statistique du mineur GPU (2 par défaut ; `0` = désactivée). Si SRBMiner publie ses statistiques moins souvent, la limite devient deux fois cet intervalle, pour ne pas juger entre deux lignes |

Déroulement : après le répit, une lecture toutes les 30 s (SRBMiner publie ses statistiques
toutes les 30 à 90 s, seules les nouvelles comptent) ; `SALAD_BAD_READINGS` lectures
consécutives sous le seuil donnent un verdict, une lecture au-dessus remet le compteur à
zéro. Une lecture à 0 ne compte pas pour le seuil mais pour `SALAD_ZERO_READINGS` : deux
lectures à 0 de suite et la machine est jugée en panne. Plus aucune ligne de statistiques
pendant `SALAD_STALE_MINUTES` (mineur figé) : verdict aussi. Après un verdict, 10 min de
pause. Les lignes du chien de garde commencent par `[salad]`.

Conseil : première mise en service en `observe`, lecture des logs pendant une heure,
puis `reallocate`. Les seuils se placent vers 85 % du hashrate d'une carte saine **sans
overclock** (sur Salad, impossible d'overclocker), par exemple pour pearlhash : RTX 5090
≈ 340 TH/s → `300T`, RTX 4090 ≈ 290 TH/s → `250T`, RTX 3090 ≈ 130 TH/s → `100T`.

Exemple (Docker Run dans Salad) :

```
docker run --gpus all -e GPU_MINER=srbminer -e GPU_ARGS="--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE_PEARL --worker SALAD" -e SALAD_WATCHDOG=observe -e SALAD_MIN_HASHRATE=5090=300T,4090=250T,3090=100T -e SALAD_MAX_RESTARTS=5 clusmi/rentingminers:AAAA-MM-JJ-HHMM
```

`AAAA-MM-JJ-HHMM` est l'étiquette datée du build (résumé du workflow GitHub). Modifier ces
variables ou l'étiquette dans Salad (Edit) crée une nouvelle version du groupe et redéploie
tous les replicas.

## À savoir

- **Frais** : chaque mineur prélève des frais de développeur fixés par son auteur
  (Pearl : SRBMiner, ForgeMiner, PeakMiner et RGminer 2 %, krig 0 % ; XMRig 1 % ;
  SRBMiner 0,85 % pour randomdrgx). Compare les mineurs sur le hashrate vu par la pool
  (menu P des outils), pas sur celui qu'ils affichent.
- **Pilotes** : sur une machine louée, le pilote NVIDIA est celui de l'hôte. Un mineur qui
  l'exige plus récent s'arrête au démarrage et l'image le relance en boucle ; c'est visible
  dans les logs (`Le mineur GPU s'est arrete (code …)`). Sur Salad, réalloue la machine.
- **Mineur CPU en conteneur** : les messages sur les « huge pages » et les registres
  « MSR » sont normaux. Ces optimisations demandent des droits que seul l'hôte a ; sans
  elles, RandomX perd environ 10 à 20 %.
- **Impact sur le GPU** : le mineur GPU a besoin d'un peu de CPU. Compare le hashrate GPU
  vu par la pool avec et sans minage CPU, et réduis les threads CPU si besoin (`-t` pour
  XMRig, `--cpu-threads` pour SRBMiner).
- **Vérifier un template** : ajoute `DRY_RUN=1`, le log montre les commandes exactes.
- **Lancer un mineur à la main** : `docker run --rm --gpus all clusmi/rentingminers --help`
  lance SRBMiner avec ces arguments ; `-e MINER=rgminer` (ou forgeminer, krigminer,
  peakminer) pour un autre mineur.

## Dépannage

- **`rien a miner`** : aucun côté n'est complet. Il faut `GPU_MINER` + `GPU_ARGS` et/ou
  `CPU_MINER` + `CPU_ARGS`.
- **`GPU_MINER=... inconnu`** : valeurs possibles `srbminer`, `forgeminer`, `krigminer`,
  `peakminer`, `rgminer` (les raccourcis `forge`, `krig`, `peak`, `rg` marchent aussi).
- **`CPU_ARGS est renseigne mais CPU_MINER manque`** (et variantes) : un côté a l'une de
  ses deux variables sans l'autre ; complète-le ou vide les deux.
- **`variables d'une ancienne version ignorees`** : le conteneur reçoit aussi les anciens
  noms (`MINER`, `POOL`, `WALLET`, `CPU_POOL`…). Vast.ai réinjecte parfois les variables du
  template d'origine d'une location ; elles sont ignorées, seules `GPU_MINER`, `GPU_ARGS`,
  `CPU_MINER` et `CPU_ARGS` comptent. La ligne `Variables recues` dit lesquelles sont
  arrivées.
- **`guillemet non ferme`** : un guillemet ouvert dans `GPU_ARGS` ou `CPU_ARGS` sans son
  guillemet fermant.
- **Le mineur GPU s'arrête aussitôt et se relance en boucle** : ses propres lignes, juste
  avant `Le mineur GPU s'est arrete`, disent pourquoi : option inconnue (vérifie la
  syntaxe **de ce mineur**, pas celle de SRBMiner), pilote trop ancien, pool injoignable.
- **Pas de hashrate dans Salad-Switch-Log / Vast-Switch-Log** avec ForgeMiner, krig ou
  PeakMiner : normal pour l'instant (voir [Hashrate dans les logs](#hashrate-dans-les-logs)) ;
  envoie la ligne `reponse brute` des logs.
- **`API ... injoignable`** : le mineur n'a pas démarré ou son API est coupée par tes
  arguments (`-a 0` pour PeakMiner, par exemple).
- **Hashrate CPU très bas** : cherche `slow mode` (XMRig) dans les logs, et vérifie que la
  ligne `[rentingminers] CPU` contient `--randomx-no-numa` (XMRig) ou
  `--disable-numa-binding` (SRBMiner).
- **Le mineur refuse une option** : son message est dans les logs ; l'image ne vérifie pas
  les arguments, elle les transmet.
- **`No such container` sur vast.ai** : l'image n'a pas pu être téléchargée ; vérifie que
  le dépôt Docker Hub est public.
- **`SALAD_WATCHDOG est renseigne mais ce conteneur ne tourne pas sur Salad`** : la variable
  est dans un template vast.ai ; sans effet, à retirer.
- **`Chien de garde Salad : disponible seulement avec GPU_MINER=srbminer`** : le groupe
  tourne avec un autre mineur ; `SALAD_WATCHDOG` est ignoré, sans conséquence.
- **`Pas de seuil pour « ... »`** : la carte attribuée par Salad n'est pas dans
  `SALAD_MIN_HASHRATE` ; elle mine normalement, sans surveillance du hashrate.
- **`Demande de reallocation refusee ou sans reponse`** : le service de métadonnées de Salad
  n'a pas accepté la demande ; le chien de garde réessaie au prochain verdict. Si ça
  persiste, réalloue l'instance à la main (menu ⋮ → Reallocate).
