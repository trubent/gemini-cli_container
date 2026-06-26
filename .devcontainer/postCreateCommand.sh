#!/usr/bin/env bash
set -e

echo "Securing local credential files..."
sudo chown -R vscode:vscode /workspaces/*/credentials 2>/dev/null || true
chmod 600 /workspaces/*/credentials/gcp/*.json 2>/dev/null || true

echo "Installing Gemini CLI out of the box..."
sudo npm install -g @google/gemini-cli

echo "Checking installed tools..."
terraform version || true
ansible --version || true
aws --version || true
gcloud version || true
kubectl version --client=true || true
helm version || true
gh --version || true

echo "Gemini Agent container is 100% ready."