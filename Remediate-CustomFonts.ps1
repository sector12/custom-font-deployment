#Requires -Version 5.1
<#
    Remediate-CustomFonts.ps1
    Intune Remediations - REMEDIATION script.

    Assignment: Run as logged-on credentials = No (SYSTEM),
    Run in 64-bit PowerShell = Yes, file encoding = UTF-8.

    For each font staged by the detection script:
      1. download every URL (zip or single .ttf/.otf; source-agnostic),
      2. remove any files from the PREVIOUS install of this font that are not
         in the new set (clean swap - no orphans left behind),
      3. force-install the new files machine-wide (overwrite),
      4. record the fingerprint + installed file list so detection knows the
         font is current.
    A font's staging entry is cleared only when ALL its URLs succeed; a partial
    failure is left staged and retried next cycle.

    No font list lives here - fonts are edited only in the detection script.
#>

$StageRoot  = 'HKLM:\SOFTWARE\CustomFontInstaller\Pending'
$StateRoot  = 'HKLM:\SOFTWARE\CustomFontInstaller\Installed'
$FontRegKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$FontsDir   = Join-Path $env:windir 'Fonts'
$LogPath    = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\CustomFontDeployment.log'
$UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'   # some hosts (DaFont) reject requests with no UA

function Write-Log {
    param([string]$Message)
    $line = '[{0}] [REMEDIATE] {1}' -f (Get-Date -Format 'u'), $Message
    Write-Output $line
    try {
        $dir = Split-Path $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
    } catch { }
}

# Windows PowerShell 5.1 may negotiate TLS 1.0/1.1 by default; force 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not ('FontNative.Win' -as [type])) {
    Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FontNative {
    public static class Win {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int AddFontResourceEx(string lpFileName, uint fl, IntPtr pdv);
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool RemoveFontResourceEx(string lpFileName, uint fl, IntPtr pdv);
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
            uint flags, uint timeout, out IntPtr result);
    }
}
'@
}

function Test-IsFont {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 4) { return $false }
    $sig = '{0:X2}{1:X2}{2:X2}{3:X2}' -f $Bytes[0], $Bytes[1], $Bytes[2], $Bytes[3]
    return @('00010000', '4F54544F', '74727565', '74746366') -contains $sig
}

# Download one URL into $WorkDir; return local font-file path(s) it yields.
function Get-FontFilesFromDownload {
    param([string]$Url, [string]$WorkDir, [string]$Tag)
    $dl = Join-Path $WorkDir "$Tag.bin"
    Invoke-WebRequest -Uri $Url -OutFile $dl -UseBasicParsing -UserAgent $UserAgent -ErrorAction Stop
    $bytes = [System.IO.File]::ReadAllBytes($dl)

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B) {         # ZIP ('PK')
        $zip = Join-Path $WorkDir "$Tag.zip"; Move-Item -LiteralPath $dl -Destination $zip -Force
        $ex  = Join-Path $WorkDir "$Tag`_x"
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force -ErrorAction Stop
        return @(Get-ChildItem -Path $ex -Recurse -File |
                 Where-Object { $_.Extension.ToLowerInvariant() -in @('.ttf', '.otf') } |
                 Select-Object -ExpandProperty FullName)
    }
    elseif (Test-IsFont $bytes) {                                                       # single font file
        $leaf = [System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName(($Url -split '\?')[0]))
        if ($leaf -notmatch '\.(ttf|otf)$') {
            $inferExt = if ($bytes[0] -eq 0x4F) { '.otf' } else { '.ttf' }
            $leaf = '{0}{1}' -f $Tag, $inferExt
        }
        $named = Join-Path $WorkDir $leaf; Move-Item -LiteralPath $dl -Destination $named -Force
        return @($named)
    }
    else {
        throw 'Download was neither a ZIP nor a font file (likely an HTML error/redirect page). Verify the URL in a browser.'
    }
}

function Get-RegNameFor {
    param([string]$FileName)
    $ext  = [System.IO.Path]::GetExtension($FileName).ToLowerInvariant()
    $type = if ($ext -eq '.otf') { 'OpenType' } else { 'TrueType' }
    '{0} ({1})' -f [System.IO.Path]::GetFileNameWithoutExtension($FileName), $type
}

function Install-FontFile {
    param([string]$SourcePath)
    $fileName = [System.IO.Path]::GetFileName($SourcePath)
    $dest     = Join-Path $FontsDir $fileName
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force            # overwrite = force-replace
    New-ItemProperty -Path $FontRegKey -Name (Get-RegNameFor $fileName) -Value $fileName -PropertyType String -Force | Out-Null
    [FontNative.Win]::AddFontResourceEx($dest, 0, [IntPtr]::Zero) | Out-Null
    Write-Log ("Installed: {0}" -f $fileName)
    return $fileName
}

function Remove-FontFile {
    param([string]$FileName)
    $dest = Join-Path $FontsDir $FileName
    # -Name is wildcard-matched by the registry provider, so escape []*? (e.g. the
    # Josefin Sans "[wght]" variable-font names) or the entry silently won't remove.
    $regName = [System.Management.Automation.WildcardPattern]::Escape((Get-RegNameFor $FileName))
    try { [FontNative.Win]::RemoveFontResourceEx($dest, 0, [IntPtr]::Zero) | Out-Null } catch { }
    try { Remove-ItemProperty -Path $FontRegKey -Name $regName -Force -ErrorAction SilentlyContinue } catch { }
    # -LiteralPath so "[wght]" is treated literally, not as a wildcard (which makes
    # Test-Path enumerate the special C:\Windows\Fonts folder and throw DirIOError).
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
    Write-Log ("Removed old file: {0}" -f $FileName)
}

Write-Log '--- Remediation start ---'
if (-not (Test-Path $StageRoot)) { Write-Log 'No staging root - nothing to do.'; exit 0 }
$staged = @(Get-ChildItem -Path $StageRoot -ErrorAction SilentlyContinue)
if ($staged.Count -eq 0) { Write-Log 'Nothing staged - nothing to do.'; exit 0 }

if (-not (Test-Path $StateRoot)) { New-Item -Path $StateRoot -Force | Out-Null }
$installedAny = $false

foreach ($item in $staged) {
    $familyName = $item.PSChildName
    $pk         = "$StageRoot\$familyName"
    $sp         = Get-ItemProperty -Path $pk -ErrorAction SilentlyContinue
    $urls       = @($sp.Urls)
    $fingerprint= $sp.Fingerprint
    $safe       = ($familyName -replace '[^A-Za-z0-9]', '_')
    $workDir    = Join-Path $env:TEMP ("fontwork_" + $safe)
    Write-Log ("Processing '{0}' ({1} URL(s), target {2})." -f $familyName, $urls.Count, $fingerprint)

    $familyOK   = $true
    $newFiles   = @()

    try {
        if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # 1. Download everything first; only touch the system if all URLs succeed.
        $idx = 0
        foreach ($u in $urls) {
            $idx++
            try {
                $files = @(Get-FontFilesFromDownload -Url $u -WorkDir $workDir -Tag ("u$idx"))
                if ($files.Count -eq 0) { throw 'No .ttf/.otf files found in the download.' }
                $newFiles += $files
            } catch {
                $familyOK = $false
                Write-Log ("  URL failed [{0}]: {1}" -f $u, $_.Exception.Message)
            }
        }

        if ($familyOK -and $newFiles.Count -gt 0) {
            $newNames = @($newFiles | ForEach-Object { [System.IO.Path]::GetFileName($_) })

            # 2. Clean up orphans from the previous install of this font.
            $stateKey = "$StateRoot\$familyName"
            if (Test-Path $stateKey) {
                $prevFiles = @((Get-ItemProperty -Path $stateKey -ErrorAction SilentlyContinue).Files)
                foreach ($old in $prevFiles) {
                    if ($old -and ($newNames -notcontains $old)) { Remove-FontFile -FileName $old }
                }
            }

            # 3. Force-install the new set.
            $installedNames = @()
            foreach ($f in $newFiles) { $installedNames += (Install-FontFile -SourcePath $f); $installedAny = $true }

            # 4. Record state so detection sees this font as current.
            New-Item -Path $stateKey -Force | Out-Null
            New-ItemProperty -Path $stateKey -Name 'Fingerprint' -Value $fingerprint                -PropertyType String      -Force | Out-Null
            New-ItemProperty -Path $stateKey -Name 'Files'       -Value ([string[]]$installedNames) -PropertyType MultiString -Force | Out-Null

            Remove-Item -Path $pk -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log ("Completed '{0}' ({1} file(s))." -f $familyName, $installedNames.Count)
        }
        else {
            Write-Log ("'{0}' left staged for retry (a download failed)." -f $familyName)
        }
    }
    catch {
        Write-Log ("ERROR processing '{0}': {1}" -f $familyName, $_.Exception.Message)
    }
    finally {
        if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Best-effort notify of font-table change. Session-0 isolation means an
# interactive user may still need to log off/on for a new or swapped font to
# appear inside already-running applications.
if ($installedAny) {
    try {
        $res = [IntPtr]::Zero
        [FontNative.Win]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, $null, 2, 1000, [ref]$res) | Out-Null
    } catch { }
}

Write-Log '--- Remediation end ---'
exit 0
