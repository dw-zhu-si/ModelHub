using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace ModelHub.Windows.Services;

/// <summary>
/// Windows Credential Manager adapter. Secrets never enter JSON configuration, logs, or UI state.
/// Callers receive only a short success/failure indication; this class does not enumerate credentials.
/// </summary>
public interface ICredentialVault
{
    void Write(string targetName, string secret);
    string? Read(string targetName);
    bool Exists(string targetName);
    void Delete(string targetName);
}

public sealed class WindowsCredentialVault : ICredentialVault
{
    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    public void Write(string targetName, string secret)
    {
        ValidateTarget(targetName);
        ArgumentException.ThrowIfNullOrWhiteSpace(secret);
        EnsureWindows();

        var blob = Encoding.UTF8.GetBytes(secret);
        if (blob.Length > 5120)
        {
            throw new ArgumentOutOfRangeException(nameof(secret), "Credential Manager generic credentials are limited to 5120 bytes.");
        }

        var credential = new NativeCredential
        {
            Type = CredTypeGeneric,
            TargetName = targetName,
            CredentialBlobSize = (uint)blob.Length,
            Persist = CredPersistLocalMachine,
            UserName = Environment.UserName,
        };

        credential.CredentialBlob = Marshal.AllocCoTaskMem(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, credential.CredentialBlob, blob.Length);
            if (!CredWrite(ref credential, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential Manager rejected the secret.");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(blob);
            if (credential.CredentialBlob != IntPtr.Zero)
            {
                // CredWrite copies the blob synchronously. Scrub our unmanaged
                // staging allocation before returning it to the process heap.
                Marshal.Copy(blob, 0, credential.CredentialBlob, blob.Length);
                Marshal.FreeCoTaskMem(credential.CredentialBlob);
            }
        }
    }

    public string? Read(string targetName)
    {
        ValidateTarget(targetName);
        EnsureWindows();
        if (!CredRead(targetName, CredTypeGeneric, 0, out var credentialPointer))
        {
            var error = Marshal.GetLastWin32Error();
            return error == ErrorNotFound ? null : throw new Win32Exception(error, "Credential Manager could not read the secret.");
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(credentialPointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return null;
            }
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            try
            {
                return Encoding.UTF8.GetString(bytes);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        finally
        {
            CredFree(credentialPointer);
        }
    }

    public bool Exists(string targetName)
    {
        ValidateTarget(targetName);
        EnsureWindows();
        if (!CredRead(targetName, CredTypeGeneric, 0, out var credentialPointer))
        {
            var error = Marshal.GetLastWin32Error();
            return error == ErrorNotFound ? false : throw new Win32Exception(error, "Credential Manager could not query the secret.");
        }
        CredFree(credentialPointer);
        return true;
    }

    public void Delete(string targetName)
    {
        ValidateTarget(targetName);
        EnsureWindows();
        if (!CredDelete(targetName, CredTypeGeneric, 0) && Marshal.GetLastWin32Error() != ErrorNotFound)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential Manager could not delete the secret.");
        }
    }

    private static void ValidateTarget(string targetName)
    {
        if (string.IsNullOrWhiteSpace(targetName)
            || targetName.Length > 256
            || !targetName.Equals(targetName.Trim(), StringComparison.Ordinal)
            || targetName.Any(char.IsControl)
            || !targetName.StartsWith("ModelHub.Windows/", StringComparison.Ordinal))
        {
            throw new ArgumentException("The credential target is invalid.", nameof(targetName));
        }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows Credential Manager is available only on Windows.");
        }
    }

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite([In] ref NativeCredential userCredential, uint flags);

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPointer);

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32", SetLastError = true)]
    private static extern void CredFree(IntPtr credentialPointer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;
        public string? TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }
}
