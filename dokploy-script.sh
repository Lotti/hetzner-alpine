#!/usr/bin/env bash

set -euo pipefail
DOCKER_VERSION=28.5.0
TRAEFIK_VERSION=3.6.7
POSTGRES_VERSION=16
REDIS_VERSION=7
DOKPLOY_IMAGE="dokploy/dokploy:${DOKPLOY_VERSION:-latest}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@localhost.invalid}"
TZ_VALUE="${TZ:-UTC}"
OS_TYPE=$(grep -w "ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')
SYS_ARCH=$(uname -m)

echo "Installing requirements for: OS: $OS_TYPE"
if [ "${EUID}" -ne 0 ]; then
  echo "Please run this script as root or with sudo ❌"
  exit
fi

# Check if the OS is manjaro, if so, change it to arch
if [ "$OS_TYPE" = "manjaro" ] || [ "$OS_TYPE" = "manjaro-arm" ]; then
  OS_TYPE="arch"
fi

# Check if the OS is Asahi Linux, if so, change it to fedora
if [ "$OS_TYPE" = "fedora-asahi-remix" ]; then
  OS_TYPE="fedora"
fi

# Check if the OS is popOS, if so, change it to ubuntu
if [ "$OS_TYPE" = "pop" ]; then
  OS_TYPE="ubuntu"
fi

# Check if the OS is linuxmint, if so, change it to ubuntu
if [ "$OS_TYPE" = "linuxmint" ]; then
  OS_TYPE="ubuntu"
fi

#Check if the OS is zorin, if so, change it to ubuntu
if [ "$OS_TYPE" = "zorin" ]; then
  OS_TYPE="ubuntu"
fi

if [ "$OS_TYPE" = "arch" ] || [ "$OS_TYPE" = "archarm" ]; then
  OS_VERSION="rolling"
else
  OS_VERSION=$(grep -w "VERSION_ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')
fi

if [ "$OS_TYPE" = 'amzn' ]; then
  dnf install -y findutils >/dev/null
fi

case "$OS_TYPE" in
arch | ubuntu | debian | raspbian | centos | fedora | rhel | ol | rocky | sles | opensuse-leap | opensuse-tumbleweed | almalinux | opencloudos | amzn | alpine) ;;
*)
  echo "This script only supports Debian, Redhat, Arch Linux, Alpine Linux, or SLES based operating systems for now."
  exit
  ;;
esac

echo -e "---------------------------------------------"
echo "| CPU Architecture  | $SYS_ARCH"
echo "| Operating System  | $OS_TYPE $OS_VERSION"
echo "| Docker            | $DOCKER_VERSION"

echo -e "---------------------------------------------
"
echo -e "1. Installing required packages (curl, wget, git, jq, openssl). "

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

port_in_use() {
  ss -tulnp | grep -q ":$1 "
}

get_primary_interface() {
  local iface=""

  iface=$(ip route show default 2>/dev/null | awk 'NR==1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

  if [ -z "$iface" ]; then
    iface=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  fi

  if [ -z "$iface" ]; then
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
  fi

  printf '%s\n' "$iface"
}

get_interface_ipv4() {
  local iface="$1"

  ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {split($4, parts, "/"); print parts[1]}'
}

get_interface_ipv6() {
  local iface="$1"

  ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {split($4, parts, "/"); print parts[1]}'
}

get_advertise_addr() {
  local iface=""
  local ipv4=""
  local ipv6=""

  iface=$(get_primary_interface)

  if [ -z "$iface" ]; then
    echo "Error: Could not determine the primary network interface." >&2
    echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
    exit 1
  fi

  ipv4=$(get_interface_ipv4 "$iface")
  if [ -n "$ipv4" ]; then
    printf '%s\n' "$ipv4"
    return 0
  fi

  ipv6=$(get_interface_ipv6 "$iface")
  if [ -n "$ipv6" ]; then
    printf '%s\n' "$ipv6"
    return 0
  fi

  echo "Error: Could not determine a global IPv4 or IPv6 address on ${iface}." >&2
  echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
  exit 1
}

wait_for_docker() {
  local attempt=0

  until docker info >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      echo "Error: Docker did not become ready in time." >&2
      exit 1
    fi
    sleep 1
  done
}

ensure_docker_running() {
  case "$OS_TYPE" in
  alpine)
    rc-update add docker default >/dev/null 2>&1 || true
    rc-service docker start >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
    ;;
  esac

  wait_for_docker
}

docker_secret_exists() {
  docker secret inspect "$1" >/dev/null 2>&1
}

docker_service_exists() {
  docker service inspect "$1" >/dev/null 2>&1
}

create_or_rotate_postgres_secret() {
  local secret_name="dokploy_postgres_password"
  local password=""

  if docker_secret_exists "$secret_name"; then
    echo "Docker secret ${secret_name} already exists ✅"
    return 0
  fi

  password=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
  printf '%s' "$password" | docker secret create "$secret_name" - >/dev/null
  echo "Docker secret ${secret_name} created ✅"
}

deploy_support_services() {
  if docker_service_exists dokploy-postgres; then
    echo "Service dokploy-postgres already exists ✅"
  else
    docker service create \
      --name dokploy-postgres \
      --constraint 'node.role==manager' \
      --network dokploy-network \
      --env POSTGRES_USER=dokploy \
      --env POSTGRES_DB=dokploy \
      --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
      --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
      --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data \
      "postgres:${POSTGRES_VERSION}" >/dev/null
    echo "Service dokploy-postgres created ✅"
  fi

  if docker_service_exists dokploy-redis; then
    echo "Service dokploy-redis already exists ✅"
  else
    docker service create \
      --name dokploy-redis \
      --constraint 'node.role==manager' \
      --network dokploy-network \
      --mount type=volume,source=dokploy-redis,target=/data \
      "redis:${REDIS_VERSION}" >/dev/null
    echo "Service dokploy-redis created ✅"
  fi
}

deploy_or_update_dokploy() {
  if docker_service_exists dokploy; then
    docker service update \
      --image "$DOKPLOY_IMAGE" \
      --env-add "ADVERTISE_ADDR=${advertise_addr}" \
      --env-add "POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password" \
      --env-add "TZ=${TZ_VALUE}" \
      dokploy >/dev/null
    echo "Service dokploy updated ✅"
  else
    docker service create \
      --name dokploy \
      --replicas 1 \
      --network dokploy-network \
      --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
      --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
      --mount type=volume,source=dokploy,target=/root/.docker \
      --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
      --publish published=3000,target=3000,mode=host \
      --update-parallelism 1 \
      --update-order stop-first \
      --constraint 'node.role == manager' \
      --env "ADVERTISE_ADDR=${advertise_addr}" \
      --env "POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password" \
      --env "TZ=${TZ_VALUE}" \
      "$DOKPLOY_IMAGE" >/dev/null
    echo "Service dokploy created ✅"
  fi
}

format_ip_for_url() {
  local ip="$1"

  if echo "$ip" | grep -q ':'; then
    printf '[%s]\n' "$ip"
  else
    printf '%s\n' "$ip"
  fi
}

case "$OS_TYPE" in
arch)
  pacman -Sy --noconfirm --needed curl wget git git-lfs jq openssl >/dev/null || true
  ;;
alpine)
  sed -i '/^#.*/community/s/^#//' /etc/apk/repositories
  apk update >/dev/null
  apk add bash ca-certificates curl wget git git-lfs jq openssl sudo unzip tar iproute2-minimal iproute2-ss >/dev/null
  update-ca-certificates >/dev/null 2>&1 || true
  ;;
ubuntu | debian | raspbian)
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl wget git git-lfs jq openssl >/dev/null
  ;;
centos | fedora | rhel | ol | rocky | almalinux | opencloudos | amzn)
  if [ "$OS_TYPE" = "amzn" ]; then
    dnf install -y wget git git-lfs jq openssl >/dev/null
  else
    if ! command -v dnf >/dev/null; then
      yum install -y dnf >/dev/null
    fi
    if ! command -v curl >/dev/null; then
      dnf install -y curl >/dev/null
    fi
    dnf install -y wget git git-lfs jq openssl unzip >/dev/null
  fi
  ;;
sles | opensuse-leap | opensuse-tumbleweed)
  zypper refresh >/dev/null
  zypper install -y curl wget git git-lfs jq openssl >/dev/null
  ;;
*)
  echo "This script only supports Debian, Redhat, Arch Linux, or SLES based operating systems for now."
  exit
  ;;
esac

echo -e "2. Validating ports. "

# check if something is running on port 80
if port_in_use 80; then
  if docker inspect dokploy-traefik >/dev/null 2>&1 || docker_service_exists dokploy-traefik; then
    echo "Traefik already appears to be using port 80 ✅"
  else
    echo "Something is already running on port 80" >&2
    exit 1
  fi
fi

# check if something is running on port 443
if port_in_use 443; then
  if docker inspect dokploy-traefik >/dev/null 2>&1 || docker_service_exists dokploy-traefik; then
    echo "Traefik already appears to be using port 443 ✅"
  else
    echo "Something is already running on port 443" >&2
    exit 1
  fi
fi

# check if something is running on port 3000
if port_in_use 3000; then
  if command_exists docker && { docker service inspect dokploy >/dev/null 2>&1 || docker inspect dokploy >/dev/null 2>&1; }; then
    echo "Dokploy already appears to be using port 3000 ✅"
  else
    echo "Something is already running on port 3000" >&2
    echo "Dokploy requires port 3000 to be available." >&2
    exit 1
  fi
fi

echo -e "3. Installing RClone. "

if command_exists rclone; then
  echo "RClone already installed ✅"
else
  curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1
  RCLONE_VERSION=$(rclone --version | head -n 1 | awk '{print $2}' | sed 's/^v//')
  echo "RClone version $RCLONE_VERSION installed ✅"
fi

echo -e "4. Installing Docker. "

# Detect if docker is installed via snap
if [ -x "$(command -v snap)" ]; then
  SNAP_DOCKER_INSTALLED=$(snap list docker >/dev/null 2>&1 && echo "true" || echo "false")
  if [ "$SNAP_DOCKER_INSTALLED" = "true" ]; then
    echo " - Docker is installed via snap."
    echo "   Please note that Dokploy does not support Docker installed via snap."
    echo "   Please remove Docker with snap (snap remove docker) and reexecute this script."
    exit 1
  fi
fi

echo -e "3. Check Docker Installation. "
if ! [ -x "$(command -v docker)" ]; then
  echo " - Docker is not installed. Installing Docker. It may take a while."
  case "$OS_TYPE" in
  "almalinux")
    dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
    if ! [ -x "$(command -v docker)" ]; then
      echo " - Docker could not be installed automatically. Please visit https://docs.docker.com/engine/install/ and install Docker manually to continue."
      exit 1
    fi
    systemctl start docker >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    ;;
  "opencloudos")
    # Special handling for OpenCloud OS
    echo " - Installing Docker for OpenCloud OS..."
    dnf install -y docker >/dev/null 2>&1
    if ! [ -x "$(command -v docker)" ]; then
      echo " - Docker could not be installed automatically. Please visit https://docs.docker.com/engine/install/ and install Docker manually to continue."
      exit 1
    fi

    # Remove --live-restore parameter from Docker configuration if it exists
    if [ -f "/etc/sysconfig/docker" ]; then
      echo " - Removing --live-restore parameter from Docker configuration..."
      sed -i 's/--live-restore[^[:space:]]*//' /etc/sysconfig/docker >/dev/null 2>&1
      sed -i 's/--live-restore//' /etc/sysconfig/docker >/dev/null 2>&1
      # Clean up any double spaces that might be left
      sed -i 's/  */ /g' /etc/sysconfig/docker >/dev/null 2>&1
    fi

    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
    echo " - Docker configured for OpenCloud OS"
    ;;
  "alpine")
    apk add docker docker-cli-compose >/dev/null 2>&1
    rc-update add docker default >/dev/null 2>&1
    service docker start >/dev/null 2>&1
    if ! [ -x "$(command -v docker)" ]; then
      echo " - Failed to install Docker with apk. Try to install it manually."
      echo "   Please visit https://wiki.alpinelinux.org/wiki/Docker for more information."
      exit 1
    fi
    ;;
  "arch")
    pacman -Sy docker docker-compose --noconfirm >/dev/null 2>&1
    systemctl enable docker.service >/dev/null 2>&1
    if ! [ -x "$(command -v docker)" ]; then
      echo " - Failed to install Docker with pacman. Try to install it manually."
      echo "   Please visit https://wiki.archlinux.org/title/docker for more information."
      exit 1
    fi
    ;;
  "amzn")
    dnf install docker -y >/dev/null 2>&1
    DOCKER_CONFIG=/usr/local/lib/docker
    mkdir -p "$DOCKER_CONFIG/cli-plugins" >/dev/null 2>&1
    curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o "$DOCKER_CONFIG/cli-plugins/docker-compose" >/dev/null 2>&1
    chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose" >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    if ! [ -x "$(command -v docker)" ]; then
      echo " - Failed to install Docker with dnf. Try to install it manually."
      echo "   Please visit https://www.cyberciti.biz/faq/how-to-install-docker-on-amazon-linux-2/ for more information."
      exit 1
    fi
    ;;
  "fedora")
    if [ -x "$(command -v dnf5)" ]; then
      # dnf5 is available
      dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo --overwrite >/dev/null 2>&1
    else
      # dnf5 is not available, use dnf
      dnf config-manager --add-repo=https://download.docker.com/linux/fedora/docker-ce.repo >/dev/null 2>&1
    fi
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
    if ! [ -x "$(command -v docker)" ]; then
      echo " - Docker could not be installed automatically. Please visit https://docs.docker.com/engine/install/ and install Docker manually to continue."
      exit 1
    fi
    systemctl start docker >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    ;;
  *)
    if [ "$OS_TYPE" = "ubuntu" ] && [ "$OS_VERSION" = "24.10" ]; then
      echo "Docker automated installation is not supported on Ubuntu 24.10 (non-LTS release)."
      echo "Please install Docker manually."
      exit 1
    fi

    if ! [ -x "$(command -v docker)" ]; then
      curl -s https://get.docker.com | sh -s -- --version "$DOCKER_VERSION" 2>&1
      if ! [ -x "$(command -v docker)" ]; then
        echo " - Docker installation failed."
        echo "   Maybe your OS is not supported?"
        echo " - Please visit https://docs.docker.com/engine/install/ and install Docker manually to continue."
        exit 1
      fi
    fi
    if [ "$OS_TYPE" = "rocky" ]; then
      systemctl start docker >/dev/null 2>&1
      systemctl enable docker >/dev/null 2>&1
    fi

    if [ "$OS_TYPE" = "centos" ]; then
      systemctl start docker >/dev/null 2>&1
      systemctl enable docker >/dev/null 2>&1
    fi
    ;;

  esac
  echo " - Docker installed successfully."
else
  echo " - Docker is installed."
fi

ensure_docker_running

echo -e "5. Setting up Docker Swarm"

# Check if the node is already part of a Docker Swarm
if docker info | grep -q 'Swarm: active'; then
  echo "Already part of a Docker Swarm ✅"
else
  advertise_addr="${ADVERTISE_ADDR:-$(get_advertise_addr)}"
  echo "Advertise address: $advertise_addr"

  # Initialize Docker Swarm
  docker swarm init --advertise-addr "$advertise_addr"
  echo "Swarm initialized ✅"
fi

echo -e "6. Setting up Network"

# Check if the dokploy-network already exists
if docker network ls | grep -q 'dokploy-network'; then
  echo "Network dokploy-network already exists ✅"
else
  # Create the dokploy-network if it doesn't exist
  if docker network create --driver overlay --attachable dokploy-network; then
    echo "Network created ✅"
  else
    echo "Failed to create dokploy-network ❌" >&2
    exit 1
  fi
fi

echo -e "7. Setting up Directories"

# Check if the /etc/dokploy directory exists
if [ -d /etc/dokploy ]; then
  echo "/etc/dokploy already exists ✅"
else
  # Create the /etc/dokploy directory
  mkdir -p /etc/dokploy
  chmod 777 /etc/dokploy

  echo "Directory /etc/dokploy created ✅"
fi

mkdir -p "/etc/dokploy" && mkdir -p "/etc/dokploy/traefik" && mkdir -p "/etc/dokploy/traefik/dynamic" && mkdir -p "/etc/dokploy/logs" && mkdir -p "/etc/dokploy/applications" && mkdir -p "/etc/dokploy/compose" && mkdir -p "/etc/dokploy/ssh" && mkdir -p "/etc/dokploy/traefik/dynamic/certificates" && mkdir -p "/etc/dokploy/monitoring" && mkdir -p "/etc/dokploy/registry" && mkdir -p "/etc/dokploy/schedules" && mkdir -p "/etc/dokploy/volume-backups" && mkdir -p "/etc/dokploy/volume-backup-lock" && mkdir -p "/etc/dokploy/patch-repos"
chmod 700 "/etc/dokploy/ssh"
touch "/etc/dokploy/traefik/dynamic/acme.json"

echo -e "8. Setting up Traefik"

if [ -f "/etc/dokploy/traefik/dynamic/acme.json" ]; then
  chmod 600 "/etc/dokploy/traefik/dynamic/acme.json"
fi
if [ -f "/etc/dokploy/traefik/traefik.yml" ]; then
  echo "Traefik config already exists ✅"
else
  echo "providers:
  swarm:
    exposedByDefault: false
    watch: true
  docker:
    exposedByDefault: false
    watch: true
    network: dokploy-network
  file:
    directory: /etc/dokploy/traefik/dynamic
    watch: true
entryPoints:
  web:
    address: :80
  websecure:
    address: :443
    http3:
      advertisedPort: 443
    http:
      tls:
        certResolver: letsencrypt
api:
  insecure: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: ${LETSENCRYPT_EMAIL}
      storage: /etc/dokploy/traefik/dynamic/acme.json
      httpChallenge:
        entryPoint: web
" >/etc/dokploy/traefik/traefik.yml
fi

echo -e "9. Setting up Middlewares"

if [ -f "/etc/dokploy/traefik/dynamic/middlewares.yml" ]; then
  echo "Middlewares config already exists ✅"
else
  echo "http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
" >/etc/dokploy/traefik/dynamic/middlewares.yml
fi

echo -e "10. Setting up Traefik Instance"

# Check if dokpyloy-traefik exists
if docker service inspect dokploy-traefik >/dev/null 2>&1; then
  echo "Migrating Traefik to Standalone..."
  docker service rm dokploy-traefik
  sleep 8
  echo "Traefik migrated to Standalone ✅"
fi

if docker inspect dokploy-traefik >/dev/null 2>&1; then
  echo "Traefik already exists ✅"
else
  # Create the dokploy-traefik container
  docker run -d --name dokploy-traefik --restart always -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic -v /var/run/docker.sock:/var/run/docker.sock -p 443:443 -p 80:80 -p 443:443/udp "traefik:v${TRAEFIK_VERSION}"

  docker network connect dokploy-network dokploy-traefik
  echo "Traefik version $TRAEFIK_VERSION installed ✅"
fi

echo -e "11. Deploying Dokploy Services"

create_or_rotate_postgres_secret
deploy_support_services
deploy_or_update_dokploy

formatted_addr=$(format_ip_for_url "$advertise_addr")
echo ""
echo "Dokploy is installed ✅"
echo "Wait 15-30 seconds for the services to become healthy."
echo "Open: http://${formatted_addr}:3000"

echo -e "12. Installing Nixpacks"

if command_exists nixpacks; then
  echo "Nixpacks already installed ✅"
else
  export NIXPACKS_VERSION=1.41.0
  bash -c "$(curl -fsSL https://nixpacks.com/install.sh)"
  echo "Nixpacks version $NIXPACKS_VERSION installed ✅"
fi

echo -e "13. Installing Buildpacks"

SUFFIX=""
if [ "$SYS_ARCH" = "aarch64" ] || [ "$SYS_ARCH" = "arm64" ]; then
  SUFFIX="-arm64"
fi
if command_exists pack; then
  echo "Buildpacks already installed ✅"
else
  BUILDPACKS_VERSION=0.39.1
  curl -sSL "https://github.com/buildpacks/pack/releases/download/v0.39.1/pack-v${BUILDPACKS_VERSION}-linux${SUFFIX}.tgz" | tar -C /usr/local/bin/ --no-same-owner -xzv pack
  echo "Buildpacks version $BUILDPACKS_VERSION installed ✅"
fi

echo -e "14. Installing Railpack"

if command_exists railpack; then
  echo "Railpack already installed ✅"
else
  export RAILPACK_VERSION=0.15.4
  bash -c "$(curl -fsSL https://railpack.com/install.sh)"
  echo "Railpack version $RAILPACK_VERSION installed ✅"
fi
