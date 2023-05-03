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
    [Parameter(Mandatory=$false,
        HelpMessage = "The destination file for the results")]
    [string]$output,
    [Parameter(Mandatory=$false,
        HelpMessage = "A CSV containing mappings for users as source, dest (with header)")]
    [string]$additionalMappings,
    [Parameter(Mandatory=$false)]
    [switch]$debugQuery = $false,
    [Parameter(Mandatory=$false)]
    [switch]$debugPage = $false
)

$ErrorActionPreference = "Stop"
$MAX_SERIALIZATION_DEPTH = 20

$gqlDirectAccessQuery = @'
query ($org: String!, $endCursor: String) {
    organization(login: $org) {
      repositories(first: 100, after: $endCursor) {
        pageInfo{
          hasNextPage
          endCursor
        }
        nodes {
          name
          collaborators(first: 100, affiliation:DIRECT) {
            pageInfo{
                  hasNextPage
                  endCursor
            }
            edges {
              permissionSources {
                permission
                source {
                  ... on Repository {
                    nameWithOwner
                    repoName: name
                  }
                }
              }
              node {
                userHandle: login
              }
            }
          }
        }
      }
    }
  }
'@

$gqlMannequinQuery = $query = @'
query ($org: String!, $endCursor: String) {
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
  organization(login: $org) {
    mannequins(first: 100, after: $endCursor){
        pageInfo{
            hasNextPage
            endCursor
        }
        nodes {
            id,
            databaseId,
            email,
            login,
            claimant {
                login
            }
        }
    }
  }
}
'@

$gqlOrgSsoQuery = @'
query ($org:String!, $endCursor: String) {
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
  organization(login: $org) {
    samlIdentityProvider {
      externalIdentities(first: 100, after: $endCursor) {
        totalCount
        edges {
          node {
            guid
            samlIdentity {
              nameId
              username
              givenName
              emails {
                primary
              }
            }
            user {
              login
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}
'@

$gqlOrgMemberQuery = @'
query ($org: String!, $endCursor: String) {
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
  organization(login: $org) {
    membersWithRole(first: 100, after: $endCursor) {
      pageInfo{
          hasNextPage
          endCursor
      }
      edges {
        role
        node {
          email
          login
          name
          organizationVerifiedDomainEmails(login: $org)
        }
      }
    }
  }
}
'@

$gqlTeamQuery = @'
query ($org: String!, $endCursor: String) {
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
  organization(login: $org) {
    teams(first: 100) {
      nodes {
        name
        slug
        parentTeam {
          name
        }
        members(first: 100, after: $endCursor) {
          pageInfo{
              hasNextPage
              endCursor
          }
          edges {
            role
            node {
              login
              name
            }
          }
        }
      }
    }
  }
}
'@

filter Convert-ToLower {
    if ($_) {
        [string]$_.ToLower()
    }
    else {
        $_
    }
}

function Read-GraphQL {
  [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, HelpMessage="The query to execute")] 
        [string]$query,
        [Parameter(Mandatory=$true, HelpMessage="The token to use to authenticate to GitHub")] 
        [securestring]$token,
        [Parameter(Mandatory=$false, HelpMessage="Hashtable of additional values to include in the query")] 
        [hashtable]$variables,
        [Parameter(Mandatory=$false, HelpMessage="Indicates whether to automatically paginate")]
        [bool]$paginate=$true
    )

    $result = Invoke-GraphQLApi -query $query -token $token -variables $variables -paginate $paginate
    if ($DebugPreference -eq 'Continue') {
      $caller = (Get-PSCallStack)[1].Command
      $result | ConvertTo-Json -Depth $MAX_SERIALIZATION_DEPTH | Out-File -Path "dbg-gql-$caller.json"
    }

    $result
}

function Invoke-GraphQLApi {
  [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, HelpMessage="The query to execute")] 
        [string]$query,
        [Parameter(Mandatory=$true, HelpMessage="The token to use to authenticate to GitHub")] 
        [securestring]$token,
        [Parameter(Mandatory=$false, HelpMessage="Hashtable of additional values to include in the query")] 
        [hashtable]$variables,
        [Parameter(Mandatory=$false, HelpMessage="Indicates whether to automatically paginate")]
        [bool]$paginate=$true
    )

    $payload = @{ 
      query=$query
      variables=$variables 
    }
    $body = $payload  | ConvertTo-Json
    if ($debugQuery) { Write-Debug "QUERY: $body" }
    $result = Invoke-RestMethod https://api.github.com/graphql -Authentication OAuth -Token $token -Body $body -Method Post
    if ($debugQuery) { Write-Debug "RESULT: $($result | ConvertTo-Json -Depth 8)" }
    
    if ($result.errors) {
      Write-Error "Query returned an error: $($result.errors | ConvertTo-Json)"
    }
    
    if ($paginate){
      $page = Find-PageInfo -Results $result
      if ($page){
        if ($debugPage) { Write-Debug "Has more pages: $($page.pageInfo.hasNextPage)" }
        if ($page.pageInfo.hasNextPage) {
          $vars = @{
            endCursor = $page.pageInfo.endCursor
            org = $org
          }
          $originalField = Find-PagedProperty -Object $result -Path $page.field
          $newResult = Invoke-GraphQLApi -query $query -token $token -variables $vars -paginate $true
          $retrievedField = Find-PagedProperty -Object $newResult -Path $page.field
          $retrievedField.Value = $originalField.Value + $retrievedField.Value
          return $newResult
        }
      }
      else {
        if ($debugPage) { Write-Debug "No page info found. Not paginating." }
      }
    }
    $result
}

function Find-PagedProperty($object, $path) {
  if ($debugPage) { Write-Debug "Finding property $path" }
  if (-not $object) {
    return $null
  }
  $fields = $path.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
  $cur = $object
  foreach($field in $fields){    
    #Write-Debug "Stepping $field"
    #Write-Debug "$field exists: $($null -ne $cur.$field)"
    if ($null -eq $cur.$field){
      throw "Paged property not found: $path ($field)"
    }
    $cur = $cur.$field
  }
  $arrField = $cur.PSObject.properties | Where-Object { $_.TypeNameOfValue -eq 'System.Object[]' } | Select-Object -First 1
  if ($null -eq $arrField) {
    throw 'Could not find pageable array -- may need nodes or edges'
  }
  if ($debugPage) { Write-Debug "Discovered $($arrField.Name)" }
  $arrField
}

function Find-PageInfo([object]$results, [string]$field=$null, [int]$depth = 0) {
  $MAX_DEPTH = 6
  if ($depth -gt $MAX_DEPTH) {
    Write-Warning "Max search depth ($MAX_DEPTH) exceeded. Paging will be skipped."
    return $null
  }
  if (-not $results) {
    if ($debugPage) { Write-Debug "$field is null" }
    return $null
  }
  elseif ($results.pageInfo) {
    if ($debugPage) { Write-Debug "Found page info for $field" }
    return @{
      field = $field
      pageInfo = $results.pageInfo
    }
  }
  else {
    $properties =  $results | Get-Member -membertype noteproperty
    $depth++
    foreach($prop in $properties) {
      $name = $prop.Name
      $pageInfo = Find-PageInfo -results $results.$($name) -field "$field.$name" -depth $depth
      if ($null -ne $pageInfo)
      {
        return $pageInfo
      }
    }
  }
}

function Invoke-GraphQLExe {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, HelpMessage="The query to execute")] 
        [string]$query,
        [Parameter(Mandatory=$true, HelpMessage="The token to use to authenticate to GitHub")] 
        [securestring]$token,
        [Parameter(Mandatory=$false, HelpMessage="Hashtable of additional values to include in the query")] 
        [hashtable]$variables,
        [Parameter(Mandatory=$false, HelpMessage="Indicates whether to automatically paginate")]
        [bool]$paginate=$true
    )
    
    $arguments = @('api', 'graphql', '--paginate')
    foreach($key in $variables.Keys) {
        $arguments += "-F"
        $arguments += "$key=$($variables[$key])"
    }
    
    $arguments+='-f'
    $arguments+="query=$query"

    Write-Debug "Configuring authentication"
    (ConvertFrom-SecureString -SecureString $token -AsPlainText) | &gh auth login --with-token
    Write-Debug "Authentication configured"

    $arguments | Write-Debug
    $org = $variables['org']
    $results = &gh api graphql --paginate -F org=$org -f query=$query
    Write-Debug "RESULTS: $results"
    $results | ConvertFrom-Json
}

function Get-TeamMembers {
  [CmdletBinding()]
  param (
      [Parameter(Mandatory=$true,
              HelpMessage="The source organization name")] 
      [string]$org,
      [Parameter(Mandatory=$true,
              HelpMessage="The source organization PAT")] 
      [securestring]$token
  )

  Write-Debug $MyInvocation.MyCommand
  $results = Read-GraphQL -variables @{org=$org} -query $gqlTeamQuery -token $token

  $teams = $results.data.organization.teams.nodes | ForEach-Object { 
      $team = $_.name
      $slug = $_.slug
      $parentTeam = $_.parentTeam.name
      foreach ($member in $_.members.edges) {
          [PSCustomObject]@{
              team = $team
              slug = $slug
              parentTeam = $parentTeam
              role = $member.role
              login = $member.node.login | Convert-ToLower
              name = $member.node.name
          }
      }
  }
  $teams
}

function Get-OrgMannequins {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,
                HelpMessage="The destination organization name")] 
        [string]$org,
        [Parameter(Mandatory=$true,
                HelpMessage="The destination organization PAT")] 
        [securestring]$token
    )
    
    Write-Debug $MyInvocation.MyCommand
    $results = Read-GraphQL -variables @{org=$org} -query $gqlMannequinQuery -token $token
    $mannequins = $results.data.organization.mannequins.nodes
    $mannequins | ForEach-Object {
        if ($_){
          [PSCustomObject]@{
              id = $_.id
              databaseId = $_.databaseId
              email = $_.email | Convert-ToLower
              login = $_.login | Convert-ToLower
              claimant = if ($_.claimant) { $_.claimant.login } else { $null }
          }
        }
    }
}

function Get-OrgMembersSso {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,
                HelpMessage="The destination organization name")] 
        [string]$org,
        [Parameter(Mandatory=$true,
                HelpMessage="The destination organization PAT")] 
        [securestring]$token
    )
    
    Write-Debug $MyInvocation.MyCommand
    $results = Read-GraphQL -variables @{org=$org} -query $gqlOrgSsoQuery -token $token
    $users = $results.data.organization.samlIdentityProvider.externalIdentities.edges
    $users | ForEach-Object {
        if ($_){
          $primaryEmail = ($_.node.samlIdentity.emails | Where-Object { $_.primary })
          [PSCustomObject]@{
              nameId = $_.node.samlIdentity.nameId 
              username = $_.node.samlIdentity.username | Convert-ToLower
              givenName = $_.node.samlIdentity.givenName
              primaryEmail = if ($primaryEmail -and $primaryEmail.primary){$primaryEmail.primary | Convert-ToLower}else {$null}
              login = if ($_.node.user) { $_.node.user.login | Convert-ToLower } else { $null }
          }
        }
    }
}

function Get-OrgMembers {
  [CmdletBinding()]
  param (
      [Parameter(Mandatory=$true,
              HelpMessage="The destination organization name")] 
      [string]$org,
      [Parameter(Mandatory=$true,
              HelpMessage="The destination organization PAT")] 
      [securestring]$token
  )
  
  Write-Debug $MyInvocation.MyCommand
  $results = Read-GraphQL -variables @{org=$org} -query $gqlOrgMemberQuery -token $token
  $members = $results.data.organization.membersWithRole.edges | ForEach-Object {
      if ($_){
        $domainEmail = ($_.node.organizationVerifiedDomainEmails | Select-Object -First 1) | Convert-ToLower
        [PSCustomObject]@{
            login = $_.node.login | Convert-ToLower
            name = $_.node.name
            email = $_.node.email | Convert-ToLower
            verifiedDomainEmail = $domainEmail
            role = $_.role
            resolvedEmail = if ($domainEmail) { $domainEmail } else { $_.node.email | Convert-ToLower }
        }
      }
  }
  $members
}

function Get-RepositoryDirectAccess {
  [CmdletBinding()]
  param (
      [Parameter(Mandatory=$true,
              HelpMessage="The source organization name")] 
      [string]$org,
      [Parameter(Mandatory=$true,
              HelpMessage="The source organization PAT")] 
      [securestring]$token
  )
  
  Write-Debug $MyInvocation.MyCommand
  $results = Read-GraphQL -variables @{org=$org} -query $gqlDirectAccessQuery -token $token
  $repoAccess = $results.data.organization.repositories.nodes | ForEach-Object {
      if ($_){
        $repoName = $_.name
        foreach($collaborator in $_.collaborators.edges) {
          if ($collaborator) {
            $userHandle = $collaborator.node.userHandle
            foreach($src in $collaborator.permissionSources) {
                $permission = $src.permission
                if ($src.source.repoName){
                  "Discovered $userHandle in $repoName with permission $permission" | Write-Debug
                  [PSCustomObject]@{
                    login = $userHandle | Convert-ToLower
                    repo = $repoName | Convert-ToLower
                    permission = $permission
                  }

                  # Exit after the first permission is found. Some repos may have duplicate entries.
                  break;
                }
            }
          }
        }
      }
  }
  $repoAccess
}

function Resolve-Users {
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
    [securestring]$destPat = (ConvertTo-SecureString -String $env:GH_PAT -AsPlainText -Force)
  )

  # Get the users from the source organization's SSO details
  $sourceUsers =  Get-OrgMembersSso -org $source -token $sourcePat

  if ($DebugPreference -eq 'Continue'){
      $sourceUsers | Export-Csv -Path dbg-users-source.csv -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }

  # Get the users from the destination organization's member list
  $destUsers = Get-OrgMembers -org $dest -token $destPat

  if ($DebugPreference -eq 'Continue'){
      $destUsers | Export-Csv -Path dbg-users-destination.csv -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }

  # Identified mappings
  $mapped = @()

  # Source exists, can't find dest
  $missedSource = @()

  # Source exists but no login
  $undefinedUsers = @()

  # Destination exists but not mapped to existing user
  $missedDest = New-Object System.Collections.ArrayList
  $missedDest.AddRange([array]$destUsers) | Out-Null
  foreach($sourceUser in $sourceUsers){
    if ($null -eq $sourceUser.login){
      $undefinedUsers += $sourceUser
      continue;
    }
    
    $sourceLogin = $sourceUser.login
    $resolvedUser = $destUsers | 
      Where-Object { $_.resolvedEmail -eq $sourceUser.username `
       -or $_.resolvedEmail -eq $sourceUser.nameId }
    if ($resolvedUser){
        $missedDest.Remove($resolvedUser) | Out-Null
        $destLogin = $resolvedUser.login
        
        $map = [PSCustomObject]@{
            SourceName = $sourceUser.login
            DestName = $destLogin
            Source = $sourceUser
            Target = $resolvedUser
        }
        $mapped += $map
    }
    else {
      $missedSource += $sourceUser
    }
  }

  if ($DebugPreference -eq 'Continue') {
    $mapped | Export-Csv -Path dbg-map-resolved.csv
    $missedSource | Export-Csv -Path dbg-map-unresolved-src.csv
    $missedDest | Export-Csv -Path dbg-map-unresolved-dest.csv
    $undefinedUsers | Export-Csv -Path dbg-map-removed.csv
  }

  [PSCustomObject]@{
    Resolved = $mapped
    UnresolvedSource = $missedSource
    UnresolvedDest = $missedDest.ToArray()
    RemovedSource = $undefinedUsers
  }
}

function Resolve-DirectAccess {

  param(
    [Parameter(Mandatory=$true,
      HelpMessage = "Collection of resolved users")]
    [object]$resolved,
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub source organization name")]
    [string]$source,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub source organization PAT")]
    [securestring]$token = (ConvertTo-SecureString -String $env:GH_SOURCE_PAT -AsPlainText -Force),
    [Parameter(Mandatory=$false,
        HelpMessage = "The destination file for the results")]
    [string]$output
  )

  $access = Get-RepositoryDirectAccess -org $source -token $token
  $mapped = @()
  foreach ($access in $access){
    $resolvedUser = ($resolved  |
      Where-Object {$_.SourceName -eq $access.login } |
      Select-Object -First 1)

    if ($resolvedUser) {
      $mapped += [PSCustomObject]@{
        Repository = $access.repo
        Permission = $access.permission
        Source = $access.login
        Destination = $resolvedUser.DestName
      }
    } else {
      Write-Warning "Could not resolve repository member: $access.login"
    }
  }
  if ($output) {
    $mapped | Export-CSV -path $output -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }
  $mapped
}

function Resolve-Teams {

  param(
    [Parameter(Mandatory=$true,
      HelpMessage = "Collection of resolved users")]
    [object]$resolved,
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub source organization name")]
    [string]$source,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub source organization PAT")]
    [securestring]$token = (ConvertTo-SecureString -String $env:GH_SOURCE_PAT -AsPlainText -Force),
    [Parameter(Mandatory=$false,
        HelpMessage = "The destination file for the results")]
    [string]$output
  )

  $team = Get-TeamMembers -org $source -token $token
  $mapped = @()
  foreach ($member in $team){
    $resolvedUser = ($resolved  |
      Where-Object {$_.SourceName -eq $member.login } |
      Select-Object -First 1)

    if ($resolvedUser) {
      $mapped += [PSCustomObject]@{
        Team = $member.team
        Slug = $member.slug
        Role = $member.role
        Source = $member.login
        Destination = $resolvedUser.DestName
      }
    } else {
      Write-Warning "Could not resolve team member: $member.login"
    }
  }
  if ($output) {
    $mapped | Export-CSV -path $output -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }
  $mapped
}

function Resolve-Mannequins {

  param(
    [Parameter(Mandatory=$true,
      HelpMessage = "Collection of resolved users")]
    [object]$resolved,
    [Parameter(Mandatory=$true,
      HelpMessage = "The GitHub destination organization name")]
    [string]$dest,
    [Parameter(Mandatory=$false,
      HelpMessage = "The GitHub destination organization PAT")]
    [securestring]$token = (ConvertTo-SecureString -String $env:GH_PAT -AsPlainText -Force),
    [Parameter(Mandatory=$false,
    HelpMessage = "The destination file for the results")]
    [string]$output
  )

  # Get the list of mannequins to be resolved
  $mannequins = Get-OrgMannequins -org $dest -token $token

  if ($DebugPreference -eq 'Continue'){
      $mannequins | Export-Csv -Path dbg-mannequins.csv -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }

  $mannequinMap = New-Object -TypeName System.Collections.ArrayList
  foreach($mannequin in $mannequins){
      if ($mannequin.login.Contains('[bot]') -or $mannequin.login.Contains('joshjohanning')){
          continue
      }

      # If it's claimed, ignore it and don't output
      if ($null -ne $mannequin.claimant) {
          Write-Warning "$($mannequin.login) is claimed by $($mannequin.claimant)"
          continue
      }

      $sourceLogin = $mannequin.login
      $resolvedUser = ($resolved  | Where-Object {$_.SourceName -eq $sourceLogin } | Select-Object -First 1)

      if ($resolvedUser){
        $targetLogin = [string]$resolvedUser.DestName
        $map = [PSCustomObject]@{
              Source = $mannequin.login
              Target = $targetLogin
              Id = $mannequin.id
        }
        $mannequinMap.Add($map) | Out-Null
      }
      else {
        $mannequinMap.Add(
              [PSCustomObject]@{
              Source = $mannequin.login
              Target = $null
              Id = $mannequin.id
          }) | Out-Null
      }
  }

  if ($DebugPreference -eq 'Continue'){
    $mannequinMap | Export-Csv -Path dbg-mapped.csv -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }

  Export-Mannequins -mannequins $mannequinMap -output $output
}

function Export-Mannequins {
  param (
    [Parameter(Mandatory=$true,
      HelpMessage = "Collection of users")]
    [object]$mannequins,
    [Parameter(Mandatory=$false,
        HelpMessage = "The destination file for the results")]
    [string]$output
  )

  $results = $mannequins | Select-Object `
      -Property @{Name = 'mannequin-user'; Expression = {$_.Source}},`
                @{Name = 'mannequin-id'; Expression = {$_.Id}},`
                @{Name = 'target-user'; Expression = {$_.Target}}
  if ($output){
    $results | Export-CSV -path $output -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8
  }

  $results
}

 if ((Get-PSCallStack).Count -le 2){
  if (-not $sourcePat) {
    Write-Host "Missing source PAT"
    return
  }
  if (-not $destPat) {
    Write-Host "Missing destination (target) PAT"
    return
  }

  try {
    # Primary logic for resolving users and generating output
    $resolved = (Resolve-Users -source $source -dest $dest -sourcePat $sourcePat -destPat $destPat).Resolved
    if ($additionalMappings -and (Test-Path $additionalMappings)) {
      Write-Debug "Including mappings for users from $additionalMappings"
      $resolvedUsers = Import-Csv -Path $additionalMappings | 
          Where-Object {$_.source -ne $null -and $_.dest -ne $null } |
          Sort-Object -Property source -Unique
      $sourceNames = $resolvedUsers | Select-Object -ExpandProperty source
      $resolvedUsers = $resolvedUsers | Where-Object { $_.Source -NotIn $sourceNames }
      $resolved += (Import-Csv -Path $additionalMappings | ForEach-Object {
        [PSCustomObject]@{
          SourceName = $_.source
          DestName = $_.dest
        }
      })
    }
    Resolve-Mannequins -resolved $resolved -dest $dest -token $destPat -output $output | Format-Table
    Resolve-Teams -resolved $resolved  -source $source -token $sourcePat -output ($output -replace '.csv','-teams.csv') | Format-Table
    Resolve-DirectAccess -resolved $resolved  -source $source -token $sourcePat -output ($output -replace '.csv','-repo-access.csv') | Format-Table
  }
  catch {
    $e = $_.Exception
    $line = $_.InvocationInfo.ScriptLineNumber
    $msg = $e.Message 
    Write-Host -ForegroundColor Red "Caught exception (line $line): $e"
  }
}