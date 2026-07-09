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
    A font's staging entry is cleared (and its state recorded) only when every
    URL downloads AND every file installs (or is staged to swap on reboot). Any
    download or install failure leaves the entry staged and retried next cycle.

    No font list lives here - fonts are edited only in the detection script.
#>

$StageRoot  = 'HKLM:\SOFTWARE\CustomFontInstaller\Pending'
$StateRoot  = 'HKLM:\SOFTWARE\CustomFontInstaller\Installed'
$FontRegKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$FontsDir   = Join-Path $env:windir 'Fonts'
$RebootStage= Join-Path $env:ProgramData 'CustomFontInstaller\PendingReboot'  # holds files to swap in on reboot when a font is in use
$LogPath    = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\CustomFontDeployment.log'
$UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'   # some hosts (DaFont) reject requests with no UA

function Write-Log {
    param([string]$Message)
    $line = '[{0}] [REMEDIATE] {1}' -f (Get-Date -Format 'u'), $Message
    # Write-Host (not Write-Output): Write-Output emits $line into the success
    # stream, which pollutes the return value of any function that calls Write-Log
    # (e.g. Install-FontFile), corrupting the recorded 'Files' state list.
    Write-Host $line
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
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);
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

    # Release our own GDI registration on the existing file before overwriting it;
    # otherwise replacing a font that is currently mapped fails with
    # "cannot be performed on a file with a user-mapped section open".
    if (Test-Path -LiteralPath $dest) {
        try { [FontNative.Win]::RemoveFontResourceEx($dest, 0, [IntPtr]::Zero) | Out-Null } catch { }
    }

    # Returns 'installed' (now live), 'reboot' (will swap on next reboot) or
    # 'failed'. The caller only marks a family done when no file returns 'failed'.
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $dest -Force -ErrorAction Stop
        New-ItemProperty -Path $FontRegKey -Name (Get-RegNameFor $fileName) -Value $fileName -PropertyType String -Force | Out-Null
        [FontNative.Win]::AddFontResourceEx($dest, 0, [IntPtr]::Zero) | Out-Null
        Write-Log ("Installed: {0}" -f $fileName)
        return 'installed'
    }
    catch {
        # Still locked (mapped by a running app or the Font Cache service). Stage
        # the new file in a persistent location and let Windows swap it in on the
        # next reboot, instead of throwing and aborting the whole font family.
        try {
            if (-not (Test-Path -LiteralPath $RebootStage)) { New-Item -ItemType Directory -Path $RebootStage -Force | Out-Null }
            $persist = Join-Path $RebootStage $fileName
            Copy-Item -LiteralPath $SourcePath -Destination $persist -Force -ErrorAction Stop
            # MOVEFILE_REPLACE_EXISTING (0x1) | MOVEFILE_DELAY_UNTIL_REBOOT (0x4)
            if ([FontNative.Win]::MoveFileEx($persist, $dest, ([uint32]0x1 -bor [uint32]0x4))) {
                New-ItemProperty -Path $FontRegKey -Name (Get-RegNameFor $fileName) -Value $fileName -PropertyType String -Force | Out-Null
                Write-Log ("In use - staged to replace on next reboot: {0}" -f $fileName)
                return 'reboot'
            }
            Write-Log ("FAILED to schedule reboot-replace for '{0}' (MoveFileEx returned false, error {1})." -f $fileName, [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
            return 'failed'
        } catch {
            Write-Log ("FAILED to install '{0}': {1}" -f $fileName, $_.Exception.Message)
            return 'failed'
        }
    }
}

function Remove-FontFile {
    param([string]$FileName)
    # Whole body guarded: a corrupted/legacy orphan entry (e.g. one with invalid
    # path characters) must never throw and abort the family's reinstall.
    try {
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
    } catch {
        Write-Log ("Skipped orphan entry: {0}" -f $FileName)
    }
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

            # 3. Force-install the new set, tracking per-file outcome. 'reboot' still
            #    counts as done (the file exists and will swap on reboot); only a
            #    genuine 'failed' should keep the family staged for another attempt.
            $anyFailed = $false
            foreach ($f in $newFiles) {
                if ((Install-FontFile -SourcePath $f) -eq 'failed') { $anyFailed = $true }
                else { $installedAny = $true }
            }

            if ($anyFailed) {
                # Don't record a satisfied fingerprint or clear staging - leave it so
                # detection re-flags and remediation retries next cycle (as for a
                # failed download). $newNames is authoritative when we do record.
                Write-Log ("'{0}' had file(s) that failed to install - left staged for retry." -f $familyName)
            }
            else {
                # 4. Record state so detection sees this font as current.
                New-Item -Path $stateKey -Force | Out-Null
                New-ItemProperty -Path $stateKey -Name 'Fingerprint' -Value $fingerprint           -PropertyType String      -Force | Out-Null
                New-ItemProperty -Path $stateKey -Name 'Files'       -Value ([string[]]$newNames)  -PropertyType MultiString -Force | Out-Null

                Remove-Item -Path $pk -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log ("Completed '{0}' ({1} file(s))." -f $familyName, $newNames.Count)
            }
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
