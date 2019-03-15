# Channel State Backup Tool (for LND)

This is a simple script design for the `lnd` implementation of the Lightning Network specifications by Lightning Labs.

It is designed for a Linux environment, specifically the Raspbian Stretch distro running on a Raspberry Pi 3, but it should also work in any other Linux environment (with maybe minor tweaks).

## Some background on "channels states"

*[Explanation here]*

## What this tool does

*[Explanation here]*

## Functionality Checklist

- [x] copy `.lnd` folder and package into tar file as backup
- [x] upload tar file to Dropbox
- [x] gpg encrypt tar file before upload
- [x] stop lnd (dump memory to disk), backup data, restart lnd
- [x] only run backup process if there are channel state changes
- [x] add flags/arguments to run in various modes from the command line (for CRON jobs)
- [x] refactor code to gracefully handle any missing variables/arguments
- [ ] add a date checker to allow forced backup runs at set intervals

---

## Eventual plans

I started creating this tool with the intention of submitting it as a Pull Request to one of the Raspberry Pi `bitcoind + lnd` setup guides (RaspiBlitz, RaspiBolt guides). Once it is finished up to a level where I'm happy with the features/functionality I have planned, I'll be writing up and submitting those PRs for consideration.
