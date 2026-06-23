###############################################################################
# Homelab AKS + Argo CD
#
# Terraform provisions the PLATFORM (an AKS cluster) and installs Argo CD on it.
# Argo CD then manages everything INSIDE the cluster from your GitOps repo.
#
# State is stored remotely in Azure Blob Storage (see backend block below).
# Bootstrap that storage ONCE with the CLI before running init — see the chat.
###############################################################################

terraform {
  required_version = ">= 1.5"

  # Remote state in Azure Blob Storage. Locking is automatic (blob lease).
  # NOTE: backend blocks can't use variables — hardcode the values, or pass
  # them at init time with `-backend-config="storage_account_name=..."`.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstatehomelab2653"
    container_name       = "tfstate"
    key                  = "homelab-aks.tfstate"
    use_azuread_auth     = true # auth via your `az login` session — no key stored
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

# --------------------------------------------------------------------------- #
# Variables (sensible defaults — runs without a .tfvars file)
# --------------------------------------------------------------------------- #
variable "resource_group_name" {
  type    = string
  default = "rg-homelab-aks"
}

variable "location" {
  type    = string
  default = "West Europe" # close to Austria; "Germany West Central" also works
}

variable "cluster_name" {
  type    = string
  default = "aks-homelab"
}

variable "node_count" {
  type    = number
  default = 1 # 1 keeps cost minimal; bump to 2-3 later
}

variable "node_vm_size" {
  type    = string
  default = "Standard_B2ls_v2" # 2 vCPU / 4 GB. Standard_B2ms (8 GB) for real workloads
}

# --------------------------------------------------------------------------- #
# Providers
# --------------------------------------------------------------------------- #
provider "azurerm" {
  # azurerm v4 requires a subscription. Set ARM_SUBSCRIPTION_ID in your shell,
  # or uncomment and hardcode:
  # subscription_id = "00000000-0000-0000-0000-000000000000"
  features {}
}

# The helm provider authenticates to the AKS cluster created below.
# NOTE: helm provider v3 uses `kubernetes = { ... }` (attribute), not a block.
provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.homelab.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.homelab.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.homelab.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.homelab.kube_config[0].cluster_ca_certificate)
  }
}

# --------------------------------------------------------------------------- #
# AKS cluster (Free tier, single small node)
# --------------------------------------------------------------------------- #
resource "azurerm_resource_group" "homelab" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_kubernetes_cluster" "homelab" {
  name                = var.cluster_name
  location            = azurerm_resource_group.homelab.location
  resource_group_name = azurerm_resource_group.homelab.name
  dns_prefix          = var.cluster_name

  # Free tier: no charge for the managed control plane, no uptime SLA.
  sku_tier = "Free"

  default_node_pool {
    name            = "system"
    node_count      = var.node_count
    vm_size         = var.node_vm_size
    os_disk_size_gb = 32
  }

  identity {
    type = "SystemAssigned"
  }
}

# --------------------------------------------------------------------------- #
# Argo CD (installed via Helm — the GitOps operator)
# --------------------------------------------------------------------------- #
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # Pin a version for reproducibility — find the latest at:
  # https://artifacthub.io/packages/helm/argo/argo-cd
  version = "7.7.0"

  depends_on = [azurerm_kubernetes_cluster.homelab]
}

# --------------------------------------------------------------------------- #
# Outputs
# --------------------------------------------------------------------------- #
output "resource_group_name" {
  value = azurerm_resource_group.homelab.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.homelab.name
}

output "kube_config_raw" {
  description = "Raw kubeconfig. Prefer `az aks get-credentials` for kubectl setup."
  value       = azurerm_kubernetes_cluster.homelab.kube_config_raw
  sensitive   = true
}
