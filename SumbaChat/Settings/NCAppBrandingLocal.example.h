/**
 * SPDX-FileCopyrightText: 2026 Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copy this file to NCAppBrandingLocal.h and fill in your deployment values.
 * NCAppBrandingLocal.h is gitignored — do not commit real hostnames or keys.
 */

#define NC_BRANDING_DOMAIN @"https://cloud.example.com"
/// Single Privacy Policy URL used by Settings + delete-account flows (no hostnames in committed code).
#define NC_BRANDING_PRIVACY_URL @"https://cloud.example.com/privacy_po_example"
#define NC_BRANDING_PUSH_SERVER @"https://mtx-push.mysumba.com"
#define NC_BRANDING_PUSH_SERVER_DEBUG @"https://mtx-push-dev.mysumba.com"

/// DNS parent for `https://{subdomain}.{base}` login hosts (no scheme).
#define NC_BRANDING_BASE_DOMAIN @"example.com"
/// Prefill / fallback subdomain label when none is stored.
#define NC_BRANDING_DEFAULT_SUBDOMAIN @"cloud"
/// Contact-us recipient.
#define NC_BRANDING_SUPPORT_EMAIL @"support@example.com"

/// 32-byte privacy `uid` XOR key as lowercase hex (64 chars). Same key un-XORs on the server.
#define NC_BRANDING_UID_XOR_KEY_HEX @"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
