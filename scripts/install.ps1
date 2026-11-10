# Installs Vault on Windows from the latest release: the `myvault` command and
# the desktop app, then starts the setup. Nothing needs building and nothing
# needs admin rights. In PowerShell:
#
#   irm https://raw.githubusercontent.com/Atharv-tw/vault-app/main/scripts/install.ps1 | iex
#
# The command alone:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Atharv-tw/vault-app/main/scripts/install.ps1))) -CommandOnly
#
# Run it again to update. Your data (in %LOCALAPPDATA%\myvault) is never touched.
param([switch]$CommandOnly, [switch]$NoSetup)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'Atharv-tw/vault-app'
# Where the release files come from; set MYVAULT_RELEASE to try a build of your own.
$base = if ($env:MYVAULT_RELEASE) { $env:MYVAULT_RELEASE } else { "https://github.com/$repo/releases/latest/download" }
$lib = Join-Path $env:LOCALAPPDATA 'Programs\Vault'

if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
  Write-Error "The ready-made programs are for 64-bit Windows on Intel or AMD. On anything else, build from source: https://github.com/$repo#build-from-source"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("vault-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

# Unpacks one release file to a folder, replacing what was there only once
# the new copy has arrived whole.
function Fetch($file, $name) {
  Write-Host "Downloading $file"
  $zip = Join-Path $tmp $file
  try { Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $zip }
  catch { Write-Error "Could not download $file from $base" }
  $out = Join-Path $tmp $name
  Expand-Archive -Path $zip -DestinationPath $out
  New-Item -ItemType Directory -Force -Path $lib | Out-Null
  $dest = Join-Path $lib $name
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Move-Item (Join-Path $out 'bundle') $dest
}

try {
  Fetch 'myvault-cli-windows-x64.zip' 'myvault'
  $bin = Join-Path $lib 'myvault\bin'
  Write-Host "Installed the myvault command: $bin\myvault.exe"

  # On the PATH for new terminals, and for this one.
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = if ($userPath) { $userPath -split ';' } else { @() }
  if ($parts -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $bin) | Where-Object { $_ }) -join ';', 'User')
    Write-Host "Added $bin to your PATH; open a new terminal to use myvault there."
  }
  if (($env:Path -split ';') -notcontains $bin) { $env:Path = "$env:Path;$bin" }

  if (-not $CommandOnly) {
    Fetch 'vault-app-windows-x64.zip' 'vault-app'
    $exe = Join-Path $lib 'vault-app\vault.exe'
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Vault.lnk'
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($menu)
    $link.TargetPath = $exe
    $link.WorkingDirectory = Split-Path $exe
    $link.Description = 'Your second brain: goals, days, diary and memory'
    $link.Save()
    Write-Host "Installed the desktop app: Vault, in the Start menu"
  }
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if (-not $NoSetup -and [Environment]::UserInteractive) {
  Write-Host ''
  & (Join-Path $bin 'myvault.exe') init
} else {
  Write-Host ''
  Write-Host 'Next: myvault init'
}
