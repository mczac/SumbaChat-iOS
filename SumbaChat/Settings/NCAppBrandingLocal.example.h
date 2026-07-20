/**
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copy this file to NCAppBrandingLocal.h and fill in your deployment values.
 * NCAppBrandingLocal.h is gitignored — do not commit real hostnames.
 */

#define NC_BRANDING_DOMAIN @"https://cloud.example.com"
#define NC_BRANDING_PRIVACY_URL @"https://cloud.example.com/privacy"
#define NC_BRANDING_PUSH_SERVER @"https://push.example.com"
#define NC_BRANDING_PUSH_SERVER_DEBUG @"https://push-dev.example.com"

/// DNS parent for `https://{subdomain}.{base}` login hosts (no scheme).
#define NC_BRANDING_BASE_DOMAIN @"example.com"
/// Prefill / fallback subdomain label when none is stored.
#define NC_BRANDING_DEFAULT_SUBDOMAIN @"cloud"
/// Contact-us recipient.
#define NC_BRANDING_SUPPORT_EMAIL @"support@example.com"
