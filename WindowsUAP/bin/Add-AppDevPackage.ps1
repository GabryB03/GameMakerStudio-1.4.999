#
# Add-AppxDevPackage.ps1 is a PowerShell script designed to install app
# packages created by Visual Studio for developers.  To run this script from
# Explorer, right-click on its icon and choose "Run with PowerShell".
#
# Visual Studio supplies this script in the folder generated with its
# "Prepare Package" command.  The same folder will also contain the app
# package (a .appx file), the signing certificate (a .cer file), and a
# "Dependencies" subfolder containing all the framework packages used by the
# app.
#
# This script simplifies installing these packages by automating the
# following functions:
#   1. Find the app package and signing certificate in the script directory
#   2. Prompt the user to acquire a developer license and to install the
#      certificate if necessary
#   3. Find dependency packages that are applicable to the operating system's
#      CPU architecture
#   4. Install the package along with all applicable dependencies
#
# All command line parameters are reserved for use internally by the script.
# Users should launch this script from Explorer.
#

# .Link
# http://go.microsoft.com/fwlink/?LinkId=243053

param(
    [switch]$Force = $false,
    [switch]$GetDeveloperLicense = $false,
    [string]$CertificatePath = $null
)

$ErrorActionPreference = "Stop"

# The language resources for this script are placed in the
# "Add-AppDevPackage.resources" subfolder alongside the script.  Since the
# current working directory might not be the directory that contains the
# script, we need to create the full path of the resources directory to
# pass into Import-LocalizedData
$ScriptPath = $null
try
{
    $ScriptPath = (Get-Variable MyInvocation).Value.MyCommand.Path
    $ScriptDir = Split-Path -Parent $ScriptPath
}
catch {}

if (!$ScriptPath)
{
    PrintMessageAndExit $UiStrings.ErrorNoScriptPath $ErrorCodes.NoScriptPath
}

$LocalizedResourcePath = Join-Path $ScriptDir "Add-AppDevPackage.resources"
Import-LocalizedData -BindingVariable UiStrings -BaseDirectory $LocalizedResourcePath

$ErrorCodes = Data {
    ConvertFrom-StringData @'
    Success = 0
    NoScriptPath = 1
    NoPackageFound = 2
    ManyPackagesFound = 3
    NoCertificateFound = 4
    ManyCertificatesFound = 5
    BadCertificate = 6
    PackageUnsigned = 7
    CertificateMismatch = 8
    ForceElevate = 9
    LaunchAdminFailed = 10
    GetDeveloperLicenseFailed = 11
    InstallCertificateFailed = 12
    AddPackageFailed = 13
    ForceDeveloperLicense = 14
    CertUtilInstallFailed = 17
    CertIsCA = 18
    BannedEKU = 19
    NoBasicConstraints = 20
    NoCodeSigningEku = 21
    InstallCertificateCancelled = 22
    BannedKeyUsage = 23
    ExpiredCertificate = 24
'@
}

function PrintMessageAndExit($ErrorMessage, $ReturnCode)
{
    Write-Host $ErrorMessage
    if (!$Force)
    {
 #       Pause
    }
    exit $ReturnCode
}

#
# Warns the user about installing certificates, and presents a Yes/No prompt
# to confirm the action.  The default is set to No.
#
function ConfirmCertificateInstall
{
    $Answer = $host.UI.PromptForChoice(
                    "", 
                    $UiStrings.WarningInstallCert, 
                    [System.Management.Automation.Host.ChoiceDescription[]]@($UiStrings.PromptYesString, $UiStrings.PromptNoString), 
                    1)
    
    return $Answer -eq 0
}

#
# Validates whether a file is a valid certificate using CertUtil.
# This needs to be done before calling Get-PfxCertificate on the file, otherwise
# the user will get a cryptic "Password: " prompt for invalid certs.
#
function ValidateCertificateFormat($FilePath)
{
    # certutil -verify prints a lot of text that we don't need, so it's redirected to $null here
    certutil.exe -verify $FilePath > $null
    if ($LastExitCode -lt 0)
    {
        PrintMessageAndExit ($UiStrings.ErrorBadCertificate -f $FilePath, $LastExitCode) $ErrorCodes.BadCertificate
    }
    
    # Check if certificate is expired
    $cert = Get-PfxCertificate $FilePath
    if (($cert.NotBefore -gt (Get-Date)) -or ($cert.NotAfter -lt (Get-Date)))
    {
        PrintMessageAndExit ($UiStrings.ErrorExpiredCertificate -f $FilePath) $ErrorCodes.ExpiredCertificate
    }
}

#
# Verify that the developer certificate meets the following restrictions:
#   - The certificate must contain a Basic Constraints extension, and its
#     Certificate Authority (CA) property must be false.
#   - The certificate's Key Usage extension must be either absent, or set to
#     only DigitalSignature.
#   - The certificate must contain an Extended Key Usage (EKU) extension with
#     Code Signing usage.
#   - The certificate must NOT contain any other EKU except Code Signing and
#     Lifetime Signing.
#
# These restrictions are enforced to decrease security risks that arise from
# trusting digital certificates.
#
function CheckCertificateRestrictions
{
    Set-Variable -Name BasicConstraintsExtensionOid -Value "2.5.29.19" -Option Constant
    Set-Variable -Name KeyUsageExtensionOid -Value "2.5.29.15" -Option Constant
    Set-Variable -Name EkuExtensionOid -Value "2.5.29.37" -Option Constant
    Set-Variable -Name CodeSigningEkuOid -Value "1.3.6.1.5.5.7.3.3" -Option Constant
    Set-Variable -Name LifetimeSigningEkuOid -Value "1.3.6.1.4.1.311.10.3.13" -Option Constant

    $CertificateExtensions = (Get-PfxCertificate $CertificatePath).Extensions
    $HasBasicConstraints = $false
    $HasCodeSigningEku = $false

    foreach ($Extension in $CertificateExtensions)
    {
        # Certificate must contain the Basic Constraints extension
        if ($Extension.oid.value -eq $BasicConstraintsExtensionOid)
        {
            # CA property must be false
            if ($Extension.CertificateAuthority)
            {
                PrintMessageAndExit $UiStrings.ErrorCertIsCA $ErrorCodes.CertIsCA
            }
            $HasBasicConstraints = $true
        }

        # If key usage is present, it must be set to digital signature
        elseif ($Extension.oid.value -eq $KeyUsageExtensionOid)
        {
            if ($Extension.KeyUsages -ne "DigitalSignature")
            {
                PrintMessageAndExit ($UiStrings.ErrorBannedKeyUsage -f $Extension.KeyUsages) $ErrorCodes.BannedKeyUsage
            }
        }

        elseif ($Extension.oid.value -eq $EkuExtensionOid)
        {
            # Certificate must contain the Code Signing EKU
            $EKUs = $Extension.EnhancedKeyUsages.Value
            if ($EKUs -contains $CodeSigningEkuOid)
            {
                $HasCodeSigningEKU = $True
            }

            # EKUs other than code signing and lifetime signing are not allowed
            foreach ($EKU in $EKUs)
            {
                if ($EKU -ne $CodeSigningEkuOid -and $EKU -ne $LifetimeSigningEkuOid)
                {
                    PrintMessageAndExit ($UiStrings.ErrorBannedEKU -f $EKU) $ErrorCodes.BannedEKU
                }
            }
        }
    }

    if (!$HasBasicConstraints)
    {
        PrintMessageAndExit $UiStrings.ErrorNoBasicConstraints $ErrorCodes.NoBasicConstraints
    }
    if (!$HasCodeSigningEKU)
    {
        PrintMessageAndExit $UiStrings.ErrorNoCodeSigningEku $ErrorCodes.NoCodeSigningEku
    }
}

#
# Performs operations that require administrative privileges:
#   - Prompt the user to obtain a developer license
#   - Install the developer certificate (if -Force is not specified, also prompts the user to confirm)
#
function DoElevatedOperations
{
    if ($GetDeveloperLicense)
    {
        Write-Host $UiStrings.GettingDeveloperLicense

        if ($Force)
        {
            PrintMessageAndExit $UiStrings.ErrorForceDeveloperLicense $ErrorCodes.ForceDeveloperLicense
        }
        try
        {
            Show-WindowsDeveloperLicenseRegistration
        }
        catch
        {
            $Error[0] # Dump details about the last error
            PrintMessageAndExit $UiStrings.ErrorGetDeveloperLicenseFailed $ErrorCodes.GetDeveloperLicenseFailed
        }
    }

    if ($CertificatePath)
    {
        Write-Host $UiStrings.InstallingCertificate

        # Make sure certificate format is valid and usage constraints are followed
        ValidateCertificateFormat $CertificatePath
        CheckCertificateRestrictions

        # If -Force is not specified, warn the user and get consent
        if ($Force -or (ConfirmCertificateInstall))
        {
            # Add cert to store
            certutil.exe -addstore TrustedPeople $CertificatePath
            if ($LastExitCode -lt 0)
            {
                PrintMessageAndExit ($UiStrings.ErrorCertUtilInstallFailed -f $LastExitCode) $ErrorCodes.CertUtilInstallFailed
            }
        }
        else
        {
            PrintMessageAndExit $UiStrings.ErrorInstallCertificateCancelled $ErrorCodes.InstallCertificateCancelled
        }
    }
}

#
# Checks whether the machine is missing a valid developer license.
#
function CheckIfNeedDeveloperLicense
{
    $Result = $true
    try
    {
        $Result = (Get-WindowsDeveloperLicense | Where-Object { $_.IsValid }).Count -eq 0
    }
    catch {}

    return $Result
}

#
# Launches an elevated process running the current script to perform tasks
# that require administrative privileges.  This function waits until the
# elevated process terminates, and checks whether those tasks were successful.
#
function LaunchElevated
{
    # Set up command line arguments to the elevated process
    $RelaunchArgs = '-ExecutionPolicy Unrestricted -file "' + $ScriptPath + '"'

    if ($Force)
    {
        $RelaunchArgs += ' -Force'
    }
    if ($NeedDeveloperLicense)
    {
        $RelaunchArgs += ' -GetDeveloperLicense'
    }
    if ($NeedInstallCertificate)
    {
        $RelaunchArgs += ' -CertificatePath "' + $DeveloperCertificatePath.FullName + '"'
    }

    # Launch the process and wait for it to finish
    try
    {
        $AdminProcess = Start-Process "$PsHome\PowerShell.exe" -Verb RunAs -ArgumentList $RelaunchArgs -PassThru
    }
    catch
    {
        $Error[0] # Dump details about the last error
        PrintMessageAndExit $UiStrings.ErrorLaunchAdminFailed $ErrorCodes.LaunchAdminFailed
    }

    while (!($AdminProcess.HasExited))
    {
        Start-Sleep -Seconds 2
    }

    # Check if all elevated operations were successful
    if ($NeedDeveloperLicense)
    {
        if (CheckIfNeedDeveloperLicense)
        {
            PrintMessageAndExit $UiStrings.ErrorGetDeveloperLicenseFailed $ErrorCodes.GetDeveloperLicenseFailed
        }
        else
        {
            Write-Host $UiStrings.AcquireLicenseSuccessful
        }
    }
    if ($NeedInstallCertificate)
    {
        $Signature = Get-AuthenticodeSignature $DeveloperPackagePath -Verbose
        if ($Signature.Status -ne "Valid")
        {
            PrintMessageAndExit ($UiStrings.ErrorInstallCertificateFailed -f $Signature.Status) $ErrorCodes.InstallCertificateFailed
        }
        else
        {
            Write-Host $UiStrings.InstallCertificateSuccessful
        }
    }
}

#
# Finds all applicable dependency packages according to OS architecture, and
# installs the developer package with its dependencies.  The expected layout
# of dependencies is:
#
# <current dir>
#     \Dependencies
#         <Architecture neutral dependencies>.appx
#         \x86
#             <x86 dependencies>.appx
#         \x64
#             <x64 dependencies>.appx
#         \arm
#             <arm dependencies>.appx
#
function InstallPackageWithDependencies
{
    $DependencyPackagesDir = (Join-Path $ScriptDir "Dependencies")
    $DependencyPackages = @()
    if (Test-Path $DependencyPackagesDir)
    {
        # Get architecture-neutral dependencies
        $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "*.appx") | Where-Object { $_.Mode -NotMatch "d" }

        # Get architecture-specific dependencies
        if (($Env:Processor_Architecture -eq "x86" -or $Env:Processor_Architecture -eq "amd64") -and (Test-Path (Join-Path $DependencyPackagesDir "x86")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x86\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if (($Env:Processor_Architecture -eq "amd64") -and (Test-Path (Join-Path $DependencyPackagesDir "x64")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x64\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if (($Env:Processor_Architecture -eq "arm") -and (Test-Path (Join-Path $DependencyPackagesDir "arm")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "arm\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        }
    }
    Write-Host $UiStrings.InstallingPackage

    $AddPackageSucceeded = $False
    try
    {
        if ($DependencyPackages.FullName.Count -gt 0)
        {
            Write-Host $UiStrings.DependenciesFound
            $DependencyPackages.FullName
            Add-AppxPackage -Path $DeveloperPackagePath.FullName -DependencyPath $DependencyPackages.FullName -ForceApplicationShutdown
        }
        else
        {
            Add-AppxPackage -Path $DeveloperPackagePath.FullName -ForceApplicationShutdown
        }
        $AddPackageSucceeded = $?
    }
    catch
    {
        $Error[0] # Dump details about the last error
    }

    if (!$AddPackageSucceeded)
    {
        if ($NeedInstallCertificate)
        {
            PrintMessageAndExit $UiStrings.ErrorAddPackageFailedWithCert $ErrorCodes.AddPackageFailed
        }
        else
        {
            PrintMessageAndExit $UiStrings.ErrorAddPackageFailed $ErrorCodes.AddPackageFailed
        }
    }
}

#
# Main script logic when the user launches the script without parameters.
#
function DoStandardOperations
{
    # List all .appx files in the script directory
    $PackagePath = Get-ChildItem (Join-Path $ScriptDir "*.appx") | Where-Object { $_.Mode -NotMatch "d" }

    # List all .appxbundle files in the script directory
    $BundlePath = Get-ChildItem (Join-Path $ScriptDir "*.appxbundle") | Where-Object { $_.Mode -NotMatch "d" }

    $NumberOfPackages = $PackagePath.Count + $BundlePath.Count;

    # There must be exactly 1 package/bundle
    if ($NumberOfPackages -lt 1)
    {
        PrintMessageAndExit $UiStrings.ErrorNoPackageFound $ErrorCodes.NoPackageFound
    }
    elseif ($NumberOfPackages -gt 1)
    {
        PrintMessageAndExit $UiStrings.ErrorManyPackagesFound $ErrorCodes.ManyPackagesFound
    }

    if ($PackagePath.Count -eq 1)
    {
        $DeveloperPackagePath = $PackagePath
        Write-Host ($UiStrings.PackageFound -f $DeveloperPackagePath.FullName)
    }
    else
    {
        $DeveloperPackagePath = $BundlePath
        Write-Host ($UiStrings.BundleFound -f $DeveloperPackagePath.FullName)
    }

    # The package must be signed
    $PackageSignature = Get-AuthenticodeSignature $DeveloperPackagePath
    $PackageCertificate = $PackageSignature.SignerCertificate
    if (!$PackageCertificate)
    {
        PrintMessageAndExit $UiStrings.ErrorPackageUnsigned $ErrorCodes.PackageUnsigned
    }

    # Test if the package signature is trusted.  If not, the corresponding certificate
    # needs to be present in the current directory and needs to be installed.
    $NeedInstallCertificate = ($PackageSignature.Status -ne "Valid")

    if ($NeedInstallCertificate)
    {
        # List all .cer files in the script directory
        $DeveloperCertificatePath = Get-ChildItem (Join-Path $ScriptDir "*.cer") | Where-Object { $_.Mode -NotMatch "d" }

        # There must be exactly 1 certificate
        if ($DeveloperCertificatePath.Count -lt 1)
        {
            PrintMessageAndExit $UiStrings.ErrorNoCertificateFound $ErrorCodes.NoCertificateFound
        }
        elseif ($DeveloperCertificatePath.Count -gt 1)
        {
            PrintMessageAndExit $UiStrings.ErrorManyCertificatesFound $ErrorCodes.ManyCertificatesFound
        }

        Write-Host ($UiStrings.CertificateFound -f $DeveloperCertificatePath.FullName)

        # The .cer file must have the format of a valid certificate
        ValidateCertificateFormat $DeveloperCertificatePath

        # The package signature must match the certificate file
        if ($PackageCertificate -ne (Get-PfxCertificate $DeveloperCertificatePath))
        {
            PrintMessageAndExit $UiStrings.ErrorCertificateMismatch $ErrorCodes.CertificateMismatch
        }
    }

    $NeedDeveloperLicense = CheckIfNeedDeveloperLicense

    # Relaunch the script elevated with the necessary parameters if needed
    if ($NeedDeveloperLicense -or $NeedInstallCertificate)
    {
        Write-Host $UiStrings.ElevateActions
        if ($NeedDeveloperLicense)
        {
            Write-Host $UiStrings.ElevateActionDevLicense
        }
        if ($NeedInstallCertificate)
        {
            Write-Host $UiStrings.ElevateActionCertificate
        }

        $IsAlreadyElevated = ([Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value -contains "S-1-5-32-544")
        if ($IsAlreadyElevated)
        {
            if ($Force -and $NeedDeveloperLicense)
            {
                PrintMessageAndExit $UiStrings.ErrorForceDeveloperLicense $ErrorCodes.ForceDeveloperLicense
            }
            if ($Force -and $NeedInstallCertificate)
            {
                Write-Warning $UiStrings.WarningInstallCert
            }
        }
        else
        {
            if ($Force)
            {
                PrintMessageAndExit $UiStrings.ErrorForceElevate $ErrorCodes.ForceElevate
            }
            else
            {
                Write-Host $UiStrings.ElevateActionsContinue
                Pause
            }
        }

        LaunchElevated
    }

    InstallPackageWithDependencies
}

#
# Main script entry point
#
if ($GetDeveloperLicense -or $CertificatePath)
{
    DoElevatedOperations
}
else
{
    DoStandardOperations
    PrintMessageAndExit $UiStrings.Success $ErrorCodes.Success
}

# SIG # Begin signature block
# MIIh7AYJKoZIhvcNAQcCoIIh3TCCIdkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDr6TQeGU6q8Gc6
# 4UyJ3BErCSyDb5bOOr9muAPuxnPhgKCCC4MwggULMIID86ADAgECAhMzAAAAe6KB
# C4cRq+f8AAAAAAB7MA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTAwHhcNMTQxMDAxMTgwNjM4WhcNMTYwMTAxMTgwNjM4WjCBgzEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjENMAsGA1UECxMETU9Q
# UjEeMBwGA1UEAxMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMIIBIjANBgkqhkiG9w0B
# AQEFAAOCAQ8AMIIBCgKCAQEAvQcxxth2EB1eNeHpmIf/xHv5hBJHStPFJ2Zp22w2
# nNOhA3CXNR09AyJfXIEL50eYNUaSPv035IjaKWFTJMd9iXVt9WcwDtqZ40mvXhVE
# IyRFFgVmHcDac0t+/HxA4SPZKYlGHAvdNz8gd97MD7tIaeAXcx/qOxYqkhsujIJJ
# OKAqkfCh2w/3fWqRLgVrimZlJghs5DJOT5DL6br8nBYxqgjIsp4c8QsCsBZdlXxK
# m+7DAolGOmGJ8GwTtg1m3hcURkrTyXnyx34N2x22kH5gItwtcNicDAMnN6xc8ydI
# WviJIaR0Gj4Da8UiqTd9s2dNxuScWaOIuy/Ev/9DUf1zPQIDAQABo4IBejCCAXYw
# HwYDVR0lBBgwFgYIKwYBBQUHAwMGCisGAQQBgjc9BgEwHQYDVR0OBBYEFE8LE+6Q
# o6azvj+qlES88piRTzIdMFEGA1UdEQRKMEikRjBEMQ0wCwYDVQQLEwRNT1BSMTMw
# MQYDVQQFEyozODA3Nis2OGQyZjhiYi0wYTNiLTQwYjQtOWYyNC1lYjdlOTQxOWQx
# NjAwHwYDVR0jBBgwFoAU5vxfe7siAFjkck619CF0IzLm76wwVgYDVR0fBE8wTTBL
# oEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljQ29kU2lnUENBXzIwMTAtMDctMDYuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggr
# BgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWND
# b2RTaWdQQ0FfMjAxMC0wNy0wNi5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0B
# AQsFAAOCAQEAL1QbJw93iIl4XlutFtrDwEs8JT/kMaquI7SOYeIwgVH+SI71MCMZ
# TcveYIhzmIcEQz3gi+6gC28dVa6Y0GeuADG+vu3thnUKkko63nE4tGH3wDvhMRbx
# /L8wYXp13zaEV3R/HaYCiukoMfWMkN+qWdGepYUmp+PAXFTl3dVd/4oxMTdbLf4t
# lx1QqOyGSAyRrbJmPB57RWEJrGfhfYInTwr8Sy7UF/mVMxF7qCYBPJJD5pngvKsK
# TXNRW3YSyiaJ1TXHutME/dy4jipqbcZXUUA9qjRIICpPnoFxyk1VhBpKePeG96WJ
# MV0lBi+tzLVoWe5RSzxIKyI2qxzQho7SiTCCBnAwggRYoAMCAQICCmEMUkwAAAAA
# AAMwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1
# dGhvcml0eSAyMDEwMB4XDTEwMDcwNjIwNDAxN1oXDTI1MDcwNjIwNTAxN1owfjEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWlj
# cm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMDCCASIwDQYJKoZIhvcNAQEBBQAD
# ggEPADCCAQoCggEBAOkOZFB5Z7XE4/0JAEyelKz3VmjqRNjPxVhPqaV2fG1FutM5
# krSkHvn5ZYLkF9KP/UScCOhlk84sVYS/fQjjLiuoQSsYt6JLbklMaxUH3tHSwoke
# cZTNtX9LtK8I2MyI1msXlDqTziY/7Ob+NJhX1R1dSfayKi7VhbtZP/iQtCuDdMor
# sztG4/BGScEXZlTJHL0dxFViV3L4Z7klIDTeXaallV6rKIDN1bKe5QO1Y9OyFMjB
# yIomCll/B+z/Du2AEjVMEqa+Ulv1ptrgiwtId9aFR9UQucboqu6Lai0FXGDGtCpb
# nCMcX0XjGhQebzfLGTOAaolNo2pmY3iT1TDPlR8CAwEAAaOCAeMwggHfMBAGCSsG
# AQQBgjcVAQQDAgEAMB0GA1UdDgQWBBTm/F97uyIAWORyTrX0IXQjMubvrDAZBgkr
# BgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUw
# AwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBN
# MEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0
# cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoG
# CCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01p
# Y1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDCBnQYDVR0gBIGVMIGSMIGPBgkrBgEE
# AYI3LgMwgYEwPQYIKwYBBQUHAgEWMWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9Q
# S0kvZG9jcy9DUFMvZGVmYXVsdC5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcA
# YQBsAF8AUABvAGwAaQBjAHkAXwBTAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZI
# hvcNAQELBQADggIBABp071dPKXvEFoV4uFDTIvwJnayCl/g0/yosl5US5eS/z7+T
# yOM0qduBuNweAL7SNW+v5X95lXflAtTx69jNTh4bYaLCWiMa8IyoYlFFZwjjPzwe
# k/gwhRfIOUCm1w6zISnlpaFpjCKTzHSY56FHQ/JTrMAPMGl//tIlIG1vYdPfB9XZ
# cgAsaYZ2PVHbpjlIyTdhbQfdUxnLp9Zhwr/ig6sP4GubldZ9KFGwiUpRpJpsyLcf
# ShoOaanX3MF+0Ulwqratu3JHYxf6ptaipobsqBBEm2O2smmJBsdGhnoYP+jFHSHV
# e/kCIy3FQcu/HUzIFu+xnH/8IktJim4V46Z/dlvRU3mRhZ3V0ts9czXzPK5UslJH
# asCqE5XSjhHamWdeMoz7N4XR3HWFnIfGWleFwr/dDY+Mmy3rtO7PJ9O1Xmn6pBYE
# AackZ3PPTU+23gVWl3r36VJN9HcFT4XG2Avxju1CCdENduMjVngiJja+yrGMbqod
# 5IXaRzNij6TJkTNfcR5Ar5hlySLoQiElihwtYNk3iUGJKhYP12E8lGhgUu/WR5mg
# gEDuFYF3PpzgUxgaUB04lZseZjMTJzkXeIc2zk7DX7L1PUdTtuDl2wthPSrXkizO
# N1o+QEIxpB8QCMJWnL8kXVECnWp50hfT2sGUjgd7JXFEqwZq5tTG3yOalnXFMYIV
# vzCCFbsCAQEwgZUwfjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMAITMwAA
# AHuigQuHEavn/AAAAAAAezANBglghkgBZQMEAgEFAKCBwjAZBgkqhkiG9w0BCQMx
# DAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkq
# hkiG9w0BCQQxIgQgg/pZZeE/1C2B77fYHkoDT3MzZQ2kNQTNDAPsgcHASjMwVgYK
# KwYBBAGCNwIBDDFIMEagLIAqAEEAZABkAC0AQQBwAHAARABlAHYAUABhAGMAawBh
# AGcAZQAuAHAAcwAxoRaAFGh0dHA6Ly9taWNyb3NvZnQuY29tMA0GCSqGSIb3DQEB
# AQUABIIBAKDQ+pcbeSwP16osA/t0G2lHZOz4OTxlSF1Zz6lJdmVbZsllR71Ilu9f
# cawPoLXB2btJ1LG+Zdv2gy7pKPauY6Lj/LX3OPDErxeNx7PbQyBU4TXy4sxlz+ID
# 3E+g9IkghAHWEtvcHYSme9zX36ror8PEki6/fZpOXSEj60hy/tfxqJbQrvO5acxa
# TdJFUjJ0CxfxvWOXJrV12rdmCHadYClHekXfzs+TIFCNe4numqSUFioKtThD2kN5
# sMAZV42cA7oq7vZL0Y5QQtEAW7xl4ILB85BEfiZ0WoYaXiFmct/f2ksjmECD6X76
# uLI++TsuALzUhiZM8dbXeJsTxgVI0Y6hghM1MIITMQYKKwYBBAGCNwMDATGCEyEw
# ghMdBgkqhkiG9w0BBwKgghMOMIITCgIBAzEPMA0GCWCGSAFlAwQCAQUAMIIBNQYL
# KoZIhvcNAQkQAQSgggEkBIIBIDCCARwCAQEGCisGAQQBhFkKAwEwMTANBglghkgB
# ZQMEAgEFAAQga3GLIhcT+cLJR1a9038fzP+iV0W2u/5VFNdNCAkiFIMCBlTBKC2M
# uRgTMjAxNTAyMDkwNzI5MTguNzI0WjAHAgEBgAIB9KCBsaSBrjCBqzELMAkGA1UE
# BhMCVVMxCzAJBgNVBAgTAldBMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNVBAsTBE1PUFIxJzAlBgNVBAsTHm5D
# aXBoZXIgRFNFIEVTTjpCQkVDLTMwQ0EtMkRCRTElMCMGA1UEAxMcTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgU2VydmljZaCCDsAwggZxMIIEWaADAgECAgphCYEqAAAAAAAC
# MA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAxMDAeFw0xMDA3MDEyMTM2NTVaFw0yNTA3MDEyMTQ2NTVaMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
# MIIBCgKCAQEAqR0NvHcRijog7PwTl/X6f2mUa3RUENWlCgCChfvtfGhLLF/Fw+Vh
# wna3PmYrW/AVUycEMR9BGxqVHc4JE458YTBZsTBED/FgiIRUQwzXTbg4CLNC3ZOs
# 1nMwVyaCo0UN0Or1R4HNvyRgMlhgRvJYR4YyhB50YWeRX4FUsc+TTJLBxKZd0WET
# bijGGvmGgLvfYfxGwScdJGcSchohiq9LZIlQYrFd/XcfPfBXday9ikJNQFHRD5wG
# Pmd/9WbAA5ZEfu/QS/1u5ZrKsajyeioKMfDaTgaRtogINeh4HLDpmc085y9Euqf0
# 3GS9pAHBIAmTeM38vMDJRF1eFpwBBU8iTQIDAQABo4IB5jCCAeIwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFNVjOlyKMZDzQ3t8RhvFM2hahW1VMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/
# MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJ
# oEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01p
# Y1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYB
# BQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9v
# Q2VyQXV0XzIwMTAtMDYtMjMuY3J0MIGgBgNVHSABAf8EgZUwgZIwgY8GCSsGAQQB
# gjcuAzCBgTA9BggrBgEFBQcCARYxaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL1BL
# SS9kb2NzL0NQUy9kZWZhdWx0Lmh0bTBABggrBgEFBQcCAjA0HjIgHQBMAGUAZwBh
# AGwAXwBQAG8AbABpAGMAeQBfAFMAdABhAHQAZQBtAGUAbgB0AC4gHTANBgkqhkiG
# 9w0BAQsFAAOCAgEAB+aIUQ3ixuCYP4FxAz2do6Ehb7Prpsz1Mb7PBeKp/vpXbRkw
# s8LFZslq3/Xn8Hi9x6ieJeP5vO1rVFcIK1GCRBL7uVOMzPRgEop2zEBAQZvcXBf/
# XPleFzWYJFZLdO9CEMivv3/Gf/I3fVo/HPKZeUqRUgCvOA8X9S95gWXZqbVr5MfO
# 9sp6AG9LMEQkIjzP7QOllo9ZKby2/QThcJ8ySif9Va8v/rbljjO7Yl+a21dA6fHO
# mWaQjP9qYn/dxUoLkSbiOewZSnFjnXshbcOco6I8+n99lmqQeKZt0uGc+R38ONiU
# 9MalCpaGpL2eGq4EQoO4tYCbIjggtSXlZOz39L9+Y1klD3ouOVd2onGqBooPiRa6
# YacRy5rYDkeagMXQzafQ732D8OE7cQnfXXSYIghh2rBQHm+98eEA3+cxB6STOvdl
# R3jo+KhIq/fecn5ha293qYHLpwmsObvsxsvYgrRyzR30uIUBHoD7G4kqVDmyW9rI
# DVWZeodzOwjmmC3qjeAzLhIp9cAvVCch98isTtoouLGp25ayp0Kiyc8ZQU3ghvkq
# mqMRZjDTu3QyS99je/WZii8bxyGvWbWu3EQ8l1Bx16HSxVXjad5XwdHeMMD9zOZN
# +w2/XU/pnR4ZOC+8z1gFLu8NoFA12u8JJxzVs341Hgi62jbb01+P3nSISRIwggTS
# MIIDuqADAgECAhMzAAAAUGczu9f74RcaAAAAAABQMA0GCSqGSIb3DQEBCwUAMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTE0MDUyMzE3MjAwOVoXDTE1
# MDgyMzE3MjAwOVowgasxCzAJBgNVBAYTAlVTMQswCQYDVQQIEwJXQTEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMQ0wCwYD
# VQQLEwRNT1BSMScwJQYDVQQLEx5uQ2lwaGVyIERTRSBFU046QkJFQy0zMENBLTJE
# QkUxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCRIY8TvquljNudp7VisqDCXFVCo8HC
# EyCKb4joAJRmp2ur6chlKuuE34p8aq2CHsD7bNzEMeB0NOZuEPLP+w/x7c9lJOV1
# N5JWPfu3sQgNVgfvru3QPfGCl9En/oE4sPhrsOh9JKJMF+AAy+yPno34hhmDkMd/
# NqSXEsBKsDs9qK5Xg699Dfv2m34W9YJr8zZ0LYU3engn/BthrOqAO/JUt22o78D7
# /gw1/Xvdu6AzuMGBdmmSYpTpEAKzA+7wG8B+4m+oGrGaJLcG/H0YwzI8wKJ/XqtU
# hZazjf/Dh/fZBQtQVIjoEx1M37QBb1QoVURqEMXPoZ3yCbjbplTKPOkbAgMBAAGj
# ggEbMIIBFzAdBgNVHQ4EFgQUCARZ9qAvtyG0aAYBtudmgbD9QdswHwYDVR0jBBgw
# FoAU1WM6XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDov
# L2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENB
# XzIwMTAtMDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAx
# MC0wNy0wMS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDAN
# BgkqhkiG9w0BAQsFAAOCAQEAXlD7H173mgNrKxVGBtVH6VTn8VvVlxd6nn7b1OhX
# Vtk3x/otxVfI68ssK3k+fSAXwqsvEHvd3PkW+J0sG0MLf5737fR3AZwv2L16XKUw
# OfO0cTNtsqQgyApyjQZNac+AUxjjvqTSZKw3H4TQEQ5WAyUxTuiClBzoDVcz26zR
# 9BwwgNSlM7z2M2tlxKIWgDApn0dYQNdnEpugbCjJ0a9w+pRriRHqkxTP9ISdcQEQ
# 2eZ0MMHPZ4IBx7rZ0CAPBL6MKdrim34IhHBTWGj5RzVu57TazbRvUUWUue5+/tzG
# 5Yf+sIo/ING5ZZd4QguRrZO5cmbW9tMA2CfVEmnIUPokkaGCA3EwggJZAgEBMIHb
# oYGxpIGuMIGrMQswCQYDVQQGEwJVUzELMAkGA1UECBMCV0ExEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjENMAsGA1UECxME
# TU9QUjEnMCUGA1UECxMebkNpcGhlciBEU0UgRVNOOkJCRUMtMzBDQS0yREJFMSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiUKAQEwCQYFKw4D
# AhoFAAMVADIm2/E358tdnLwjkN9z70yROwvFoIHCMIG/pIG8MIG5MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMQ0wCwYDVQQLEwRNT1BSMScwJQYD
# VQQLEx5uQ2lwaGVyIE5UUyBFU046NTdGNi1DMUUwLTU1NEMxKzApBgNVBAMTIk1p
# Y3Jvc29mdCBUaW1lIFNvdXJjZSBNYXN0ZXIgQ2xvY2swDQYJKoZIhvcNAQEFBQAC
# BQDYgn0+MCIYDzIwMTUwMjA5MDAyNjM4WhgPMjAxNTAyMTAwMDI2MzhaMHcwPQYK
# KwYBBAGEWQoEATEvMC0wCgIFANiCfT4CAQAwCgIBAAICLJ8CAf8wBwIBAAICGJQw
# CgIFANiDzr4CAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAaAKMAgC
# AQACAxbjYKEKMAgCAQACAwehIDANBgkqhkiG9w0BAQUFAAOCAQEAVByNwYCSZn2l
# YR8ze2+XJOlkCrbYg1yHLZwsqF6/xKSoEVmFr4Qum4N53wyFeOZo/Vv5EsW1PnVY
# g1/YBrABvRahi7xml7vO9YblGTnWhZAZIjTWxhUZWVaNLv4dho2BchaYC7TBdPeK
# dnA5YhL0KAxg+pMvT2JHrLeM7TcbIVoKTriugpSMzdIwxmo3geTwBrjKr6f2rsvl
# EhdSabLXrH4QdC/AMlZdn4ekwuLo3C4SJA+xuvbtTmiSxLsHk1rFj5dmHqekJg+e
# 4z2v6UakP863hUGeU0zlLkdaJt9zkqiST680fsrLS/48gui8CBmvQA6NBb1pAa2e
# rLbOMxsayDGCAvUwggLxAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwAhMzAAAAUGczu9f74RcaAAAAAABQMA0GCWCGSAFlAwQCAQUAoIIBMjAaBgkq
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIOSImMiqoW37
# bttOjZB8bfOzXS2N0lmQsHZU/8ifWzf7MIHiBgsqhkiG9w0BCRACDDGB0jCBzzCB
# zDCBsQQUMibb8Tfny12cvCOQ33PvTJE7C8UwgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAFBnM7vX++EXGgAAAAAAUDAWBBRntMBu4G6+
# mRjwXRzfXJM1BpoPIjANBgkqhkiG9w0BAQsFAASCAQCP9ZdgMd+Q83hRrUAXC8SK
# 9VGpU1gh7BaW0TZ+hGp9MdqHf3zEc/aSKZtYDQyVYpbUzpQ/uz178o78kyaKkr2l
# z/kLaRLk7HAxSMpo99SrQxRTohjQ48RITwxzKWnENP4GWa2u4pwfk1Btj/Jl46gs
# XPCUyTGtf+3Xm16bD4hr8ib1mcGVWRB+cQ+Lro2i8p6dlR5Qm1zyw7iVfR3mvX0p
# nF3dDyo42Qj/2NnrW8Xx2UxFvaeLzmVQ01VZo/XYtzMlHffGpMIIBOKH+mg2iF7s
# mNN0n0Qn9fADFVCaYMrQ1Isrodw68mzRqU9AnJYUtMdqOyOLJD5nI1+FIvpVW7Hp
# SIG # End signature block
