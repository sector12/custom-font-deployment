#Requires -Version 5.1
<#
    Detect-CustomFonts.ps1
    Intune Remediations - DETECTION script.

    Assignment: Run as logged-on credentials = No (SYSTEM),
    Run in 64-bit PowerShell = Yes, file encoding = UTF-8.

    Exit 1 = a font needs (re)installing  -> remediation runs.
    Exit 0 = everything up to date.

    HOW IT WORKS (so a version swap is built in, not a one-off):
      Each font has a Version tag and a list of Urls. This script computes a
      fingerprint = "<Version>#<hash of the Urls>" and compares it, plus the
      exact installed file list, against what was recorded at the last
      successful install. If the fingerprint differs (you bumped Version, or
      changed a source URL) OR a recorded file is missing, the font is
      (re)staged and the remediation script force-replaces it.

    ======================================================================
    HOW TO ADD OR CHANGE A FONT  (edit ONLY the CONFIG block):
      FamilyName : friendly name (also the registry key + log label).
      Version    : any string. CHANGE IT to force every device to reinstall
                   when the build changed but the URL did not (e.g. DaFont
                   refreshed their zip in place).
      Urls       : list (always @( ... )). Each link may return a .zip OR a
                   single .ttf/.otf. Changing a URL also forces a reinstall,
                   because the fingerprint includes a hash of the Urls.
                   Test every URL in a browser first.
    ======================================================================
#>

# ===================== CONFIG: EDIT THIS LIST ONLY =====================
$FontRegistry = @(

    # Lato - Google-fonts-helper zip (all weights in one URL).
    @{ FamilyName = 'Lato'
       Version    = '1'
       Urls       = @(
           'https://gwfh.mranftl.com/api/fonts/lato?download=zip&formats=ttf'
       ) }

    # Josefin Sans - official google/fonts repo (variable fonts: upright + italic).
    @{ FamilyName = 'Josefin Sans'
       Version    = '1'
       Urls       = @(
           'https://raw.githubusercontent.com/google/fonts/main/ofl/josefinsans/JosefinSans%5Bwght%5D.ttf'
           'https://raw.githubusercontent.com/google/fonts/main/ofl/josefinsans/JosefinSans-Italic%5Bwght%5D.ttf'
       ) }

    # OpenDyslexic (canonical, as-is) - DaFont zip = the classic v2.001 build,
    # unmodified, so it keeps the "OpenDyslexic" name. The zip also carries the
    # OpenDyslexicAlta and OpenDyslexicMono families.
    @{ FamilyName = 'OpenDyslexic'
       Version    = '1'
       Urls       = @(
           'https://dl.dafont.com/dl/?f=open_dyslexic'
       ) }

    # OpenDys B - the newer redesign (GitHub 0.99), renamed for OFL compliance
    # ("OpenDyslexic" is a Reserved Font Name, so a modified build must not use it).
    # Hosted in this repo (sector12/OpenDys-B) alongside OFL.txt. The four files
    # must exist on the branch named in the URLs below (main) before the first
    # device run - see README.md.
    @{ FamilyName = 'OpenDys B'
       Version    = '1'
       Urls       = @(
           'https://raw.githubusercontent.com/sector12/OpenDys-B/main/OpenDysB-Regular.otf'
           'https://raw.githubusercontent.com/sector12/OpenDys-B/main/OpenDysB-Bold.otf'
           'https://raw.githubusercontent.com/sector12/OpenDys-B/main/OpenDysB-Italic.otf'
           'https://raw.githubusercontent.com/sector12/OpenDys-B/main/OpenDysB-BoldItalic.otf'
       ) }
)
# =======================================================================

$StageRoot = 'HKLM:\SOFTWARE\CustomFontInstaller\Pending'
$StateRoot = 'HKLM:\SOFTWARE\CustomFontInstaller\Installed'
$FontsDir  = Join-Path $env:windir 'Fonts'
$LogPath   = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\CustomFontDeployment.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] [DETECT] {1}' -f (Get-Date -Format 'u'), $Message
    Write-Output $line
    try {
        $dir = Split-Path $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
    } catch { }
}

# Short, stable fingerprint of a URL list (order-independent).
function Get-UrlHash {
    param([string[]]$Urls)
    $joined = (($Urls | Sort-Object) -join '|')
    $md5    = [System.Security.Cryptography.MD5]::Create()
    $bytes  = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
    (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
}

# Rebuild the (transient) Pending tree each run; ensure the (persistent) state root exists.
try {
    if (Test-Path $StageRoot) { Remove-Item $StageRoot -Recurse -Force }
    New-Item -Path $StageRoot -Force | Out-Null
    if (-not (Test-Path $StateRoot)) { New-Item -Path $StateRoot -Force | Out-Null }
} catch {
    Write-Log "WARN: registry prep failed: $($_.Exception.Message)"
}

$needing = 0

foreach ($font in $FontRegistry) {
    $desiredFp = '{0}#{1}' -f $font.Version, (Get-UrlHash $font.Urls)
    $stateKey  = "$StateRoot\$($font.FamilyName)"
    $ok = $false

    if (Test-Path $stateKey) {
        $sp     = Get-ItemProperty -Path $stateKey -ErrorAction SilentlyContinue
        $instFp = $sp.Fingerprint
        $files  = @($sp.Files)
        if ($instFp -eq $desiredFp -and $files.Count -gt 0) {
            $ok = $true
            foreach ($fn in $files) {
                if (-not (Test-Path (Join-Path $FontsDir $fn))) { $ok = $false; break }
            }
        }
    }

    if ($ok) {
        Write-Log ("OK: '{0}' up to date ({1})." -f $font.FamilyName, $desiredFp)
    }
    else {
        Write-Log ("NEEDS INSTALL: '{0}' -> target {1}." -f $font.FamilyName, $desiredFp)
        try {
            $pk = "$StageRoot\$($font.FamilyName)"
            New-Item -Path $pk -Force | Out-Null
            New-ItemProperty -Path $pk -Name 'Urls'        -Value ([string[]]$font.Urls) -PropertyType MultiString -Force | Out-Null
            New-ItemProperty -Path $pk -Name 'Fingerprint' -Value $desiredFp             -PropertyType String      -Force | Out-Null
            $needing++
        } catch {
            Write-Log ("ERROR staging '{0}': {1}" -f $font.FamilyName, $_.Exception.Message)
        }
    }
}

if ($needing -gt 0) {
    Write-Log ("{0} font(s) need action. Signalling remediation (exit 1)." -f $needing)
    exit 1
} else {
    Write-Log 'All fonts up to date (exit 0).'
    exit 0
}
