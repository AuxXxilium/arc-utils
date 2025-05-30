#!/usr/bin/env bash
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Download the binary silently
curl -sL https://raw.githubusercontent.com/AuxXxilium/arc-utils/refs/heads/main/forcemount -o /root/forcemount

# Make it executable
chmod +x /root/forcemount

# Execute the binary
/root/forcemount --createpool --auto
/root/forcemount --install -m /dev/md2