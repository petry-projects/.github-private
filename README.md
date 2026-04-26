# PR Review Agent

Automated PR review and auto-merge for the `petry-projects` organization using Claude Code or GitHub Copilot.

**Status:** ✅ Active with GitHub App authentication

## Quick Links

- 🚀 [Setup Guide](SETUP.md) — Configure and run the agent
- 📖 [Full Documentation](AGENT.md) — Architecture and capabilities
- 🔧 [GitHub App Setup](GITHUB_APP_SETUP.md) — Detailed app configuration
- 🔑 [Security](SETUP.md#security-considerations) — Token rotation and best practices

## What It Does

Automatically reviews open PRs across `petry-projects` organization repos:
- Analyzes code quality, correctness, and security
- Posts approval reviews when PRs pass all checks
- Enables auto-merge to land approved changes
- Escalates to human review when needed

Runs hourly and can be triggered manually.
