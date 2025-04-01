#!/bin/bash
# Variables – customize these values as needed.
RESOURCE_GROUP="vigilantRG"
LOCATION="eastus"
# ACR name must be globally unique; here we append a timestamp for uniqueness.
ACR_NAME="vigilantacr$(date +%s)"
CONTAINER_INSTANCE_NAME="vigilant-instance"
IMAGE_NAME="vigilantonion:latest"
GITHUB_REPO_URL="https://github.com/andreyglauzer/VigilantOnion.git"
# Generate a unique DNS label for the container instance
DNS_LABEL="vigilant-instance-$(date +%s)"

echo "Creating resource group: $RESOURCE_GROUP in $LOCATION"
az group create --name $RESOURCE_GROUP --location $LOCATION

echo "Creating Azure Container Registry: $ACR_NAME"
az acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Basic --location $LOCATION

# VERY IMPORTANT: Enable the admin account for the ACR.
echo "Enabling admin account for ACR: $ACR_NAME"
az acr update -n $ACR_NAME --admin-enabled true

echo "Cloning VigilantOnion repository from GitHub"
git clone $GITHUB_REPO_URL
cd VigilantOnion

# Patch requirements.txt to replace outdated BeautifulSoup with beautifulsoup4
if grep -qi "beautifulsoup" requirements.txt; then
    echo "Patching requirements.txt to use beautifulsoup4 instead of beautifulsoup"
    sed -i 's/beautifulsoup/beautifulsoup4/Ig' requirements.txt
fi

# Check if a Dockerfile exists; if not, create one.
if [ ! -f Dockerfile ]; then
    echo "Dockerfile not found. Creating a sample Dockerfile..."
    cat <<'EOF' > Dockerfile
# Use an official Python runtime as a parent image
FROM python:3.8-slim

# Install tor and any additional OS packages needed
RUN apt-get update && apt-get install -y tor && rm -rf /var/lib/apt/lists/*

# Set the working directory in the container
WORKDIR /app

# Copy requirements and install them
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . .

# Expose a port if your app serves HTTP endpoints (adjust if necessary)
EXPOSE 8080

# Command to run the script (adjust arguments as needed)
CMD ["python", "observer.py", "--config", "config/config.yml", "--crawler"]
EOF
fi

echo "Building Docker image in ACR..."
az acr build --registry $ACR_NAME --image $IMAGE_NAME .

# Retrieve ACR credentials
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query "username" -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query "passwords[0].value" -o tsv)
FULL_IMAGE_NAME="$ACR_NAME.azurecr.io/$IMAGE_NAME"

echo "Deploying container instance: $CONTAINER_INSTANCE_NAME"
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_INSTANCE_NAME \
  --image $FULL_IMAGE_NAME \
  --cpu 1 --memory 1.5 \
  --os-type Linux \
  --registry-login-server "$ACR_NAME.azurecr.io" \
  --registry-username "$ACR_USERNAME" \
  --registry-password "$ACR_PASSWORD" \
  --restart-policy OnFailure \
  --ip-address Public \
  --ports 8080 \
  --dns-name-label $DNS_LABEL

echo "Deployment complete. Use the following command to get the public FQDN:"
az container show --resource-group $RESOURCE_GROUP --name $CONTAINER_INSTANCE_NAME --query ipAddress.fqdn -o tsv
