<#
.SYNOPSIS
 Audits the secrets being used in a given GitHub organization, its repositories, and their environments
.DESCRIPTION
 This requires the GitHub CLI to be installed and the GEI PAT environment variables 
 (GH_PAT, GH_SOURCE_PAT) to be set (or provided on the command line. The tokens will
 require the following scopes:
  - admin:org
#>

#Requires -Version 7.0
param(
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub source organization name")]
    [string]$source,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub destination organization PAT")]
    [securestring]$sourcePat = (ConvertTo-SecureString -String $env:GH_SOURCE_PAT -AsPlainText -Force),
    [Parameter(Mandatory=$false,
        HelpMessage = "The destination file for the results")]
    [string]$output,
    [switch]$debugRequests
)

$ErrorActionPreference = "Stop"
function Invoke-RestApi {
    param(
        [string] $url,
        [string] $method = 'GET',
        [string] $body = $null,
        [securestring] $token,
        [int] $maxPages = 10
    )

    Write-Debug "Query: $url"
    if (--$maxPages -lt 0){
        throw "No more pages allowed for processing"
    }

    $headers = @{
        Accept = 'application/vnd.github+json'
        'Content-Type' = 'application/json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $response = Invoke-WebRequest -Authentication Bearer -Token $token `
                      -URI $url -Method $method -Headers $headers -Body $body
    $results = $response.Content | ConvertFrom-Json

    if ($DebugPreference -eq 'Continue' -and $debugRequests){
        $script:fileCounter++
        $fileName = "dbg-secrets-request-{0:d4}.txt" -f $script:fileCounter
        Write-Debug "Writing response to $fileName"
        $response.RawContent | Out-File -FilePath $fileName -Encoding utf8
    }

    $pageLink = if ($response.Headers.ContainsKey('Link')) { $response.Headers['Link'] } else { $null }
    
    if ($pageLink){
        Write-Debug "Server indicated multiple pages available"
        $pageLinks = [Regex]::Matches($pageLink, '<([\S]*)>; rel="([^"]{4,5})"')
        $last = $pageLinks | Where-Object { $_.Groups[2].Value -eq 'last' } | Select-Object -First 1
        if ($last -and $last.Groups[1].Value -ne $url) {
            $next = $pageLinks| Where-Object { $_.Groups[2].Value -eq 'next' } | Select-Object -First 1
            if ($next) {
                $linkUrl = $next.Groups[1].Value
                if ($linkUrl -ne $url){
                    $nestedResponse = Invoke-RestApi -url $linkUrl -token $token -maxPages $maxPages
                    $resultsHasTotal =  [bool]($results.PSobject.Properties.name -match 'total_count')
                    $responseHasTotal =  [bool]($nestedResponse.PSobject.Properties.name -match 'total_count')
                    
                    if ($resultsHasTotal -and $responseHasTotal) {
                        $results.total_count += $nestedResponse.total_count
                        $results.PSObject.properties | Write-Debug
                        $arrField = $results.PSObject.properties | Where-Object { $_.TypeNameOfValue -eq 'System.Object[]' } | Select-Object -First 1
                        if ($null -eq $arrField) {
                            throw 'Could not find pageable array.'
                        }
                        $field = $arrField.Name
                        $results.$field += $nestedResponse.$field
                    }
                    else {
                        if ($results -isnot [array]) {
                            $results = @($results)
                        }
                        $results += $nestedResponse
                    }
                }
            }
        }
    }
    $results
}

function Get-OrgSecrets {
    param(
        [string] $org,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/orgs/$org/actions/secrets?per_page=100"
    Invoke-RestApi -url $url -token $token
}

function Get-RepoSecrets {
    param(
        [string] $org,
        [string] $repo,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/repos/$org/$repo/actions/secrets?per_page=100"
    Invoke-RestApi -url $url -token $token
}

function Get-RepoEnvSecrets {
    param(
        [string] $org,
        [string] $repoId,
        [string] $envName,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/repositories/$repoId/environments/$envName/secrets?per_page=100"
    Invoke-RestApi -url $url -token $token
}

function Get-Environments {
    param(
        [string] $org,
        [string] $repo,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/repos/$org/$repo/environments?per_page=100"
    Invoke-RestApi -url $url -token $token
}

function Get-DependabotOrgSecrets{
    param(
        [string] $org,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/orgs/$org/dependabot/secrets?per_page=100"
    Invoke-RestApi -url $url -token $token
}

function Get-DependabotRepoSecrets{
    param(
        [string] $org,
        [string] $repo,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/repos/$org/$repo/dependabot/secrets?per_page=100"
    Invoke-RestApi -url $url -token $token
}

function Get-OrgRepositories {
    
    param(
        [string] $org,
        [securestring] $token
    )

    Write-Debug $MyInvocation.MyCommand
    $url = "https://api.github.com/orgs/$org/repos?per_page=100"
    $response = Invoke-RestApi -url $url -token $token
    $response | ForEach-Object {
        [PSCustomObject]@{
            Id = $_.id
            Name = $_.name
            FullName = $_.full_name
        }
    }
}

function New-SecretRecords($org, $repo, $environment, [bool]$isDependabot, $secrets){
    if (-not $secrets){
        return @()
    }
    $secrets | ForEach-Object {
        if ($_) {
            [PSCustomObject]@{
                org = $org
                repo = $repo
                environment = $environment
                isDependabot = $isDependabot
                secretName = $_.name
            }
        }
    }
}

class Progress {
    [string] $activity
    [int] $total
    [int] $current

    Progress([string] $activity, [array] $data, [int] $multiplier = 1){
        $this.activity = $activity
        $this.total = $data.Count * $multiplier
        $this.current = 0
    }

    Increment() {
        $this.current++
        $progress = ($this.current/$this.total)*100
        Write-Progress -Activity $this.activity -Status ("{0:N2}%" -f $progress ) -PercentComplete $progress
    }
}

try {
    $records = @()
    Write-Progress -Activity "Processing $source organization" -Status "5%" -PercentComplete 5
    $records += New-SecretRecords -org $source -repo $null -environment $null -isDependabot $false `
        -secrets (Get-OrgSecrets -org $source -token $sourcePat).secrets
    Write-Progress -Activity "Processing $source organization"  -Status "33%" -PercentComplete 33
    $records += New-SecretRecords -org $source -repo $null -environment $null -isDependabot $true `
        -secrets (Get-DependabotOrgSecrets -org $source -token $sourcePat).secrets
    Write-Progress -Activity "Processing $source organization"  -Status "66%" -PercentComplete 66    

    $repos = Get-OrgRepositories -org $source -token $sourcePat
    Write-Progress -Activity "Processing $source organization" -Completed
    $repoProgress = [Progress]::new("Processing $source repos", $repos, 3)
    foreach($repo in $repos){ 
        $repoProgress.Increment()
        $records += New-SecretRecords -org $source -repo $repo.Name -environment $null -isDependabot $false `
            -secrets (Get-RepoSecrets -org $source -repo $repo.Name -token $sourcePat).secrets
        $repoProgress.Increment()
        $records += New-SecretRecords -org $source -repo $repo.Name -environment $null -isDependabot $true `
            -secrets (Get-DependabotRepoSecrets -org $source -repo $repo.Name -token $sourcePat).secrets
        $repoProgress.Increment()
        $environments = (Get-Environments -org $source -repo $repo.Name -token $sourcePat).environments
        foreach ($environment in $environments){
            $envName = $environment.name
            $records += New-SecretRecords -org $source -repo $repo.Name -environment $envName -isDependabot $false `
                -secrets (Get-RepoEnvSecrets -repoId $repo.Id -org $source -token $sourcePat -envName $envName).secrets
        }
    }

    if ($output){
        $records | Export-Csv -Path $output -NoTypeInformation
    }
    $records
}
catch {
  $e = $_.Exception
  $line = $_.InvocationInfo.ScriptLineNumber
  $msg = $e.Message 
  Write-Host -ForegroundColor Red "Caught exception (line $line): $e"
  Write-Error $msg
}