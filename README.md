# gh-migration-scripts
PowerShell scripts to assist in migrating between GH environments

## Usages
mapOrganizationMembers creates a set of CSV files for mapping one organization to another. If `-Debug` is provided, it also dumps additional information that can be useful for troubleshooting or for resolving users. The `-debug*` switches enable additional details or files. The script expects the GEI tokens to be available as environment variables (`$env:GH_SOURCE_PAT` and `$env:GH_PAT`), but explicit tokens can be provided on the command line. It also supports using `-additionalMappings` to provide a CSV with two columns (`source`, `dest`). This will override any mappings that the script otherwise generates. Blank/incomplete lines and duplicates are ignored. 

Currently it looks to resolve users in the source by scanning the related org SSO links via GraphQL. The destination relies on the fact that EMU will typically expose the email, but can fall back to a verifiedDomainEmail.

**Known limitations:**
- Teams with > 100 assigned members/permissions not currently supported. Needs paging.
- Assumes org-to-org migration
- Any users to be mapped must exist in the target org for the automatic logic to work
- Assumes the source org is GHEC and the target is EMU
- Does not yet identify source teams that used the IdP for membership. Needs to have that logic added.
- Starts the user scan in the source at the org level. Should start with Enterprise for enterprise-mapped SSO.
- SSO mappings may only exist during active sessions. User mappings should be captured from each run.
- Source does not scan the verifiedDomainEmails for possible matches
- Script currently does not capture roles fully. It uses GraphQL, so it returns high-level permissions. To capture roles, a query would be needed for each repository.
- Object serialization for debugging is limited to a depth of 20 for most GraphQL calls
- REST call paging is currently set with a default limit of 10 pages (via the maxPages variable on `Invoke-RestApi`)
- Array results from multiple paged requests are currently concatenated to the paged node, with the final request's `pageInfo` returned for GraphQL
- GraphQL paging does not currently have a recursion/depth guard


`rebuildPermissions` uses two generated CSVs to rebuild the Team permissions and the direct repository permissions. At the moment, it assumes the Teams exist.

`auditSecrets` lists all secret names in an organization (org-level, org dependabot, repo-level, repo-dependabot, environment)

`migrateVisibility` updates all matching repositories in a destination to have the same visibility settings as the corresponding source repository.

## Paging

Dynamic paging is implemented for the calls. For REST APIs, it reads the headers and collects up to 10 pages (configurable). The results are concatenated into a single array that is returned. For the GraphQL calls, the code looks for the first `pageInfo` block and the first array at the same level. It will look up to 6 levels deep in the results. If more pages exist (`hasMorePages`), the code will automatically paginate the results and concatenate the arrays. The final `pageInfo` block will be returned. It currently retrieves all pages unless pagination is disabled (`$paginate=false`)

## Debug

The scripts support a `-Debug` parameter. If enabled, more details are provided about the process. Additionally, files containing results, query responses, and interim analysis (all beginning with `dbg-`) can be created. Script parameters starting with `debug` can enable/disable some of those results.
