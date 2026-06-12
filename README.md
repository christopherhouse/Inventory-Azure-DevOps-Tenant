# 🚀 Azure DevOps Tenant Inventory

A PowerShell script that takes a read-only census of an **Azure DevOps organization** and produces source-side row counts for the 16 entity tables synced by an ELT connector (Fivetran-style schema) — so you can validate that what landed in your warehouse matches what's actually in the org. 📊

Perfect for migration planning, sync validation, tenant audits, or just answering the eternal question: *"what's actually in this org?"* 🤔

---

## ✨ What it does

`Get-Ado-Inventory.ps1` authenticates with your existing **Azure CLI** session (no PATs to mint or rotate! 🔐), walks every project in the organization, and produces a count for each of these destination tables:

| Table | Count source | Notes |
|---|---|---|
| `project` | Core `_apis/projects` | One row per project |
| `item` | Analytics OData `WorkItems` | Server-side `aggregate($count)` — work items |
| `work_item_revision` | Analytics OData `WorkItemRevisions` | All historic revisions incl. current |
| `label` | Analytics OData `Tags` | Work item tags per project |
| `query` | `wit/queries` (recursive) | Saved work item queries — folders excluded |
| `plan` | `work/plans` | Delivery plans |
| `approval` | `pipelines/approvals` | Pipeline (environment) approvals |
| `project_property` | `projects/{id}/properties` | Properties per project |
| `project_pipeline` | `_apis/pipelines` | YAML/classic build pipelines |
| `pull_request` | `git/pullrequests?searchCriteria.status=all` | All statuses, paged project-wide |
| `pull_request_reviewer` | `reviewers[]` on the PR list | One row per (PR, reviewer) |
| `pull_request_commit` | per-PR `/commits` | Continuation-token paged |
| `pull_request_work_item` | per-PR `/workitems` | Linked work item refs |
| `commit` | per-repo `/commits` (paged) | Default branch history |
| `commit_change_counts` | `changeCounts` on the commit list | One row per commit |
| `commit_parents` | per-commit GET, summing `parents[]` | One row per (commit, parent) edge |

> 🧭 **Why the mixed sources?** The Analytics OData API (`analytics.dev.azure.com`) only models work-item, pipeline, and test data — git entities (commits, pull requests) don't exist there, so those counts come from the Git REST API.

Along the way it prints a colorful, emoji-studded progress report per project, then finishes with an org-level totals table and a CSV export. 🎉

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

## 📄 CSV output

The script writes `ado-entity-counts.csv` to the output folder with one row per project plus a `(TOTAL)` row:

```csv
"Organization","ProjectName","pull_request","pull_request_commit","commit_parents","commit_change_counts","commit","pull_request_work_item","pull_request_reviewer","item","work_item_revision","plan","label","approval","project","query","project_property","project_pipeline"
"chhouse","Customer Work","16","22","71","56","56","9","4","11","49","0","4","72","1","0","12","61"
"chhouse","(TOTAL)","16","22","73","59","59","9","4","25","95","0","4","72","7","0","72","68"
```

A `?` in console output (or a blank CSV cell) means that particular count couldn't be retrieved — usually a permissions gap on a single API — while the rest of the inventory carries on. 💪

---

## 🔍 How it works

1. 🔑 **Token acquisition** — calls `az account get-access-token` against the Azure DevOps resource ID, optionally scoped to `-TenantId`.
2. 🔭 **Project enumeration** — lists up to 1,000 projects via the Core REST API (`api-version=7.1`).
3. 📋 **Work item domain** — `item`, `work_item_revision`, and `label` use the **Analytics OData** endpoint with a server-side `aggregate($count)`, so even huge backlogs are counted without paging.
4. 📁 **Git domain** — commits are paged per repository (1,000 at a time); pull requests are paged project-wide with `status=all`, and each PR's commits and linked work items are counted individually.
5. 🧬 **Commit parents** — the commit *list* APIs never return parent links, so the script fetches each commit individually and sums its `parents[]`. This is the slowest step (one call per commit) — expect it to dominate runtime on large repos.
6. 💾 **Report** — per-project rows plus an org `(TOTAL)` row are exported to CSV.

Every API call is wrapped in error handling: failures produce a warning and a `?` placeholder rather than killing the run. 🛡️

### ⚠️ Count caveats

- ⏭️ **Disabled repositories are skipped** — Azure DevOps refuses REST access to a disabled repo's git data (`TF401019`), so their commits/PRs can't be counted (your connector can't read them either).
- 🌿 **Commits cover the default branch** — the commits API returns default-branch history; commits reachable only from other branches aren't included.
- 📂 **`query` counts queries, not folders** — folder nodes in the query hierarchy are excluded; nested folders are walked recursively (the API caps `$depth` at 2).
- 📊 **`commit_change_counts` grain** — counted as one row per commit carrying a `changeCounts` object (Add/Edit/Delete columns), so it normally equals `commit`.

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
