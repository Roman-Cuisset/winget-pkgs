param(
    [Parameter(Mandatory)][string]$CandidateArchive,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedExecutableSha256
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -ne 'Roman-Cuisset/winget-pkgs' -or
    $env:RUNNER_ARCH.ToLowerInvariant() -ne $env:WINGET_TEST_ARCH -or
    [Environment]::GetFolderPath('LocalApplicationData') -ne $env:LOCALAPPDATA) {
    throw 'This test must use an isolated native GitHub-hosted Windows profile.'
}

$id = 'RomanCuisset.OctetLedger'
$stageSource = 'OctetLedgerStage'
$candidatePath = (Resolve-Path -LiteralPath $CandidateArchive).Path
$fixture = Join-Path $env:RUNNER_TEMP 'octetledger-https-catalogue'
$sourceProcess = $certificate = $certificateStore = $null
$data = Join-Path $env:LOCALAPPDATA 'OctetLedger'
$link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\octetledger.exe'
$database = Join-Path $data 'octetledger.db'
$settings = Join-Path $data 'settings.json'
$ready = Join-Path $data 'collector.ready'
$pidFile = Join-Path $data 'collector.pid'
$logFile = Join-Path $data 'collector.log'
$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ((Test-Path $link) -or (Test-Path $data)) { throw 'An OctetLedger installation already exists in this profile.' }

$evidence = [ordered]@{
    status = 'fail'
    architecture = $env:WINGET_TEST_ARCH
    candidateZipSha256 = (Get-FileHash -LiteralPath $candidatePath).Hash
    steps = [Collections.Generic.List[string]]::new()
}
function Record([string]$Step) {
    $evidence.steps.Add($Step)
    Write-Host $Step
}
function Wait-For([scriptblock]$Check, [string]$Description, [int]$Seconds = 100) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = & $Check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 500
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw "Timed out waiting for $Description."
}
function Invoke-WinGet([string[]]$Arguments) {
    Write-Host ('winget ' + ($Arguments -join ' '))
    & $script:client @Arguments
    if ($LASTEXITCODE -ne 0) { throw "WinGet returned $LASTEXITCODE for $($Arguments -join ' ')." }
}
function Assert-Version([string]$Version) {
    if ((& $link version) -ne "OctetLedger $Version" -or $LASTEXITCODE -ne 0) { throw "Portable alias does not run OctetLedger $Version." }
    $entries = @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object DisplayName -eq 'OctetLedger')
    if ($entries.Count -ne 1 -or $entries[0].DisplayVersion -ne $Version) {
        $registrations = $entries | Select-Object PSChildName,DisplayVersion | ConvertTo-Json -Compress
        throw "WinGet did not register one user-scope OctetLedger $Version installation. Actual: $registrations"
    }
    return $entries[0].PSChildName
}
function Assert-CandidateExecutable {
    $evidence.executableSha256 = (Get-FileHash $link).Hash.ToLowerInvariant()
    if ($evidence.executableSha256 -ne $ExpectedExecutableSha256.ToLowerInvariant()) {
        throw 'Installed executable does not match the native build for this architecture.'
    }
}
function Get-AliasInfo {
    $item = Get-Item -LiteralPath $link -Force
    $target = $item.ResolveLinkTarget($true).FullName
    if ($item.LinkType -ne 'SymbolicLink' -or -not $target) { throw 'WinGet did not create the expected portable symlink.' }
    [pscustomobject]@{ LinkType = $item.LinkType; Target = $target }
}
function Get-ZoneId([string]$Path) {
    if (-not $Path) { return $null }
    $zone = Get-Content -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue
    $match = [regex]::Match(($zone -join "`n"), 'ZoneId=(\d+)')
    if ($match.Success) { [int]$match.Groups[1].Value } else { $null }
}
function Read-Database([string]$Mode) {
    if (-not (Test-Path -LiteralPath $database)) { return }
    $code = @'
import sqlite3, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

path, mode = sys.argv[1:]
key = "winget-upgrade-fixture"
uri = Path(path).resolve().as_uri() + ("?mode=rw" if mode == "seed" else "?mode=ro")
with sqlite3.connect(uri, uri=True) as db:
    if mode == "adapter":
        if db.execute("SELECT 1 FROM sqlite_master WHERE name='adapter_state'").fetchone():
            row = db.execute("SELECT interface_id FROM adapter_state ORDER BY interface_id LIMIT 1").fetchone()
            if row:
                print(row[0])
    else:
        assert db.execute("PRAGMA quick_check").fetchone() == ("ok",)
        if mode == "seed":
            stamp = (datetime.now(timezone.utc) - timedelta(days=2)).strftime("%Y-%m-%dT12:00:00.0000000+00:00")
            db.execute("INSERT INTO adapter_state (interface_id,name,description,type,last_received,last_sent,last_seen_utc) VALUES (?,?,?,?,?,?,?)",
                       (key, key, "Fixture", "Ethernet", 8192, 2048, stamp))
            db.execute("INSERT INTO traffic_minute (interface_id,minute_utc,bytes_received,bytes_sent) VALUES (?,?,?,?)",
                       (key, stamp, 8192, 2048))
        assert db.execute("SELECT bytes_received,bytes_sent FROM traffic_minute WHERE interface_id=?", (key,)).fetchall() == [(8192, 2048)]
        if mode == "samples":
            rows = db.execute("SELECT DISTINCT captured_utc FROM collection_sample ORDER BY captured_utc").fetchall()
            assert len(rows) >= 2, rows
            print("\n".join(row[0] for row in rows))
        else:
            print(db.execute("PRAGMA user_version").fetchone()[0])
'@
    $value = $code | python - $database $Mode
    if ($LASTEXITCODE -ne 0) { throw "SQLite test failed ($Mode)." }
    return $value
}
try {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    $installedClientVersion = if ($command) { (& $command.Source --version 2>$null) -join '' } else { '' }
    $match = [regex]::Match($installedClientVersion, '^v(\d+\.\d+)')
    if (-not $match.Success -or [version]$match.Groups[1].Value -lt [version]'1.28') {
        $toolDir = Join-Path $env:RUNNER_TEMP 'official-winget'
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
        $toolRelease = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380'
        $bundle = Join-Path $toolDir 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        $dependencyArchive = Join-Path $toolDir 'DesktopAppInstaller_Dependencies.zip'
        Invoke-WebRequest "$toolRelease/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $bundle
        Invoke-WebRequest "$toolRelease/DesktopAppInstaller_Dependencies.zip" -OutFile $dependencyArchive
        Expand-Archive -LiteralPath $dependencyArchive -DestinationPath "$toolDir/dependencies"
        $env:OCTETLEDGER_TEST_APP_INSTALLER_PATH = $toolDir
        # Call Appx in Windows PowerShell so DependencyPath stays an array.
        $bootstrap = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$toolDir = $env:OCTETLEDGER_TEST_APP_INSTALLER_PATH
$dependencies = @(Get-ChildItem "$toolDir/dependencies/$env:WINGET_TEST_ARCH" -File | Where-Object {
    $_.Extension -in '.appx','.msix'
} | ForEach-Object FullName)
if (-not $dependencies.Count) { throw 'No matching App Installer framework packages.' }
Add-AppxPackage -Path "$toolDir/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -DependencyPath $dependencies -ForceApplicationShutdown
$clientPackage = Get-AppxPackage -Name Microsoft.DesktopAppInstaller | Sort-Object Version -Descending | Select-Object -First 1
$clientPackage.InstallLocation | Set-Content "$toolDir/client-location.txt"
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) { throw 'Official App Installer setup failed.' }
        $script:client = Join-Path (Get-Content "$toolDir/client-location.txt").Trim() 'winget.exe'
    }
    else {
        $script:client = $command.Source
    }
    $evidence.clientVersion = (& $script:client --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $evidence.clientVersion -notmatch '^v\d') { throw 'Native WinGet client unavailable.' }

    $probe = Join-Path $env:RUNNER_TEMP 'octetledger-winget-probe.vbs'
    'WScript.Echo "VBScript OK"' | Set-Content -LiteralPath $probe -Encoding ascii
    if ((& cscript.exe //nologo $probe) -ne 'VBScript OK' -or $LASTEXITCODE -ne 0) { throw 'VBScript is not available on this runner.' }

    $options = @('--scope', 'user', '--architecture', $env:WINGET_TEST_ARCH,
                 '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mpStatus) {
        $evidence.defender = $mpStatus | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled
    }

    $evidence.communitySource = (& $script:client source export --name winget) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $evidence.communitySource -notmatch '"Trusted"') {
        throw 'Could not verify the trust level of the public WinGet source.'
    }
    Invoke-WinGet (@('install', '--id', $id, '--exact', '--version', '0.3.0', '--source', 'winget') + $options)
    $evidence.communityRegistration = Assert-Version '0.3.0'
    $evidence.communityZoneId = Get-ZoneId (Get-AliasInfo).Target
    Invoke-WinGet @('uninstall', '--id', $id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    Record 'measured the portable payload zone from the official Microsoft catalogue'

    # Use a disposable loopback TLS certificate for the isolated REST source.
    # WinGet applies its normal catalogue trust rules and verifies both ZIP hashes.
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=OctetLedger WinGet loopback validation', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddIpAddress([Net.IPAddress]::Loopback)
        $request.CertificateExtensions.Add($san.Build())
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $eku = [Security.Cryptography.OidCollection]::new()
        [void]$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $false))
        $now = [DateTimeOffset]::UtcNow
        $leaf = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddHours(1))
        try {
            [IO.File]::WriteAllText("$fixture/certificate.pem", $leaf.ExportCertificatePem())
            [IO.File]::WriteAllText("$fixture/key.pem", $rsa.ExportPkcs8PrivateKeyPem())
            $certificate = [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadCertificate($leaf.RawData)
        } finally { $leaf.Dispose() }
    } finally { $rsa.Dispose() }
    $certificateStore = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
    $certificateStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $certificateStore.Add($certificate)
    $sourceProcess = Start-Process python -WindowStyle Hidden -PassThru -RedirectStandardError "$fixture/server.log" -ArgumentList @(
        '-u', "`"$PSScriptRoot/serve-winget-candidate.py`"", $env:WINGET_TEST_ARCH, "`"$candidatePath`"",
        "`"$fixture/certificate.pem`"", "`"$fixture/key.pem`"", "`"$fixture/address.txt`""
    )
    $endpoint = Wait-For { Get-Content -LiteralPath "$fixture/address.txt" -Raw -ErrorAction SilentlyContinue } 'the TLS catalogue' 10
    Invoke-WebRequest "$endpoint/information" | Out-Null
    Invoke-WinGet @('source', 'add', '--name', $stageSource, '--arg', $endpoint, '--type', 'Microsoft.Rest',
                    '--explicit', '--trust-level', 'trusted', '--accept-source-agreements', '--disable-interactivity')
    $evidence.stagingSource = (& $script:client source export --name $stageSource) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $evidence.stagingSource -notmatch '"Trusted"') { throw 'Wrong staging source trust level.' }

    Invoke-WinGet (@('install', '--id', $id, '--exact', '--version', '0.3.0', '--source', $stageSource) + $options)
    $evidence.registrationBefore = Assert-Version '0.3.0'
    $evidence.stagedLegacyZoneId = Get-ZoneId (Get-AliasInfo).Target
    if ($evidence.stagedLegacyZoneId -ne $evidence.communityZoneId) { throw 'The staged legacy package zone differs from the official catalogue.' }
    # Seed the legacy database with the official executable, independently of
    # the retired 0.3.0 startup launcher.
    & $link collect
    if ($LASTEXITCODE -ne 0) { throw 'The legacy CLI could not collect a baseline.' }
    $adapter = Read-Database 'adapter'
    if (-not $adapter) { throw 'The legacy CLI did not record an adapter baseline.' }
    & $link interface set $adapter
    if ($LASTEXITCODE -ne 0) { throw 'The legacy collector could not save its interface preference.' }
    $savedSettings = (Get-FileHash $settings).Hash
    & $link collector stop
    if ($LASTEXITCODE -ne 0) { throw 'The legacy collector could not stop before the upgrade.' }
    $evidence.sourceSchema = [int](Read-Database 'seed')
    if ($evidence.sourceSchema -ne 0) { throw 'Unexpected legacy database schema.' }
    Record 'installed 0.3.0 from the published WinGet manifest and seeded a preference and historical fixture'

    Invoke-WinGet (@('upgrade', '--id', $id, '--exact', '--version', '0.11.1', '--source', $stageSource) + $options)
    $evidence.registrationAfter = Assert-Version '0.11.1'
    if ($evidence.registrationAfter -ne $evidence.registrationBefore) { throw 'The upgrade changed the portable package identity.' }
    Assert-CandidateExecutable
    if ((Get-FileHash $settings).Hash -ne $savedSettings) { throw 'WinGet changed the existing settings.' }
    [void](Read-Database 'verify')
    Record 'WinGet upgraded the single user-scope package in place and preserved SQLite and settings'

    $aliasInfo = Get-AliasInfo
    $evidence.aliasLinkType = $aliasInfo.LinkType
    $evidence.aliasTarget = $aliasInfo.Target
    $evidence.zoneIdBeforeInstall = Get-ZoneId $aliasInfo.Target
    $installOutput = & $link collector install 2>&1
    $installExit = $LASTEXITCODE
    $evidence.firstInstallExit = $installExit
    if ($installExit -ne 0) {
        $evidence.firstInstallError = ($installOutput -join "`n")
        $evidence.pidAfterFailure = Test-Path -LiteralPath $pidFile
        $evidence.readyAfterFailure = Test-Path -LiteralPath $ready
        $evidence.logAfterFailure = if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Raw } else { $null }
        $evidence.launchersAfterFailure = @(Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" |
            Where-Object { $_.CommandLine -like "*$data*" } | Select-Object ProcessId, CommandLine)
        throw "Collector install failed with WinGet zone '$($evidence.zoneIdBeforeInstall)'. $($installOutput -join ' ')"
    }
    $evidence.zoneIdAfterInstall = Get-ZoneId $aliasInfo.Target
    if ($evidence.zoneIdAfterInstall -ne $evidence.zoneIdBeforeInstall) { throw 'Collector registration changed the Windows zone mark.' }
    $firstReady = Wait-For { Get-Content -LiteralPath $ready -Raw -ErrorAction SilentlyContinue } 'the updated collector first successful collection'
    $null = Wait-For {
        $current = Get-Content -LiteralPath $ready -Raw -ErrorAction SilentlyContinue
        if ($current -and [DateTimeOffset]$current -gt [DateTimeOffset]$firstReady) { $current }
    } 'the updated collector second successful collection'
    $evidence.samplesUtc = @(Read-Database 'samples')
    $evidence.migratedSchema = [int](Read-Database 'verify')
    $startup = Get-ItemProperty -LiteralPath $registry
    $hasScopedStartup = $startup.PSObject.Properties.Name -like 'OctetLedger Collector *'
    $hasLegacyStartup = $startup.PSObject.Properties['OctetLedger Collector']
    if ($evidence.migratedSchema -ne 6 -or (Get-FileHash $settings).Hash -ne $savedSettings -or
        -not $hasScopedStartup -or $hasLegacyStartup -or
        -not (Get-ScheduledTask -TaskName 'OctetLedger Watchdog*' -ErrorAction SilentlyContinue)) {
        throw 'SQLite migration, settings or collector registrations did not match the upgrade contract.'
    }
    Record 're-registered collector, two successful samples, historical bytes and settings preserved'
    $worker = [int]((Get-Content -LiteralPath $pidFile -Raw).Split('|')[0])
    if (-not (Get-Process -Id $worker -ErrorAction SilentlyContinue)) { throw 'Collector PID does not identify a live worker.' }
    & $link collector stop
    if ($LASTEXITCODE -ne 0 -or (Get-Process -Id $worker -ErrorAction SilentlyContinue)) { throw 'Collector stop did not wait for the worker to exit.' }
    Record 'collector stop waited for the live worker to exit'
    & $link collector uninstall
    if ($LASTEXITCODE -ne 0) { throw 'Could not unregister the test collector.' }
    if ((Get-ItemProperty -LiteralPath $registry).PSObject.Properties.Name -like 'OctetLedger Collector*' -or
        (Get-ScheduledTask -TaskName 'OctetLedger Watchdog*' -ErrorAction SilentlyContinue)) { throw 'Collector registrations survived uninstall.' }
    Invoke-WinGet @('uninstall', '--id', $id, '--exact', '--source', $stageSource, '--accept-source-agreements', '--disable-interactivity')
    if ((Test-Path -LiteralPath $link) -or (Test-Path -LiteralPath $aliasInfo.Target)) { throw 'WinGet left the executable or its alias behind.' }
    if ((Get-FileHash $settings).Hash -ne $savedSettings -or [int](Read-Database 'verify') -ne 6) {
        throw 'Uninstall changed history or settings.'
    }
    Record 'uninstalled portable package while preserving its SQLite database and settings'
    $evidence.status = 'pass'
}
catch {
    $evidence.error = $_.Exception.Message
    if (Test-Path "$data/collector.log") {
        Get-Content -LiteralPath "$data/collector.log" -Tail 12 | ForEach-Object { Write-Host $_ }
    }
    throw
}
finally {
    if ($sourceProcess) {
        if (-not $sourceProcess.HasExited) { Stop-Process -InputObject $sourceProcess -ErrorAction SilentlyContinue }
        $sourceProcess.Dispose()
    }
    if ($certificateStore) {
        if ($certificate) { $certificateStore.Remove($certificate) }
        $certificateStore.Dispose()
    }
    if ($certificate) { $certificate.Dispose() }
    New-Item -ItemType Directory -Path evidence -Force | Out-Null
    if (Test-Path -LiteralPath "$fixture/server.log") { Copy-Item -LiteralPath "$fixture/server.log" -Destination evidence/ }
    $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "evidence/winget-$env:WINGET_TEST_ARCH.json"
}
