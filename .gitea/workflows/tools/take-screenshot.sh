#!/usr/bin/env bash

echo "Installing Chrome dependencies..."
apt-get update > /dev/null
apt-get install -yq libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libx11-xcb1 > /dev/null
echo "Installing Puppeteer..."
npm install -g puppeteer > /dev/null
echo "Running screenshot script..."
env NODE_PATH=/usr/lib/node_modules node /opt/spartan-installer/.gitea/workflows/tools/screenshot.js