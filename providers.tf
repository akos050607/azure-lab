provider "azurerm" {
  # Required, even when empty. The block is where provider-wide behaviours are
  # configured (for example whether `destroy` may delete a non-empty resource
  # group); azurerm refuses to initialise without it.
  features {}

  # Mandatory from azurerm v4 onward — earlier versions silently inherited
  # whichever subscription `az login` happened to leave selected, which is a
  # pleasant default right up until it applies to the wrong one.
  #
  # In CI this comes from ARM_SUBSCRIPTION_ID instead, alongside the other three
  # ARM_* variables of a service principal — or from nothing at all, if the
  # pipeline uses OIDC federation and there is no stored credential.
  subscription_id = var.subscription_id
}
