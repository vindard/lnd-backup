### Note: This README is still a work-in-progress!

# Reckless Channel State Backup Tool (for Lnd)

> The Lightning Network is amazing tech, but it's still very early days. We're literally building the ship around us while we're flying and so naturally some things aren't quite finished as yet. One of these things is *the ability to recover* from some sort of failure that might affect the state of the channels database. This is where this "reckless lnd backup" script comes in.


This is a simple script design for the `lnd` implementation of the Lightning Network specifications by Lightning Labs.

It is designed for a Linux environment, specifically the Raspbian Stretch distro running on a Raspberry Pi 3, but it should also work in any other Linux environment (with maybe minor tweaks).

## Purpose
**To make periodic backups that one can use to recover funds from a failed node.**

The current failure mode for an lnd node is for the user to lose ***all*** funds currently locked into channels. This solution, while not perfect, seeks to provide at least some avenue for persons to recover funds.

## Setup

To get started, download the script:
```
$ cd && wget -qN https://raw.githubusercontent.com/vindard/lnd-backup/master/do-lndbackup.sh
$ sudo chmod +x do-lndbackup.sh
```

Run your first backup job:
```
$ sudo ./do-lndbackup.sh
```

This first backup creates the necessary directories and starts storing a state log and your first backup file locally at the hardcoded backup folder: `~/.lndbackup-<your-devoce-name>/`. The default settings for the script would create an unencrypted tar file of your `.lnd` folder and store it locally at this same backup folder.


### Setting up off-site backups
To be properly secure, backup files created should ideally be stored on a separate device from your node. To easily facilitate this, this script makes use of gpg encryption and Dropbox's cloud services to upload encrypted copies of your backups to their servers.

*Note: The script is designed to only allow **encrypted** versions of your backups to be uploaded to the cloud.*

**1. Setting up gpg encryption**
* [Steps to get a pgp key]

**2. Dropbox API**
* [Steps to get a Dropbox API key]


### Scheduling automatic backups

* [Steps to setup cron jobs]

```
0 */6 * * * /bin/bash -l /home/<your-home-folder>/lnd-data-backups/do-lndbackup.sh -s -m 12h
30 */2 * * * /bin/bash -l /home/<your-home-folder>/lnd-data-backups/do-lndbackup.sh
```
### (Optional) Understanding the different backup modes
* 'stopped' vs. 'inflight' backups
* state change monitoring and forced runs
* 'minimum time before force' runs

---
## Some background on "channel states"

`lnd` channels are "stateful". This means that your being able to draw balances and successfully participate in the network *depends* on you having the latest state of your channels. A channel's state is represented by...

## What this tool does

*[Explanation here]*

### Functionality Checklist

- [x] copy `.lnd` folder and package into tar file as backup
- [x] upload tar file to Dropbox
- [x] gpg encrypt tar file before upload
- [x] stop lnd (dump memory to disk), backup data, restart lnd
- [x] only run backup process if there are channel state changes
- [x] add flags/arguments to run in various modes from the command line (for CRON jobs)
- [x] refactor code to gracefully handle any missing variables/arguments
- [x] add a date checker to allow forced backup runs at set intervals

---

## Eventual plans

I started creating this tool with the intention of submitting it as a Pull Request to one of the Raspberry Pi `bitcoind + lnd` setup guides (RaspiBlitz, RaspiBolt guides). Once it is finished up to a level where I'm happy with the features/functionality I have planned, I'll be writing up and submitting those PRs for consideration.
