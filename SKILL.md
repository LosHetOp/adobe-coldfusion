---
name: coldfusion-native
description: Install a disposable native Adobe ColdFusion 2025 security testing lab with current updates, Auto-Lockdown and verified Apache or IIS connectivity.
---

Read README.md for prerequisites, commands and paths. Use a fresh x86_64 VM:
Ubuntu 24.04 LTS with systemd, or Windows 11 Pro / Windows Server with IIS support.
VM provisioning and remote access are separate from installation.

On Ubuntu, run `bash /absolute/path/to/this/repo/setup.sh` as root. On Windows,
run `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\absolute\path\to\this\repo\setup.ps1`
in an already elevated Windows PowerShell 5.1 process. Allow 45 minutes initially;
downloads and Windows servicing vary. If Windows requests a prerequisite reboot
before ColdFusion installation, reboot and rerun. Diagnose other failures before
replacing or restoring the VM; do not repeat a fresh installation over partial state.

Prefer Ubuntu 24.04. Only if a 24.04 image is unavailable, use another Ubuntu
x86_64 release with `bash /absolute/path/to/this/repo/setup-any-ubuntu.sh` as root.
This temporary fallback is untested and outside Adobe's documented ColdFusion 2025
Ubuntu support. It relaxes the release check only; all update, lockdown and runtime
checks still apply. Record the actual OS and this limitation with test results.

Require exit code 0 and final JSON with `status: ready`. Read `credentials_file`
and `security_receipt` from that JSON inside the guest. Passwords are generated;
keep them out of shared logs. The update level comes from Adobe's catalog fetched
at setup time. Do not bypass verification or remove updates to make a test pass.

Application files belong in `/var/www/html` on Ubuntu or `C:\inetpub\wwwroot` on
Windows. Use the application URL on port 80; the Administrator uses port 8500.
Keep fixtures small, preserve the behavior under test, and make files readable by
Apache/IIS without broad permission changes. Verify execution and observable
effects, including completion of asynchronous work, rather than HTTP status alone.
Custom fixtures do not establish the behavior of unavailable applications,
extensions or Enterprise-only features.

Failures retain state and logs for diagnosis. Discard the VM when finished.
Developer licensing is selected by default. This is a disposable security testing
lab, not a production deployment.
