# qbop 3.0.0

qbop 3.0 adds first-class browser authentication, replaces inbound API Basic Auth with revocable API keys, and improves the accuracy of port-transition reporting.

## Breaking changes

- Browser authentication is enabled by default. Fresh installations and upgraded 2.x databases without an administrator redirect normal browser traffic to `/setup` for one-time administrator creation. Set `WEB_AUTH_ENABLED=false` before startup only when the UI is protected by another trusted access layer.
- Inbound API HTTP Basic Auth has been removed. Every API client must use a qbop API key with `Authorization: Bearer qbop_...`.
- Every API endpoint requires an API key, including `/api/health`. API authentication remains required when browser authentication is disabled, so update monitoring checks as part of the upgrade.

Before upgrading, back up qbop's persistent data and configuration, remove obsolete `BASIC_AUTH_*` settings, and review the [2.x to 3.0 upgrade guide](README.md#upgrading-from-qbop-2x-to-30).

## Authentication and account management

- qbop now supports one administrator account with one-time setup at `/setup`, login at `/login`, logout from the normal UI, and email/password management at `/account`.
- A lost administrator password can be reset without email or SMTP by running `bundle exec rake user:reset-password` inside the container.
- Browser sessions persist safely across restarts using an automatically managed session secret in the data volume.

## API and UI

- API-key management is integrated into `/api-docs` alongside the endpoint documentation.
- Named API keys can be created and revoked independently.
- A new API-key secret is displayed once at creation time and is not stored in recoverable form.
- API keys record `last_used_at` when successfully used.
- Navigation and account/authentication screens have been cleaned up for the new workflow.

## Port-transition and history correctness

- Port-transition history now has an explicit `error` state for failed downstream synchronization.
- OPNsense apply failures remain eligible for retry on later job runs.
- If an OPNsense alias save succeeds but applying the firewall configuration fails, the transition is recorded as an error rather than synchronized.
- OPNsense stats no longer report a saved-but-unapplied port as the current active port.
