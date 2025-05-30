#!/usr/bin/env bash
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Download the binary silently
curl -fsSL https://raw.githubusercontent.com/AuxXxilium/arc-utils/refs/heads/main/installsve -o /root/installsve

# Make it executable
chmod +x /root/installsve

# Execute the binary
/root/installsve