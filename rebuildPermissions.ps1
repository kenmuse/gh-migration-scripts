<#
.SYNOPSIS
 Rebuilds the permissions for teams and repositories in a target organization
.DESCRIPTION
 This requires the GitHub CLI to be installed and the GEI PAT environment variables 
 (GH_PAT, GH_SOURCE_PAT) to be set (or provided on the command line. The tokens will
 require the following scopes:
  - admin:org
#>

#Requires -Version 7.0
param(
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub destination organization name")]
    [string]$dest,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub destination organization PAT")]
    [securestring]$destPat = (ConvertTo-SecureString -String $env:GH_PAT -AsPlainText -Force),
    [Parameter(Mandatory=$false,
        HelpMessage = "A CSV containing team permissions")]
    [string]$teamCsv = 'results-teams.csv',
    [Parameter(Mandatory=$false,
        HelpMessage = "A CSV containing direct access permissions")]
    [string]$accessCsv = 'results-repo-access.csv'
)

$ErrorActionPreference = "Stop"

function Invoke-Throttle {
<#
    .SYNOPSIS
    Applies a time-based throttle to any updating requests
    .DESCRIPTION
    GitHub recommends never updating records more often than once per second
    to avoid throttling. This implements that logic.
#>    
    $DELAY = 1 # Time in seconds to wait between updating requests
    $now = [DateTime]::Now.Ticks
    $last = $script:lastRequest
    if ($last){
        $nowComp = $now / 1000000
        $target = (1000000 * $DELAY) + $last
        $targetComp = $target/1000000
        if ($nowComp -lt $targetComp) {
            Start-Sleep -Seconds ($targetComp - $nowComp)
            $now = [DateTime]::Now.Ticks
        }
    }
    $script:lastRequest = $now
}

function Update-TeamMembership {
    param(
        [string] $org,
        [string] $slug,
        [string] $role,
        [string] $handle,
        [securestring] $token
    )
    
    Invoke-Throttle

    $url = "https://api.github.com/orgs/$org/teams/$slug/memberships/$handle"
    $method = 'PUT'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'Content-Type' = 'application/json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $body = @{
        role = $role
    } | ConvertTo-Json

    $response = Invoke-WebRequest -Authentication Bearer -Token $token `
                                  -URI $url -Method $method -Headers $headers -Body $body
}

function Get-Repository {
    param(
        [string] $org,
        [string] $repo,
        [securestring] $token
    )

    $url = "https://api.github.com/repos/$org/$repo"
    $method = 'GET'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'Content-Type' = 'application/json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $response = Invoke-WebRequest -Authentication Bearer -Token $token `
                                  -URI $url -Method $method -Headers $headers
    return $response.Content | ConvertFrom-Json    
}

function Get-ExternalGroups {
    param(
        [string] $org,
        [string] $team,
        [securestring] $token
    )

    $url = "https://api.github.com/orgs/$org/teams/$team/external-groups"
    $method = 'GET'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'Content-Type' = 'application/json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    try {
        $response = Invoke-WebRequest -Authentication Bearer -Token $token `
                                    -URI $url -Method $method -Headers $headers
        return $response.Content | ConvertFrom-Json    
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 400) {
            # The team does not allow external groups (explicit members present)
            return $null
        }
        throw $_
    }
}

function Get-IsRepositoryArchived {
    param(
        [string] $org,
        [string] $repo,
        [securestring] $token
    )

    $response = Get-Repository -org $org -repo $repo -token $token
    return [bool]$response.archived
}

function Update-RepositoryAccess {
    param(
        [string] $org,
        [string] $repo,
        [string] $permission,
        [string] $handle,
        [securestring] $token
    )

    Invoke-Throttle

    $url = "https://api.github.com/repos/$org/$repo/collaborators/$handle"
    $method = 'PUT'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'Content-Type' = 'application/json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $body = @{
        permission = $permission
    } | ConvertTo-Json

    $response = Invoke-WebRequest -Authentication Bearer -Token $token `
                                  -URI $url -Method $method -Headers $headers -Body $body
}

if ((Get-PSCallStack).Count -le 2){
    if (-not $destPat) {
      Write-Host "Missing source PAT"
      return
    }

    if (-not ($teamCsv -and (Test-Path $teamCsv))) {
        throw "Team file not found: $teamCsv"
    }

    if (-not ($accessCsv -and (Test-Path $accessCsv))) {
        throw "Access file not found: $accessCsv"
    }

    $teams = Import-Csv -Path $teamCsv
    $access = Import-Csv -Path $accessCsv

    $teamsWithExternalGroups = @{}
    foreach ($team in $teams){
        if (-not $team.Destination -or -not $Team.Slug -or -not $team.Role){
            "Incomplete team mapping found for $($team.Source) ($($team.Destination)) in $dest/$($team.Slug). Skipping." | Write-Host
            continue
        }

        if ($teamsWithExternalGroups.ContainsKey($team.Slug)){
            if ($teamsWithExternalGroups[$team.Slug]){
                continue
            }
        }
        else {
            $externalGroups = Get-ExternalGroups -org $dest -team $team.Slug -token $destPat
            if ($externalGroups -and $externalGroups.groups -and ($externalGroups.groups.Count -gt 0)){
                $teamsWithExternalGroups[$team.Slug] = $true
                "Team is managed by an external group: $($team.Slug). Skipping." | Write-Host
                continue
            }
            else {
                $teamsWithExternalGroups[$team.Slug] = $false
            }
        }

        "Adding team $($team.Role) permission to @$dest/$($team.Slug) for @$($team.Destination)" | Write-Host
        try {
            $role = $team.Role.ToLower()
            if ($role -ne "member" -and $role -ne "maintainer"){
                "Invalid role specified for @$($team.Destination): $role. Skipping" | Write-Warning
                continue
            }

            Update-TeamMembership -org $dest -slug $team.Slug `
                                -role $role -handle $team.Destination -token $destPat
        }
        catch {
            $StatusCode = $_.Exception.Response.StatusCode.value__
            "Failed to update $($team.Slug) ($StatusCode)" | Write-Warning
            $_.Exception.Response | Write-Warning
            throw $_
        }
    }

    foreach ($access in $access){
        if (-not $access.Destination -or -not $access.Repository -or -not $access.Permission){
            "Incomplete repo mapping found for $($access.Source) ($($access.Destination)) in $dest/$($access.Repository). Skipping." | Write-Host
            continue
        }

        "Adding repository $($access.Permission) permission to $dest/$($access.Repository) for @$($access.Destination)" | Write-Host
        try{
            $permission = $access.Permission.ToLower()
            switch ($permission){
                'pull' { }
                'triage' { }
                'push' { }
                'maintain' { }
                'admin' { }
                'read' { $permission = 'pull' }
                'write' { $permission = 'push' }
                default {
                    "Invalid permission specified for @$($access.Destination): $permission. Skipping"  | Write-Warning
                    continue
                }
            }

            if (Get-IsRepositoryArchived -org $dest -repo $access.Repository -token $destPat){
                "Skipping archived repository $($access.Repository)" | Write-Host
                continue
            }

            Update-RepositoryAccess -org $dest -repo $access.Repository `
                                    -permission $permission -handle $access.Destination -token $destPat
        }
        catch {
            $StatusCode = $_.Exception.Response.StatusCode.value__
            "Failed to update $($access.Repository) ($StatusCode)" | Write-Warning
            if ($_.Exception -and $_.Exception.Response) {
                $_.Exception.Response | Write-Warning
            }
            else {
                $_.Exception | Write-Warning
            }
            throw $_
        }
    }
}
