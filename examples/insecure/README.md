# Insecure mode

Minimal imgproxy on Azure Container Apps with no request signing (`insecure = true`): community edition, default resource
limits, public access, no monitoring and no Blob Storage. It fetches public placeholder images.

> [!WARNING]
> This example is intended for **development and testing only**. Without request signing anyone can use your
> imgproxy (unlimited bandwidth costs, no protection against abuse, no control over processed images). Never use
> this configuration in production.

## Azure setup

You need an Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), authenticated:

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Prerequisites

Create a resource group:

```bash
RESOURCE_GROUP=imgproxy-example
LOCATION=germanywestcentral

az group create --name $RESOURCE_GROUP --location $LOCATION
```

## Deploy

```bash
echo "resource_group_name = \"$RESOURCE_GROUP\"" > terraform.tfvars

terraform init
terraform plan
terraform apply
```

Print a ready-to-open URL (paste it into a browser; no signature is required in insecure mode):

```bash
echo "$(terraform output -raw url)/insecure/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
```

## Cleanup

```bash
terraform destroy
```

The resource group was created with `az`, so delete it separately:

```bash
az group delete --name $RESOURCE_GROUP --yes
```

## Next

Continue with [signed](../signed/).
