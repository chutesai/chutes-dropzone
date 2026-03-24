# Chutes Dropzone — Security Audit

Last reviewed: 2026-03-24

This document records the security posture of the Chutes Dropzone stack. It is
intended for operators, reviewers, and anyone inspecting our code to understand
how user data is protected.

---

## Architecture

Dropzone runs two user-facing applications (n8n and OpenWebUI) behind a single
TLS-terminating edge proxy. All backend services communicate over an internal
Docker network. Only the edge proxy is externally reachable.

No backend service publishes ports to the host.

---

## Authentication

Both applications authenticate users exclusively through Chutes OAuth 2.0 / OIDC
with PKCE. Password-based login is disabled for all user-facing flows.

- Authorization code exchange is protected by SHA-256 PKCE challenge.
- State parameter is signed and verified to prevent CSRF.
- Redirect paths are normalized to reject open redirects.
- Required scopes are validated on every login.
- Session cookies use `httpOnly`, `sameSite`, and `secure` flags.

There are no user-visible admin accounts. The only "admin" is an internal
service account used by background configuration scripts. It cannot log in
through the UI and is never exposed to end users.

---

## Data Isolation

### User-to-User

Each user's credentials and sessions are scoped to their own identity. No API
path allows one user to access another user's data, credentials, or chat history.
Chutes API calls are made with each user's own OAuth token.

### User-to-Operator

Operators cannot access user data through the application:

- There is no admin fallback or impersonation mechanism.
- The internal service account has no access to user OAuth sessions or content.
- Admin promotion (via allowlist) does not grant access to other users' data.

### Database-Level

Each application connects to its own database with its own dedicated credentials.
Cross-database access is explicitly revoked. A compromise of one application
cannot read or write the other's data.

Row-level security is not applied because both n8n and OpenWebUI are upstream
open-source projects with their own migration systems. Maintaining RLS patches
against every upstream schema change would be fragile. Database-level isolation
with separate users provides an equivalent boundary.

---

## Network Boundaries

All inter-service communication stays on an internal Docker bridge network.
The edge proxy strips internal identity headers from external requests before
forwarding, preventing spoofing. As defense-in-depth, internal-only endpoints
also verify request origin at the application layer.

---

## Encryption

**At rest:** Application credentials are AES-encrypted with a dedicated key.
Disk-level encryption depends on the host (LUKS, cloud provider, etc.).

**In transit:** TLS 1.2/1.3 is enforced on all external traffic with HSTS
enabled. Internal container-to-container traffic is unencrypted, which is
standard for same-host Docker networking.

---

## Secrets Management

All secrets are auto-generated during deployment and stored in a file with
owner-read-only permissions (`600`). No secrets are committed to version control.

The credential encryption key is critical: rotating it permanently strands all
existing encrypted credentials. It should only be changed on a fresh install or
after exporting all credentials.

For production deployments on managed infrastructure, operators should consider
injecting secrets via a secrets manager rather than storing them on disk.

---

## Input Validation

- Audio endpoints enforce size limits on both text input and file uploads.
- OAuth flows validate all parameters (code, state, flow token, scopes).
- The edge proxy enforces request body size limits.

---

## Security Headers

The edge proxy sets `X-Content-Type-Options`, `X-Frame-Options`,
`Referrer-Policy`, `Strict-Transport-Security`, and `Permissions-Policy` on all
responses.

---

## Known Trade-offs

| Item | Notes |
|------|-------|
| No row-level security | Mitigated by database-level isolation. Upstream projects control their own schemas. |
| Encryption key rotation | Irreversible — strands existing credentials. Document and back up before rotating. |
| Secrets stored on disk | File is owner-read-only. Use a secrets manager for managed infrastructure. |
| Internal traffic unencrypted | Standard for same-host Docker. Not warranted for this threat model. |

---

## Audit Changelog

### 2026-03-24

- Removed admin fallback credential access — operators cannot access user data.
- Added per-service database credentials with cross-database access revoked.
- Added internal header stripping at the proxy layer with application-layer
  loopback verification as defense-in-depth.
- Changed the OpenWebUI admin to a hidden service account with password auth
  disabled.
- Added input size limits on audio endpoints.
- Verified no backend services expose ports to the host.
