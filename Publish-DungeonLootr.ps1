# Publish Dungeon Lootr to NickB926/dungeon-lootr (same idea as PlayerTools)
# Usage:
#   npm run publish:updates
#   npm run publish:updates -- -Message "parry fix"
#   npm run publish:updates -- -SkipVersionBump
#   .\Publish-DungeonLootr.ps1 -Version 1.2.0 -Message "big drop"
param(
  [string]$Version = '',
  [string]$Message = '',
  [switch]$SkipVersionBump,
  [switch]$Public
)

$ErrorActionPreference = 'Stop'
$repoRoot = 'C:\Users\Revi\Documents\dungeon-lootr'
$payloadDir = Join-Path $repoRoot 'dungeon-lootr'
$ataSrcCandidates = @(
  'C:\Users\Revi\Documents\playertools\PlayerTools\AtaraxiaLibrary.lua',
  'C:\Users\Revi\AppData\Local\Potassium\scripts\PlayerTools\AtaraxiaLibrary.lua'
)
$potassiumPayload = 'C:\Users\Revi\AppData\Local\Potassium\scripts\dungeon-lootr'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Bump-PatchVersion([string]$v) {
  if ($v -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
    throw "version.json version must look like 1.0.0 (got '$v')"
  }
  $major = [int]$Matches[1]
  $minor = [int]$Matches[2]
  $patch = [int]$Matches[3] + 1
  return "$major.$minor.$patch"
}

if (-not (Test-Path $repoRoot)) { throw "Missing repo $repoRoot" }
New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null

$verPath = Join-Path $repoRoot 'version.json'
$oldRaw = Get-Content $verPath -Raw
$ver = $oldRaw | ConvertFrom-Json
$oldVersion = [string]$ver.version

if ($Version) {
  $ver.version = $Version
} elseif (-not $SkipVersionBump) {
  $ver.version = Bump-PatchVersion $oldVersion
  Write-Host "==> Bumping $oldVersion -> $($ver.version)"
} else {
  Write-Host "==> Keeping version $($ver.version) (-SkipVersionBump)"
}

if ($Message) {
  $ver.message = $Message
} elseif (-not $ver.message -or $ver.message -eq '') {
  $ver.message = "Dungeon Lootr $($ver.version)"
}

Write-Host "==> Publishing Dungeon Lootr $($ver.version): $($ver.message)"

# Canonical working copies live at repo root (flat). Stage into dungeon-lootr/ for friends.
$flatMap = @{
  'DungeonLootr.lua' = 'DungeonLootr.lua'
  'LootHUD.lua'      = 'LootHUD.lua'
  'launch.lua'       = 'launch.lua'
}
foreach ($pair in $flatMap.GetEnumerator()) {
  $from = Join-Path $repoRoot $pair.Key
  if (-not (Test-Path $from)) { throw "Missing source $from" }
  Copy-Item -Force $from (Join-Path $payloadDir $pair.Value)
  Write-Host "==> Staged $($pair.Key)"
}

$updaterSrc = Join-Path $payloadDir 'Updater.lua'
if (-not (Test-Path $updaterSrc)) {
  throw "Missing $updaterSrc - create dungeon-lootr/Updater.lua first"
}

$ataSrc = $ataSrcCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ataSrc) { throw 'AtaraxiaLibrary.lua not found (PlayerTools)' }
Copy-Item -Force $ataSrc (Join-Path $payloadDir 'AtaraxiaLibrary.lua')
Write-Host "==> Bundled AtaraxiaLibrary from $ataSrc"

$verJson = ($ver | ConvertTo-Json -Depth 5) + [Environment]::NewLine
Write-Utf8NoBom $verPath $verJson
Write-Utf8NoBom (Join-Path $payloadDir 'version.json') $verJson

# Keep Potassium executor copy in sync so local loadstring paths match.
New-Item -ItemType Directory -Force -Path $potassiumPayload | Out-Null
Copy-Item -Force (Join-Path $payloadDir '*') $potassiumPayload
Write-Host "==> Synced Potassium scripts/dungeon-lootr"

$pkgPath = Join-Path $repoRoot 'package.json'
if (Test-Path $pkgPath) {
  $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
  $pkg.version = $ver.version
  Write-Utf8NoBom $pkgPath (($pkg | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
}

Set-Location $repoRoot

$gitIdentity = @(
  '-c', 'user.email=nickb926@users.noreply.github.com',
  '-c', 'user.name=NickB926'
)

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  & git @gitIdentity @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)"
  }
}

try {
  if (-not (Test-Path (Join-Path $repoRoot '.git'))) {
    git init
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    git branch -M main
    if (-not (Test-Path (Join-Path $repoRoot '.gitignore'))) {
      Write-Utf8NoBom (Join-Path $repoRoot '.gitignore') ".desktop-launch.log`n.desktop-launch.lock`n*.log`n.tmp*`n"
    }
    git add -A
    Invoke-Git commit -m "Dungeon Lootr $($ver.version): $($ver.message)"
    gh repo create NickB926/dungeon-lootr --public --source=. --remote=origin --push
    if ($LASTEXITCODE -ne 0) { throw 'gh repo create failed' }
  } else {
    git add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
    $status = git status --porcelain
    if (-not $status) {
      Write-Host 'No file changes after sync - nothing to push.'
      exit 0
    }
    Invoke-Git commit -m "Dungeon Lootr $($ver.version): $($ver.message)"
    git push -u origin HEAD
    if ($LASTEXITCODE -ne 0) { throw "git push failed (exit $LASTEXITCODE)" }
  }

  if ($Public) {
    gh repo edit NickB926/dungeon-lootr --visibility public --accept-visibility-change-consequences
    if ($LASTEXITCODE -ne 0) { throw 'gh repo edit failed' }
  }
} catch {
  Write-Host "==> Publish failed - restoring version.json to $oldVersion"
  Write-Utf8NoBom $verPath $oldRaw
  throw
}

Write-Host ''
Write-Host "==> Published $($ver.version)  (was $oldVersion) - pushed to GitHub"
Write-Host 'Friend / reinstall:'
Write-Host 'loadstring(game:HttpGet("https://raw.githubusercontent.com/NickB926/dungeon-lootr/main/bootstrap.lua"))()'
