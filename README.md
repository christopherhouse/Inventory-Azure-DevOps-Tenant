# 🚀 Azure DevOps Tenant Inventory

A PowerShell script that takes a fast, read-only census of an **Azure DevOps organization** — projects, work items, repos, pipelines, service connections, variable groups, wikis, and artifact feeds — and rolls it all up into a tidy CSV summary. 📊

Perfect for migration planning, tenant audits, or just answering the eternal question: *"what's actually in this org?"* 🤔

---

## ✨ What it does

`Get-Ado-Inventory.ps1` authenticates with your existing **Azure CLI** session (no PATs to mint or rotate! 🔐), walks every project in the organization via the Azure DevOps REST APIs, and counts:

| | Resource | Source API |
|---|---|---|
| 📦 | **Projects** | Core `projects` API |
| 📋 | **Work Items** | Analytics OData (`v4.0-preview`) |
| 📁 | **Git Repositories** | `git/repositories` |
| ⚙️ | **Pipelines** | `pipelines` |
| 🔌 | **Service Connections** | `serviceendpoint/endpoints` |
| 🧮 | **Variable Groups** | `distributedtask/variablegroups` |
| 📖 | **Wikis** | `wiki/wikis` |
| 📚 | **Artifact Feeds** (org-wide) | `packaging/feeds` |

Along the way it prints a colorful, emoji-studded progress report per project, then finishes with an org-level summary table and a CSV export. 🎉

---

## 📋 Prerequisites

- 🪟 **PowerShell** — Windows PowerShell 5.1 or PowerShell 7+ (the script avoids PS7-only syntax on purpose)
- ☁️ **Azure CLI** (`az`) — installed and signed in: `az login`
- 👤 An identity with **read access** to the target Azure DevOps organization (Basic access level is plenty)

> 💡 No Personal Access Token required! The script acquires a Microsoft Entra access token for the Azure DevOps resource (`499b84ac-1321-427f-aa17-267ca6975798`) straight from your `az` session.

---

## 🏃 Usage

### Basic

```powershell
.\Get-Ado-Inventory.ps1 -Organization contoso
```

### When the org lives in a different Entra tenant 🏢

If your `az` default subscription belongs to a different tenant than the one backing the Azure DevOps organization, pass the tenant explicitly:

```powershell
.\Get-Ado-Inventory.ps1 -Organization contoso -TenantId 00000000-0000-0000-0000-000000000000
```

Find your available tenants with:

```powershell
az account list --query "[].{name:name, tenantId:tenantId}" -o table
```

### Custom output folder 📂

```powershell
.\Get-Ado-Inventory.ps1 -Organization contoso -OutDir .\reports
```

---

## 🎛️ Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Organization` | ✅ Yes | — | The Azure DevOps organization name (the `contoso` in `dev.azure.com/contoso`) |
| `-TenantId` | ❌ No | az default | The Microsoft Entra tenant that backs the organization. Needed when it differs from your `az` CLI default context |
| `-OutDir` | ❌ No | `.\ado-inventory` | Folder where the CSV report is written (created automatically) |

---

## 🖥️ Sample output

```
  🚀 Azure DevOps Inventory — org: contoso
  ═══════════════════════════════════════════

🔑 Acquiring Azure DevOps access token...
✅ Token acquired.
🔭 Enumerating projects...
✅ Found 3 project(s).

  📦 [1/3] Widgets
       📋 412  📁 9  ⚙️ 14  🔌 5  🧮 7  📖 1
  📦 [2/3] Gadgets
       📋 87   📁 4  ⚙️ 6   🔌 2  🧮 3  📖 0
  📦 [3/3] Gizmos
       📋 230  📁 6  ⚙️ 11  🔌 4  🧮 5  📖 1

🌐 Collecting org-wide feed information...

  ✨ ═══════════════════════════════════ ✨
     🏆 Azure DevOps Inventory Summary
  ✨ ═══════════════════════════════════ ✨

  🏢 Organization        contoso
  📦 Projects            3
  📋 Work Items          729
  📁 Repositories        19
  ⚙️ Pipelines           31
  🔌 Service Connections 11
  🧮 Variable Groups     15
  📖 Wikis               2
  📚 Artifact Feeds      4

💾 Report written to: .\ado-inventory\ado-org-summary.csv
🎉 Inventory complete!
```

### 📄 CSV output

The script writes `ado-org-summary.csv` to the output folder with one summary row per run:

```csv
"Organization","Projects","WorkItems","Repositories","Pipelines","ServiceConnections","VariableGroups","Wikis","ArtifactFeeds"
"contoso","3","729","19","31","11","15","2","4"
```

A `?` in console output (or a blank CSV cell) means that particular count couldn't be retrieved — usually a permissions gap on a single API — while the rest of the inventory carries on. 💪

---

## 🔍 How it works

1. 🔑 **Token acquisition** — calls `az account get-access-token` against the Azure DevOps resource ID, optionally scoped to `-TenantId`.
2. 🔭 **Project enumeration** — lists up to 1,000 projects via the Core REST API (`api-version=7.1`).
3. 📦 **Per-project counts** — for each project, queries the Git, Pipelines, Service Endpoint, Variable Group, and Wiki APIs.
4. 📋 **Work item counts** — uses the **Analytics OData** endpoint with a server-side `aggregate($count)`, so even huge backlogs are counted without paging through work items.
5. 🌐 **Org-wide extras** — counts artifact feeds at the organization level.
6. 💾 **Report** — aggregates everything into a single summary object and exports it to CSV.

Every API call is wrapped in error handling: failures produce a warning and a `?` placeholder rather than killing the run. 🛡️

---

## 🛠️ Troubleshooting

### 💥 "Azure DevOps returned a sign-in page instead of JSON"

This is the script's built-in detection for a **tenant mismatch**. Azure DevOps responds to a token from the wrong tenant with HTTP `203` and an HTML sign-in page instead of a proper error. Fix it by passing `-TenantId` with the Entra tenant that actually backs the organization:

```powershell
az account list -o table   # find the right tenant
.\Get-Ado-Inventory.ps1 -Organization contoso -TenantId <that-tenant-id>
```

### 💥 "Failed to acquire Azure DevOps access token"

Your `az` session is missing or expired — run `az login` (add `--tenant <id>` if needed) and try again.

### ⚠️ "No projects found or insufficient permissions"

Either the organization name is misspelled, or your identity can't see any projects in it. Double-check the org name in the `dev.azure.com/<org>` URL and your access level.

### ❓ Question marks in the output

A `?` for a single count means that one API call failed (often a permission missing for that specific feature, e.g. Analytics views for work item counts). The warning printed above the summary tells you which URI failed.

---

## 📜 License

Licensed under the terms of the [LICENSE](LICENSE) file in this repository.
