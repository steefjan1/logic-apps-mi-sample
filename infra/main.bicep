targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment — used to derive a short unique resource token')
param environmentName string

@minLength(1)
@description('Azure region for all resources. Must support the WS1 Workflow Standard SKU.')
param location string

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

output AZURE_LOCATION string = location
output AZURE_LOGIC_APP_NAME string = resources.outputs.logicAppName
output AZURE_RUNTIME_STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
output AZURE_DATA_STORAGE_ACCOUNT_NAME string = resources.outputs.dataStorageAccountName
