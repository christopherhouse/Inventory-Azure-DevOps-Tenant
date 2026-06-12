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

function Get-WorkItemCount {
    param(
        [string]$Organization,
        [string]$Project
    )

    $projectEncoded = [uri]::EscapeDataString($Project)

    $uri = "https://analytics.dev.azure.com/$Organization/$projectEncoded/_odata/v4.0-preview/WorkItems?`$apply=aggregate(`$count as Count)"

    $result = Invoke-AdoJson $uri

    if ($null -eq $result) {
        return $null
    }

    if ($result.value.Count -gt 0) {
        return [int]$result.value[0].Count
    }

    # An empty aggregate result means the project has no work items.
    return 0
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

$projectInventory = @()
$projectNumber = 0

foreach ($project in $projects) {

    $projectName = $project.name
    $projectEncoded = [uri]::EscapeDataString($projectName)
    $projectNumber++

    Write-Host "  📦 [$projectNumber/$($projects.Count)] " -NoNewline -ForegroundColor DarkCyan
    Write-Host $projectName -ForegroundColor White

    $repoCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/git/repositories?api-version=7.1"

    $pipelineCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/pipelines?api-version=7.1"

    $serviceConnectionCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/serviceendpoint/endpoints?api-version=7.1"

    $variableGroupCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/distributedtask/variablegroups?api-version=7.1"

    $wikiCount = Get-CountFromRest `
        "https://dev.azure.com/$Organization/$projectEncoded/_apis/wiki/wikis?api-version=7.1"

    $workItemCount = Get-WorkItemCount `
        -Organization $Organization `
        -Project $projectName

    Write-Host ("       📋 {0}  📁 {1}  ⚙️ {2}  🔌 {3}  🧮 {4}  📖 {5}" -f `
        (Get-ValueOrPlaceholder $workItemCount), (Get-ValueOrPlaceholder $repoCount), `
        (Get-ValueOrPlaceholder $pipelineCount), (Get-ValueOrPlaceholder $serviceConnectionCount), `
        (Get-ValueOrPlaceholder $variableGroupCount), (Get-ValueOrPlaceholder $wikiCount)) `
        -ForegroundColor DarkGray

    $projectInventory += [PSCustomObject]@{
        Organization       = $Organization
        Project            = $projectName
        ProjectId          = $project.id
        State              = $project.state
        Visibility         = $project.visibility
        WorkItems          = $workItemCount
        Repositories       = $repoCount
        Pipelines          = $pipelineCount
        ServiceConnections = $serviceConnectionCount
        VariableGroups     = $variableGroupCount
        Wikis              = $wikiCount
    }
}

Write-Host ""
Write-Status "🌐" "Collecting org-wide feed information..."

$artifactFeedCount = Get-CountFromRest `
    "https://feeds.dev.azure.com/$Organization/_apis/packaging/feeds?api-version=7.1"

$summary = [PSCustomObject]@{
    Organization       = $Organization
    Projects           = $projects.Count
    WorkItems          = ($projectInventory | Measure-Object WorkItems -Sum).Sum
    Repositories       = ($projectInventory | Measure-Object Repositories -Sum).Sum
    Pipelines          = ($projectInventory | Measure-Object Pipelines -Sum).Sum
    ServiceConnections = ($projectInventory | Measure-Object ServiceConnections -Sum).Sum
    VariableGroups     = ($projectInventory | Measure-Object VariableGroups -Sum).Sum
    Wikis              = ($projectInventory | Measure-Object Wikis -Sum).Sum
    ArtifactFeeds      = $artifactFeedCount
}

$summary |
    Export-Csv `
        "$OutDir\ado-org-summary.csv" `
        -NoTypeInformation

Write-Host ""
Write-Host "  ✨ ═══════════════════════════════════ ✨" -ForegroundColor Magenta
Write-Host "     🏆 Azure DevOps Inventory Summary" -ForegroundColor Magenta
Write-Host "  ✨ ═══════════════════════════════════ ✨" -ForegroundColor Magenta
Write-Host ""

$summaryRows = @(
    @{ Emoji = '🏢'; Label = 'Organization';        Value = $summary.Organization }
    @{ Emoji = '📦'; Label = 'Projects';            Value = $summary.Projects }
    @{ Emoji = '📋'; Label = 'Work Items';          Value = $summary.WorkItems }
    @{ Emoji = '📁'; Label = 'Repositories';        Value = $summary.Repositories }
    @{ Emoji = '⚙️'; Label = 'Pipelines';           Value = $summary.Pipelines }
    @{ Emoji = '🔌'; Label = 'Service Connections'; Value = $summary.ServiceConnections }
    @{ Emoji = '🧮'; Label = 'Variable Groups';     Value = $summary.VariableGroups }
    @{ Emoji = '📖'; Label = 'Wikis';               Value = $summary.Wikis }
    @{ Emoji = '📚'; Label = 'Artifact Feeds';      Value = $summary.ArtifactFeeds }
)

foreach ($row in $summaryRows) {
    Write-Host "  $($row.Emoji) " -NoNewline
    Write-Host ("{0,-20}" -f $row.Label) -NoNewline -ForegroundColor Cyan
    Write-Host (Get-ValueOrPlaceholder $row.Value) -ForegroundColor Yellow
}

Write-Host ""
Write-Status "💾" "Report written to: $OutDir\ado-org-summary.csv" Green
Write-Status "🎉" "Inventory complete!" Green
