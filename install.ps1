# godot-cli installer for Windows PowerShell.
#
#   irm https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.ps1 | iex
#
# For Git Bash, MSYS2 or Cygwin use install.sh instead: it handles Windows too
# and is the better-tested path. This script exists for people who do not have
# a POSIX shell.
#
# Deliberately plain. It is written by someone who cannot run PowerShell, so
# every step is one obvious thing that fails loudly rather than anything
# clever that fails obscurely.

[CmdletBinding()]
param(
    # Release to install; the latest release when omitted.
    [string] $Version = '',
    # Install root.
    [string] $Prefix = (Join-Path $env:USERPROFILE '.godot-cli'),
    # Also copy the agent skill into the editor/agent directories.
    [switch] $InstallSkill,
    # Add the bin directory to the user PATH permanently.
    [switch] $AddToPath
)

$ErrorActionPreference = 'Stop'
$Repo = 'unabated-games/godot-cli'
$DownloadBase = "https://github.com/$Repo/releases/download"

function Fail($message) {
    Write-Error $message
    exit 1
}

function Get-LatestVersion {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    $tag = $release.tag_name
    if (-not $tag) { Fail 'Could not determine the latest release.' }
    return $tag.TrimStart('v')
}

function Get-Target {
    # PROCESSOR_ARCHITECTURE is AMD64 or ARM64 on the architectures we publish.
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x86_64-windows' }
        'ARM64' { return 'aarch64-windows' }
        default { Fail "No published binary for $($env:PROCESSOR_ARCHITECTURE). Build from source: https://github.com/$Repo#building" }
    }
}

if (-not $Version) { $Version = Get-LatestVersion }
$target = Get-Target
$archive = "godot-cli-$Version-$target.zip"
$url = "$DownloadBase/v$Version/$archive"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("godot-cli-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Write-Host "Downloading $archive"
    $archivePath = Join-Path $work $archive
    Invoke-WebRequest -Uri $url -OutFile $archivePath

    # The checksum is not optional. A mismatch means what arrived is not what
    # was built, and installing it anyway is the one thing this must not do.
    $sumsPath = Join-Path $work 'SHA256SUMS'
    Invoke-WebRequest -Uri "$DownloadBase/v$Version/SHA256SUMS" -OutFile $sumsPath

    $expected = $null
    foreach ($line in Get-Content $sumsPath) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $archive) {
            $expected = $parts[0]
            break
        }
    }
    if (-not $expected) { Fail "SHA256SUMS has no entry for $archive." }

    $actual = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        Fail "Checksum mismatch for ${archive}: expected $expected, got $actual."
    }
    Write-Host 'Checksum verified'

    Expand-Archive -LiteralPath $archivePath -DestinationPath $work -Force
    $extracted = Join-Path $work "godot-cli-$Version-$target"
    if (-not (Test-Path $extracted)) { Fail "Unexpected archive layout in $archive." }

    Write-Host "Installing to $Prefix"
    New-Item -ItemType Directory -Path $Prefix -Force | Out-Null

    # The same layout install.sh produces, checked against a real archive:
    # the release has no `examples/` of its own, it lives under `share/`, and
    # only a subset of `docs/` is installed.
    foreach ($dir in @('bin', 'templates', 'skills', 'third_party')) {
        $from = Join-Path $extracted $dir
        if (Test-Path $from) { Copy-Item -Path $from -Destination $Prefix -Recurse -Force }
    }

    $docsDir = Join-Path $Prefix 'docs'
    New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
    foreach ($doc in @('agent_quickstart.md', 'agent_godot_basics.md', 'agent_scene_authoring.md',
                       'agent_batch_commands.md', 'commands.md', 'mcp_tools.json')) {
        $from = Join-Path $extracted "docs\$doc"
        if (Test-Path $from) { Copy-Item -Path $from -Destination $docsDir -Force }
    }

    foreach ($pair in @(@('share\examples', 'examples'), @('share\completions', 'share\completions'),
                        @('share\man\man1', 'share\man\man1'))) {
        $from = Join-Path $extracted $pair[0]
        $to = Join-Path $Prefix $pair[1]
        if (Test-Path $from) {
            New-Item -ItemType Directory -Path $to -Force | Out-Null
            Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
        }
    }

    # The MIT and Apache-2.0 notices have to travel with the binary.
    foreach ($file in @('LICENSE', 'THIRDPARTY.md')) {
        $from = Join-Path $extracted $file
        if (Test-Path $from) { Copy-Item -Path $from -Destination $Prefix -Force }
    }

    # The same variables install.sh writes into env.sh, for a shell that has
    # no way to source one.
    $envPs1 = Join-Path $Prefix 'env.ps1'
    @"
# godot-cli environment - dot-source this file: . "$Prefix\env.ps1"
`$env:GODOT_CLI_HOME = '$Prefix'
`$env:GODOT_CLI = '$Prefix\bin\godot-cli.exe'
`$env:GODOT_CLI_TEMPLATES_ROOT = '$Prefix\templates'
`$env:PATH = '$Prefix\bin;' + `$env:PATH
"@ | Set-Content -Path $envPs1 -Encoding UTF8

    if ($InstallSkill) {
        $skillSrc = Join-Path $extracted 'skills\godot-scene-authoring'
        if (Test-Path $skillSrc) {
            $targets = @(
                (Join-Path $env:USERPROFILE '.cursor\skills\godot-scene-authoring'),
                (Join-Path $env:USERPROFILE '.claude\skills\godot-scene-authoring'),
                (Join-Path $env:USERPROFILE '.config\opencode\skills\godot-scene-authoring'),
                (Join-Path $env:USERPROFILE '.agents\skills\godot-scene-authoring')
            )
            foreach ($dest in $targets) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Copy-Item -Path (Join-Path $skillSrc '*') -Destination $dest -Recurse -Force
                Write-Host "  skill: $dest"
            }
        }
    }

    if ($AddToPath) {
        $binDir = Join-Path $Prefix 'bin'
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$binDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
            Write-Host "Added $binDir to your user PATH (new shells will see it)."
        }
    }

    $exe = Join-Path $Prefix 'bin\godot-cli.exe'
    $reportedVersion = if (Test-Path $exe) { (& $exe --version 2>$null) } else { 'unknown' }
    @"
installed_from=release v$Version
installed_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
binary_version=$reportedVersion
"@ | Set-Content -Path (Join-Path $Prefix 'VERSION') -Encoding UTF8

    if (-not (Test-Path $exe)) { Fail "Binary not found after install: $exe" }
    Write-Host ''
    Write-Host "Installed $reportedVersion to $Prefix"

    Write-Host ''
    Write-Host 'Activate in this shell:'
    Write-Host "  . `"$Prefix\env.ps1`""
    Write-Host ''
    Write-Host 'Smoke test:'
    Write-Host "  & `"$exe`" ping --json"
}
finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}
