#!/bin/bash
# Quick script to launch AutoChest in production mode
# Connected to cloud server at 75.119.142.247

export AUTOCHEST_PRODUCTION=true
export AUTOCHEST_SERVER_IP=75.119.142.247
love .
