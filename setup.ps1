#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Local ColdFusion 2025 + IIS installation on Windows Server or Windows 11.
.DESCRIPTION
Downloads the Adobe Windows GUI installer by default; -InstallerUrl overrides it.
Lockdown defaults on.
Pass -NoLockdown to skip Auto-Lockdown; required updates still run.
Defaults to Developer licensing (SILENT_INSTALL_TYPE=3), with no license file.
Use -UpdateOnly for an existing installation; credentials/lockdown are retained.
Vendor diagnostics and README-credentials.md are restricted to SYSTEM/Administrators.
.PARAMETER NoLockdown
Skip downloading and running Auto-Lockdown. ColdFusion updates and update
verification still run. IIS connector configuration still runs.
.PARAMETER InstallType
Developer by default. Select trial explicitly only when needed. This selects
the license mode, independently of the secure installation profile.
.EXAMPLE
.\setup.ps1 -NoLockdown
Install Developer edition with IIS and the latest update, without lockdown.
.EXAMPLE
.\setup.ps1
Install Developer edition with IIS, the latest update, and lockdown.
#>
[CmdletBinding()]
param(
    [string]$InstallerUrl = 'https://trials.adobe.com/AdobeProducts/CSTD/16/win64/ColdFusion_2025_GUI_WWEJ_win64.exe',
    [string]$LockdownUrl = 'https://cfdownload.adobe.com/pub/adobe/coldfusion/2025/lockdown/ColdFusion_2025_Lockdown_WWEJ_win64.exe',
    [System.Management.Automation.PSCredential]$DownloadCredential,
    [hashtable]$DownloadHeaders = @{},
    [string]$InstallerSha256, [string]$LockdownSha256,
    [Security.SecureString]$AdminPassword,
    [Security.SecureString]$ServicePassword,
    [Security.SecureString]$LockdownAdminPassword,
    [string]$CfServiceUsername = 'cfsvc',
    [string]$LockdownAdminUsername = 'cflockadmin',
    [string]$CfInstallDir = 'C:\ColdFusion2025',
    [string]$WorkDir = 'C:\ProgramData\CF2025Local',
    [ValidateSet('developer','trial')][string]$InstallType = 'developer',
    [switch]$NoLockdown,
    [switch]$UpdateOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Log { param([string]$Msg) Write-Output "[install-cf2025] $Msg" }
function Die { param([string]$Msg) throw $Msg }
function Get-WindowsPlatform($OperatingSystem) {
    # ProductType: 1=workstation, 2=domain controller, 3=server.
    # Both Windows 11 and current Windows Server report version 10.0.
    $version = [version]$OperatingSystem.Version
    $build = [int]$OperatingSystem.BuildNumber
    if ([int]$OperatingSystem.ProductType -in @(2,3) -and $version.Major -eq 10 -and $build -ge 14393) {
        return 'Server'
    }
    if ([int]$OperatingSystem.ProductType -eq 1 -and $version.Major -eq 10 -and $build -ge 22000) {
        return 'Windows11'
    }
    Die 'Requires Windows Server 2016 or later, or Windows 11 with the required IIS features.'
}
function Install-Iis([string]$Platform) {
    Log "Checking IIS prerequisites for $Platform..."
    if ($Platform -eq 'Server') {
        Import-Module ServerManager -ErrorAction Stop
        $required = @(
            'Web-Server','Web-WebServer','Web-Common-Http','Web-Static-Content',
            'Web-Default-Doc','Web-Dir-Browsing','Web-Http-Errors','Web-Health',
            'Web-Http-Logging','Web-Performance','Web-Stat-Compression','Web-Security',
            'Web-Filtering','Web-ISAPI-Ext','Web-ISAPI-Filter','Web-ASP-Net45',
            'Web-CGI','Web-Mgmt-Tools','Web-Mgmt-Console','Web-Scripting-Tools'
        )
        $inventory = @(Get-WindowsFeature -ErrorAction Stop)
        $unavailable = @($required | Where-Object { $_ -notin $inventory.Name })
        if ($unavailable.Count) { Die "Required IIS roles unavailable: $($unavailable -join ', '). Check the Windows Server installation options." }
        $missing = @($inventory | Where-Object { $_.Name -in $required -and -not $_.Installed } | Select-Object -ExpandProperty Name)
        if ($missing.Count) {
            # No -Restart: never reboot the user's host automatically.
            $result = Install-WindowsFeature -Name $missing -IncludeManagementTools -LogPath (Join-Path $WorkDir 'iis-features.log') -ErrorAction Stop
            if (-not $result.Success) { Die 'IIS role installation failed. Inspect iis-features.log; no automatic retry was attempted.' }
            if ([string]$result.RestartNeeded -eq 'Yes') { Die 'IIS needs a reboot. Reboot, then rerun the same command; ColdFusion and account creation have not started.' }
        }
        $remaining = @(Get-WindowsFeature -Name $required | Where-Object { -not $_.Installed })
        if ($remaining.Count) { Die 'Required IIS roles are not installed after setup. Inspect iis-features.log.' }
    } elseif ($Platform -eq 'Windows11') {
        Import-Module Dism -ErrorAction Stop
        # Client Windows uses optional-feature names, not ServerManager role names.
        $required = @(
            'IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures',
            'IIS-StaticContent','IIS-DefaultDocument','IIS-DirectoryBrowsing','IIS-HttpErrors',
            'IIS-HealthAndDiagnostics','IIS-HttpLogging','IIS-Performance',
            'IIS-HttpCompressionStatic','IIS-Security','IIS-RequestFiltering',
            'IIS-ApplicationDevelopment','IIS-NetFxExtensibility45','IIS-ASPNET45',
            'IIS-ISAPIExtensions','IIS-ISAPIFilter','IIS-CGI',
            'IIS-WebServerManagementTools','IIS-ManagementConsole','IIS-ManagementScriptingTools'
        )
        $inventory = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)
        $unavailable = @($required | Where-Object { $_ -notin $inventory.FeatureName })
        if ($unavailable.Count) { Die "This Windows edition/image lacks required IIS features: $($unavailable -join ', '). Use a Windows 11 edition/image offering these features (such as Pro), or Windows Server." }
        $selected = @($inventory | Where-Object { $_.FeatureName -in $required })
        if (@($selected | Where-Object { [string]$_.State -match 'Pending' }).Count) { Die 'IIS feature changes are pending a reboot. Reboot, then rerun the same command before installing ColdFusion.' }
        $missing = @($selected | Where-Object { [string]$_.State -ne 'Enabled' } | Select-Object -ExpandProperty FeatureName)
        if ($missing.Count) {
            $result = @(Enable-WindowsOptionalFeature -Online -FeatureName $missing -All -NoRestart -LogPath (Join-Path $WorkDir 'iis-features.log') -ErrorAction Stop)
            if (@($result | Where-Object { $_.RestartNeeded }).Count) { Die 'IIS needs a reboot. Reboot, then rerun the same command; ColdFusion and account creation have not started.' }
        }
        $remaining = @(Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -in $required -and [string]$_.State -ne 'Enabled' })
        if ($remaining.Count) { Die 'Required IIS optional features are not enabled after setup. Inspect iis-features.log.' }
    } else {
        Die 'Unsupported Windows platform; refusing IIS changes.'
    }
    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Test-Path 'IIS:\Sites\Default Web Site') -or -not (Test-Path 'IIS:\AppPools\DefaultAppPool')) {
        Die 'Expected IIS Default Web Site/DefaultAppPool is missing. Review existing IIS configuration before continuing.'
    }
    Start-Service W3SVC -ErrorAction Stop
    Log 'IIS features are enabled and W3SVC is running.'
}
function Set-JavaFirewallPolicy {
    # Decide inbound access before either JVM can listen, avoiding Windows'
    # interactive allow/block question. IIS connects locally; remote clients
    # use IIS rather than gaining access to every Java listener.
    Import-Module NetSecurity -ErrorAction Stop
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $pathHash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($CfInstallDir.ToLowerInvariant()))).Replace('-','').Substring(0,12)
    } finally { $hasher.Dispose() }
    $group = 'ColdFusion 2025 local installer - Java inbound policy'
    # Windows Firewall permits local loopback traffic independently of these
    # network rules; NetSecurity rejects an explicit IPv6 loopback rule.
    $policies = @(
        @{ Suffix = 'Network'; Action = 'Block'; RemoteAddress = 'Any' }
    )
    foreach ($executable in @('java.exe','javaw.exe')) {
        $program = Join-Path $CfInstallDir "jre\bin\$executable"
        foreach ($policy in $policies) {
            $name = "CF2025Local-$pathHash-$executable-$($policy.Suffix)"
            $ruleArguments = @{
                Name = $name; PolicyStore = 'PersistentStore'; Direction = 'Inbound'
                Program = $program; Action = $policy.Action; RemoteAddress = $policy.RemoteAddress
                LocalAddress = 'Any'; Protocol = 'Any'; Profile = 'Any'; Enabled = 'True'
                EdgeTraversalPolicy = 'Block'; ErrorAction = 'Stop'
            }
            $existingRule = Get-NetFirewallRule -Name $name -PolicyStore PersistentStore -ErrorAction SilentlyContinue
            if ($existingRule) {
                if ($existingRule.Group -ne $group) { Die "Firewall rule name collision: $name. Review the existing rule before continuing." }
                Set-NetFirewallRule @ruleArguments
            } else {
                $null = New-NetFirewallRule @ruleArguments -DisplayName "ColdFusion Java $executable - $($policy.Suffix) inbound" `
                    -Group $group -Description 'Installer-managed: block inbound Java network access; Windows loopback remains local. Remote web access uses IIS.'
            }
            $effectiveRule = Get-NetFirewallRule -Name $name -PolicyStore ActiveStore -ErrorAction Stop
            if ([string]$effectiveRule.Enabled -ne 'True' -or [string]$effectiveRule.Action -ne $policy.Action) {
                Die "Java firewall policy is not effective: $name. Review managed firewall policy before continuing."
            }
        }
    }
    Log 'Java inbound firewall policy configured: loopback allowed; remote network access blocked. IIS and SSH rules are unchanged.'
}
function New-Password([int]$Length = 40) {
    # Adobe lockdown concatenates credentials into form bodies without URL
    # encoding. '+' becomes a space and '%' may begin an escape sequence.
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@_'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $value = ''
            while ($value.Length -lt $Length) {
                $b = New-Object byte[] 1; $rng.GetBytes($b)
                if ($b[0] -lt (256 - (256 % $alphabet.Length))) { $value += $alphabet[$b[0] % $alphabet.Length] }
            }
        } until ($value -cmatch '[A-Z]' -and $value -cmatch '[a-z]' -and $value -match '[0-9]' -and $value -match '[!@%_+=]')
        return $value
    } finally { $rng.Dispose() }
}
function Plain([Security.SecureString]$Secret, [int]$Length = 40) {
    if (-not $Secret) { return New-Password $Length }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Protect-Directory([string]$Directory) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
function Export-CfAdminDesktopCredentials([string]$Username, [string]$Password, [string]$DesktopDirectory = [Environment]::GetFolderPath('DesktopDirectory')) {
    # Resolve the initiating user's Desktop before the cflockadmin task runs.
    $desktop = $DesktopDirectory
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
        $desktop = $WorkDir
        Log 'No Desktop folder; saving portal credentials in the protected work directory.'
    }
    $destination = Join-Path $desktop 'ColdFusion-Admin-Credentials.txt'
    # CreateNew refuses existing files and links. Apply the ACL atomically at
    # creation; never change permissions on the Desktop directory.
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $callerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($callerSid)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544',$callerSid.Value) | Select-Object -Unique) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')))
    }
    $stream = [IO.FileStream]::new($destination,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$acl)
    try {
        $content = "ColdFusion Administrator portal`r`nURL: http://localhost:8500/CFIDE/administrator/index.cfm`r`nUsername: $Username`r`nPassword: $Password`r`n"
        $bytes = (New-Object Text.UTF8Encoding($true)).GetBytes($content)
        $stream.Write($bytes,0,$bytes.Length)
    } finally { $stream.Dispose() }
    Log "ColdFusion Administrator credentials saved to $destination"
}
function Write-LabReceipt {
    param([string]$Directory, [string]$InstallDirectory, [int]$UpdateLevel,
        [bool]$LockdownEnabled, [string]$AdminUsername, [string]$AdminPassword,
        [string]$RuntimeUser)
    if ($UpdateLevel -lt 1) { Die 'Invalid verified update level.' }
    $record = Get-Content -LiteralPath (Join-Path $Directory 'README-credentials.md') -Raw
    $statuses = [regex]::Matches($record, '(?m)^Status: (.+?)\r?$')
    $updates = [regex]::Matches($record, '(?m)^Verified update: (\d+)\r?$')
    if (-not $statuses.Count -or $statuses[$statuses.Count - 1].Groups[1].Value -cne 'complete; IIS execution verified') {
        Die 'IIS execution was not verified; refusing readiness receipt.'
    }
    if (-not $updates.Count -or [int]$updates[$updates.Count - 1].Groups[1].Value -ne $UpdateLevel) {
        Die 'Verified update record does not match required level.'
    }
    $adminUrl = 'http://localhost:8500/CFIDE/administrator/index.cfm'
    $credentials = [ordered]@{ administrator = [ordered]@{ url = $adminUrl; username = $AdminUsername; password = $AdminPassword } }
    $receipt = [ordered]@{
        product = 'Adobe ColdFusion'; release = '2025'; update_level = $UpdateLevel
        verified_utc = [DateTime]::UtcNow.ToString('o')
        catalog_url = 'https://guides.adobe.com/coldfusion/en/docs/introduction-to-coldfusion/coldfusion-2025-updates.html'
        lockdown = $LockdownEnabled; runtime_user = $RuntimeUser
        checks = [ordered]@{
            core_hotfix_zero_errors = $true; live_update_matches_catalog = $true
            connector_cfml_executed = $true
            lockdown_success_without_rollback = $LockdownEnabled
        }
    }
    $ready = [ordered]@{
        status = 'ready'; product = 'Adobe ColdFusion'; release = '2025'
        application_url = 'http://localhost/'; administrator_url = $adminUrl
        install_directory = $InstallDirectory; webroot = 'C:\inetpub\wwwroot'
        logs_directory = $Directory; credentials_file = (Join-Path $Directory 'credentials.json')
        security_receipt = (Join-Path $Directory 'security-receipt.json')
        update_level = $UpdateLevel; lockdown = $LockdownEnabled
    }
    function Save-PrivateJson([string]$Name, $Value) {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $caller = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($caller)
        foreach ($sid in @('S-1-5-18','S-1-5-32-544',$caller.Value) | Select-Object -Unique) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')))
        }
        $path = Join-Path $Directory $Name
        $stream = [IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$acl)
        try {
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 6))
            $stream.Write($bytes,0,$bytes.Length)
        } finally { $stream.Dispose() }
    }
    Save-PrivateJson 'credentials.json' $credentials
    Save-PrivateJson 'security-receipt.json' $receipt
    Save-PrivateJson 'ready.json' $ready
    $ready | ConvertTo-Json -Depth 6 -Compress
}
function Assert-AdobeUrl([string]$Url) {
    $u = [uri]$Url
    if ($u.Scheme -ne 'https' -or $u.Port -ne 443 -or $u.UserInfo -or ($u.Host -ne 'adobe.com' -and -not $u.Host.EndsWith('.adobe.com'))) { Die 'Downloads and redirects must use HTTPS on Adobe-owned adobe.com hosts.' }
    return $u
}
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Fetch([string]$Url, [string]$Destination, [bool]$Authenticate = $true) {
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    if ($Authenticate -and $DownloadCredential) { $handler.Credentials = $DownloadCredential.GetNetworkCredential() }
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(40)
    try {
        for ($hop = 0; $hop -lt 8; $hop++) {
            $u = Assert-AdobeUrl $Url
            $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $u)
            if ($Authenticate) { foreach ($key in $DownloadHeaders.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, [string]$DownloadHeaders[$key]) } }
            $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                    $Url = (New-Object uri($u, $response.Headers.Location)).AbsoluteUri
                    continue
                }
                if ([int]$response.StatusCode -ne 200) { Die "Adobe download returned HTTP $([int]$response.StatusCode); refresh authorized URL/authentication." }
                $file = [IO.File]::Create("$Destination.part")
                try { $response.Content.CopyToAsync($file).GetAwaiter().GetResult() } finally { $file.Dispose() }
                Move-Item -LiteralPath "$Destination.part" -Destination $Destination -Force
                return
            } finally { $response.Dispose(); $request.Dispose() }
        }
        Die 'Too many Adobe download redirects.'
    } finally { $client.Dispose(); $handler.Dispose() }
}
function Check-Installer([string]$File, [string]$Hash) {
    if ((Get-Item -LiteralPath $File).Length -lt 1MB) { Die 'Download is too small to be an installer.' }
    if ($Hash -and ($Hash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Hash)) { Die 'Installer SHA-256 mismatch/invalid hash.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Adobe (Inc\.|Systems Incorporated)') { Die 'Installer does not have a valid Adobe Authenticode signature.' }
}
function Wait-Cf {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8500/CFIDE/administrator/index.cfm' -TimeoutSec 3
            if ($r.StatusCode -eq 200) { return }
        } catch {}
        Start-Sleep 5
    }
    Die 'ColdFusion HTTP readiness timed out. Inspect cfusion/logs.'
}
function Get-CfRuntimeProcess {
    $runtimeExe = Join-Path $CfInstallDir 'cfusion\bin\coldfusion.exe'
    Get-CimInstance Win32_Process -Filter "Name='coldfusion.exe'" -ErrorAction Stop |
        Where-Object { $_.ExecutablePath -eq $runtimeExe }
}
function Stop-Cf {
    $name = 'ColdFusion 2025 Application Server'
    sc.exe stop $name 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Service -Name $name).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
    if ((Get-Service -Name $name).Status -ne 'Stopped') {
        $service = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $name }
        if ($service.ProcessId -gt 0 -and $service.PathName -like "*$CfInstallDir*") {
            Stop-Process -Id $service.ProcessId -Force
        }
        (Get-Service -Name $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
    }
    # SCM can report Stopped while the JVM child still holds port 8500.
    # Observed after cfpm update: a later service start failed while the old
    # coldfusion.exe remained listening. Never clear the cache under that JVM.
    $deadline = (Get-Date).AddSeconds(30)
    $runtimes = @(Get-CfRuntimeProcess)
    while ($runtimes.Count -and (Get-Date) -lt $deadline) {
        Start-Sleep 3
        $runtimes = @(Get-CfRuntimeProcess)
    }
    foreach ($runtime in $runtimes) {
        # Recheck the path before acting on a PID. Do not kill unrelated Java/CF instances.
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($runtime.ProcessId)" -ErrorAction Stop
        if ($current -and $current.ExecutablePath -eq (Join-Path $CfInstallDir 'cfusion\bin\coldfusion.exe')) {
            Log "Stopping leftover ColdFusion runtime PID $($current.ProcessId) after the service stopped."
            Stop-Process -Id $current.ProcessId -Force -ErrorAction Stop
        }
    }
    $deadline = (Get-Date).AddSeconds(30)
    while (@(Get-CfRuntimeProcess).Count -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
    if (@(Get-CfRuntimeProcess).Count) { Die 'ColdFusion runtime did not exit; cache cleanup and restart were aborted.' }
    if (@(Get-NetTCPConnection -LocalPort $CfAdminPort -State Listen -ErrorAction SilentlyContinue).Count) {
        Die "Port $CfAdminPort is still occupied after ColdFusion stopped; cache cleanup and restart were aborted. Inspect the listener owner."
    }
}
function Verify-Update {
    $jar = Get-ChildItem -LiteralPath (Join-Path $CfInstallDir 'cfusion\lib\updates') -Filter 'chf2025*.jar' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $jar -or $jar.Name -notmatch '^chf2025(\d+)\.jar$' -or [int]$Matches[1] -ne $LatestLevel) { Die 'Installed hotfix JAR does not match latest Adobe update.' }
    $name = 'cfverify' + [guid]::NewGuid().ToString('N') + '.cfm'
    $script:ProbePath = Join-Path $CfInstallDir "cfusion\wwwroot\$name"
    Set-Content -LiteralPath $ProbePath -Encoding ASCII -Value '<cfif cgi.remote_addr NEQ "127.0.0.1"><cfheader statuscode="404"><cfabort></cfif><cfcontent type="text/plain" reset="true"><cfoutput>#server.coldfusion.updatelevel#</cfoutput>'
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $level = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8500/$name" -TimeoutSec 5).Content.Trim()
            if ($level -match '^\d+$' -and [int]$level -eq $LatestLevel) {
                Remove-Item -LiteralPath $ProbePath -Force; $script:ProbePath = $null
                Log "Verified live update $LatestLevel against Adobe catalog and hotfix JAR."; return
            }
        } catch {}
        Start-Sleep 5
    }
    Die 'Live update level does not match latest Adobe catalog.'
}
function Assert-HotfixLog([datetime]$NotBefore = [datetime]::MinValue) {
    $hotfixFolders = @(Get-ChildItem -LiteralPath (Join-Path $CfInstallDir 'cfusion\hf-updates') -Directory |
        Where-Object { $_.Name -match '^hf-2025-(\d+)-' -and [int]$Matches[1] -eq $LatestLevel })
    $logs = @($hotfixFolders | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*Install*.log' } |
        Where-Object LastWriteTime -ge $NotBefore | Sort-Object LastWriteTime -Descending)
    if (-not $logs.Count) { Die 'No core hotfix installation log was found for the required update.' }
    $summary = Get-Content -LiteralPath $logs[0].FullName -Raw
    if ($summary -notmatch 'Installation:\s*Successful\b' -or
        $summary -notmatch '(?m)^\s*0\s+FatalErrors\s*$' -or
        $summary -notmatch '(?m)^\s*0\s+NonFatalErrors\s*$') {
        Die "Core hotfix installer did not report success with zero errors. Inspect $($logs[0].FullName). A hotfix JAR alone is insufficient."
    }
    Log 'Core hotfix installer log reports success with zero fatal/nonfatal errors.'
}
function Get-BouncyCastleVersion([string]$BaseName) {
    if ($BaseName -match '-(\d+(?:\.\d+){1,3})$') { return [version]$Matches[1] }
    # Older BC filenames use 153 for version 1.53, e.g. jdk15on-153.
    if ($BaseName -match '-(1)(\d{2})$') { return [version]($Matches[1] + '.' + $Matches[2]) }
    Die "Cannot determine Bouncy Castle version from $BaseName. No duplicate cleanup was attempted for this set."
}
function Install-CoreUpdate {
    $installedJar = Get-ChildItem -LiteralPath (Join-Path $CfInstallDir 'cfusion\lib\updates') -Filter 'chf2025*.jar' |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($installedJar -and $installedJar.Name -match '^chf2025(\d+)\.jar$' -and [int]$Matches[1] -eq $LatestLevel) {
        Assert-HotfixLog
        return
    }
    # Resolve the current hotfix from the fetched Adobe catalog and its release
    # notes; never infer a download build number or hardcode "latest".
    $linkPattern = 'href=["'']([^"'']*coldfusion-2025[^"'']*update-' + $LatestLevel + '\.html)["'']'
    $noteUrls = @([regex]::Matches($catalog,$linkPattern,'IgnoreCase') |
        ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } | Sort-Object -Unique)
    if ($noteUrls.Count -ne 1) { Die 'Cannot resolve one Adobe release-notes page for the latest update.' }
    $noteUrl = (New-Object uri([uri]'https://guides.adobe.com/', $noteUrls[0])).AbsoluteUri
    $notesPath = Join-Path $WorkDir 'adobe-update-notes.html'
    Fetch $noteUrl $notesPath $false
    $notes = Get-Content -LiteralPath $notesPath -Raw
    $hotfixUrls = @([regex]::Matches($notes,'https://cfdownload\.adobe\.com/[^"<>\s]+/hotfix-(\d+)-(\d+)\.jar') |
        Where-Object { [int]$_.Groups[1].Value -eq $LatestLevel } | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($hotfixUrls.Count -ne 1) { Die 'Cannot resolve one Adobe hotfix JAR for the required update.' }
    $coreJar = Join-Path $WorkDir 'core-hotfix.jar'
    Fetch $hotfixUrls[0] $coreJar $false
    $jarArchive = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $jarArchive = [IO.Compression.ZipFile]::OpenRead($coreJar)
        if (-not $jarArchive.GetEntry('META-INF/MANIFEST.MF')) { Die 'Adobe hotfix download is not a runnable JAR.' }
    } finally { if ($jarArchive) { $jarArchive.Dispose() } }
    $coreProps = Join-Path $WorkDir 'hotfix-silent.properties'
    @(
        'INSTALLER_UI=silent'
        ('USER_INSTALL_DIR=' + $CfInstallDir.Replace('\','/'))
        ('DOC_ROOT=' + $CfInstallDir.Replace('\','/') + '/cfusion/wwwroot/')
        'INSTANCE_LIST=ALL'
    ) | Set-Content -LiteralPath $coreProps -Encoding ASCII
    try {
        Log 'Stopping ColdFusion fully before applying the core hotfix in a standalone JVM...'
        Stop-Cf
        $coreStarted = Get-Date
        $coreProcess = Start-Process -FilePath (Join-Path $CfInstallDir 'jre\bin\java.exe') `
            -ArgumentList ('-jar "' + $coreJar + '" -i silent -f "' + $coreProps + '"') `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $WorkDir 'core-update-console.log') `
            -RedirectStandardError (Join-Path $WorkDir 'core-update-error.log')
        $null = $coreProcess.Handle
        if (-not $coreProcess.WaitForExit(1800000)) { $coreProcess.Kill(); Die 'Standalone core hotfix installer timed out.' }
        Assert-HotfixLog $coreStarted
        if ($coreProcess.ExitCode -notin @(0,1)) { Die "Standalone core hotfix installer exited with code $($coreProcess.ExitCode). Inspect core-update diagnostics." }
        if ($coreProcess.ExitCode -eq 1) { Log 'Core hotfix returned warning exit code 1; its new log confirms success with zero fatal/nonfatal errors.' }
        if ((Get-Service -Name $cfServiceName).Status -ne 'Running') { Start-Service -Name $cfServiceName }
        Wait-Cf
    } finally { Remove-Item -LiteralPath $coreProps -Force -ErrorAction SilentlyContinue }
}
$os = Get-CimInstance Win32_OperatingSystem
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Die 'Requires x64 Windows and 64-bit Windows PowerShell.' }
if ($PSVersionTable.PSEdition -ne 'Desktop') { Die 'Run with Windows PowerShell 5.1 (powershell.exe), which provides the native IIS management modules.' }
$WindowsPlatform = Get-WindowsPlatform $os
if ([int]$os.ProductType -eq 2 -and -not $NoLockdown -and -not $UpdateOnly) { Die 'Default lockdown requires local accounts and cannot run on a domain controller. Use a member/standalone machine, or explicitly select -NoLockdown.' }
Log "Detected $($os.Caption), build $($os.BuildNumber); IIS setup mode: $WindowsPlatform."
foreach ($dir in @($WorkDir,$CfInstallDir)) {
    if ($dir -notmatch '^[A-Za-z]:\\[A-Za-z0-9_\\ -]+$' -or $dir.Contains('..') -or $dir.EndsWith('\')) { Die 'Use an absolute non-root local path without metacharacters or trailing slash.' }
    if ((Test-Path -LiteralPath $dir) -and ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Die 'Reparse-point work/install paths are refused.' }
}
if ($WorkDir.StartsWith($CfInstallDir + '\',[StringComparison]::OrdinalIgnoreCase) -or $CfInstallDir.StartsWith($WorkDir + '\',[StringComparison]::OrdinalIgnoreCase) -or $WorkDir -eq $CfInstallDir) { Die 'Work and install directories must be separate.' }
if ($UpdateOnly) {
    if (-not (Test-Path -LiteralPath (Join-Path $CfInstallDir 'cfusion\bin\coldfusion.exe'))) { Die 'No existing installation for -UpdateOnly.' }
} else {
    if ((Test-Path -LiteralPath $CfInstallDir) -or (Test-Path -LiteralPath (Join-Path $WorkDir 'README-credentials.md')) -or @(Get-Service '*ColdFusion*' -ErrorAction SilentlyContinue).Count) { Die 'Existing/partial installation detected. Use -UpdateOnly for a completed install; otherwise review/restore the VM.' }
    if (-not $InstallerUrl) { Die 'Supply an authorized Adobe -InstallerUrl.' }
}
if (-not (Test-Path -LiteralPath $WorkDir)) { $null = New-Item -ItemType Directory -Path $WorkDir }
Protect-Directory $WorkDir
$RunLock = $null; $ProbePath = $null
try { $RunLock = [IO.File]::Open((Join-Path $WorkDir 'install.lock'),'OpenOrCreate','ReadWrite','None') } catch { Die 'Another installer is running or the work directory is not writable.' }
$OriginalTemp = $env:TEMP; $OriginalTmp = $env:TMP
try {
$privateTemp = Join-Path $WorkDir 'temp'
if (-not (Test-Path -LiteralPath $privateTemp)) { $null = New-Item -ItemType Directory -Path $privateTemp }
$env:TEMP = $privateTemp; $env:TMP = $privateTemp
# Finish IIS/reboot prerequisites before downloads, credentials, or account creation.
Install-Iis $WindowsPlatform
Set-JavaFirewallPolicy
$Lockdown = if ($NoLockdown) { 'false' } else { 'true' }
$CfInstallerName = 'coldfusion.exe'; $LockdownInstallerName = 'lockdown.exe'
$CfAdminUsername = 'admin'; $CfAdminPort = 8500
$CfInstallTypeCode = if ($InstallType -eq 'developer') { 3 } else { 2 }
$CfDeploymentTypeCode = 1; $CfSecureProfile = 'true'; $CfDevProfile = 'false'
$CfAutoEnableUpdates = 'true'; $CfUpdateTrue = 0; $CfAutoUpdateTrue = 0
$ChangeShutdownPort = if ($NoLockdown) { '0' } else { '1' }
$ShutdownPortNew = Get-Random -Minimum 10000 -Maximum 60000
Fetch 'https://guides.adobe.com/coldfusion/en/docs/introduction-to-coldfusion/coldfusion-2025-updates.html' (Join-Path $WorkDir 'adobe-updates.html') $false
$catalog = Get-Content -LiteralPath (Join-Path $WorkDir 'adobe-updates.html') -Raw
$levels = @([regex]::Matches($catalog, 'ColdFusion\s*(?:\(2025 release\)|2025)\s*Update\s+(\d+)', 'IgnoreCase') | ForEach-Object { [int]$_.Groups[1].Value })
if (-not $levels.Count) { Die 'Cannot establish latest update from Adobe catalog. No installation attempted.' }
$LatestLevel = ($levels | Measure-Object -Maximum).Maximum
if (-not $UpdateOnly) {
    foreach ($name in @($CfServiceUsername,$LockdownAdminUsername)) { if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,19}$') { Die 'Invalid local account name.' } }
    if (-not $NoLockdown) {
        foreach ($name in @($CfServiceUsername,$LockdownAdminUsername)) { if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Die 'Requested account exists; refusing to adopt or reset it.' } }
        if ($CfServiceUsername -eq $LockdownAdminUsername) { Die 'Runtime and lockdown administrator must be different accounts.' }
    }
    $CfAdminPassword = Plain $AdminPassword
    $CfServicePassword = Plain $ServicePassword 14
    $WindowsAdminPassword = Plain $LockdownAdminPassword
    foreach ($password in @($CfAdminPassword,$CfServicePassword,$WindowsAdminPassword)) {
        if ($password -notmatch '^[A-Za-z0-9!@%_+=.,:-]{14,}$') { Die 'Passwords need >=14 characters from letters/digits/!@%_+=.,:- (safe Adobe properties subset).' }
    }
    if (-not $NoLockdown -and $CfAdminPassword.IndexOfAny([char[]]'+%') -ge 0) {
        Die 'The ColdFusion administrator password cannot contain + or % with lockdown: Adobe sends it without URL encoding. Choose another password or omit -AdminPassword to generate a compatible value.'
    }
    if (-not $NoLockdown -and $CfServicePassword.Length -gt 14) { Die 'Runtime password must be exactly 14 characters to preserve the documented Adobe net-user workaround.' }
    $accountNotes = if ($NoLockdown) { 'No lockdown OS accounts created. CF uses the base installer service identity (normally LocalSystem); inspect Services before use.' } else {
        "Lockdown administrator: $env:COMPUTERNAME\$LockdownAdminUsername`nPassword: $WindowsAdminPassword`nPurpose: privileged Adobe lockdown/rollback operations. Retained for recovery; disable when no longer needed.`nRuntime service account: $env:COMPUTERNAME\$CfServiceUsername`nPassword: $CfServicePassword`nPurpose: low-privilege ColdFusion services; created by Adobe lockdown."
    }
    @"
# ColdFusion 2025 local installation credentials
Status: pending (retained for recovery on failure).
License selection: $InstallType (no license file; Developer is the default).
Detected OS: $($os.Caption), build $($os.BuildNumber); IIS setup mode: $WindowsPlatform.
ColdFusion Administrator: $CfAdminUsername
Password: $CfAdminPassword
Purpose: ColdFusion configuration/package administration.
URL: http://localhost:8500/CFIDE/administrator/index.cfm
IIS URL: http://localhost/ (Administrator uses built-in port).
$accountNotes
IIS identity: DefaultAppPool (built-in application pool identity, no password).
Existing OS administrator credentials are not changed.
Install path: $CfInstallDir
Webroot: C:\inetpub\wwwroot
Logs: $WorkDir\*.log; $CfInstallDir\Adobe_ColdFusion*;
$CfInstallDir\cfusion\logs; $CfInstallDir\cfusion\hf-updates;
$CfInstallDir\lockdown\cfusion\Logs; C:\inetpub\logs\LogFiles
Lockdown enabled: $Lockdown; shutdown port requested: $ShutdownPortNew
Latest Adobe update required at start: $LatestLevel
"@ | Set-Content -LiteralPath (Join-Path $WorkDir 'README-credentials.md') -Encoding UTF8
    Export-CfAdminDesktopCredentials $CfAdminUsername $CfAdminPassword
    Fetch $InstallerUrl (Join-Path $WorkDir $CfInstallerName)
    Check-Installer (Join-Path $WorkDir $CfInstallerName) $InstallerSha256
    if (-not $NoLockdown) {
        Fetch $LockdownUrl (Join-Path $WorkDir $LockdownInstallerName)
        Check-Installer (Join-Path $WorkDir $LockdownInstallerName) $LockdownSha256
        $null = New-LocalUser -Name $LockdownAdminUsername -Password (ConvertTo-SecureString $WindowsAdminPassword -AsPlainText -Force) -Description 'Adobe ColdFusion lockdown recovery administrator'
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $LockdownAdminUsername
    }
}


if (-not $UpdateOnly) {
# --- ColdFusion silent install -----------------------------------------------
$cfInstaller = Join-Path $WorkDir $CfInstallerName
if (-not (Test-Path $cfInstaller)) { Die "ColdFusion installer not found at $cfInstaller" }

$silentLicenseActivationMode = ''
$silentLicenseFilePath = ''
$silentLicenseEdition = ''
# The properties file uses double-backslash for Windows paths in some fields
# and forward-slash in others. Adobe's own templates use forward-slash for
# the install folder in the main installer, so we do the same.
$cfInstallDirFwd = $CfInstallDir -replace '\\', '/'

$propsPath = Join-Path $WorkDir 'cf-silent.properties'
$propsContent = @"
#Silent properties for ColdFusion 2025 GUI Installer (generated by deploy-cf2025-windows.sh)
INSTALLER_UI=SILENT
SILENT_INSTALL_TYPE=$CfInstallTypeCode
SILENT_LICENSE_ACTIVATION_MODE=$silentLicenseActivationMode
SILENT_LICENSE_FILE_PATH=$silentLicenseFilePath
SILENT_LICENSE_EDITION=$silentLicenseEdition
SILENT_DEPLOYMENT_TYPE=$CfDeploymentTypeCode
SILENT_SERVER_TYPE=3
SILENT_INSTALL_JNBRIDGE=true
SILENT_INSTALL_ADMIN=false
SILENT_INSTALL_SOLR=false
SILENT_INSTALL_PDFG=false
SILENT_INSTALL_FOLDER=$cfInstallDirFwd
USER_INSTALL_DIR=$cfInstallDirFwd
SILENT_ENABLE_PROD_SECURE_PROFILE=$CfSecureProfile
SILENT_ENABLE_PROD_DEFAULT_PROFILE=false
SILENT_ENABLE_DEV_PROFILE=$CfDevProfile
SILENT_ADMIN_IP=
SILENT_JETTY_IP=
SILENT_ADMIN_USERNAME=$CfAdminUsername
SILENT_ADMIN_PASSWORD=$CfAdminPassword
SILENT_ENABLE_RDS=false
SILENT_RUNTIME_USER=
SILENT_RDS_PASSWORD=
SILENT_JETTY_USERNAME=admin
SILENT_JETTY_PASSWORD=$CfAdminPassword
SILENT_CONTEXT_ROOT=
SILENT_AUTO_ENABLE_UPDATES=$CfAutoEnableUpdates
SILENT_PREV_CF_MIGR_DIR=
ENABLE_RDS=false
ENABLE_WSRP=false
ENABLE_JSDEBUG=false
ENABLE_CFR=false
ENABLE_CFSWF=false
ENABLE_CFFORMS=false
"@
Set-Content -Path $propsPath -Value $propsContent -Encoding ASCII

$cfServiceExe = Join-Path $CfInstallDir 'cfusion\bin\coldfusion.exe'
if (Test-Path $cfServiceExe) {
    Log "ColdFusion already appears installed at $CfInstallDir, skipping installer."
} else {
    # Clean up leftover InstallAnywhere state that can cause exit=255
    Remove-Item -Path "$env:TEMP\.com.zerog.registry.xml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:TEMP\install.dir.*" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:TEMP\InstallScript.iap_xml" -Force -ErrorAction SilentlyContinue

    Log "Running ColdFusion 2025 silent installer (this takes 10-20 minutes)..."
    # Do NOT use -NoNewWindow: the installer starts the CF service, which
    # inherits the console and never exits, causing -Wait to hang forever.
    $proc = Start-Process -FilePath $cfInstaller -ArgumentList "-f `"$propsPath`"" `
        -PassThru -WindowStyle Hidden
    $installerTimeoutSec = 1800
    if (-not $proc.WaitForExit($installerTimeoutSec * 1000)) {
        Log "WARNING: CF installer did not exit within ${installerTimeoutSec}s; killing it."
        $proc.Kill()
        $proc.WaitForExit(10000)
    }
    if (-not $proc.HasExited -or $proc.ExitCode -ne 0) { Die "Base installer failed/timed out. Inspect Adobe install logs." }
}

# Verify installation
$cfBatchFile = Join-Path $CfInstallDir 'cfusion\bin\cfstart.bat'
$cfServiceName = 'ColdFusion 2025 Application Server'
if (-not (Test-Path (Join-Path $CfInstallDir 'cfusion\bin'))) {
    Die "ColdFusion installer did not produce $CfInstallDir\cfusion\bin; check install logs under $CfInstallDir"
}

# Start ColdFusion service
Log "Starting ColdFusion..."
$cfSvc = Get-Service -Name $cfServiceName -ErrorAction SilentlyContinue
if ($cfSvc) {
    if ($cfSvc.Status -ne 'Running') {
        Start-Service -Name $cfServiceName
    }
} else {
    # Fall back to the batch file if the service isn't registered yet
    if (Test-Path $cfBatchFile) {
        & $cfBatchFile
    }
}

# Wait for ColdFusion to respond

Log "Waiting for ColdFusion built-in web server on port $CfAdminPort..."
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$CfAdminPort)
        $tcp.Close()
        $ready = $true; break
    } catch {}
    Start-Sleep -Seconds 5
}
if ($ready) { Log "ColdFusion port $CfAdminPort is listening." }
else        { Log "WARNING: ColdFusion did not open port $CfAdminPort within timeout; continuing anyway." }

# Complete first-run configuration by hitting the admin page with a session
# cookie (required before lockdown tool can run).
Log "Completing first-run configuration..."
try {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:${CfAdminPort}/CFIDE/administrator/index.cfm?configserver=true" `
        -UseBasicParsing -TimeoutSec 30 -DisableKeepAlive -WebSession $session -ErrorAction Stop
    Start-Sleep -Seconds 10
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:${CfAdminPort}/CFIDE/administrator/index.cfm" `
        -UseBasicParsing -TimeoutSec 30 -DisableKeepAlive -WebSession $session -ErrorAction Stop
    Log "First-run configuration completed."
} catch {
    Die 'First-run configuration request failed. Inspect Adobe runtime logs.'
}

} # fresh install
$cfServiceName = 'ColdFusion 2025 Application Server'
Wait-Cf
Install-CoreUpdate
# --- Update ColdFusion to the latest version ---------------------------------
$cfpmBat = Join-Path $CfInstallDir 'cfusion\bin\cfpm.bat'
if (Test-Path $cfpmBat) {
    Log "Updating ColdFusion to the latest version via cfpm..."

    # cfpm.bat update all prompts "Press Y to proceed:" even in non-interactive
    # mode. Pipe "y" via cmd /c so stdin feeds through the batch file's JVM.
    $updateCmd = Join-Path $WorkDir 'update.cmd'
    $updateText = '@echo off' + [Environment]::NewLine + 'echo y|call "' + $cfpmBat + '" update all >"' + $WorkDir + '\update.log" 2>&1' + [Environment]::NewLine + 'exit /b %errorlevel%'
    Set-Content -LiteralPath $updateCmd -Encoding ASCII -Value $updateText
    $updateProc = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""' + $updateCmd + '""') -WindowStyle Hidden -PassThru
    if (-not $updateProc.WaitForExit(2400000)) { $updateProc.Kill(); Die 'cfpm timed out. Inspect protected update.log.' }
    if ($updateProc.ExitCode -ne 0) { Die 'Mandatory cfpm update failed. Inspect protected update.log.' }
    if (Select-String -LiteralPath (Join-Path $WorkDir 'update.log') -SimpleMatch 'There are errors in the installation of this update' -Quiet) {
        Die 'cfpm reported core update installation errors despite its exit code. Inspect hotfix installer logs.'
    }
    Assert-HotfixLog

    # cfpm downloads the hotfix JAR and runs the update installer, but the
    # update installer leaves old BouncyCastle JARs alongside new ones in
    # cfusion/lib. Java loads classes from both signed JARs, and the signer
    # info conflicts ("SpiUtil's signer information does not match..."),
    # preventing the license service from initializing. Remove old versions.
    Log "Cleaning up duplicate BouncyCastle JARs..."
    $bcLibDir = Join-Path $CfInstallDir 'cfusion\lib'
    foreach ($prefix in @('bcprov-jdk', 'bcpkix-jdk', 'bcutil-jdk', 'bcmail-jdk')) {
        $jars = @(Get-ChildItem -Path $bcLibDir -Filter "${prefix}*.jar" -ErrorAction SilentlyContinue |
            Sort-Object { Get-BouncyCastleVersion $_.BaseName })
        if ($jars.Count -gt 1) {
            # Keep only the newest (last alphabetically — higher version number)
            $jars | Select-Object -SkipLast 1 | ForEach-Object {
                Log "  Removing old JAR: $($_.Name)"
                Remove-Item $_.FullName -Force
            }
        }
    }
    # Also clean duplicates in bundles/repo
    $bcRepoDir = Join-Path $CfInstallDir 'bundles\repo'
    if (Test-Path $bcRepoDir) {
        foreach ($prefix in @('bcprov-jdk', 'bcpkix-jdk', 'bcutil-jdk', 'bcmail-jdk')) {
            $jars = @(Get-ChildItem -Path $bcRepoDir -Filter "${prefix}*.jar" -ErrorAction SilentlyContinue |
                Sort-Object { Get-BouncyCastleVersion $_.BaseName })
            if ($jars.Count -gt 1) {
                $jars | Select-Object -SkipLast 1 | ForEach-Object {
                    Log "  Removing old JAR from bundles/repo: $($_.Name)"
                    Remove-Item $_.FullName -Force
                }
            }
        }
    }

    # Determine the installed update level from the hotfix JAR filename.
    # The JAR is named chf2025NNNN.jar where NNNN is the zero-padded update
    # number (e.g. chf20250014.jar for update 14).
    $updatesDir = Join-Path $CfInstallDir 'cfusion\lib\updates'
    $hfJar = Get-ChildItem -Path $updatesDir -Filter 'chf2025*.jar' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($hfJar) {
        $updateNum = $hfJar.Name -replace '^chf2025(\d+)\.jar$', '$1'
        $updateLevel = $updateNum.TrimStart('0')
        if (-not $updateLevel) { $updateLevel = '0' }
        $paddedLevel = $updateNum  # already zero-padded from filename

        # Extract build number from the hf-updates subdirectory name
        $hfDir = Get-ChildItem -Path (Join-Path $CfInstallDir 'cfusion\hf-updates') `
            -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^hf-2025-(\d+)-' -and [int]$Matches[1] -eq [int]$updateNum } |
            Select-Object -First 1
        $buildNumber = ''
        if ($hfDir) {
            $buildNumber = $hfDir.Name -replace '^hf-2025-\d+-', ''
        }

        # Update the tracking XML so CF Admin and cfpm report the correct level
        $updatesXmlPath = Join-Path $CfInstallDir 'cfusion\hf-updates\updates.xml'
        $existingXml = ''
        if (Test-Path $updatesXmlPath) {
            $existingXml = Get-Content $updatesXmlPath -Raw -ErrorAction SilentlyContinue
        }
        if ($existingXml -notmatch "cfhf_updatelevel>${paddedLevel}<") {
            Log "Updating updates.xml to reflect update level $paddedLevel (build $buildNumber)..."
            $backupDir = ''
            if ($hfDir) { $backupDir = Join-Path $hfDir.FullName 'backup' }
            $newItem = @"

    <item>
         <title>ColdFusion 2025 Update $updateLevel</title>
         <description>ColdFusion (2025 release) Update $updateLevel</description>
         <cfhf_id>hf-2025-$updateNum</cfhf_id>
         <cfhf_technotelink>http://www.adobe.com/go/cf2025_update${updateLevel}</cfhf_technotelink>
         <cfhf_type>General</cfhf_type>
         <cfhf_updatelevel>$paddedLevel</cfhf_updatelevel>
         <cfhf_buildnumber>$buildNumber</cfhf_buildnumber>
         <cfhf_installdate></cfhf_installdate>
         <cfhf_backupdir>$backupDir</cfhf_backupdir>
    </item>
"@
            # Prepend the new update item (most recent first) into the XML
            if ($existingXml -match '<updates>') {
                $updatedXml = $existingXml -replace '<updates>', "<updates>$newItem"
            } else {
                $updatedXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<updates>$newItem
</updates>
"@
            }
            Set-Content -Path $updatesXmlPath -Value $updatedXml -Encoding UTF8
        }
        Log "Installed hotfix artifact level $paddedLevel (build $buildNumber); live verification follows."
    } else {
        Die "No hotfix JAR found; mandatory update verification failed."
    }

    # Purge the OSGi bundle cache and restart so the updated classes load cleanly
    Log "Purging felix cache and restarting ColdFusion after update..."
    Stop-Cf
    Remove-Item -Path (Join-Path $CfInstallDir 'cfusion\bin\felix-cache') -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service -Name $cfServiceName

    Log "Waiting for ColdFusion to start after update..."
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$CfAdminPort)
            $tcp.Close()
            $ready = $true; break
        } catch {}
        Start-Sleep -Seconds 5
    }
    if ($ready) { Log "ColdFusion is running after update." }
    else        { Log "WARNING: ColdFusion did not open port $CfAdminPort after update; continuing anyway." }
} else {
    Die "cfpm.bat missing; mandatory update cannot run."
}

Wait-Cf
Verify-Update
if ($UpdateOnly) {
    $credentialsPath = Join-Path $WorkDir 'README-credentials.md'
    if (Test-Path -LiteralPath $credentialsPath) { Add-Content -LiteralPath $credentialsPath -Value "`nUpdate-only verification: $LatestLevel at $([DateTime]::UtcNow.ToString('o'))" }
    Log 'Update-only verification succeeded. Existing credentials and lockdown retained.'; return
}
function Complete-Installation {
# --- Helper: configure the IIS connector via wsconfig -----------------------
function Configure-IISConnector {
    # Add ISAPI/CGI restriction for the connector DLL (required or IIS blocks it)
    $dllPath = Join-Path $CfInstallDir 'config\wsconfig\1\isapi_redirect.dll'
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $existing = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT' `
        -Filter 'system.webServer/security/isapiCgiRestriction' -Name Collection `
        -ErrorAction SilentlyContinue | Where-Object { $_.path -eq $dllPath }
    if (-not $existing) {
        Log "Adding ISAPI/CGI restriction for ColdFusion connector DLL..."
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT' `
            -Filter 'system.webServer/security/isapiCgiRestriction' -Name Collection `
            -Value @{path=$dllPath; allowed=$true; description='ColdFusion'}
    }

    # Remove the 32-bit ASP.NET ISAPI filter that Windows Server 2025 registers
    # by default. On a 64-bit-only app pool it fails to load, and IIS aborts
    # ALL ISAPI filters for the site when any one fails — blocking the CF
    # connector DLL from loading entirely (Event 2274 / win32 status 193).
    # Must check both site and server level; the lockdown tool can re-add it.
    # Always attempt removal unconditionally — Get-WebConfigurationProperty
    # can return stale results after the lockdown tool modifies the config.
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    foreach ($psPath in @('IIS:\Sites\Default Web Site', 'MACHINE/WEBROOT/APPHOST')) {
        try {
            Remove-WebConfigurationProperty -PSPath $psPath `
                -Filter 'system.webServer/isapiFilters' -Name Collection `
                -AtElement @{name='ASP.Net_4.0_32bit'} -ErrorAction Stop
            Log "Removed incompatible 32-bit ASP.NET ISAPI filter from $psPath."
        } catch {
            # Filter wasn't present — that's fine
        }
    }

    $wsconfigExe = Join-Path $CfInstallDir 'cfusion\runtime\bin\wsconfig.exe'
    if (Test-Path $wsconfigExe) {
        & $wsconfigExe -ws iis -site "Default Web Site" -v > (Join-Path $WorkDir 'connector.log') 2>&1
        if ($LASTEXITCODE -ne 0) { Die 'IIS connector setup failed; see connector.log.' }
    } else {
        $wsconfigJar = Join-Path $CfInstallDir 'cfusion\runtime\lib\wsconfig.jar'
        $javaExe = Join-Path $CfInstallDir 'jre\bin\java.exe'
        if ((Test-Path $wsconfigJar) -and (Test-Path $javaExe)) {
            & $javaExe -jar $wsconfigJar -ws iis -site "Default Web Site" -v > (Join-Path $WorkDir 'connector.log') 2>&1
            if ($LASTEXITCODE -ne 0) { Die 'IIS connector setup failed; see connector.log.' }
        } else {
            Die 'No wsconfig tool; cannot configure IIS connector.'
        }
    }

    # Preserve lockdown ACLs and CFIDE isolation. Administrator uses port 8500.

}

# --- IIS connector / lockdown ------------------------------------------------
if ($Lockdown -eq 'true') {
    Log "Accessing ColdFusion Administrator once (Lockdown Tool prerequisite)..."
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:${CfAdminPort}/CFIDE/administrator/index.cfm" `
            -UseBasicParsing -TimeoutSec 15 -DisableKeepAlive -ErrorAction Stop
    } catch {
        Log "WARNING: could not reach the Administrator; the Lockdown Tool may refuse to run."
    }

    $lockdownInstaller = Join-Path $WorkDir $LockdownInstallerName
    if (-not (Test-Path $lockdownInstaller)) {
        Die "Lockdown installer not found at $lockdownInstaller"
    }

    $hostname = $env:COMPUTERNAME
    $cfInstallDirLockdownFwd = $CfInstallDir -replace '\\', '/'
    $lockdownPropsPath = Join-Path $WorkDir 'lockdown-silent.properties'
    $lockdownProps = @"
# Silent Properties file for Adobe ColdFusion Server Auto-Lockdown Installer
# Web Server : IIS
# Platform : Windows
# (generated by deploy-cf2025-windows.sh)
INSTALLER_UI=SILENT
SILENT_CF_SERVER_LOCATION=$cfInstallDirLockdownFwd
SERVER_IIS=1
SERVER_APACHE=0
APP_SERVER_INSTANCE=cfusion
SILENT_WEBSITES_TO_LOCKDOWN=Default Web Site
SILENT_APP_POOL_IIS_WEBSITES=DefaultAppPool
SILENT_WEBROOT_IIS_WEBSITES=C:/inetpub/wwwroot
UPDATE_CF_TRUE=$CfUpdateTrue
AUTO_UPDATE_CF_TRUE=$CfAutoUpdateTrue
HF_UPDATE_JAR_PATH=
CF_ADMIN_USERNAME=$CfAdminUsername
CF_ADMIN_PASSWORD=$CfAdminPassword
CF_ADMIN_PORT=$CfAdminPort
SYSTEM_ADMIN_USER=$LockdownAdminUsername
SYSTEM_ADMIN_PWD=$WindowsAdminPassword
SYSTEM_ADMIN_DOMAIN=$hostname
USER_CF_SERVICE_TRUE=0
CF_USER_UNAME=$CfServiceUsername
CF_USER_DOMAIN=$hostname
CF_USER_PWD=$CfServicePassword
CHANGE_SHUTDOWN_PORT_TRUE=$ChangeShutdownPort
SHUTDOWN_PORT_NEW=$ShutdownPortNew
"@
    Set-Content -Path $lockdownPropsPath -Value $lockdownProps -Encoding ASCII

    # The lockdown tool has the same hang bug on Windows as on Linux: after it
    # restarts ColdFusion for the runtime-user change, the restarted CF process
    # inherits the stdout/stderr pipe the tool reads from, so that pipe never
    # reaches EOF and the tool hangs forever even though its work is done.
    # Bound it with a generous timeout (10 minutes) instead of waiting forever.
    $lockdownTimeoutSec = 300
    Log "Running ColdFusion 2025 Server Auto-Lockdown Tool (Windows/IIS, ${lockdownTimeoutSec}s timeout)..."
    $lockdownProc = Start-Process -FilePath $lockdownInstaller `
        -ArgumentList "-f `"$lockdownPropsPath`" -i silent" `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $WorkDir 'lockdown-console.log') -RedirectStandardError (Join-Path $WorkDir 'lockdown-error.log')
    if (-not $lockdownProc.WaitForExit($lockdownTimeoutSec * 1000)) {
        Log "Lockdown Tool did not exit within ${lockdownTimeoutSec}s (expected, known hang bug). Killing it."
        $lockdownProc.Kill()
        $lockdownProc.WaitForExit(10000)
    } else {
        Log "Lockdown Tool exited with code $($lockdownProc.ExitCode)."
    }

    $lockdownLogDir = Join-Path $CfInstallDir 'lockdown\cfusion\Logs'
    if ((Test-Path $lockdownLogDir) -and (Select-String -Path (Join-Path $lockdownLogDir '*') -Pattern 'Successfully locked down ColdFusion!' -Quiet -ErrorAction SilentlyContinue)) {
        Log "Lockdown Tool applied its changes. Logs: $lockdownLogDir"
    } else {
        Log "WARNING: could not confirm lockdown progress automatically. Check logs under $lockdownLogDir"
    }

    if (-not (Select-String -Path (Join-Path $lockdownLogDir '*') -Pattern 'Successfully locked down ColdFusion!' -Quiet -ErrorAction SilentlyContinue) -or
        (Select-String -Path (Join-Path $lockdownLogDir '*') -Pattern 'Rolling back' -Quiet -ErrorAction SilentlyContinue)) {
        Die "Lockdown failed or rolled back. Inspect $lockdownLogDir"
    }
    $runtimeServices = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*$CfInstallDir*" })
    if (-not $runtimeServices.Count -or @($runtimeServices | Where-Object { $_.StartName -notmatch "[\\]$([regex]::Escape($CfServiceUsername))$" }).Count) { Die 'ColdFusion services do not all use the expected runtime account.' }
    Remove-Item -Path $lockdownPropsPath -Force -ErrorAction SilentlyContinue

    # Ensure IIS connector is configured (lockdown tool may not have done it)
    Log "Ensuring ColdFusion is connected to IIS (wsconfig)..."
    Configure-IISConnector

    iisreset /restart 2>&1 | ForEach-Object { Log $_ }
} else {
    # No lockdown — just configure the IIS connector
    Log "Skipping lockdown; connecting ColdFusion to IIS with wsconfig..."
    Configure-IISConnector

    iisreset /restart 2>&1 | ForEach-Object { Log $_ }
}

# --- Shutdown port fix (same as Linux: lockdown tool may not have done it) ---
if ($ChangeShutdownPort -eq '1' -and $ShutdownPortNew) {
    $serverXml = Join-Path $CfInstallDir 'cfusion\runtime\conf\server.xml'
    if (Test-Path $serverXml) {
        $content = Get-Content $serverXml -Raw
        if ($content -notmatch "port=`"$ShutdownPortNew`" shutdown=") {
            Log "Setting Tomcat shutdown port to $ShutdownPortNew in server.xml..."
            $content = $content -replace '(<Server port=")[0-9]+(" shutdown=)', "`${1}$ShutdownPortNew`${2}"
            Set-Content -Path $serverXml -Value $content -NoNewline
        }
    }
}

# --- Restart ColdFusion to pick up all changes --------------------------------
# Stop-Service / Restart-Service can hang for 5+ minutes waiting for the JVM.
# Use sc.exe stop (non-blocking) + poll + force-kill as a fallback.
Log "Restarting ColdFusion..."
$cfSvc = Get-Service -Name $cfServiceName -ErrorAction SilentlyContinue
if ($cfSvc) {
    Stop-Cf
    Start-Service -Name $cfServiceName
} elseif (Test-Path $cfBatchFile) {
    & (Join-Path $CfInstallDir 'cfusion\bin\cfstop.bat') 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    & $cfBatchFile
}

# --- Final 32-bit ISAPI filter cleanup ----------------------------------------
# The 32-bit ASP.Net_4.0_32bit ISAPI filter can reappear after wsconfig or
# iisreset re-reads the machine-level IIS configuration. Remove it one last
# time after all IIS changes are complete, then restart IIS so the clean
# config takes effect. Without this, the 32-bit filter causes IIS to abort
# ALL ISAPI filters for the site (including the CF connector).
Import-Module WebAdministration -ErrorAction SilentlyContinue
$filter32Removed = $false
foreach ($psPath in @('IIS:\Sites\Default Web Site', 'MACHINE/WEBROOT/APPHOST')) {
    try {
        Remove-WebConfigurationProperty -PSPath $psPath `
            -Filter 'system.webServer/isapiFilters' -Name Collection `
            -AtElement @{name='ASP.Net_4.0_32bit'} -ErrorAction Stop
        Log "Removed 32-bit ISAPI filter from $psPath."
        $filter32Removed = $true
    } catch {}
}
if ($filter32Removed) {
    iisreset /restart 2>&1 | Out-Null
}

# --- Cleanup sensitive files --------------------------------------------------
Remove-Item -Path $propsPath -Force -ErrorAction SilentlyContinue



Wait-Cf
Verify-Update
$connectorName = 'cfconnector' + [guid]::NewGuid().ToString('N') + '.cfm'
$ProbePath = Join-Path 'C:\inetpub\wwwroot' $connectorName
$connectorToken = [guid]::NewGuid().ToString('N')
$connectorProbeCreated = $false
try {
    Set-Content -LiteralPath $ProbePath -Encoding ASCII -Value ('<cfif cgi.remote_addr NEQ "127.0.0.1"><cfheader statuscode="404"><cfabort></cfif><cfcontent type="text/plain" reset="true"><cfoutput>' + $connectorToken + '</cfoutput>') -ErrorAction Stop
    $connectorProbeCreated = $true
} catch [System.UnauthorizedAccessException] {
    $ProbePath = $null
    Log 'WARNING: IIS webroot denies probe creation. Preserving permissions; end-to-end IIS execution remains UNVERIFIED.'
}
if ($connectorProbeCreated) {
    $connectorResponse = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1/$connectorName" -TimeoutSec 30
    if ($connectorResponse.Content.Trim() -ne $connectorToken) { Die 'IIS did not execute the ColdFusion connector probe.' }
    Remove-Item -LiteralPath $ProbePath -Force; $ProbePath = $null
    $completionStatus = 'complete; IIS execution verified'
    Log "Done. ColdFusion is installed at $CfInstallDir; IIS execution verified."
} else {
    $completionStatus = 'configuration finished; IIS execution verification pending (webroot access denied)'
    Write-Warning 'ColdFusion update verified, but IIS application execution requires a separate test in the intended application site.'
}
Add-Content -LiteralPath (Join-Path $WorkDir 'README-credentials.md') -Value "`nVerified update: $LatestLevel`nStatus: $completionStatus"
}

if ($Lockdown -eq 'true') {
    # Adobe removes the initiating administrator's webroot permissions while
    # granting the selected lockdown administrator access. Run the whole final
    # phase as that account, including the probes, rather than weakening ACLs.
    $phaseContext = Join-Path $WorkDir 'lockdown-context.xml'
    $phaseWorker = Join-Path $WorkDir 'complete-installation.ps1'
    $phaseResult = Join-Path $WorkDir 'lockdown-result.json'
    $phaseLog = Join-Path $WorkDir 'completion.log'
    $phaseTask = 'CF2025Complete-' + [guid]::NewGuid().ToString('N')
    $context = @{}
    foreach ($variableName in @('WorkDir','CfInstallDir','Lockdown','LockdownInstallerName',
        'CfAdminPort','CfAdminUsername','CfAdminPassword','LockdownAdminUsername',
        'WindowsAdminPassword','CfServiceUsername','CfServicePassword','CfUpdateTrue',
        'CfAutoUpdateTrue','ChangeShutdownPort','ShutdownPortNew','cfServiceName',
        'cfBatchFile','propsPath','LatestLevel','privateTemp')) {
        $context[$variableName] = Get-Variable -Name $variableName -ValueOnly
    }
    $context | Export-Clixml -LiteralPath $phaseContext
    $helpers = foreach ($helperName in @('Log','Die','Wait-Cf','Get-CfRuntimeProcess','Stop-Cf','Verify-Update','Complete-Installation')) {
        'function ' + $helperName + ' {' + (Get-Command $helperName -CommandType Function).Definition + "`n}"
    }
    $workerPreamble = @'
#Requires -Version 5.1
#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$context = Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'lockdown-context.xml')
foreach ($entry in $context.GetEnumerator()) { Set-Variable -Name $entry.Key -Value $entry.Value -Scope Script }
$env:TEMP = $privateTemp; $env:TMP = $privateTemp
$ProbePath = $null
'@
    $workerEnd = @'
try {
    Complete-Installation *> (Join-Path $WorkDir 'completion.log')
    @{ Success = $true } | ConvertTo-Json | Set-Content (Join-Path $WorkDir 'lockdown-result.json')
} catch {
    $_ | Format-List * -Force | Out-String | Set-Content (Join-Path $WorkDir 'completion-failure.log')
    @{ Success = $false } | ConvertTo-Json | Set-Content (Join-Path $WorkDir 'lockdown-result.json')
    exit 1
} finally {
    foreach ($name in @('cf-silent.properties','lockdown-silent.properties')) {
        Remove-Item -LiteralPath (Join-Path $WorkDir $name) -Force -ErrorAction SilentlyContinue
    }
    if ($ProbePath -and (Test-Path -LiteralPath $ProbePath)) { Remove-Item -LiteralPath $ProbePath -Force }
}
'@
    Set-Content -LiteralPath $phaseWorker -Value (@($workerPreamble) + $helpers + @($workerEnd)) -Encoding UTF8
    try {
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + $phaseWorker + '"') -WorkingDirectory $WorkDir
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $phaseTask -Action $action -Settings $settings `
            -User "$env:COMPUTERNAME\$LockdownAdminUsername" -Password $WindowsAdminPassword -RunLevel Highest -ErrorAction Stop
        Log "Running lockdown and final verification as $LockdownAdminUsername; progress: $phaseLog"
        Start-ScheduledTask -TaskName $phaseTask -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(20)
        while (-not (Test-Path -LiteralPath $phaseResult)) {
            Start-Sleep 5
            $taskState = (Get-ScheduledTask -TaskName $phaseTask).State
            if ($taskState -ne 'Running') {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $phaseTask
                if ($taskInfo.LastTaskResult -ne 0 -and $taskInfo.LastTaskResult -ne 267011) {
                    Die "Completion worker exited with result $($taskInfo.LastTaskResult). Inspect completion.log and completion-failure.log."
                }
            }
            if ((Get-Date) -ge $deadline) { Die 'Completion worker timed out. Inspect protected completion diagnostics.' }
        }
        if (-not (Get-Content -LiteralPath $phaseResult -Raw | ConvertFrom-Json).Success) {
            Die 'Lockdown/final verification failed. Inspect protected completion.log and completion-failure.log.'
        }
        Log 'Lockdown and final verification completed successfully.'
    } finally {
        if (Get-ScheduledTask -TaskName $phaseTask -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $phaseTask -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $phaseTask -Confirm:$false -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $phaseContext,$phaseWorker -Force -ErrorAction SilentlyContinue
    }
} else {
    Complete-Installation
}
Write-LabReceipt -Directory $WorkDir -InstallDirectory $CfInstallDir -UpdateLevel $LatestLevel `
    -LockdownEnabled ($Lockdown -eq 'true') -AdminUsername $CfAdminUsername `
    -AdminPassword $CfAdminPassword -RuntimeUser $CfServiceUsername
} catch {
  $_ | Format-List * -Force | Out-String | Set-Content -LiteralPath (Join-Path $WorkDir 'failure.log')
  throw [System.Exception]::new("Local installation failed. Inspect protected failure.log and Adobe diagnostics in $WorkDir. No automatic retry was attempted.")
} finally {
  foreach ($name in @('cf-silent.properties','lockdown-silent.properties','hotfix-silent.properties','update.cmd')) { Remove-Item -LiteralPath (Join-Path $WorkDir $name) -Force -ErrorAction SilentlyContinue }
  if ($ProbePath -and (Test-Path -LiteralPath $ProbePath)) { Remove-Item -LiteralPath $ProbePath -Force }
  if ($RunLock) { $RunLock.Dispose() }
  $env:TEMP = $OriginalTemp; $env:TMP = $OriginalTmp
}
