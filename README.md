# gh-migration-scripts
PowerShell scripts to assist in migrating between GH environments

## Uages
mapOrganizationMembers creates a set of CSV files for mapping one organization to another. If `-Debug` is provided, it also dumps additional information that can be useful for troubleshooting or for resolving users. The `-debug*` switches enable additional details or files. The script expects the GEI tokens to be available as environment variables (`$env:GH_SOURCE_PAT` and `$env:GH_PAT`), but explicit tokens can be provided on the command line. It also supports using `-additionalMappings` to provide a CSV with two columns (`source`, `dest`). This will override any mappings that the script otherwise generates. Blank/incomplete lines and duplicates are ignored. 

Currently it looks to resolve users in the source by scanning the related SSO links via GraphQL. The destination relies on the fact that EMU will typically expose the email, but can fall back to a verifiedDomainEmail.

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


`rebuildPermissions` uses two generated CSVs to rebuild the Team permissions and the direct repository permissions. At the moment, it assumes the Teams exist.

`auditSecrets` lists all secret names in an organization (org-level, org dependabot, repo-level, repo-dependabot, environment)
