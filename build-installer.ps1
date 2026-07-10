# Builds a single, shareable DailyTodoSetup.exe — a real Windows executable.
#
# Two things are compiled with the .NET Framework C# compiler (csc.exe, which
# ships with Windows):
#   1. DailyTodo.exe  — a tiny launcher that starts the app with NO console
#      window (replaces the old wscript/.vbs chain, which could open a "script
#      window" on some machines). It carries the Sobble icon.
#   2. DailyTodoSetup.exe — the installer. It embeds the app + the modern GUI
#      installer as resources; double-clicking it (no console) unpacks to a temp
#      folder and runs the installer window, which copies the app into
#      %LOCALAPPDATA% and sets up shortcuts. No admin, no external tools.
#
# Usage:  powershell -ExecutionPolicy Bypass -File build-installer.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$Dist = Join-Path $Root "dist"
if (-not (Test-Path $Dist)) { New-Item -ItemType Directory -Path $Dist -Force | Out-Null }
$OutExe = Join-Path $Dist "DailyTodoSetup.exe"
$Icon   = Join-Path $Root "icon.ico"

# --- locate the C# compiler -------------------------------------------------
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "csc.exe (.NET Framework compiler) not found." }

$Stage = Join-Path $env:TEMP ("DailyTodoBuild_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

try {
    # === 1. Compile the launcher (DailyTodo.exe) ===========================
    $launcherCs = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Daily To-Do")]
[assembly: AssemblyProduct("Daily To-Do")]
[assembly: AssemblyCompany("Daily To-Do")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyVersion("1.0.0.0")]

static class Launcher {
    [STAThread]
    static void Main() {
        try {
            string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string ps1 = Path.Combine(dir, "DailyTodo.ps1");
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
        } catch (Exception ex) {
            try { MessageBox.Show("Could not start Daily To-Do: " + ex.Message, "Daily To-Do"); } catch { }
        }
    }
}
'@
    $launcherSrc = Join-Path $Stage "Launcher.cs"
    Set-Content -Path $launcherSrc -Value $launcherCs -Encoding UTF8
    $launcherExe = Join-Path $Stage "DailyTodo.exe"
    $lArgs = @(
        "/nologo", "/target:winexe", "/platform:anycpu", "/optimize+",
        "/win32icon:`"$Icon`"",
        "/reference:System.Windows.Forms.dll",
        "/out:`"$launcherExe`"", "`"$launcherSrc`""
    )
    Write-Host "Compiling launcher DailyTodo.exe ..."
    $lp = Start-Process -FilePath $csc -ArgumentList $lArgs -Wait -PassThru -NoNewWindow
    if (-not (Test-Path $launcherExe) -or $lp.ExitCode -ne 0) { throw "Launcher compile failed (csc $($lp.ExitCode))." }

    # === 2. Files embedded in the setup (runtime + installer) ==============
    # logical name -> source path
    $Bundle = [ordered]@{
        "DailyTodo.ps1"  = Join-Path $Root "DailyTodo.ps1"
        "storage.ps1"    = Join-Path $Root "storage.ps1"
        "icon.ico"       = $Icon
        "Uninstall.ps1"  = Join-Path $Root "Uninstall.ps1"
        "Installer.ps1"  = Join-Path $Root "Installer.ps1"
        "DailyTodo.exe"  = $launcherExe
    }
    foreach ($k in $Bundle.Keys) {
        if (-not (Test-Path $Bundle[$k])) { throw "Missing required file: $k ($($Bundle[$k]))" }
    }

    # === 3. Setup stub: extract embedded files, run installer, clean up ====
    $stub = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Daily To-Do Setup")]
[assembly: AssemblyProduct("Daily To-Do")]
[assembly: AssemblyCompany("Daily To-Do")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyVersion("1.0.0.0")]

static class SetupStub {
    [STAThread]
    static int Main(string[] argv) {
        string tmp = Path.Combine(Path.GetTempPath(), "DTsetup_" + Guid.NewGuid().ToString("N").Substring(0, 8));
        try {
            Directory.CreateDirectory(tmp);
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string res in asm.GetManifestResourceNames()) {
                string outPath = Path.Combine(tmp, res);
                using (Stream rs = asm.GetManifestResourceStream(res))
                using (FileStream fs = File.Create(outPath)) { rs.CopyTo(fs); }
            }

            bool silent = false;
            foreach (string a in argv) {
                if (a.Equals("/silent", StringComparison.OrdinalIgnoreCase)) silent = true;
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
                            Path.Combine(tmp, "Installer.ps1") + "\"" + (silent ? " -Silent -NoLaunch" : "");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = tmp;
            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        } catch (Exception ex) {
            try { MessageBox.Show("Setup could not start: " + ex.Message, "Daily To-Do Setup"); } catch { }
            return 1;
        } finally {
            try { Directory.Delete(tmp, true); } catch { }
        }
    }
}
'@
    $stubSrc = Join-Path $Stage "SetupStub.cs"
    Set-Content -Path $stubSrc -Value $stub -Encoding UTF8

    $args = @(
        "/nologo", "/target:winexe", "/platform:anycpu", "/optimize+",
        "/win32icon:`"$Icon`"",
        "/reference:System.Windows.Forms.dll",
        "/out:`"$OutExe`""
    )
    foreach ($name in $Bundle.Keys) {
        $args += "/resource:`"$($Bundle[$name])`",`"$name`""
    }
    $args += "`"$stubSrc`""

    Write-Host "Compiling DailyTodoSetup.exe ..."
    $p = Start-Process -FilePath $csc -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ((Test-Path $OutExe) -and $p.ExitCode -eq 0) {
        $kb = [math]::Round((Get-Item $OutExe).Length / 1KB, 1)
        Write-Host ""
        Write-Host "Done. Shareable installer created:"
        Write-Host "  $OutExe  ($kb KB)"
        Write-Host ""
        Write-Host "Remember to re-sign after building:  powershell -File sign-installer.ps1"
    } else {
        throw "Compilation failed (csc exit code $($p.ExitCode))."
    }
} finally {
    Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
}
