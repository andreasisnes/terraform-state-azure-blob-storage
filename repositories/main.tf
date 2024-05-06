terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "2.48.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.100.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  use_oidc = true
  features {
  }
}

locals {
  environment  = lower(var.environment)
  file_content = yamldecode(file(var.repository_file))
  teams        = [for team in local.file_content.teams : team]

  repositories = flatten([for team in local.file_content.teams :
    [
      for repository in team.repositories :
      {
        name : repository
        team : team
      }
    ]
  ])
}

data "azurerm_client_config" "current" {}

data "azurerm_storage_account" "st" {
  name                = var.arm_storage_account_name
  resource_group_name = var.arm_resource_group_name
}

data "azurerm_storage_container" "github_container" {
  name                 = "github"
  storage_account_name = data.azurerm_storage_account.st.name
}

resource "azuread_application" "app_oidc" {
  display_name            = "GitHub: ${each.key} ${upper(local.environment)}"
  prevent_duplicate_names = true
  for_each                = { for team in local.teams : team.name => team }
}

resource "azuread_service_principal" "app_oidc_principal" {
  client_id = azuread_application.app_oidc[each.key].client_id
  for_each  = { for team in local.teams : team.name => team }
}

resource "azuread_application_federated_identity_credential" "identity_federation" {
  application_id = azuread_application.app_oidc[each.value.name].id
  display_name   = "github.${lower(local.file_content.organization)}.${each.key}.environment.${local.environment}"
  subject        = "repo:${local.file_content.organization}/${each.key}:environment:${local.environment}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  description    = "Allow GitHub actions run within the context of '${local.environment}' from the repository https://github.com/${local.file_content.organization}/${each.key} to have access to the app registration"
  for_each       = { for repository in local.repositories : repository.name => repository.team }
}

resource "azurerm_storage_container" "repository" {
  name                 = "github-${each.key}-${local.environment}"
  storage_account_name = data.azurerm_storage_account.st.name

  lifecycle {
    prevent_destroy = true
  }

  for_each = { for repository in local.repositories : repository.name => repository.team }
}

resource "azurerm_role_assignment" "app" {
  scope                = azurerm_storage_container.repository[each.key].resource_manager_id
  principal_id         = azuread_service_principal.app_oidc_principal[each.value.name].object_id
  role_definition_name = "Storage Blob Data Owner" # b7e6dc6d-f1e8-4753-8033-0f276bb0955b
  principal_type       = "ServicePrincipal"

  timeouts {
    create = "40s"
    delete = "40s"
    read   = "40s"
  }
  for_each = { for repository in local.repositories : repository.name => repository.team }
}

resource "github_repository_environment" "environment" {
  environment = local.environment
  repository  = "${local.file_content.organization}/${each.key}"
  for_each    = { for repository in local.repositories : repository.name => repository.team }
}

resource "github_actions_environment_variable" "arm_client_id" {
  variable_name = "ARM_CLIENT_ID"
  value         = azuread_application.app_oidc[each.value.name].client_id
  repository    = "${local.file_content.organization}/${each.key}"
  environment   = github_repository_environment.environment[each.key].id

  for_each = { for repository in local.repositories : repository.name => repository.team }
}

resource "github_actions_environment_variable" "tfstate_arm_storage_account_name" {
  variable_name = "ARM_TFSTATE_STORAGE_ACCOUNT_NAME"
  value         = var.arm_storage_account_name
  repository    = "${local.file_content.organization}/${each.key}"
  environment   = github_repository_environment.environment[each.key].id

  for_each = { for repository in local.repositories : repository.name => repository.team }
}

resource "github_actions_environment_variable" "arm_tenant_id" {
  variable_name = "ARM_TENANT_ID"
  value         = data.azurerm_client_config.current.tenant_id
  repository    = "${local.file_content.organization}/${each.key}"
  environment   = github_repository_environment.environment[each.key].id

  for_each = { for repository in local.repositories : repository.name => repository.team }
}

output "test" {
  value = data.github_repository.repository
}
