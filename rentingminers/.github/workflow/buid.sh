name: Construire et publier l'image

# Lancement manuel (onglet Actions > "Run workflow") et a chaque modification
# des fichiers sur la branche main.
on:
  workflow_dispatch:
  push:
    branches: [main]

permissions:
  contents: read

env:
  IMAGE: clusmi/rentingminers

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Trouver les dernieres versions des mineurs
        id: versions
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          chmod +x scripts/*.sh
          args=$(scripts/resolve-versions.sh)
          echo "$args"
          {
            echo "build_args<<EOF"
            echo "$args"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      # Chaque build est publie sous deux etiquettes : "latest" (vast.ai : recycle)
      # et une etiquette datee (SaladCloud : Salad ne re-telecharge pas une image
      # dont l'etiquette n'a pas change ; changer l'etiquette dans Edit suffit).
      - name: Etiquette datee
        id: tag
        env:
          BUILD_ARGS: ${{ steps.versions.outputs.build_args }}
        run: |
          tag=$(date -u +%Y-%m-%d-%H%M)
          echo "tag=$tag" >> "$GITHUB_OUTPUT"
          {
            echo "### Image publiee : ${IMAGE}:latest et ${IMAGE}:${tag}"
            echo
            echo "Mineurs inclus :"
            echo "$BUILD_ARGS" | grep '_VERSION=' | sed 's/^/- /'
            echo
            echo "SaladCloud : Edit > Image Source > \`${IMAGE}:${tag}\` pour passer sur cette version."
          } >> "$GITHUB_STEP_SUMMARY"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Construire et envoyer sur Docker Hub
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          pull: true
          no-cache: true
          tags: |
            ${{ env.IMAGE }}:latest
            ${{ env.IMAGE }}:${{ steps.tag.outputs.tag }}
          build-args: ${{ steps.versions.outputs.build_args }}
