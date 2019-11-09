# Copyright: (c) 2018, Jordan Borean (@jborean93) <jborean93@gmail.com>
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

Function New-PBKDF2Key {
    <#
    .SYNOPSIS
    Uses the PBKDF2 functiion to derive a key used in cryptographic functions.

    .DESCRIPTION
    This function can be used to generated a cryptographically secure key based
    on the PBKDF2 function. This function calls some native Win32 APIs as the
    .NET class Rfc2898DeriveBytes that generates these keys does not allow the
    hash algorithm to be changed until .NET 4.7.2.

    Because we want this script to run on older versions on Windows and Ansible
    Vault uses the SHA256 algorithm we have to resort to using the native
    function BCryptDeriveKeyPBKDF2.

    .PARAMETER Algorithm
    [String] Specifies the algorithm to use for the HMAC calculation. This must
    be one of the algorithm identifiers specified in
    https://msdn.microsoft.com/en-us/library/windows/desktop/aa375534.aspx.

    .PARAMETER Password
    [SecureString] The password used as the part of the PBKDF2 function.

    .PARAMETER Salt
    [byte[]] The salt used as part of the PBKDF2 function.

    .PARAMETER Length
    [UInt32] The length of the derived key.

    .PARAMETER Iterations
    [UInt64] The number of iterations for the PBKDF2 function.

    .OUTPUTS
    [byte[]] The derived key of the PBKDF2 function run.

    .EXAMPLE
    $salt = New-Object -TypeName byte[] -ArgumentList 32
    $random_gen = New-Object -TypeName System.Security.Cryptography.RNGCryptoServiceProvider
    $random_gen.GetBytes($salt)

    New-PBKDF2Key -Algorithm SHA256 -Password $sec_string -Salt $salt -Length 32 -Iterations 10000

    .NOTES
    As Windows has not automatic marshalling for a SecureString to a P/Invoke
    call, the SecureString is temporarily assigned to a IntPtr before being
    passed to the BCryptDeriveKeyPBKDF2 with the SecureStringToGlobalAllocAnsi
    function. This pointer is immediately cleared withZeroFreeGlobalAllocAnsi
    as soon as possible.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification="Does not adjust system state, creates a new key that is in memory")]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory=$true)] [String]$Algorithm,
        [Parameter(Mandatory=$true)] [SecureString]$Password,
        [Parameter(Mandatory=$true)] [byte[]]$Salt,
        [Parameter(Mandatory=$true)] [UInt32]$Length,
        [Parameter(Mandatory=$true)] [UInt64]$Iterations
    )

    $return_codes = @{
        "3221225485" = "An invalid parameter was passed to a service or function (STATUS_INVALID_PARAMETER 0xC0000000D)"
        "3221225480" = "An invalid HANDLE was specified (STATUS_INVALID_HANDLE 0xC0000008)"
        "3221225495" = "A memory allocation failure occurred (STATUS_NO_MEMORY 0xC0000017)"
        "3221226021" = "The object was not found (STATUS_NOT_FOUND 0xC0000225)"
    }

    $algo = [IntPtr]::Zero
    $open_flags = 0x00000008  # BCRYPT_ALG_HANDLE_HMAC_FLAG

    $res = Invoke-Win32Api -DllName Bcrypt.dll `
        -MethodName BCryptOpenAlgorithmProvider `
        -ReturnType UInt32 `
        -ParameterTypes @([Ref], [String], [String], [UInt32]) `
        -Parameters @([Ref]$algo, $Algorithm, $null, $open_flags)
    if ($res -ne 0) {
        if ($return_codes.ContainsKey($res.ToString())) {
            $exception_msg = $return_codes.$($res.ToString())
        } else {
            $hex_code = ("{0:x8}" -f $res).ToUpper()
            $exception_msg = "Unknown error (0x$hex_code)"
        }
        throw "Failed to open algorithm provider with ID '$Algorithm': $exception_msg"
    }

    try {
        $key = New-Object -TypeName byte[] -ArgumentList $Length
        $pass = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocAnsi($Password)
        try {
            $res = Invoke-Win32Api -DllName Bcrypt.dll `
                -MethodName BCryptDeriveKeyPBKDF2 `
                -ReturnType UInt32 `
                -ParameterTypes @([IntPtr], [IntPtr], [UInt32], [byte[]], [UInt32], [UInt64], [byte[]], [UInt32], [UInt32]) `
                -Parameters @($algo, $pass, $Password.Length, $Salt, $Salt.Length, $Iterations, $key, $key.Length, 0)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocAnsi($pass)
        }

        if ($res -ne 0) {
            if ($return_codes.ContainsKey($res.ToString())) {
                $exception_msg = $return_codes.$($res.ToString())
            } else {
                $hex_code = ("{0:x8}" -f $res).ToUpper()
                $exception_msg = "Unknown error (0x$hex_code)"
            }

            throw "Failed to derive key: $exception_msg"
        }
    } finally {
        $res = Invoke-Win32Api -DllName Bcrypt.dll `
            -MethodName BCryptCloseAlgorithmProvider `
            -ReturnType UInt32 `
            -ParameterTypes @([IntPtr], [UInt32]) `
            -Parameters @($algo, 0)
        if ($res -ne 0) {
            if ($return_codes.ContainsKey($res.ToString())) {
                $exception_msg = $return_codes.$($res.ToString())
            } else {
                $hex_code = ("{0:x8}" -f $res).ToUpper()
                $exception_msg = "Unknown error (0x$hex_code)"
            }

            throw "Failed to close algorithm provider: $exception_msg"
        }
    }

    return [byte[]]$key
}