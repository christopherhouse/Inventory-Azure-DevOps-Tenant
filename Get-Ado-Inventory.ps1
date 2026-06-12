param(
    [Parameter(Mandatory)]
    [string]$Organization,

    # Entra tenant that backs the Azure DevOps organization. Required when it
    # differs from the az CLI default context (see 'az account list').
    [string]$TenantId,

    [string]$OutDir = ".\ado-inventory"
)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# PS 5.1-compatible stand-in for the ?? operator.
function Get-ValueOrPlaceholder {
    param($Value)

    if ($null -ne $Value) { return $Value }
    return '?'
}

function Write-Status {
    param(
        [string]$Emoji,
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )

    Write-Host "$Emoji " -NoNewline
    Write-Host $Message -ForegroundColor $Color
}

Write-Host ""
Write-Host "  🚀 Azure DevOps Inventory " -ForegroundColor Magenta -NoNewline
Write-Host "— org: " -NoNewline
Write-Host $Organization -ForegroundColor Yellow
Write-Host "  ═══════════════════════════════════════════" -ForegroundColor DarkMagenta
Write-Host ""

# Azure DevOps resource ID
$adoResource = "499b84ac-1321-427f-aa17-267ca6975798"

Write-Status "🔑" "Acquiring Azure DevOps access token..."

$tokenArgs = @(
    'account', 'get-access-token',
    '--resource', $adoResource,
    '--query', 'accessToken',
    '-o', 'tsv'
)

if ($TenantId) {
    $tokenArgs += @('--tenant', $TenantId)
}

$token = az @tokenArgs

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Status "💥" "Token acquisition failed!" Red
    throw "Failed to acquire Azure DevOps access token. Run 'az login' first."
}

Write-Status "✅" "Token acquired." Green

$headers = @{
    Authorization = "Bearer $token"
}

function Invoke-AdoJson {
    param(
        [string]$Uri
    )

    try {
        $result = Invoke-RestMethod `
            -Uri $Uri `
            -Headers $headers `
            -Method Get
    }
    catch {
        Write-Warning "Failed: $Uri"
        Write-Warning $_.Exception.Message
        return $null
    }

    # A token that is not valid for the organization gets HTTP 203 with a
    # sign-in HTML page instead of an error, which Invoke-RestMethod returns
    # as a plain string.
    if ($result -is [string] -and $result -match '(?i)<html') {
        throw ("Azure DevOps returned a sign-in page instead of JSON. " +
            "The access token is not valid for organization '$Organization'. " +
            "Re-run with -TenantId set to the Entra tenant that backs the " +
            "organization (see 'az account list' for available tenants).")
    }

    return $result
}

function Get-CountFromRest {
    param(
        [string]$Uri
    )

    $result = Invoke-AdoJson $Uri

    if ($null -eq $result) {
        return $null
    }

    if ($null -ne $result.count) {
        return [int]$result.count
    }

    if ($null -ne $result.value) {
        return @($result.value).Count
    }

    return $null
}

# Server-side row count of an Analytics OData entity set, so even large
# tables are counted without paging.
function Get-AnalyticsCount {
    param(
        [string]$Project,
        [string]$EntitySet
    )

    $projectEncoded = [uri]::EscapeDataString($Project)

    $uri = "https://analytics.dev.azure.com/$Organization/$projectEncoded/_odata/v4.0-preview/$EntitySet`?`$apply=aggregate(`$count as Count)"

    $result = Invoke-AdoJson $uri

    if ($null -eq $result) {
        return $null
    }

    if ($result.value.Count -gt 0) {
        return [int]$result.value[0].Count
    }

    # An empty aggregate result means the entity set has no rows.
    return 0
}

# Counts saved work item queries (folders excluded), recursing into folders
# because the queries API caps $depth at 2.
function Get-QueryCount {
    param(
        [string]$ProjectEncoded,
        [string]$FolderId
    )

    if ($FolderId) {
        $uri = "https://dev.azure.com/$Organization/$ProjectEncoded/_apis/wit/queries/$FolderId`?`$depth=2&`$expand=none&api-version=7.1"
    }
    else {
        $uri = "https://dev.azure.com/$Organization/$ProjectEncoded/_apis/wit/queries?`$depth=2&api-version=7.1"
    }

    $result = Invoke-AdoJson $uri

    if ($null -eq $result) {
        return $null
    }

    if ($FolderId) {
        $nodes = @($result.children)
    }
    else {
        $nodes = @($result.value)
    }

    $count = 0

    foreach ($node in $nodes) {
        if ($null -eq $node) { continue }

        if (-not $node.isFolder) {
            $count++
            continue
        }

        if ($node.children) {
            foreach ($child in $node.children) {
                if (-not $child.isFolder) {
                    $count++
                }
                elseif ($child.hasChildren) {
                    # Depth limit reached; re-query from this folder.
                    $sub = Get-QueryCount -ProjectEncoded $ProjectEncoded -FolderId $child.id
                    if ($null -ne $sub) { $count += $sub }
                }
            }
        }
        elseif ($node.hasChildren) {
            $sub = Get-QueryCount -ProjectEncoded $ProjectEncoded -FolderId $node.id
            if ($null -ne $sub) { $count += $sub }
        }
    }

    return $count
}

# Pages a REST list endpoint that signals more results via the
# x-ms-continuationtoken response header (e.g. pull request commits).
function Get-ContinuationCount {
    param(
        [string]$Uri
    )

    $total = 0
    $continuationToken = $null

    do {
        $pageUri = $Uri
        if ($continuationToken) {
            $pageUri += "&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        try {
            $response = Invoke-WebRequest `
                -Uri $pageUri `
                -Headers $headers `
                -Method Get `
                -UseBasicParsing
        }
        catch {
            Write-Warning "Failed: $pageUri"
            Write-Warning $_.Exception.Message
            return $null
        }

        $page = $response.Content | ConvertFrom-Json
        $total += @($page.value).Count

        # PS7 exposes header values as string arrays; PS5.1 as strings.
        $continuationToken = @($response.Headers['x-ms-continuationtoken'])[0]
    } while ($continuationToken)

    return $total
}

Write-Status "🔭" "Enumerating projects..."

$projectsResult = Invoke-AdoJson `
    "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1&`$top=1000"

$projects = @($projectsResult.value | Where-Object { $_ })

if ($projects.Count -eq 0) {
    Write-Status "💥" "No projects found!" Red
    throw "No projects found or insufficient permissions."
}

Write-Status "✅" "Found $($projects.Count) project(s)." Green
Write-Host ""

# One column per destination table we validate counts against.
$entityColumns = @(
    'pull_request', 'pull_request_commit', 'commit_parents',
    'commit_change_counts', 'commit', 'pull_request_work_item',
    'pull_request_reviewer', 'item', 'work_item_revision', 'plan',
    'label', 'approval', 'project', 'query', 'project_property',
    'project_pipeline'
)

$projectInventory = @()
$projectNumber = 0

foreach ($project in $projects) {

    $projectName = $project.name
    $projectEncoded = [uri]::EscapeDataString($projectName)
    $projectNumber++

    Write-Host "  📦 [$projectNumber/$($projects.Count)] " -NoNewline -ForegroundColor DarkCyan
    Write-Host $projectName -ForegroundColor White

    # ── Work item domain (Analytics OData) ─────────────────────────────
    $itemCount = Get-AnalyticsCount -Project $projectName -EntitySet 'WorkItems'
    $workItemRevisionCount = Get-AnalyticsCount -Project $projectName -EntitySet 'WorkItemRevisions'
    $labelCount = Get-AnalyticsCount -Project $projectName -EntitySet 'Tags'

    # ── Project-scoped REST counts ──────────────────────────────────────
    $queryCount = Get-QueryCount -ProjectEncoded $projectEncoded

    $planCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/work/plans?api-version=7.1"

    $approvalCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/pipelines/approvals?top=2000&api-version=7.1-preview.1"

    $projectPropertyCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/_apis/projects/$($project.id)/properties?api-version=7.1-preview.1"

    $pipelineCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/pipelines?api-version=7.1"

    # ── Git: commits per enabled repository ─────────────────────────────
    $reposResult = Invoke-AdoJson `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/git/repositories?api-version=7.1"

    $repos = @($reposResult.value | Where-Object { $_ })
    $enabledRepos = @($repos | Where-Object { -not $_.isDisabled })
    $disabledRepoCount = $repos.Count - $enabledRepos.Count

    if ($disabledRepoCount -gt 0) {
        Write-Host "       ⏭️ Skipping $disabledRepoCount disabled repo(s) — their git data is not readable via REST." -ForegroundColor DarkYellow
    }

    $commitCount = 0
    $commitChangeCountRows = 0
    $commitParentCount = 0
    $commitIds = @()

    foreach ($repo in $enabledRepos) {

        $pageSize = 1000
        $skip = 0

        do {
            $page = Invoke-AdoJson ("https://dev.azure.com/$Organization/$projectEncoded/_apis/git/repositories/$($repo.id)/commits" +
                "?searchCriteria.`$top=$pageSize&searchCriteria.`$skip=$skip&api-version=7.1")

            if ($null -eq $page) { break }

            $pageCommits = @($page.value)
            $commitCount += $pageCommits.Count
            $commitChangeCountRows += @($pageCommits | Where-Object { $null -ne $_.changeCounts }).Count

            foreach ($c in $pageCommits) {
                $commitIds += [PSCustomObject]@{ RepoId = $repo.id; CommitId = $c.commitId }
            }

            $skip += $pageSize
        } while ($pageCommits.Count -eq $pageSize)
    }

    # The commit list APIs never include parent links, so parent edges have
    # to be summed one commit at a time.
    if ($commitIds.Count -gt 0) {
        Write-Host "       🧬 Counting parent links for $($commitIds.Count) commit(s)..." -ForegroundColor DarkGray

        $processed = 0
        foreach ($ref in $commitIds) {
            $commit = Invoke-AdoJson `
                "https://dev.azure.com/$Organization/$projectEncoded/_apis/git/repositories/$($ref.RepoId)/commits/$($ref.CommitId)?api-version=7.1"

            if ($null -ne $commit) {
                $commitParentCount += @($commit.parents).Count
            }

            $processed++
            if ($processed % 200 -eq 0) {
                Write-Host "       ⏳ $processed/$($commitIds.Count) commits..." -ForegroundColor DarkGray
            }
        }
    }

    # ── Git: pull requests and their joins ──────────────────────────────
    $pullRequestCount = 0
    $pullRequestReviewerCount = 0
    $pullRequestCommitCount = 0
    $pullRequestWorkItemCount = 0

    $prPageSize = 500
    $prSkip = 0
    $prRefs = @()

    do {
        $prPage = Invoke-AdoJson ("https://dev.azure.com/$Organization/$projectEncoded/_apis/git/pullrequests" +
            "?searchCriteria.status=all&`$top=$prPageSize&`$skip=$prSkip&api-version=7.1")

        if ($null -eq $prPage) { break }

        $prs = @($prPage.value)
        $pullRequestCount += $prs.Count

        foreach ($pr in $prs) {
            $pullRequestReviewerCount += @($pr.reviewers).Count
            $prRefs += [PSCustomObject]@{
                RepoId        = $pr.repository.id
                PullRequestId = $pr.pullRequestId
            }
        }

        $prSkip += $prPageSize
    } while ($prs.Count -eq $prPageSize)

    if ($prRefs.Count -gt 0) {
        Write-Host "       🔗 Counting commits + work items for $($prRefs.Count) pull request(s)..." -ForegroundColor DarkGray

        $processed = 0
        foreach ($prRef in $prRefs) {
            $prBase = "https://dev.azure.com/$Organization/$projectEncoded/_apis/git/repositories/$($prRef.RepoId)/pullRequests/$($prRef.PullRequestId)"

            $prCommits = Get-ContinuationCount "$prBase/commits?api-version=7.1"
            if ($null -ne $prCommits) { $pullRequestCommitCount += $prCommits }

            $prWorkItems = Get-CountFromRest "$prBase/workitems?api-version=7.1"
            if ($null -ne $prWorkItems) { $pullRequestWorkItemCount += $prWorkItems }

            $processed++
            if ($processed % 100 -eq 0) {
                Write-Host "       ⏳ $processed/$($prRefs.Count) pull requests..." -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ("       🔀 PRs {0}  📁 commits {1}  🧬 parents {2}  📋 items {3}  🕘 revisions {4}" -f `
        $pullRequestCount, $commitCount, $commitParentCount, `
        (Get-ValueOrPlaceholder $itemCount), (Get-ValueOrPlaceholder $workItemRevisionCount)) `
        -ForegroundColor DarkGray

    $projectInventory += [PSCustomObject]@{
        Organization           = $Organization
        ProjectName            = $projectName
        pull_request           = $pullRequestCount
        pull_request_commit    = $pullRequestCommitCount
        commit_parents         = $commitParentCount
        commit_change_counts   = $commitChangeCountRows
        commit                 = $commitCount
        pull_request_work_item = $pullRequestWorkItemCount
        pull_request_reviewer  = $pullRequestReviewerCount
        item                   = $itemCount
        work_item_revision     = $workItemRevisionCount
        plan                   = $planCount
        label                  = $labelCount
        approval               = $approvalCount
        project                = 1
        query                  = $queryCount
        project_property       = $projectPropertyCount
        project_pipeline       = $pipelineCount
    }
}

# ── Org-wide totals ─────────────────────────────────────────────────────
$totals = [ordered]@{
    Organization = $Organization
    ProjectName  = '(TOTAL)'
}

foreach ($column in $entityColumns) {
    $totals[$column] = ($projectInventory | Measure-Object $column -Sum).Sum
}

$totalsRow = [PSCustomObject]$totals

$csvPath = Join-Path $OutDir 'ado-entity-counts.csv'

@($projectInventory) + @($totalsRow) |
    Export-Csv $csvPath -NoTypeInformation

Write-Host ""
Write-Host "  ✨ ═══════════════════════════════════ ✨" -ForegroundColor Magenta
Write-Host "     🏆 Entity Counts (org total)" -ForegroundColor Magenta
Write-Host "  ✨ ═══════════════════════════════════ ✨" -ForegroundColor Magenta
Write-Host ""

foreach ($column in $entityColumns) {
    Write-Host "  📊 " -NoNewline
    Write-Host ("{0,-24}" -f $column) -NoNewline -ForegroundColor Cyan
    Write-Host (Get-ValueOrPlaceholder $totalsRow.$column) -ForegroundColor Yellow
}

Write-Host ""
Write-Status "💾" "Report written to: $csvPath" Green
Write-Status "🎉" "Inventory complete!" Green
