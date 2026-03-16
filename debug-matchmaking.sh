#!/bin/bash
# Quick script to debug matchmaking issues on production server

echo "=========================================="
echo "AutoChest Matchmaking Debug"
echo "=========================================="
echo ""

echo "1. Checking server status..."
ssh root@75.119.142.247 "sudo systemctl status autochest-server --no-pager"
echo ""

echo "2. Checking if server is listening on port 12345..."
ssh root@75.119.142.247 "sudo ss -tulpn | grep 12345"
echo ""

echo "3. Last 30 lines of server logs:"
ssh root@75.119.142.247 "sudo journalctl -u autochest-server -n 30 --no-pager"
echo ""

echo "4. Matchmaking log (if exists):"
ssh root@75.119.142.247 "tail -n 20 /opt/autochest/server/matchmaking.log 2>/dev/null || echo 'No matchmaking.log found'"
echo ""

echo "=========================================="
echo "To watch logs in real-time, run:"
echo "ssh root@75.119.142.247 'sudo journalctl -u autochest-server -f'"
echo "=========================================="
