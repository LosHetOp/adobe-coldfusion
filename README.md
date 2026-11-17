# ColdFusion Native

Disposable Adobe ColdFusion **security testing lab** on Ubuntu 24.04 LTS x86_64
or x64 Windows 11 Pro / Windows Server 2016+ with IIS support. ColdFusion,
its bundled Java runtime, and Apache/IIS run natively inside a provisioned VM.

## Run

In a fresh Ubuntu 24.04 LTS VM, as root:

```bash
bash /absolute/path/to/adobe-coldfusion/setup.sh
```

In a fresh Windows VM, from an already elevated **Windows PowerShell 5.1** process:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\path\adobe-coldfusion\setup.ps1
```

Requires internet access, working OS package/feature servicing, and a full guest
OS with its service manager. Roughly 10 GB RAM and 25 GB free disk are practical
initial lab allocations, not vendor minimums. Allow 45 minutes initially;
downloads and servicing vary. VM creation, SSH, Hyper-V and desktop configuration
are separate. Docker, WSL, minimal containers, ARM guests and PowerShell 7 are
outside this setup's scope.

The default setup selects **ColdFusion 2025 Developer**, configures Apache or IIS,
applies the latest update published in Adobe's catalog at run start, and runs
Adobe Auto-Lockdown. Default download endpoints do not require Adobe sign-in.
The scripts download vendor installers; this repository does not bundle them.
Windows executables require valid Adobe signatures. Optional independently
obtained SHA-256 values can be supplied for installer verification.

Require **exit code 0 and final JSON with `status: ready`**. The JSON contains
URLs and paths to protected credentials and the security receipt. Before readiness,
setup checks the core hotfix log for zero fatal/nonfatal errors, verifies the live
update level against the catalog, requires lockdown success without rollback,
and executes a temporary CFML probe through Apache/IIS. An installed JAR or an
HTTP 200 alone is insufficient.

### Temporary fallback when Ubuntu 24.04 is unavailable

Prefer `setup.sh` on Ubuntu 24.04. Only when a 24.04 image is unavailable in the
selected region or image catalog, use a fresh VM on another Ubuntu release:

```bash
bash /absolute/path/to/adobe-coldfusion/setup-any-ubuntu.sh
```

**This fallback is untested and outside Adobe's documented Ubuntu support for
ColdFusion 2025.** Adobe lists Ubuntu 24 LTS in its
[system requirements](https://guides.adobe.com/coldfusion/en/docs/introduction-to-coldfusion/system-requirements.html).
The temporary script removes only the Ubuntu release restriction. It still
requires Ubuntu x86_64/amd64, systemd, available dependencies and all normal
update, lockdown and execution checks. It does not add ARM/Graviton support or
guarantee compatibility with other Ubuntu releases. Successful installation does
not establish vendor support.

Record the actual OS version, script used and platform limitation with test
results. Recheck on Ubuntu 24.04 before drawing conclusions about that supported
platform. Do not use the fallback to bypass a failed 24.04 installation or another
verification failure; diagnose the failure and restore/discard that guest first.

## Paths and credentials

| Item | Ubuntu | Windows |
| --- | --- | --- |
| Application | `http://localhost/` | `http://localhost/` |
| Administrator | `http://localhost:8500/CFIDE/administrator/index.cfm` | Same |
| Application webroot | `/var/www/html` | `C:\inetpub\wwwroot` |
| ColdFusion | `/opt/coldfusion2025` | `C:\ColdFusion2025` |
| State and setup logs | `/var/lib/cf2025-local` | `C:\ProgramData\CF2025Local` |
| Credentials | State directory: `credentials.json` | Same |
| Security receipt | State directory: `security-receipt.json` | Same |
| Readiness result | State directory: `ready.json` | Same |
| Recovery record | State directory: `README-credentials.md` | Same |
| Runtime logs | `cfusion/logs` under ColdFusion | Same |
| Hotfix logs | `cfusion/hf-updates` under ColdFusion | Same |
| Lockdown logs | `lockdown/cfusion/Logs` under ColdFusion | Same |

Read generated credentials as root/Administrator inside the guest. Passwords stay
in protected files, not the final console JSON. Setup also exports portal-only
credentials to `ColdFusion-Admin-Credentials.txt` on the initiating user's Desktop.
Ubuntu falls back to that user's home; Windows falls back to the protected state
directory if no Desktop exists. Treat credentials and vendor logs as sensitive.

Use localhost inside the guest for Administrator access. Configure any remote
application access separately. Windows Java firewall rules block network access
to JVM listeners; IIS is the application entry point. Setup does not configure
remote Administrator access.

## Test fixtures

Place small `.cfm`, `.cfc`, `Application.cfc` and supporting files in the application
webroot. For a smoke test, create a `.cfm` file containing:

```cfm
<cfcontent type="text/plain" reset="true"><cfoutput>ColdFusion fixture executed</cfoutput>
```

Request `http://localhost/<fixture-name>.cfm` and check its output. This confirms
execution, not a security property. For other tests, preserve the required paths,
methods, encoding, authentication and roles, and verify the resulting effects.
For asynchronous work, verify completion rather than request acceptance alone.

Make fixtures readable by the existing Apache/IIS identity without weakening
lockdown or unrelated permissions. Use the application webroot, not the
Administrator webroot. Custom fixtures exercise ColdFusion behavior; they do not
verify the behavior of an unavailable application, extension or external service.
Remove test fixtures when finished.

## Lifecycle and scope

Failures retain state and diagnostics. Fresh installation refuses existing
ColdFusion paths, credentials and conflicting accounts. Diagnose failures, then
restore/discard the guest before another fresh attempt. There is no automatic
uninstall or reset.

Windows servicing may require a prerequisite reboot. Setup stops before
ColdFusion/account creation and asks for a reboot and rerun. Elevation must
already be available; setup does not approve UAC prompts or reboot automatically.
Linux setup starts ColdFusion for the current run and does not configure its boot
service. Revalidate readiness after reboot.

The lab selects Developer licensing, not a production or Enterprise deployment.
Solr, PDF Generator, .NET integration and external databases are not installed by
default. Major ColdFusion releases are not upgraded automatically. The security
receipt records setup-time checks, not a complete audit or live drift monitoring.
Maintenance switches are separate from fresh setup and do not produce its fresh
readiness receipt.

The underlying default installers were tested on Windows 11 Pro and Ubuntu
24.04.4 with Update 14, lockdown and connector execution. Windows credential/JSON
helpers passed isolated checks; Bash and embedded Python passed syntax checks.
The complete packaged revision, other Ubuntu releases, Windows Server,
no-lockdown/update-only modes and interactive Administrator sign-in have not had
equivalent end-to-end validation.
