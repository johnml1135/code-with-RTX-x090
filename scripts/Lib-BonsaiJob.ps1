Set-StrictMode -Version Latest

function Initialize-BonsaiJobNative {
    if ('BonsaiJobNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class BonsaiJobProcess : IDisposable {
    private IntPtr job;
    private IntPtr process;
    public int ProcessId { get; private set; }
    public bool KernelWorkingSetCapApplied { get; private set; }
    public int WorkingSetLimitErrorCode { get; private set; }
    public string WorkingSetLimitMessage { get; private set; }
    internal BonsaiJobProcess(IntPtr jobHandle, IntPtr processHandle, int pid, bool capApplied, int errorCode, string errorMessage) {
        job = jobHandle; process = processHandle; ProcessId = pid;
        KernelWorkingSetCapApplied = capApplied; WorkingSetLimitErrorCode = errorCode; WorkingSetLimitMessage = errorMessage;
    }
    public bool Wait(int milliseconds) {
        uint result = BonsaiJobNative.WaitForSingleObject(process, (uint)milliseconds);
        if (result == 0) return true;
        if (result == 0x102) return false;
        throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
    }
    public uint ExitCode {
        get {
            uint code;
            if (!BonsaiJobNative.GetExitCodeProcess(process, out code))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
            return code;
        }
    }
    public void Terminate(uint exitCode) {
        if (job != IntPtr.Zero && !BonsaiJobNative.TerminateJobObject(job, exitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateJobObject failed");
    }
    public void Dispose() {
        if (job != IntPtr.Zero) { BonsaiJobNative.CloseHandle(job); job = IntPtr.Zero; }
        if (process != IntPtr.Zero) { BonsaiJobNative.CloseHandle(process); process = IntPtr.Zero; }
    }
}

public static class BonsaiJobNative {
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const uint QUOTA_LIMITS_HARDWS_MAX_ENABLE = 0x00000004;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct StartupInfo {
        public uint cb;
        public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimitInformation info, uint length);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetProcessWorkingSetSizeEx(IntPtr process, UIntPtr minimumWorkingSetSize, UIntPtr maximumWorkingSetSize, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)]
    internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)]
    internal static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)]
    internal static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)]
    internal static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    private static string Quote(string value) {
        if (value.Length > 0 && value.IndexOfAny(new char[] {' ', '\t', '\n', '\v', '"'}) < 0) return value;
        StringBuilder result = new StringBuilder(); result.Append('"'); int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append('"'); slashes = 0; continue; }
            result.Append('\\', slashes); slashes = 0; result.Append(c);
        }
        result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
    }

    public static BonsaiJobProcess Start(string executable, string[] arguments, string workingDirectory, ulong maxWorkingSetBytes) {
        if (IntPtr.Size != 8) throw new InvalidOperationException("Bonsai working-set jobs require 64-bit PowerShell");
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");
        ProcessInformation pi = new ProcessInformation();
        bool processCreated = false;
        try {
            ExtendedLimitInformation limits = new ExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            uint size = (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation));
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref limits, size))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject working-set limit failed");

            StringBuilder command = new StringBuilder(Quote(executable));
            foreach (string arg in arguments) { command.Append(' '); command.Append(Quote(arg)); }
            StartupInfo si = new StartupInfo();
            si.cb = (uint)Marshal.SizeOf(typeof(StartupInfo)); si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = GetStdHandle(-10); si.hStdOutput = GetStdHandle(-11); si.hStdError = GetStdHandle(-12);
            if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero, workingDirectory, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess suspended server failed");
            processCreated = true;
            if (!AssignProcessToJobObject(job, pi.hProcess))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed");
            bool kernelCapApplied = true;
            int workingSetErrorCode = 0;
            string workingSetErrorMessage = null;
            if (!SetProcessWorkingSetSizeEx(pi.hProcess, new UIntPtr(64UL * 1024UL * 1024UL), new UIntPtr(maxWorkingSetBytes), QUOTA_LIMITS_HARDWS_MAX_ENABLE)) {
                workingSetErrorCode = Marshal.GetLastWin32Error();
                Win32Exception error = new Win32Exception(workingSetErrorCode);
                if (workingSetErrorCode != 1314)
                    throw new Win32Exception(workingSetErrorCode, "SetProcessWorkingSetSizeEx working-set ceiling failed");
                kernelCapApplied = false;
                workingSetErrorMessage = error.Message;
            }
            if (ResumeThread(pi.hThread) == 0xFFFFFFFF)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread failed");
            CloseHandle(pi.hThread);
            return new BonsaiJobProcess(job, pi.hProcess, pi.dwProcessId, kernelCapApplied, workingSetErrorCode, workingSetErrorMessage);
        } catch {
            if (processCreated) { TerminateJobObject(job, 1); CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
            CloseHandle(job); throw;
        }
    }
}
'@
}

function Start-BonsaiLimitedProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$MaxWorkingSetGiB
    )
    Initialize-BonsaiJobNative
    $bytes = [uint64]$MaxWorkingSetGiB * 1GB
    return [BonsaiJobNative]::Start($Executable, $Arguments, $WorkingDirectory, $bytes)
}

function Test-BonsaiWorkingSetBreach {
    param(
        [Parameter(Mandatory)][long]$WorkingSetBytes,
        [Parameter(Mandatory)][long]$LimitBytes,
        [bool]$KernelWorkingSetCapApplied = $false
    )
    return [bool](Get-BonsaiWorkingSetEvaluation -WorkingSetBytes $WorkingSetBytes -LimitBytes $LimitBytes -KernelWorkingSetCapApplied $KernelWorkingSetCapApplied).breach
}

function Get-BonsaiWorkingSetEvaluation {
    param(
        [Parameter(Mandatory)][long]$WorkingSetBytes,
        [Parameter(Mandatory)][long]$LimitBytes,
        [Parameter(Mandatory)][bool]$KernelWorkingSetCapApplied
    )
    if ($WorkingSetBytes -lt 0 -or $LimitBytes -le 0) { throw 'working-set counters must be nonnegative and the configured limit must be positive' }
    $tolerance = if ($KernelWorkingSetCapApplied) { [int64]65536 } else { [int64]0 }
    $effectiveLimit = [int64]($LimitBytes + $tolerance)
    [pscustomobject]@{
        rawWorkingSetBytes=[int64]$WorkingSetBytes
        configuredLimitBytes=[int64]$LimitBytes
        toleranceBytes=$tolerance
        effectiveLimitBytes=$effectiveLimit
        kernelWorkingSetCapApplied=[bool]$KernelWorkingSetCapApplied
        breach=([int64]$WorkingSetBytes -gt $effectiveLimit)
    }
}

function Test-BonsaiGpuMemoryBreach {
    param([Parameter(Mandatory)][long]$UsedMiB,[Parameter(Mandatory)][long]$TotalMiB,[Parameter(Mandatory)][ValidateRange(1,100)][int]$LimitPercent)
    if ($TotalMiB -le 0 -or $UsedMiB -lt 0) { throw 'GPU memory counters must be nonnegative and total memory must be positive' }
    return (([double]$UsedMiB * 100.0 / [double]$TotalMiB) -ge $LimitPercent)
}

function Get-BonsaiGpuMemorySnapshot {
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return [pscustomobject]@{ available=$false; reason='nvidia-smi not found' } }
    try {
        $lines = @(& $command.Source '--query-gpu=memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { return [pscustomobject]@{ available=$false; reason='nvidia-smi query failed' } }
        $parts = ([string]$lines[0]).Split(',')
        if ($parts.Count -ne 2) { return [pscustomobject]@{ available=$false; reason='unexpected nvidia-smi output' } }
        $used = [int64]$parts[0].Trim(); $total = [int64]$parts[1].Trim()
        [pscustomobject]@{ available=$true; usedMiB=$used; totalMiB=$total; usedPercent=[math]::Round(($used * 100.0 / $total),2) }
    } catch {
        return [pscustomobject]@{ available=$false; reason=$_.Exception.Message }
    }
}
