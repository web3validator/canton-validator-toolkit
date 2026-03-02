# Contributing

Bug reports, fixes, and improvements are welcome.

## How to contribute

1. Fork the repo
2. Create a branch: `git checkout -b fix/your-fix`
3. Test on a real Canton node before submitting
4. Open a pull request with a clear description

## Guidelines

- Test all script changes on DevNet before PRs
- No hardcoded secrets, tokens, or IPs
- Keep shell scripts POSIX-compatible (no bashisms)
- One logical change per PR

## Reporting issues

Open a GitHub issue with:
- Canton version (`VERSION` from `~/.canton/toolkit.conf`)
- Network (mainnet/testnet/devnet)
- OS and Docker version
- Relevant log output (`~/.canton/logs/`)

## Questions

Open an issue or reach out via the Canton Network validator community.