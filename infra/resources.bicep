@description('Azure region for all resources')
param location string

@description('Short unique token used to build globally-unique resource names')
param resourceToken string

@description('Tags applied to every resource')
param tags object

// ---------------------------------------------------------------------------
// Storage: Logic App runtime content (required plumbing — workflow state,
// not the data the workflow reads)
// ---------------------------------------------------------------------------
resource runtimeStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// ---------------------------------------------------------------------------
// Storage: the actual data the workflow reads. Deliberately a SEPARATE
// account from the runtime storage above, so the RBAC role assignment below
// is visibly scoped to only what the workflow touches — not the whole
// resource group, not the runtime account too.
// ---------------------------------------------------------------------------
resource dataStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'data${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource dataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${dataStorage.name}/default/zero-trust-demo'
}

// ---------------------------------------------------------------------------
// App Service Plan — Workflow Standard (WS1), the smallest Logic Apps
// Standard tier
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'plan-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    reserved: false
  }
}

// ---------------------------------------------------------------------------
// Managed connector connection — Azure Blob Storage, Managed Identity auth.
// No connection string, no client secret.
// ---------------------------------------------------------------------------
resource azureBlobConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'azureblob'
  location: location
  tags: tags
  properties: {
    displayName: 'azureblob'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azureblob')
    }
  }
}

// ---------------------------------------------------------------------------
// Logic App Standard (the 'kind' value is what makes this a Logic App
// rather than a plain Function App)
// ---------------------------------------------------------------------------
resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'logic-${resourceToken}'
  location: location
  tags: union(tags, { 'azd-service-name': 'workflows' })
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${runtimeStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${runtimeStorage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${runtimeStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${runtimeStorage.listKeys().keys[0].value}'
        }
        { name: 'WEBSITE_CONTENTSHARE', value: toLower('logic-${resourceToken}') }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '~20' }
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'WORKFLOWS_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'WORKFLOWS_RESOURCE_GROUP_NAME', value: resourceGroup().name }
        { name: 'WORKFLOWS_LOCATION_NAME', value: location }
        { name: 'WORKFLOWS_MANAGEMENT_BASE_URI', value: environment().resourceManager }
        { name: 'DATA_STORAGE_ACCOUNT_NAME', value: dataStorage.name }
        {
          name: 'azureblob_connectionRuntimeUrl'
          value: reference(azureBlobConnection.id, '2016-06-01', 'Full').properties.connectionRuntimeUrl
        }
      ]
    }
  }
}

// Trust the Logic App's managed identity on the connection's access policy —
// this is the step that removes the need for a local connection key.
resource connectionAccessPolicy 'Microsoft.Web/connections/accessPolicies@2016-06-01' = {
  parent: azureBlobConnection
  name: logicApp.identity.principalId
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        tenantId: subscription().tenantId
        objectId: logicApp.identity.principalId
      }
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC — least privilege, scoped to the data storage account only.
// Not the resource group. Not the runtime storage account. One account.
// ---------------------------------------------------------------------------
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource blobReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataStorage.id, logicApp.id, storageBlobDataReaderRoleId)
  scope: dataStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output logicAppName string = logicApp.name
output storageAccountName string = runtimeStorage.name
output dataStorageAccountName string = dataStorage.name
