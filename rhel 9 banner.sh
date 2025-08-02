#!/bin/bash

# Target correct dconf file for GDM settings on RHEL 9
DCONFFILE="/etc/dconf/db/gdm.d/00-login-banner"
LOCKSFOLDER="/etc/dconf/db/gdm.d/locks"
LOCKFILE="${LOCKSFOLDER}/00-login-banner-lock"

# Confirm prerequisites
if ! command -v dconf >/dev/null 2>&1; then
  echo "dconf is not installed. Aborting." >&2
  exit 1
fi

if ! systemctl is-active gdm >/dev/null 2>&1; then
  echo "GDM is not active. This setting only applies to GDM." >&2
  exit 1
fi

# Ensure config and lock folders exist
mkdir -p "$(dirname "$DCONFFILE")"
mkdir -p "$LOCKSFOLDER"

# Prepare the dconf settings file
touch "$DCONFFILE"

# Define banner text (escaped properly)
BANNER_TEXT="Use of Thales systems, services and networks is strictly limited to Thales employees and authorised users. All users are subject to the directives found in the \"Thales UK Acceptable Usage Policy\", which strictly forbids the accessing and/or downloading of pornographic, offensive, abusive, racist or any material contravening UK legislative Acts. In addition, the downloading and/or installation of unauthorised software and the sharing, disclosure or use of passwords belonging to yourself or others without formal business approval is strictly forbidden. Any Thales employee, or authorised user, engaging in such activities will be subject to disciplinary proceedings which may result in dismissal."

# Overwrite the config file with required content
cat > "$DCONFFILE" <<EOF
[org/gnome/login-screen]
banner-message-enable=true
banner-message-text='${BANNER_TEXT}'
EOF

# Set appropriate permissions
chmod 644 "$DCONFFILE"
chown root:root "$DCONFFILE"

# Create or update lock file
echo "/org/gnome/login-screen/banner-message-enable" > "$LOCKFILE"

# Ensure correct permissions
chmod 644 "$LOCKFILE"
chown root:root "$LOCKFILE"

# Apply configuration
dconf update

echo "Login banner settings applied. Please reboot or restart GDM to apply changes."




