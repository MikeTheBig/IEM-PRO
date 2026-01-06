#!/bin/bash

# IEM Pro Installation Script
# Usage: ./install-iem-pro.sh [configuration-file.json] [hostname]

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables - MODIFY THESE FOR YOUR SETUP
NAMESPACE="testlab"
CHART_PATH="./application-management-service-v1.14.9.tgz"
POSTGRES_HOST="postgres.local" # Eller ændre til ip addressen, hvis ikke DNS domain virker
POSTGRES_DB="iem_pro"
POSTGRES_USER="iem_user"
POSTGRES_PASSWORD="SecurePassword123!"
IEM_ADMIN_PASSWORD="Siemens1234!"
CUSTOMER_ADMIN_PASSWORD="S13mens@PCT!"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required parameters are provided
if [ $# -lt 2 ]; then
    print_error "Usage: $0 <configuration-file.json> <hostname>"
    print_error "Example: $0 configuration-mysetup.json iempro2"
    exit 1
fi

CONFIG_FILE="$1"
HOSTNAME="$2"

# Validate files exist
if [ ! -f "$CONFIG_FILE" ]; then
    print_error "Configuration file '$CONFIG_FILE' not found!"
    exit 1
fi

if [ ! -f "$CHART_PATH" ]; then
    print_error "Helm chart '$CHART_PATH' not found!"
    exit 1
fi

if [ ! -d "out" ] || [ ! -f "out/certChain.crt" ]; then
    print_error "Certificate files not found! Run ./gen_with_ca_DNS.sh $HOSTNAME first"
    exit 1
fi

print_status "Starting IEM Pro installation..."
print_status "Configuration: $CONFIG_FILE"
print_status "Hostname: $HOSTNAME"
print_status "Namespace: $NAMESPACE"

# Check if namespace exists, create if not
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    print_status "Creating namespace $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
else
    print_status "Namespace $NAMESPACE already exists"
fi

# Check if TLS secret exists, create if not
if ! kubectl get secret kongcert -n "$NAMESPACE" &> /dev/null; then
    print_status "Creating TLS secret"
    kubectl create secret tls kongcert --key out/myCert.key --cert out/myCert.crt -n "$NAMESPACE"
else
    print_status "TLS secret already exists"
fi

# Test database connectivity
print_status "Testing database connectivity..."
if pg_isready -h "$POSTGRES_HOST" -p 5432 -U "$POSTGRES_USER" &> /dev/null; then
    print_status "Database connectivity OK"
else
    print_warning "Database connectivity test failed, continuing anyway..."
fi

# Check if release already exists
if helm list -n "$NAMESPACE" | grep -q iempro; then
    print_warning "IEM Pro installation already exists. This will upgrade the existing installation."
    read -p "Continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Installation cancelled"
        exit 1
    fi
    HELM_COMMAND="upgrade"
else
    HELM_COMMAND="install"
fi

print_status "Running Helm $HELM_COMMAND..."

# Run helm install/upgrade
helm $HELM_COMMAND iempro \
    --namespace "$NAMESPACE" \
    --set-file global.activationConfig="$CONFIG_FILE" \
    --set global.hostname="$HOSTNAME" \
    --set global.storageClass=local-path \
    --set global.storageClassPg=local-path \
    --set global.gateway.ingress.enabled=false \
    --set global.certChain="$(cat ./out/certChain.crt | base64 -w 0)" \
    --set global.proxy.http_proxy='' \
    --set global.proxy.https_proxy='' \
    --set global.proxy.no_proxy='.svc\,.svc.cluster.local\,localhost\,127.0.0.1\,10.0.0.0/8\,172.16.0.0/12\,192.168.0.0/16\,POD_IP_RANGE\,SERVICE_IP_RANGE' \
    --set global.iemAdminPassword="$IEM_ADMIN_PASSWORD" \
    --set global.customerAdminPassword="$CUSTOMER_ADMIN_PASSWORD" \
    --set central-auth.keycloak.customerRealmAdmin.email=testlab@siemens.com \
    --set central-auth.keycloak.customerRealmAdmin.firstName=TEST \
    --set central-auth.keycloak.customerRealmAdmin.lastName=Lab \
    --set central-auth.keycloak.customerRealmAdmin.username=testlab \
    --set central-auth.keycloak.initialUser.email=iemuser@siemens.com \
    --set central-auth.keycloak.initialUser.enabled=true \
    --set central-auth.keycloak.initialUser.firstName=IEM \
    --set central-auth.keycloak.initialUser.lastName=User \
    --set central-auth.keycloak.initialUser.username=iemuser \
    --set kong.env.SSL_CERT=/etc/secrets/kongcert/tls.crt \
    --set kong.env.SSL_CERT_KEY=/etc/secrets/kongcert/tls.key \
    --set kong.secretVolumes[0]=kongcert \
    --set device-catalog.firmwaremanagement.enabled=true \
    --set device-catalog.workflowexecutor.enabled=true \
    --set postgresql.enabled=false \
    --set global.database.host="$POSTGRES_HOST" \
    --set global.database.port=5432 \
    --set global.database.name="$POSTGRES_DB" \
    --set global.database.username="$POSTGRES_USER" \
    --set global.database.password="$POSTGRES_PASSWORD" \
    "$CHART_PATH"

if [ $? -eq 0 ]; then
    print_status "Helm $HELM_COMMAND completed successfully!"
else
    print_error "Helm $HELM_COMMAND failed!"
    exit 1
fi

print_status "Monitoring pod startup..."

# Wait for pods to start
print_status "Waiting for pods to be ready (this may take several minutes)..."

# Function to check pod status
check_pods() {
    local not_ready=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ (Running|Completed) ]]; then
            not_ready=$((not_ready + 1))
        fi
    done < <(kubectl get pods -n "$NAMESPACE" --no-headers | awk '{print $3}')
    return $not_ready
}

# Wait loop with timeout
timeout=600  # 10 minutes
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if check_pods; then
        print_status "All pods are ready!"
        break
    else
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    fi
done

if [ $elapsed -ge $timeout ]; then
    print_warning "Timeout reached. Some pods may still be starting."
fi

print_status "Current pod status:"
kubectl get pods -n "$NAMESPACE"

print_status "Getting Traefik service port..."
TRAEFIK_PORT=$(kubectl get svc -n kube-system traefik -o jsonpath='{.spec.ports[?(@.name=="web")].nodePort}')

if [ -n "$TRAEFIK_PORT" ]; then
    print_status "IEM Pro should be accessible at:"
    print_status "  https://$HOSTNAME:$TRAEFIK_PORT"
    print_status "  Login: iemuser / $IEM_ADMIN_PASSWORD"
    print_status "  Admin: testlab / $CUSTOMER_ADMIN_PASSWORD"
else
    print_warning "Could not determine Traefik port. Check service manually with:"
    print_warning "  kubectl get svc -n kube-system traefik"
fi

print_status "Installation complete!"
print_status ""
print_status "Next steps:"
print_status "1. Verify all pods are running: kubectl get pods -n $NAMESPACE"
print_status "2. Check ingress setup if needed"
print_status "3. Update DNS records if hostname changed"
print_status "4. Test edge device onboarding"