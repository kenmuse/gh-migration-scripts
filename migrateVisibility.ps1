<#
.SYNOPSIS
 Maps the members of one organization to another, creating a new mannequin file.
.DESCRIPTION
 This requires the GitHub CLI to be installed and the GEI PAT environment variables 
 (GH_PAT, GH_SOURCE_PAT) to be set (or provided on the command line. The tokens will
 require the following scopes:
  - admin:org
  - user:email
  - read:user
#>

#Requires -Version 7.0
param(
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub source organization name")]
    [string]$source,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub source organization PAT")]
    [securestring]$sourcePat = (ConvertTo-SecureString -String $env:GH_SOURCE_PAT -AsPlainText -Force),
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub destination organization name")]
    [string]$dest,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub destination organization PAT")]
    [securestring]$destPat = (ConvertTo-SecureString -String $env:GH_PAT -AsPlainText -Force),
    [switch]$debugRequests=$false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

class Progress {
    [string] $activity
    [int] $total
    [int] $current

    Progress([string] $activity, [array] $data){
        $this.activity = $activity
        $this.total = $data.Count
        $this.current = 0
    }

    Progress([string] $activity, [array] $data, [int] $multiplier = 1){
        $this.activity = $activity
        $this.total = $data.Count * $multiplier
        $this.current = 0
    }

    Increment() {
        $progress = ($this.current/$this.total)*100
        Write-Progress -Activity $this.activity -Status ("{0:N2}%" -f $progress ) -PercentComplete $progress
        $this.current++
    }
}

$last = $script:lastRequest = 0
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

function Get-Repository {
    param(
        [Parameter(Mandatory)]
        [string] $org,
        [Parameter(Mandatory)]
        [string] $repo,
        [Parameter(Mandatory)]
        [securestring] $token
    )

    Write-Debug "$($MyInvocation.MyCommand) $org/$repo"
    $url = "https://api.github.com/repos/$org/$repo"
    Invoke-RestApi -url $url -token $token
}

function Get-OrgRepositories {
    param(
        [Parameter(Mandatory)]
        [string] $org,
        [Parameter(Mandatory)]
        [securestring] $token
    )

    Write-Debug "$($MyInvocation.MyCommand) ($org)"
    $url = "https://api.github.com/orgs/$org/repos"
    Invoke-RestApi -url $url -token $token
}

function Get-IsRepositoryArchived {
    param(
        [string] $org,
        [string] $repo,
        [securestring] $token
    )

    Write-Debug "$($MyInvocation.MyCommand) ($org/$repo)"
    $response = Get-Repository -org $org -repo $repo -token $token
    return [bool]$response.archived
}

function Get-RepoVisibility {
    param(
        [Parameter(Mandatory)]
        [string] $org,
        [Parameter(Mandatory)]
        [string] $repo,
        [Parameter(Mandatory)]
        [securestring] $token
    )

    Write-Debug "$($MyInvocation.MyCommand) ($org/$repo)"
    $url = "https://api.github.com/repos/$org/$repo"
    $response = Invoke-RestApi -url $url -token $token
    [string]$response.visibility
}

function Update-RepoVisibility {
    param(
        [Parameter(Mandatory)]
        [string] $org,
        [Parameter(Mandatory)]
        [string] $repo,
        [Parameter(Mandatory)]
        [securestring] $token,
        [Parameter(Mandatory)]
        [ValidateSet('public','private','internal', IgnoreCase = $true)]
        [string]$visibility
    )

    Write-Debug "$($MyInvocation.MyCommand) ($org/$repo)"
    Invoke-Throttle
    $url = "https://api.github.com/repos/$org/$repo"
    $body = @{
        visibility = $visibility
    } | ConvertTo-Json
    Invoke-RestApi -url $url -token $token -method 'PATCH' -body $body
}

function Update-Repositories {
    param(
        [Parameter(Mandatory=$true,
        HelpMessage = "The GitHub source organization name")]
        [string]$sourceOrg,
        [Parameter(Mandatory=$false,
        HelpMessage = "The GitHub source organization PAT")]
        [securestring]$sourceToken,
        [Parameter(Mandatory=$true,
        HelpMessage = "The GitHub destination organization name")]
        [string]$destinationOrg,
        [Parameter(Mandatory=$false,
        HelpMessage = "The GitHub destination organization PAT")]
        [securestring]$destToken
    )

    $sourceRepos = Get-OrgRepositories -org $sourceOrg -token $sourceToken
    $progress = [Progress]::new("Updating repositories", $sourceRepos)
    foreach ($sourceRepo in $sourceRepos)
    {
        $progress.Increment()
        $repoName = $sourceRepo.name
        $visibility = $sourceRepo.visibility
        if ([bool]$sourceRepo.archived){
            Write-Debug "Repository $sourceOrg/$repoName is archived. Skipping."
            continue
        }

        try {
            $destVisibility = Get-RepoVisibility -org $destinationOrg -repo $repoName -token $destToken
            if ($destVisibility -eq $visibility) {
                Write-Debug "Destination repository $destinationOrg/$repoName already has $visibility visibility. Skipping."
                continue
            }
        } catch {
            $hasResponse = ($_.Exception.PsObject.Properties | Select-Object -ExpandProperty Name) -contains 'Response'
            if($hasResponse -and $_.Exception.Response.StatusCode.Value__ -eq 404 ) {
                Write-Warning "Repository $destinationOrg/$repoName does not exist or you do not have permission to update it."
                continue
            }
            else {
                throw
            }
        }
        
        Write-Debug "Updating repository $destinationOrg/$repoName visibility: $visibility"
        Update-RepoVisibility -org $destinationOrg -repo $repoName -visibility $visibility -token $destToken

    }
}

if ((Get-PSCallStack).Count -le 2){
    try {
        Update-Repositories -sourceOrg $source -sourceToken $sourcePat -destinationOrg $dest -destToken $destPat
    }
    catch {
        $e = $_.Exception
        $line = $_.InvocationInfo.ScriptLineNumber
        $msg = $e.Message 
        Write-Host -ForegroundColor Red "Caught exception (line $line): $e"
        throw
    }
}
