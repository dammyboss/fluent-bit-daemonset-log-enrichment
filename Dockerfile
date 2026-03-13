# ==========================================================
# Stage 1: Pre-cache container images using skopeo
# ==========================================================
FROM quay.io/skopeo/stable:v1.21.0 AS image-fetcher

WORKDIR /images

RUN skopeo copy \
    docker://bitnami/kubectl:latest \
    docker-archive:kubectl-latest.tar:bitnami/kubectl:latest

# ==========================================================
# Stage 2: Final nebula-devops image with pre-cached images
# ==========================================================
FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.3

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024
ENV ALLOWED_NAMESPACES="bleater,logging,monitoring,platform-ops,observability,cert-manager,default,argocd"

# Copy pre-cached images into k3s auto-import directory
COPY --from=image-fetcher /images/*.tar /var/lib/rancher/k3s/agent/images/
