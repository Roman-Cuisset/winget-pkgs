$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:RUNNER_ARCH.ToLowerInvariant() -ne $env:WINGET_TEST_ARCH -or
    [Environment]::GetFolderPath('LocalApplicationData') -ne $env:LOCALAPPDATA) {
    throw 'This test must use an isolated native GitHub-hosted Windows profile.'
}

$id = 'RomanCuisset.OctetLedger'
$manifest = Join-Path $PWD 'manifests/r/RomanCuisset/OctetLedger/0.11.0'
$legacyManifest = Join-Path $PWD 'manifests/r/RomanCuisset/OctetLedger/0.3.0'
$data = Join-Path $env:LOCALAPPDATA 'OctetLedger'
$link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\octetledger.exe'
$database = Join-Path $data 'octetledger.db'
$settings = Join-Path $data 'settings.json'
$ready = Join-Path $data 'collector.ready'
$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ((Test-Path $link) -or (Test-Path $data)) { throw 'An OctetLedger installation already exists in this profile.' }

$evidence = [ordered]@{
    status = 'fail'
    architecture = $env:WINGET_TEST_ARCH
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
function Assert-OfficialExecutable {
    $expected = switch ($env:WINGET_TEST_ARCH) {
        'x64' { 'a1ebd68b3fc188499184b4ff483bfd838e7ebd704dcbaea29851ac6964294d2b' }
        'arm64' { '9b250fa68bba5018b48d36490bf1c50d298472415a1c48ac4cc3d60ea9a4aa31' }
    }
    $evidence.executableSha256 = (Get-FileHash $link).Hash.ToLowerInvariant()
    if ($evidence.executableSha256 -ne $expected) { throw 'Installed executable is not the one published for this architecture.' }
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

    Invoke-WinGet @('validate', '--manifest', $manifest)
    Invoke-WinGet @('settings', '--enable', 'LocalManifestFiles')
    $options = @('--scope', 'user', '--architecture', $env:WINGET_TEST_ARCH,
                 '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    Invoke-WinGet (@('install', '--manifest', $manifest) + $options)
    $null = Assert-Version '0.11.0'
    Assert-OfficialExecutable
    Invoke-WinGet @('uninstall', '--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    Record 'validated manifest, fresh portable install, command alias and uninstall'

    # Both versions need the same source identity. The official 0.3.0 manifest is
    # mirrored here to stage an upgrade before 0.11.0 enters the public catalogue.
    Invoke-WinGet @('validate', '--manifest', $legacyManifest)
    Invoke-WinGet (@('install', '--manifest', $legacyManifest) + $options)
    $evidence.registrationBefore = Assert-Version '0.3.0'
    & $link collector install
    if ($LASTEXITCODE -ne 0) { throw 'The legacy collector could not start.' }
    $adapter = Wait-For { Read-Database 'adapter' } 'the legacy collector first SQLite observation'
    & $link interface set $adapter
    if ($LASTEXITCODE -ne 0) { throw 'The legacy collector could not save its interface preference.' }
    $savedSettings = (Get-FileHash $settings).Hash
    & $link collector stop
    if ($LASTEXITCODE -ne 0) { throw 'The legacy collector could not stop before the upgrade.' }
    $evidence.sourceSchema = [int](Read-Database 'seed')
    if ($evidence.sourceSchema -ne 0) { throw 'Unexpected legacy database schema.' }
    Record 'installed 0.3.0 from the published WinGet manifest and seeded a preference and historical fixture'

    Invoke-WinGet (@('upgrade', '--manifest', $manifest) + $options)
    $evidence.registrationAfter = Assert-Version '0.11.0'
    if ($evidence.registrationAfter -ne $evidence.registrationBefore) { throw 'The upgrade changed the portable package identity.' }
    Assert-OfficialExecutable
    if ((Get-FileHash $settings).Hash -ne $savedSettings) { throw 'WinGet changed the existing settings.' }
    [void](Read-Database 'verify')
    Record 'WinGet upgraded the single user-scope package in place and preserved SQLite and settings'

    & $link collector install
    if ($LASTEXITCODE -ne 0) { throw 'Could not re-register the collector after the upgrade.' }
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
    & $link collector uninstall
    if ($LASTEXITCODE -ne 0) { throw 'Could not unregister the test collector.' }
    Invoke-WinGet @('uninstall', '--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Get-FileHash $settings).Hash -ne $savedSettings -or [int](Read-Database 'verify') -ne 6) {
        throw 'Uninstall changed history or settings.'
    }
    Record 'uninstalled portable package while preserving its SQLite database and settings'
    $evidence.status = 'pass'
}
catch {
    $evidence.error = $_.Exception.Message
    throw
}
finally {
    New-Item -ItemType Directory -Path evidence -Force | Out-Null
    $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "evidence/winget-$env:WINGET_TEST_ARCH.json"
}
