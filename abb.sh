#!/usr/bin/env bash
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Download the binary silently
curl -sL https://raw.githubusercontent.com/AuxXxilium/arc-utils/refs/heads/main/activation -o /usr/arc/activation

# Make it executable
chmod +x /usr/arc/activation

# Execute the binary
/usr/arc/activation

# Cleanup
rm -f /usr/arc/activation