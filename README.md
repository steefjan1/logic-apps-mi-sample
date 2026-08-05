# logic-apps-mi-sample

A Logic Apps Standard project, provisioned end to end with `azd up`, showing
Managed Identity used as the authentication method both locally (VS Code)
and once deployed — the scenario from [Use connectors with Managed Identity
in the Logic Apps Standard
extension](https://techcommunity.microsoft.com/blog/integrationsonazureblog/use-connectors-with-managed-identity-in-the-logic-apps-standard-extension/4539485)
by Wagner Silveira, companion to the blog post *"Managed Identity Closes the
Last Gap Between Your Laptop and Production."*

The workflow reads a blob container on a schedule using the Azure Blob
Storage managed connector, authenticated with Managed Identity — no
connection string or access key anywhere in the project.

## What gets provisioned

`azd up` creates, in a new resource group:

| Resource | Why |
|---|---|
| Storage account (`st<token>`) | Logic App runtime content — required plumbing |
| Storage account (`data<token>`) | The actual data the workflow reads — **kept separate on purpose** |
| App Service Plan, WS1 (Workflow Standard) | Hosts the Logic App |
| Logic App Standard (`logic-<token>`) | System-assigned managed identity, `kind: functionapp,workflowapp` |
| API connection (`azureblob`) | Managed connector, `authentication.type: ManagedServiceIdentity` |
| Connection access policy | Trusts the Logic App's identity — no local key |
| Role assignment | Storage Blob Data Reader, scoped to `data<token>` only — **not** the resource group, **not** the runtime storage account |

That last row is the point of the sample: the RBAC scoping from the blog
post, made concrete instead of just asserted.

## Deploy with azd

```bash
azd auth login
azd up
```

`azd up` provisions the infrastructure (`azd provision`) and deploys the
workflow project (`azd deploy`) in one step. Pick an environment name and a
region that supports the WS1 SKU when prompted (most paired regions do;
check the [Workflow Standard availability
table](https://learn.microsoft.com/en-us/azure/logic-apps/single-tenant-overview-compare#regions-and-availability-zone-support)
if in doubt).

To tear everything down afterward:

```bash
azd down --purge
```

## Run it locally first (optional, but the whole point of the post)

1. Install the [Azure Logic Apps (Standard) extension](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-azurelogicapps)
   for VS Code, on a version recent enough to support Managed Identity for
   local run/debug.
2. `az login` as the identity you want the extension to use locally — it
   picks this up through the Azure default credential pattern.
3. `cd workflow-app`, copy `local.settings.json.example` to
   `local.settings.json`, and fill in the subscription ID, resource group,
   region, and `DATA_STORAGE_ACCOUNT_NAME` from your `azd up` output
   (`azd env get-values` after provisioning shows them).
4. Leave `WORKFLOWS_AUTHENTICATION_METHOD` unset to use the Managed
   Identity behavior. Set it to `Raw` to fall back to the legacy local-key
   behavior if you need to compare.
5. Grant your **signed-in user** the same Storage Blob Data Reader role on
   `data<token>` that the deployed app gets (see `infra/resources.bicep`)
   — the RBAC assignment in Bicep only covers the app's identity, not you.
6. Run/debug the workflow from VS Code.

## The one gotcha worth knowing up front

With Managed Identity as the auth type, the designer won't populate
dynamic dropdown values for managed connectors — you supply values (like
the folder path here) directly instead of picking them from a live list.
`workflow.json` hardcodes the folder path for that reason.

## If something won't authorize

Check the RBAC role assignment on the target resource before anything
else. A Managed Identity with too broad a role — Contributor on the
resource group, say, instead of Storage Blob Data Reader on one storage
account — will authenticate just fine and still be the wrong outcome.

## `dotnet` deployed, `node` locally — that's expected

The deployed Logic App's `FUNCTIONS_WORKER_RUNTIME` app setting is set to
`dotnet` in `resources.bicep`. That's not a mismatch with local dev — it's
current Microsoft guidance: Azure now normalizes this setting to `dotnet`
for all deployed Standard logic apps regardless of what you set it to.
`local.settings.json.example`, by contrast, stays on `node`, which is
still what the VS Code extension defaults to for local run/debug. If a
workflow action that needs the JS worker (like Execute JavaScript Code)
fails locally, that split is usually why — this sample's own workflow
doesn't use one, so it shouldn't bite you here, but it's worth knowing
before you extend it.

## Deploying without azd

If you'd rather provision manually or already have the resources:

```bash
az deployment sub create \
  --location <region> \
  --template-file infra/main.bicep \
  --parameters environmentName=<name> location=<region>
```

Then zip-deploy the workflow project the same way `azd deploy` does:

```bash
cd workflow-app
zip -r ../workflow.zip .
az logicapp deployment source config-zip \
  --resource-group <your-resource-group> \
  --name <your-logic-app-name> \
  --src ../workflow.zip
```

## Honesty check

This template is built from documented Azure resource shapes (the
`Microsoft.Web/sites` `kind: functionapp,workflowapp` pattern, the
`azd`/`host: function` service model used in Microsoft's own Logic Apps
Standard `azd` samples, and the API connection + access policy pattern from
Microsoft's connector docs) — but it hasn't been run end to end against a
live subscription. The pieces most likely to need a tweak if `azd up`
errors out:

- **`azureblob_connectionRuntimeUrl`** — resolved via
  `reference(..., 'Full').properties.connectionRuntimeUrl` in
  `resources.bicep`, the standard workaround for a property Bicep doesn't
  expose in its typed schema. If this fails to resolve at deploy time,
  fetch it manually from the connection resource after a first deploy and
  hardcode it temporarily to unblock yourself.
- **Resource provider registration** — `Microsoft.Web/connections`
  usually registers automatically the first time you create one, but if
  the deployment fails on that resource, run
  `az provider register --namespace Microsoft.Web` and retry.
- **Region support for WS1** — not every region has Workflow Standard
  capacity; if provisioning fails on the plan, try `westeurope`,
  `eastus2`, or another major region.

If you hit and fix one of these, it's worth a note back in this README for
the next person.

### Fixed since the first version of this sample

- `infra/resources.bicep` — the API connection was missing `kind: 'V2'`.
  Without it, `connectionRuntimeUrl` isn't returned by the Microsoft.Web/connections
  API at all — not a Bicep bug, an API behavior tied to that `kind` value
  (long-standing, still-open upstream issue:
  [Azure/bicep#3494](https://github.com/Azure/bicep/issues/3494)). Bicep's
  linter doesn't know the `kind` property exists for this resource type
  (its schema is incomplete) and will warn accordingly — that warning is
  expected and doesn't block deployment.
- `infra/resources.bicep` — the API connection access policy's `name` was
  set to `logicApp.identity.principalId`. Bicep rejects that: a resource
  name has to be computable before deployment starts, and a
  system-assigned identity's principal ID only exists once the identity
  is actually created. Fixed to `name: logicApp.name`; the principal ID
  still goes into `properties.principal.identity.objectId`, which is fine
  at runtime.
- `workflow-app/package.json` — added. `azd`'s `language: js` packaging
  step runs `npm install` before zipping, which fails outright without a
  `package.json` even when there's nothing to install.

