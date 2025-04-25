using namespace System;
using namespace System.Collections;
using namespace System.Collections.Generic;
using namespace System.Collections.ObjectModel;
using namespace System.Diagnostics;
using namespace System.Diagnostics.CodeAnalysis;
using namespace System.IO;
using namespace System.Linq;
using namespace System.Management;
using namespace System.Management.Automation;
using namespace System.Net;
using namespace System.Security.Cryptography;
using namespace System.Security.Principal;
using namespace System.ServiceProcess;
using namespace System.Text;
using namespace System.Text.Json;
using namespace System.Text.RegularExpressions;
using namespace Microsoft.Automation;
using namespace Microsoft.PowerShell.Commands;

# cSpell:ignore uiaccess, idgs, Nuitka

[CmdletBinding(SupportsShouldProcess = $True)]
Param (
  # Specifies an optional string for the versioning format. Defaults to "v${major}.${minor}.${patch}".
  [Parameter(Mandatory = $False,
             HelpMessage = 'An optional string for the versioning format. Defaults to "v${major}.${minor}.${patch}".')]
  [ValidateNotNullOrWhiteSpace()]
  [string]
  $VersionFormat = 'v${major}.${minor}.${patch}',
  # Specifies a switch to Generate At Test Ations.
  [Parameter(Mandatory = $False,
             HelpMessage = 'A switch to Generate At Test Ations.')]
  [switch]
  $AtTest,
  # Specifies a secure string for the GitHub secret when doing GitHub actions.
  [Parameter(Mandatory = $False,
             HelpMessage = 'A secure string for the GitHub secret when doing GitHub actions.')]
  [ValidateNotNull()]
  [SecureString]
  $GitHubToken,
  # Specifies an override for the output build version. Should be a [System.Collection.Hashtable] or [System.Management.Automation.PSCustomObject].
  [Parameter(Mandatory = $False,
             HelpMessage = 'An override for the output build version. Should be a [System.Collection.Hashtable] or [System.Management.Automation.PSCustomObject].')]
  [Alias('Version', 'Override')]
  [ValidateNotNull()]
  [object]
  $VersionOverride,
  # Specifies an override for the override of the output build version. Specifies to use the last version if avaliable.
  [Parameter(Mandatory = $False,
             HelpMessage = 'An override for the override of the output build version. Specifies to use the last version if avaliable.')]
  [switch]
  $UseLastVersion
)

Begin {
  If ($PSBoundParameters.ContainsKey('VersionOverride')) {
    If ($VersionOverride -isnot [Hashtable] -or $VersionOverride -isnot [PSCustomObject] -or $VersionOverride -isnot [PSCustomObject]) {
      Throw "Parameter VersionOverride should be a [System.Collection.Hashtable] or [System.Management.Automation.PSCustomObject], got [$($VersionOverride.GetType().FullName)].";
    }
  }

  [bool] $script:Debug = ($PSBoundParameters.ContainsKey('Debug'));
  [bool] $script:Verbose = ($PSBoundParameters.ContainsKey('Verbose'));
  [bool] $script:WhatIf = ($PSBoundParameters.ContainsKey('WhatIf'));

  Push-Location -LiteralPath $PSScriptRoot -Debug:$script:Debug -Verbose:$script:Verbose;
  [string] $Platform = 'Windows';
  [string] $Arch = 'x86_64';
  [string] $env:BUILD_OUTPUT = '__main__.dist';
  [string] $env:Executable = 'RimSort.exe';

  If ($PSBoundParameters.ContainsKey('GitHubToken') -and $Null -ne $GitHubToken) {
    $env:GitHubToken = (ConvertFrom-SecureString -SecureString $GitHubToken -AsPlainText -Debug:$script:Debug -Verbose:$script:Verbose);
  } ElseIf ($PSBoundParameters.ContainsKey('GitHubToken') -and $Null -eq $GitHubToken) {
    $env:GitHubToken = (Read-Host -Prompt 'GitHub Token:' -MaskInput);
  } ElseIf (-not $PSBoundParameters.ContainsKey('GitHubToken') -and $Null -eq $GitHubToken -and $Null -ne $env:GitHubToken) {
    $env:GitHubToken = $env:GitHubToken;
  }

  [FileInfo[]] $PythonEnvActivatePath = @(Get-ChildItem -Path "$($PWD.Path)\*\Scripts\activate.ps1" -Debug:$script:Debug -Verbose:$script:Verbose);
  & ($PythonEnvActivatePath | Select-Object -First 1).FullName 2>&1 | Out-Host;

  Function Invoke-Process {
    [CmdletBinding(SupportsShouldProcess = $True)]
    Param(
      # Specifies the command info object to execute the process with.
      [Parameter(Mandatory = $True,
                 HelpMessage = 'The command info object to execute the process with.')]
      [ValidateNotNull()]
      [CommandInfo]
      $Command,
      # Specifies the collection of arguments to run the command with.
      [Parameter(Mandatory = $False,
                 HelpMessage = 'The collection of arguments to run the command with.')]
      [AllowEmptyCollection()]
      [string[]]
      $Arguments = @(),
      # Specifies the string to pipe into the command if needed.
      [Parameter(Mandatory = $False,
                 HelpMessage = 'The string to pipe into the command if needed.')]
      [ValidateNotNull()]
      [object]
      $Pipe,
      # Specifies a switch to output the data normally.
      [Parameter(Mandatory = $False,
                 HelpMessage = 'A switch to output the data normally.')]
      [switch]
      $Raw
    )

    Begin {
      [string[]] $Output = $Null;
    } Process {
      If ($PSBoundParameters.ContainsKey('Pipe')) {
        If ($Raw.IsPresent) {
          If ($PSCmdlet.ShouldProcess("$($Pipe) | & `"$($Command.Source)`" $($Arguments -join ' ') | Out-Host", 'Start-Process')) {
            $Pipe | & "$($Command.Source)" $Arguments | Out-Host;
          }
        } Else {
          If ($PSCmdlet.ShouldProcess("$($Pipe) | & `"$($Command.Source)`" $($Arguments -join ' ') 2>&1", 'Start-Process')) {
            $Output = @($Pipe | & "$($Command.Source)" $Arguments 2>&1);
          }
        }
      } Else {
        If ($Raw.IsPresent) {
          If ($PSCmdlet.ShouldProcess("& `"$($Command.Source)`" $($Arguments -join ' ') | Out-Host", 'Start-Process')) {
            & "$($Command.Source)" $Arguments | Out-Host;
          }
        } Else {
          If ($PSCmdlet.ShouldProcess("& `"$($Command.Source)`" $($Arguments -join ' ') 2>&1", 'Start-Process')) {
            $Output = @(& "$($Command.Source)" $Arguments 2>&1);
          }
        }
      }
    } End {
      Write-Output -NoEnumerate -InputObject $Output;
    }
  }
} Process {
  Try {
    # Add submodules to pythonpath

    If ($IsWindows) {
      $env:PYTHONPATH = "$env:PYTHONPATH;$($PWD.Path)\submodules\SteamworksPy"
    } Else {
      $env:PYTHONPATH = "$env:PYTHONPATH;$($PWD.Path)/submodules/SteamworksPy"
    }

    # Remove problematic brew libs

    If ($IsMacOS) {
      [CommandInfo] $Brew = (Get-Command -Name 'brew' -Debug:$script:Debug -Verbose:$script:Verbose);
      Invoke-Process -Command $Brew -Arguments @('remove', '--force', '--ignore-dependencies', "'openssl@3'") -Raw -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose
      Invoke-Process -Command $Brew -Arguments @('cleanup', "'openssl@3'") -Raw -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose
    }

    # Get semantic version
    Function Get-SemanticVersion {
      [CmdletBinding()]
      [OutputType([PSCustomObject])]
      Param(
        # Specifies an override for the override of the output build version. Specifies to use the last version if avaliable.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'An override for the override of the output build version. Specifies to use the last version if avaliable.')]
        [switch]
        $UseLastVersion,
        [Parameter(Mandatory = $False,
                   HelpMessage = 'The prefix to use to identify tags')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $TagPrefix = 'v',
        [Parameter(Mandatory = $False,
                   HelpMessage = "A string which, if present in a git commit, indicates that a change represents a major (breaking) change, supports regular expressions wrapped with '/'")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MajorPattern = '(MAJOR)',
        [Parameter(Mandatory = $False,
                   HelpMessage = 'A string which indicates the flags used by the `MajorPattern` regular expression. Supported flags: idgs')]
        [ValidatePattern('[idgs]{1,4}')]
        [string]
        $MajorRegExpFlags = [string]::Empty,
        [Parameter(Mandatory = $False,
                   HelpMessage = "Same as above except indicating a minor change, supports regular expressions wrapped with '/'")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MinorPattern = '(MINOR)',
        [Parameter(Mandatory = $False,
                   HelpMessage = 'A string which indicates the flags used by the `MinorPattern` regular expression. Supported flags: idgs')]
        [ValidatePattern('[idgs]{0,4}')]
        [string]
        $MinorRegExpFlags = [string]::Empty,
        [Parameter(Mandatory = $False,
                   HelpMessage = 'A string to determine the format of the version output')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $VersionFormat = '${major}.${minor}.${patch}-prerelease${increment}',
        [Parameter(Mandatory = $False,
                   HelpMessage = "Optional path to check for changes. If any changes are detected in the path the 'changed' output will true. Enter multiple paths separated by spaces.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $ChangePath = @('src/my-service'),
        [Parameter(Mandatory = $False,
                   HelpMessage = 'Named version, will be used as suffix for name version tag')]
        [AllowEmptyString()]
        [AllowNull()]
        [string]
        $Namespace = $Null,
        [Parameter(Mandatory = $False,
                   HelpMessage = 'If this is set to true, *every* commit will be treated as a new version.')]
        [switch]
        $BumpEachCommit,
        [Parameter(Mandatory = $False,
                   HelpMessage = 'If true, the body of commits will also be searched for major/minor patterns to determine the version type.')]
        [switch]
        $SearchCommitBody,
        [Parameter(Mandatory = $False,
                   HelpMessage = 'If BumpEachCommit is also set to true, setting this value will cause the version to increment only if the pattern specified is matched.')]
        [AllowEmptyString()]
        [AllowNull()]
        [string]
        $BumpEachCommitPatchPattern = [string]::Empty,
        [Parameter(Mandatory = $False,
                   HelpMessage = "The output method used to generate list of users, 'csv' or 'json'.")]
        [ValidateSet('csv', 'json')]
        [string]
        $UserFormatType = 'csv',
        [Parameter(Mandatory = $False,
                   HelpMessage = 'Prevents pre-v1.0.0 version from automatically incrementing the major version. If enabled, when the major version is 0, major releases will be treated as minor and minor as patch. Note that the version_type output is unchanged.')]
        [switch]
        $DisablePrereleaseMode,
        [Parameter(Mandatory = $False,
                   HelpMessage = 'If true, the branch will be used to select the maximum version.')]
        [switch]
        $VersionFromBranch
      )

      Begin {
        [PSCustomObject] $Output = [PSCustomObject]::new();
        [int]      $Major = 0;
        [int]      $Minor = 0;
        [int]      $Patch = 0;
        [int]      $Increment = 0;
        [string]   $VersionType = [string]::Empty;
        [string]   $FormattedVersion = [string]::Empty;
        [string]   $VersionTag = [string]::Empty;
        [string[]] $Authors = @();
        [bool]     $Changed = $False;
        [bool]     $IsTagged = $False;
        [string]   $PreviousCommit = [string]::Empty;
        [string]   $PreviousVersion = [string]::Empty;
        [string]   $CurrentCommit = [string]::Empty;
        [string[]] $DebugOutput = @();
        [string]   $Repository = [string]::Empty;

        If (-not ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY))) {
          $Repository = $env:GITHUB_REPOSITORY;
        } Else {
          $Repository = $PSScriptRoot;
        }

        If (-not $Changed) {
          Write-Information -MessageData 'No changes detected for this commit';
        }

        Write-Information -MessageData "Version is $($FormattedVersion)";

        If (-not [string]::IsNullOrWhiteSpace($Repository)) {
          Write-Information -MessageData "To create a release for this version, go to https://github.com/$($Repository)/releases/new?tag=$($VersionTag)&target=$(($CurrentCommit -split '/')[-1])"
        }

        [string] $NamespaceSeperator = '-';
        [PSCustomObject] $Config = [PSCustomObject]::new();
        $Config | Add-Member -MemberType NoteProperty -Name 'MajorPattern'               -Value $MajorPattern                           -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'MajorRegExpFlags'           -Value $MajorRegExpFlags                       -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'MinorPattern'               -Value $MinorPattern                           -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'MinorRegExpFlags'           -Value $MinorRegExpFlags                       -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'ChangePath'                 -Value $ChangePath                             -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'Namespace'                  -Value $Namespace                              -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'BumpEachCommit'             -Value ($BumpEachCommit.IsPresent)             -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'TagPrefix'                  -Value $TagPrefix                              -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'VersionFormat'              -Value $VersionFormat                          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'BumpEachCommitPatchPattern' -Value $BumpEachCommitPatchPattern             -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'UserFormatType'             -Value $UserFormatType                         -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'EnablePrereleaseMode'       -Value (-not $DisablePrereleaseMode.IsPresent) -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'VersionFromBranch'          -Value ($VersionFromBranch.IsPresent)          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'UseBranches'                -Value $False                                  -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'SearchCommitBody'           -Value ($SearchCommitBody.IsPresent)           -Debug:$script:Debug -Verbose:$script:Verbose;
        $Config | Add-Member -MemberType NoteProperty -Name 'Git'                        -Value (Get-Command -Name 'git')               -Debug:$script:Debug -Verbose:$script:Verbose;
      } Process {
        Function Test-IsEmptyRepo {
          [CmdletBinding(SupportsShouldProcess = $True)]
          [OutputType([bool])]
          Param(
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [object] $Output = $False;
          } Process {
            [string] $Command = (Invoke-Process -Command $Config.Git -Arguments @('rev-parse','HEAD') -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            If ($Command -is [string[]] -or $Command -is [object[]]) {
              $Command = ($Command -join "`n").Trim();
            }

            If ($Command -isnot [string] -or $Command -notmatch '^[a-f0-9]{40}$') {
              $Output = $True;
            }
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Resolve-CurrentCommit {
          [SuppressMessage('PSUseDeclaredVarsMoreThanAssignments', '', MessageId='global:ResolveCurrentCommitError', Justification='This is because of the global variable.')]
          [SuppressMessage('PSAvoidGlobalVars', 'global:ResolveCurrentCommitError', Justification='Used for debugging.')]
          [CmdletBinding(SupportsShouldProcess = $True)]
          [OutputType([string])]
          Param(
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [object] $Output = @();
          } Process {
            $Output = (Invoke-Process -Command $Config.Git -Arguments @('rev-parse','HEAD') -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            If ($Output -is [string[]] -or $Output -is [object[]]) {
              $Output = ($Output -join "`n").Trim();
            }

            If ($Output -isnot [string] -or $Output -notmatch '^[a-f0-9]{40}$') {
              [string] $MessageBase = 'Failed to run the command "git rev-parse HEAD".'
              If ($script:Debug) {
                $global:ResolveCurrentCommitError = $Output;
                Throw [InvalidOperationException]::new("$($MessageBase) Get the command output at `"`$global:.ResolveCurrentCommitError`"");
              } Else {
                Throw [InvalidOperationException]::new($MessageBase);
              }
            }
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Resolve-LastRelease {
          [SuppressMessage('PSUseDeclaredVarsMoreThanAssignments', '', MessageId='global:ResolveLastReleaseTryCatchBlockError', Justification='This is because of the global variable.')]
          [SuppressMessage('PSAvoidGlobalVars', 'global:ResolveLastReleaseTryCatchBlockError', Justification='Used for debugging.')]
          [CmdletBinding(SupportsShouldProcess = $True)]
          [OutputType([PSCustomObject])]
          Param(
            # Specifies a PSCustomObject determining the current commit.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject determining the current commit.')]
            [ValidateNotNull()]
            [PSCustomObject]
            $CurrentCommit,
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [PSCustomObject] $Output = [PSCustomObject]::new();
            [int] $Major = $Null;
            [int] $Minor = $Null;
            [int] $Patch = $Null;
            [string] $Root = '';
            [bool] $IsTagged = $False;
            [string] $NamespaceSeperator = '-';
            [string] $TagFormat = "$($Config.TagPrefix)[0-9]*.[0-9]*.[0-9]*";

            If (-not [string]::IsNullOrWhiteSpace($Config.Namespace)) {
              $TagFormat = "$($Config.TagPrefix)[0-9]*.[0-9]*.[0-9]*$($NamespaceSeperator)$($Config.Namespace)";
            }

            If ($Config.VersionFromBranch -and $Config.OnVersionBranch) {
              If ($Null -eq $Config.BranchNameMajor -or $Config.BranchNameMinor -eq -1) {
                $TagFormat = ($TagFormat -replace '\[0-9\]\*\.\[0-9\]\*\.\[0-9\]*', "$($Config.BranchNameMajor).[0-9]*.[0-9]*");
              } Else {
                $TagFormat = ($TagFormat -replace '\[0-9\]\*\.\[0-9\]\*\.\[0-9\]*', "$($Config.BranchNameMajor).$($Config.BranchNameMinor).[0-9]*");
              }
            }
          } Process {
            [string] $CurrentTag = (Invoke-Process -Command $Config.Git -Arguments @('tag', '--points-at', "$($CurrentCommit)", "'$($TagFormat)'") -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            $IsTagged = (-not [string]::IsNullOrWhiteSpace($CurrentTag));

            If ($IsTagged) {
              $CurrentTag.Trim();
            }

            [int] $CurrentMajor = $Null;
            [int] $CurrentMinor = $Null;
            [int] $CurrentPatch = $Null;
            [Version] $ParsedCurrentTag = $Null;
            [string] $TrimmedCurrentTag = ($CurrentTag -replace "^$([Regex]::Escape($Config.TagPrefix))", '' -replace "$($NamespaceSeperator)$([Regex]::Escape($Config.Namespace))$", '');

            If ([Version]::TryParse($TrimmedCurrentTag, [Ref] $ParsedCurrentTag)) {
              $CurrentMajor = $ParsedTag.Major;
              $CurrentMinor = $ParsedTag.Minor;
              $CurrentPatch = $ParsedTag.Build;
            }

            [int] $TagsCount = 0;
            [string] $Tag = [string]::Empty;
            [string] $Command = $Null;
            [string[]] $Tags = @();

            Try {
              [string] $RefPrefixPattern = 'refs/tags/';

              If ($Config.UseBranches) {
                $RefPrefixPattern = 'refs/heads/';
              }

              If (-not [string]::IsNullOrWhiteSpace($CurrentTag)) {
                # If we already have the current branch tagged, we are checking for the previous one
                # so that we will have an accurate increment (assuming the new tag is the expected one)
                $Command = (Invoke-Process -Command $Config.Git -Arguments @('for-each-ref', '--sort=-v:*refname', '--format=%(refname:short)', "--merged=$($CurrentCommit)", "$($RefPrefixPattern)$($TagFormat)") -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose).Trim();
                $Tags = @($Command -split "`n| ");
                $TagsCount = $Tags.Length;
                $Tag = ($Tags | Where-Object { $_ -match $TagFormat -and $_ -ne $CurrentTag } | Select-Object -First 1);
              } Else {
                $Command = (Invoke-Process -Command $Config.Git -Arguments @('for-each-ref', '--sort=-v:*refname', '--format=%(refname:short)', "--merged=$($CurrentCommit)", "$($RefPrefixPattern)$($TagFormat)") -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose).Trim();
                $Tags = @($Command -split "`n| ");
                $TagsCount = $Tags.Length;
                $Tag = ($Tags | Where-Object { $_ -match $TagFormat } | Select-Object -First 1);
              }

              If ([string]::IsNullOrWhiteSpace($Tag)) {
                $Tag = [string]::Empty;
              }

              $Tag = $Tag.Trim();
            } Catch {
              If ($script:Debug) {
                $global:ResolveLastReleaseTryCatchBlockError = $_;
              }
              $Tag = [string]::Empty;
            }

            [Version] $ParsedTag = $Null;

            If ([string]::IsNullOrWhiteSpace($Tag)) {
              If ([string]::IsNullOrWhiteSpace("$(Invoke-Process -Command $Config.Git -Arguments @('remote') -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose)")) {

                # Since there is no remote, we assume that there are no other tags to pull. In
                # practice this isn't likely to happen, but it keeps the test output from being
                # polluted with a bunch of warnings.

                If ($TagsCount -gt 0) {
                  Write-Warning -Message "None of the $($TagsCount) tags(s) found were valid version tags for the present configuration. If this is unexpected, check to ensure that the configuration is correct and matches the tag format you are using.";
                } Else {
                  Write-Warning -Message "No tags are present for this repository. If this is unexpected, check to ensure that tags have been pulled from the remote.";
                }
              }

              $TrimmedTag = ($Tag -replace "^$([Regex]::Escape($Config.TagPrefix))", '' -replace "$($NamespaceSeperator)$([Regex]::Escape($Config.Namespace))$", '');
              $ParsedTag = $Null;

              If ([Version]::TryParse($TrimmedTag, [Ref] $ParsedTag)) {
                $Major = $ParsedTag.Major;
                $Minor = $ParsedTag.Minor;
                $Patch = $ParsedTag.Build;
              }

              $Root = '';
            } Else {
              $TrimmedTag = ($Tag -replace "^$([Regex]::Escape($Config.TagPrefix))", '' -replace "$($NamespaceSeperator)$([Regex]::Escape($Config.Namespace))$", '');
              $ParsedTag = $Null;

              If ([Version]::TryParse($TrimmedTag, [Ref] $ParsedTag)) {
                $Major = $ParsedTag.Major;
                $Minor = $ParsedTag.Minor;
                $Patch = $ParsedTag.Build;
              }

              $Root = (Invoke-Process -Command $Config.Git -Arguments @('merge-base', "$($Tag)", "$($CurrentCommit)") -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            }
          } End {
            $Output | Add-Member -MemberType NoteProperty -Name 'Major'        -Value $Major         -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Minor'        -Value $Minor         -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Patch'        -Value $Patch         -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Hash'         -Value ($Root.Trim()) -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'CurrentMajor' -Value $CurrentMajor  -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'CurrentMinor' -Value $CurrentMinor  -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'CurrentPatch' -Value $CurrentPatch  -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'IsTagged'     -Value $IsTagged      -Debug:$script:Debug -Verbose:$script:Verbose;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Get-AllCommits {
          [SuppressMessage('PSUseSingularNouns', 'Get-AllCommits')]
          [CmdletBinding(SupportsShouldProcess = $True)]
          [OutputType([PSCustomObject])]
          Param(
            # Specifies the hash for the last release.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'The hash for the last release.')]
            [AllowEmptyString()]
            [AllowNull()]
            [string]
            $EndHash,
            # Specifies a PSCustomObject determining the current commit.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject determining the current commit.')]
            [ValidateNotNull()]
            [string]
            $StartHash,
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [PSCustomObject] $Output = [PSCustomObject]::new();
            [PSCustomObject[]] $Commits = @();
            [bool] $Changed = $True;
            [string] $LogSplitter = '@@@START_RECORD'
            [string[][]] $FormatPlaceholders = @(
                @('hash', '%H'),
                @('subject', '%s'),
                @('body', '%b'),
                @('author', '%an'),
                @('authorEmail', '%ae'),
                @('authorDate', '%aI'),
                @('committer', '%cn'),
                @('committerEmail', '%ce'),
                @('committerDate', '%cI'),
                @('tags', '%d')
            );
            [string] $Pretty = "$($LogSplitter)%n$(@($FormatPlaceholders | ForEach-Object { Return "@@@$($_[0])%n$($_[1])" } ) -join '%n')";
            [string] $HashCheck = "$($StartHash)..$($EndHash)";
            If ([string]::IsNullOrWhiteSpace($StartHash)) {
              $HashCheck = $EndHash;
            }
            [string[]] $LogCommand = @('log', "--pretty=`"$($Pretty)`"", '--author-date-order', "$($HashCheck)");
            If (-not [string]::IsNullOrWhiteSpace($Config.ChangePath)) {
              $LogCommand += @('--');
              $LogCommand += $Config.ChangePath
            }
          } Process {
            [string] $Log = (Invoke-Process -Command $Config.Git -Arguments $LogCommand -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            [string[]] $Entries = @($Log -split $LogSplitter | Select-Object -Skip 1);
            ForEach ($Entry in $Entries) {
              [HashTable] $Fields = [ordered]@{};
              ForEach ($Value in @($Entry -split '@@@' | Select-Object -Skip 1)) {
                [int] $FirstLine = $Value.IndexOf("`n");
                If ($FirstLine -eq -1) {
                  $FirstLine = $Value.IndexOf(" ");
                }
                [string] $Key = $Value.SubString(0, $FirstLine);
                $Fields[$Key] = $Value.SubString($FirstLine + 1).Trim();
              }
              [string[]] $Tags = @($Fields.tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('tags: ') } | ForEach-Object { $_.SubString(5).Trim() });

              [PSCustomObject] $CommitInfo = [PSCustomObject]::new();
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Hash'           -Value ($Fields.hash)                             -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Subject'        -Value ($Fields.subject)                          -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Body'           -Value ($Fields.body)                             -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Author'         -Value ($Fields.author)                           -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'AuthorEmail'    -Value ($Fields.authorEmail)                      -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Date'           -Value ([DateTime]::Parse($Fields.authorDate))    -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Committer'      -Value ($Fields.committer)                        -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'CommitterEmail' -Value ($Fields.committerEmail)                   -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'CommitterDate'  -Value ([DateTime]::Parse($Fields.committerDate)) -Debug:$script:Debug -Verbose:$script:Verbose;
              $CommitInfo | Add-Member -MemberType NoteProperty -Name 'Tags'           -Value $Tags                                      -Debug:$script:Debug -Verbose:$script:Verbose;
              $Commits += $CommitInfo;
            }
          } End {
            $Output | Add-Member -MemberType NoteProperty -Name 'Changed' -Value $Changed -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Commits' -Value $Commits -Debug:$script:Debug -Verbose:$script:Verbose;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Invoke-ClassifyVersion {
          [CmdletBinding()]
          [OutputType([PSCustomObject])]
          Param(
            # Specifies a PSCustomObject that determines the last release.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the last release.')]
            [PSCustomObject]
            $LastRelease,
            # Specifies a PSCustomObject that determines the set of commits in the repository.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the set of commits in the repository.')]
            [PSCustomObject]
            $CommitsSet,
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            Function Get-ParsedPattern {
              [CmdletBinding()]
              [OutputType([PSCustomObject])]
              Param(
                # Specifies a pattern to test against.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A pattern to test against.')]
                [AllowEmptyString()]
                [ValidateNotNull()]
                [string]
                $Pattern,
                # Specifies a set of flags to test against.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A set of flags to test against..')]
                [AllowEmptyString()]
                [ValidatePattern('[idgs]{0,4}')]
                [string]
                $Flags,
                # Specifies a PSCustomObject that determines the config of the commands.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
                [PSCustomObject]
                $Config
              )

              Begin {
                [PSCustomObject] $Output = [PSCustomObject]::new();
                [ScriptBlock] $ScriptBlock = $Null;
              } Process {
                If ($Pattern -match '^\/.+\/[i]*$') {
                  [int] $RegexEnd = $Pattern.LastIndexOf('/');
                  [string] $ParsedFlags = $Pattern.Substring($RegexEnd + 1);
                  If ([string]::IsNullOrWhiteSpace($ParsedFlags)) {
                    $ParsedFlags = $Flags;
                  }

                  [Regex] $script:Regex = [Regex]::new($Pattern.Substring(1, $RegexEnd), $ParsedFlags);
                  If ($Config.SearchCommitBody) {
                    $ScriptBlock = {
                      Param(
                        # Specifies a PSCustomObject containing commit information.
                        [Parameter(Mandatory = $True,
                                   HelpMessage = 'A PSCustomObject containing commit information.')]
                        [PSCustomObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Regex -or $Commit.Body -match $script:Regex;
                    }
                  } Else {
                    $ScriptBlock = {
                      Param(
                        # Specifies a PSCustomObject containing commit information.
                        [Parameter(Mandatory = $True,
                                   HelpMessage = 'A PSCustomObject containing commit information.')]
                        [PSCustomObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Regex;
                    }
                  }
                } Else {
                  [string] $script:Pattern = $Pattern
                  If ($Config.SearchCommitBody) {
                    $ScriptBlock = {
                      Param(
                        # Specifies a PSCustomObject containing commit information.
                        [Parameter(Mandatory = $True,
                                   HelpMessage = 'A PSCustomObject containing commit information.')]
                        [PSCustomObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Pattern -or $Commit.Body -match $script:Pattern;
                    }
                  } Else {
                    $ScriptBlock = {
                      Param(
                        # Specifies a PSCustomObject containing commit information.
                        [Parameter(Mandatory = $True,
                                   HelpMessage = 'A PSCustomObject containing commit information.')]
                        [PSCustomObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Pattern;
                    }
                  }
                }
              } End {
                $Output | Add-Member -MemberType NoteProperty -Name 'ScriptBlock' -Value ($ScriptBlock) -Debug:$script:Debug -Verbose:$script:Verbose;
                Write-Output -InputObject $Output;
              }
            }

            Function Get-NextVersion {
              [CmdletBinding()]
              [OutputType([PSCustomObject])]
              Param(
                # Specifies a PSCustomObject that determines the current release information.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSCustomObject that determines the current release information.')]
                [PSCustomObject]
                $Current,
                # Specifies a string that determines the version type.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A string that determines the version type.')]
                [ValidateSet('Major', 'Minor', 'Patch', 'None')]
                [string]
                $Type
              )

              Begin {
                [PSCustomObject] $Output = [PSCustomObject]::new();
                [int] $Major = 0;
                [int] $Minor = 0;
                [int] $Patch = 0;
              } Process {
                If ($EnablePrereleaseMode -and $Current.Major -eq 0) {
                  If ($Type -eq 'Major') {
                    $Major = $Current.Major;
                    $Minor = $Current.Minor + 1;
                    $Patch = 0;
                  } ELseIf ($Type -eq 'Minor' -or $Type -eq 'Patch') {
                    $Major = $Current.Minor;
                    $Minor = $Current.Minor;
                    $Patch = $Current.Patch + 1;
                  } ELseIf ($Type -eq 'None') {
                    $Major = $Current.Minor;
                    $Minor = $Current.Minor;
                    $Patch = $Current.Patch;
                  } ELse {
                    Throw [Exception]::new("Unknown change type: $($Type)")
                  }
                } Else {
                  If ($Type -eq 'Major') {
                    $Major = $Current.Major + 1;
                    $Minor = 0;
                    $Patch = 0;
                  } ELseIf ($Type -eq 'Minor') {
                    $Major = $Current.Minor;
                    $Minor = $Current.Minor + 1;
                    $Patch = 0;
                  } ELseIf ($Type -eq 'Patch') {
                    $Major = $Current.Minor;
                    $Minor = $Current.Minor;
                    $Patch = $Current.Patch + 1;
                  } ELseIf ($Type -eq 'None') {
                    $Major = $Current.Minor;
                    $Minor = $Current.Minor;
                    $Patch = $Current.Patch;
                  } ELse {
                    Throw [Exception]::new("Unknown change type: $($Type)")
                  }
                }
              } End {
                $Output | Add-Member -MemberType NoteProperty -Name 'Major' -Value $Major -Debug:$script:Debug -Verbose:$script:Verbose;
                $Output | Add-Member -MemberType NoteProperty -Name 'Minor' -Value $Minor -Debug:$script:Debug -Verbose:$script:Verbose;
                $Output | Add-Member -MemberType NoteProperty -Name 'Patch' -Value $Patch -Debug:$script:Debug -Verbose:$script:Verbose;
                Write-Output -NoEnumerate -InputObject $Output;
              }
            }

            Function Resolve-CommitType {
              [CmdletBinding()]
              [OutputType([PSCustomObject])]
              Param(
                # Specifies a PSCustomObject that determines the last release.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSCustomObject that determines the last release.')]
                [PSCustomObject]
                $LastRelease,
                # Specifies a PSCustomObject that determines the current release information.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSCustomObject that determines the current release information.')]
                [PSCustomObject]
                $CommitsSet,
                # Specifies a ScriptBlock that checks against the major version.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A ScriptBlock that checks against the major version.')]
                [ScriptBlock]
                $MajorPattern,
                # Specifies a ScriptBlock that checks against the minor version.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A ScriptBlock that checks against the minor version.')]
                [ScriptBlock]
                $MinorPattern,
                # Specifies a ScriptBlock that checks against the patch version.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A ScriptBlock that checks against the patch version.')]
                [ScriptBlock]
                $PatchPattern,
                # Specifies a PSCustomObject that determines the config of the commands.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
                [PSCustomObject]
                $Config
              )

              Begin {
                [PSCustomObject] $Output = [PSCustomObject]::new();
                [string] $Type = 'None';
                [int] $Increment = 0;
                [bool] $Changed = $False;
              } Process {
                If ($CommitsSet.Commits.Length -ne 0) {
                  [List[PSCustomObject]] $Commits = [List[PSCustomObject]]::new($CommitsSet.Commits);
                  $Commits.Reverse();

                  If ($Config.BumpEachCommit) {
                    ForEach ($Commit in $Commits) {
                      If (Invoke-Command -ScriptBlock $MajorPattern -ArgumentList @($Commit) -Debug:$script:Debug -Verbose:$script:Verbose) {
                        $Type = 'Major';
                      } ElseIf (Invoke-Command -ScriptBlock $MinorPattern -ArgumentList @($Commit) -Debug:$script:Debug -Verbose:$script:Verbose) {
                        $Type = 'Major';
                      } ElseIf ((Invoke-Command -ScriptBlock $PatchPattern -ArgumentList @($Commit) -Debug:$script:Debug -Verbose:$script:Verbose) -or ($LastRelease.Major -eq 0 -and $LastRelease.Minor -eq 0 -and $LastRelease.Patch -eq 0 -and $Commits.Count -gt 0)) {
                        $Type = 'Patch';
                      } Else {
                        $Type = 'None';
                      }

                      $Changed = $True;
                    }
                  } Else {
                    [int] $Index = 1;
                    ForEach ($Commit in $Commits) {
                      If (Invoke-Command -ScriptBlock $MajorPattern -ArgumentList @($Commit) -Debug:$script:Debug -Verbose:$script:Verbose) {
                        $Type = 'Major';
                        $Increment = $Commits.Count - $Index;
                        $Changed = $CommitsSet.Changed;
                        Break;
                      }
                      $Index++;
                    }

                    If (-not $Changed) {
                      $Index = 1;
                      ForEach ($Commit in $Commits) {
                        If (Invoke-Command -ScriptBlock $MinorPattern -ArgumentList @($Commit) -Debug:$script:Debug -Verbose:$script:Verbose) {
                          $Type = 'Minor';
                          $Increment = $Commits.Count - $Index;
                          $Changed = $CommitsSet.Changed;
                          Break;
                        }
                        $Index++;
                      }

                      If (-not $Changed) {
                        $Type = 'Patch';
                        $Increment = $CommitsSet.Commits.Length - 1;
                        $Changed = $True;
                      }
                    }
                  }
                }
              } End {
                $Output | Add-Member -MemberType NoteProperty -Name "Type"      -Value $Type      -Debug:$script:Debug -Verbose:$script:Verbose;
                $Output | Add-Member -MemberType NoteProperty -Name "Increment" -Value $Increment -Debug:$script:Debug -Verbose:$script:Verbose;
                $Output | Add-Member -MemberType NoteProperty -Name "Changed"   -Value $Changed   -Debug:$script:Debug -Verbose:$script:Verbose;
                Write-Output -NoEnumerate -InputObject $Output;
              }
            }

            [PSCustomObject] $Output = [PSCustomObject]::new();
            [ScriptBlock] $MajorPattern = (Get-ParsedPattern -Pattern $Config.MajorPattern -Flags $Config.MajorRegExpFlags -Config $Config -Debug:$script:Debug -Verbose:$script:Verbose).ScriptBlock;
            [ScriptBlock] $MinorPattern = (Get-ParsedPattern -Pattern $Config.MinorPattern -Flags $Config.MinorRegExpFlags -Config $Config -Debug:$script:Debug -Verbose:$script:Verbose).ScriptBlock;
            [ScriptBlock] $PatchPattern = (Get-ParsedPattern -Pattern $Config.BumpEachCommitPatchPattern -Flags ([string]::Empty) -Config $Config -Debug:$script:Debug -Verbose:$script:Verbose).ScriptBlock;
            [bool] $EnablePrereleaseMode = $Config.EnablePrereleaseMode;
            [string] $Type = 'None';
            [int] $Increment = 0;
            [bool] $Changed = $False;
            [int] $Major = 0;
            [int] $Minor = 0;
            [int] $Patch = 0;
          } Process {
            If ($Config.BumpEachCommit -and $Null -ne $LastRelease.CurrentPatch -and $LastRelease.CurrentPatch -ne 0) {
              $Major = $LastRelease.Major;
              $Minor = $LastRelease.Minor;
              $Patch = $LastRelease.Patch;
            } ElseIf ($Config.BumpEachCommit) {
              $Major = $LastRelease.Major;
              $Minor = $LastRelease.Minor;
              $Patch = $LastRelease.Patch;

              If ($CommitsSet.Commits.Length -ne 0) {
                [List[PSCustomObject]] $Commits = [List[PSCustomObject]]::new($CommitsSet.Commits);
                $Commits.Reverse();
                [PSCustomObject] $ResolvedCommitType = (Resolve-CommitType -LastRelease $LastRelease -CommitsSet $Commits -MajorPattern $MajorPattern -MinorPattern $MinorPattern -PatchPattern $PatchPattern -Config $Config -Debug:$script:Debug -Verbose:$script:Verbose);
                $Type = $ResolvedCommitType.Type;
                $Increment = $ResolvedCommitType.Increment;
                $Changed = $ResolvedCommitType.Changed;

                If ($Config.EnablePrereleaseMode -and $LastRelease.Major -eq 0) {
                  If ($Type -eq 'Major' -or $Type -eq 'Minor') {
                    $Minor += 1;
                    $Patch = 0;
                    $Increment = 0;
                  } ElseIf ($Type -eq 'Patch') {
                    $Patch += 1;
                    $Increment = 0;
                  } Else {
                    $Increment++;
                  }
                } Else {
                  If ($Type -eq 'Major') {
                    $Major += 1;
                    $Minor = 0;
                    $Patch = 0;
                    $Increment = 0;
                  } ElseIf ($Type -eq 'Minor') {
                    $Minor += 1;
                    $Patch = 0;
                  } ElseIf ($Type -eq 'Patch') {
                    $Patch += 1;
                    $Increment = 0;
                  } Else {
                    $Increment++;
                  }
                }
              }
            } Else {
              [PSCustomObject] $ResolvedCommitType = (Resolve-CommitType -LastRelease $LastRelease -CommitsSet $CommitsSet -MajorPattern $MajorPattern -MinorPattern $MinorPattern -PatchPattern $PatchPattern -Config $Config -Debug:$script:Debug -Verbose:$script:Verbose);

              $Type = $ResolvedCommitType.Type;
              $Increment = $ResolvedCommitType.Increment;
              $Changed = $ResolvedCommitType.Changed;
              [PSCustomObject] $NextVersion = (Get-NextVersion -Type $Type -Current $LastRelease -Debug:$script:Debug -Verbose:$script:Verbose);
              $Major = $NextVersion.Major;
              $Minor = $NextVersion.Minor;
              $Patch = $NextVersion.Patch;

              If ($Null -ne $LastRelease.CurrentPatch) {
                [bool] $VersionsMatch = $LastRelease.CurrentMajor -eq $Major -and $LastRelease.CurrentMinor -eq $Minor -and $LastRelease.CurrentPatch -eq $Patch;
                [int] $CurrentIncrement = 0;
                If ($VersionsMatch) {
                  $CurrentIncrement = $Increment;
                }

                $Type = 'None';
                $Increment = $CurrentIncrement;
                $Major = $LastRelease.CurrentMajor;
                $Minor = $LastRelease.CurrentMinor;
                $Patch = $LastRelease.CurrentPatch;
              }
            }
          } End {
            $Output | Add-Member -MemberType NoteProperty -Name 'Type'      -Value $Type      -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Increment' -Value $Increment -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Changed'   -Value $Changed   -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Major'     -Value $Major     -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Minor'     -Value $Minor     -Debug:$script:Debug -Verbose:$script:Verbose;
            $Output | Add-Member -MemberType NoteProperty -Name 'Patch'     -Value $Patch     -Debug:$script:Debug -Verbose:$script:Verbose;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Format-Version {
          [CmdletBinding()]
          [OutputType([string])]
          Param(
            # Specifies an int that represents the major version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the major version to use.')]
            [int]
            $Major,
            # Specifies an int that represents the minor version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the minor version to use.')]
            [int]
            $Minor,
            # Specifies an int that represents the patch version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the patch version to use.')]
            [int]
            $Patch,
            # Specifies an int that represents the increment version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the increment version to use.')]
            [int]
            $Increment,
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [string] $Output = $Null;
          } Process {
            $Output = ($Config.VersionFormat -replace '\$\{major\}', $Major -replace '\$\{minor\}', $Minor -replace '\$\{patch\}', $Patch -replace '\$\{increment\}', $Increment);
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Format-Tag {
          [CmdletBinding()]
          [OutputType([string])]
          Param(
            # Specifies an int that represents the major version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the major version to use.')]
            [int]
            $Major,
            # Specifies an int that represents the minor version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the minor version to use.')]
            [int]
            $Minor,
            # Specifies an int that represents the patch version to use.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'An int that represents the patch version to use.')]
            [int]
            $Patch,
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [string] $Output = $Null;
            [string] $NamespaceSeperator = '-';
            # TODO: Check if I forgor this:
            #[bool] $OnVersionBranch = $False;
          } Process {
            [string] $Result = "$($Config.TagPrefix)$($Major).$($Minor).$($Patch)";
            If (-not [string]::IsNullOrWhiteSpace($Config.Namespace)) {
              $Output = "$($Result)$($NamespaceSeperator)$($Config.Namespace)";
            } Else {
              $Output = $Result;
            }
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Format-Users {
          [SuppressMessage('PSUseSingularNouns', 'Format-Users')]
          [CmdletBinding()]
          [OutputType([string])]
          Param(
            # Specifies a PSCustomObject array determining list of authors to format.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject array determining list of authors to format.')]
            [ValidateNotNullOrEmpty()]
            [PSCustomObject[]]
            $List,
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [string] $Output = $Null;
          } Process {
            If ($Config.UserFormatType -eq 'json') {
              $Output = ($List | ForEach-Object {
                @{
                  name = $_.Name;
                  email = $_.Email
                }
              } | ConvertTo-Json -AsArray -Depth 100 -Debug:$script:Debug -Verbose:$script:Verbose);
            } ElseIf ($Config.UserFormatType -eq 'csv') {
              $Output = (@($List | ForEach-Object { "$($_.Name) <$($_.Email)>"}) -join ', ');
            } Else {
              Throw [NotImplementedException]::new("Invalid user format type $($Config.UserFormatType)");
            }
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Resolve-BranchName {
          [CmdletBinding(SupportsShouldProcess = $True)]
          [OutputType([PSCustomObject])]
          Param(
            # Specifies a PSCustomObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSCustomObject that determines the config of the commands.')]
            [PSCustomObject]
            $Config
          )

          Begin {
            [PSCustomObject] $Output = [PSCustomObject]::new();
            $Major = -1;
            $Minor = -1;
            $OnVersionBranch = $False;
          } Process {
            [string] $BranchName = $Config.Branch;

            If ($BranchName -eq 'HEAD') {
              $BranchName = (Invoke-Process -Command $Config.Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            }

            $BranchName = $BranchName.Trim();
            [Regex] $Pattern = $Null;
            [int] $RegexEnd = 0;
            [string] $ParsedFlags = [string]::Empty;

            If ($Config.VersionFromBranch -is [bool] -and $Config.VersionFromBranch -eq $True) {
              $Pattern = [Regex]::new("(?:[0-9]+.[0-9]+|[0-9]+)$");
            } ElseIf ($Config.VersionFromBranch.ToString() -match '^\/.+\/[i]*$') {
              $RegexEnd = $Config.VersionFromBranch.ToString().LastIndexOf('/');
              $ParsedFlags = $Config.VersionFromBranch.ToString().Substring($Config.VersionFromBranch.ToString().LastIndexOf('/') + 1);
              $Pattern = [Regex]::new($Config.VersionFromBranch.ToString().Substring(1, $RegexEnd), $ParsedFlags);
            } Else {
              $Pattern = [Regex]::new($Config.VersionFromBranch.ToString());
            }

            [Match] $Result = $Pattern.Match($BranchName);

            If ($Null -eq $Result) {
              [int] $Major = -1;
              $OnVersionBranch = $False;
            } Else {
              [string] $BranchVersion = [string]::Empty;
              If ($Result.Groups.Count -eq 1) {
                $BranchVersion = $Result.Groups[0].Value;
              } ElseIf ($Result.Groups.Count -eq 2) {
                $BranchVersion = $Result.Groups[1].Value;
              } Else {
                Throw [Exception]::new("Unable to parse version from branch named '$($BranchName)' using pattern '$($Pattern.ToString())'.");
              }

              $OnVersionBranch = $True;

              [string[]] $VersionValues = ($BranchVersion -split '\.');

              If ($VersionValues.Length -gt 2) {
                Throw [Exception]::new("The version string '$($BranchVersion)' parsed from branch '$($BranchName)' is invalid. It must be in the format 'major.minor' or 'major'.");
              }

              $Major = [int]::Parse($VersionValues[0]);

              If ($VersionValues.Length -gt 2) {
                Throw [Exception]::new("The version string '$($BranchVersion)' parsed from branch '$($BranchName)' is invalid. It must be in the format 'major.minor' or 'major'.");
              }

              If (-not [int]::TryParse($VersionValues[0], [Ref] $Major)) {
                Throw [Exception]::new("The major version '$($VersionValues[0])' parsed from branch '$($BranchName)' is invalid. It must be a number.");
              }

              If ($VersionValues.Length -gt 1) {
                If (-not [int]::TryParse($VersionValues[1], [Ref] $Minor)) {
                  Throw [Exception]::new("The minor version '$($VersionValues[1])' parsed from branch '$($BranchName)' is invalid. It must be a number.");
                }
              }
            }
          } End {
            $Config | Add-Member -MemberType NoteProperty -Name 'Major'           -Value $Major           -Debug:$script:Debug -Verbose:$script:Verbose;
            $Config | Add-Member -MemberType NoteProperty -Name 'Minor'           -Value $Minor           -Debug:$script:Debug -Verbose:$script:Verbose;
            $Config | Add-Member -MemberType NoteProperty -Name 'OnVersionBranch' -Value $OnVersionBranch -Debug:$script:Debug -Verbose:$script:Verbose;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        [string] $CurrentCommit = (Resolve-CurrentCommit -Config $Config -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);

        If (-not (Test-IsEmptyRepo -Config $Config -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose)) {
          $BranchNameMajor = -1;
          $BranchNameMinor = -1;
          $OnVersionBranch = $False;

          If ($Config.VersionFromBranch) {
            [PSCustomObject] $BranchInformation = (Resolve-BranchName -Config $Config -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
            $BranchNameMajor = $BranchInformation.Major;
            $BranchNameMinor = $BranchInformation.Minor;
            $OnVersionBranch = $BranchInformation.OnVersionBranch;
          }

          $Config | Add-Member -MemberType NoteProperty -Name 'BranchNameMajor' -Value $BranchNameMajor `
            -Debug:$script:Debug -Verbose:$script:Verbose;
          $Config | Add-Member -MemberType NoteProperty -Name 'BranchNameMinor' -Value $BranchNameMinor `
            -Debug:$script:Debug -Verbose:$script:Verbose;
          $Config | Add-Member -MemberType NoteProperty -Name 'OnVersionBranch' -Value $OnVersionBranch `
            -Debug:$script:Debug -Verbose:$script:Verbose;

          [PSCustomObject] $LastRelease = (Resolve-LastRelease -CurrentCommit $CurrentCommit -Config $Config `
            -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
          [PSCustomObject] $CommitsSet = (Get-AllCommits -StartHash $LastRelease.Hash -EndHash $CurrentCommit -Config $Config `
            -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose);
          [PSCustomObject] $Classification = (Invoke-ClassifyVersion -LastRelease $LastRelease -CommitsSet $CommitsSet -Config $Config `
            -Debug:$script:Debug -Verbose:$script:Verbose);

          $Major = $Classification.Major;
          $Minor = $Classification.Minor;
          $Patch = $Classification.Patch;
          $Increment = $Classification.Increment;
          $VersionType = $Classification.Type;

          If ($UseLastVersion.IsPresent) {
            $Major = $LastRelease.Major
            $Minor = $LastRelease.Minor
            $Patch = $LastRelease.Patch;
            $Increment = $LastRelease.Increment;
          }

          $FormattedVersion = (Format-Version -Major $Major -Minor $Minor -Patch $Patch -Increment $Increment -Config $Config `
            -Debug:$script:Debug -Verbose:$script:Verbose);
          $VersionTag = (Format-Tag -Major $Major -Minor $Minor -Patch $Patch -Config $Config `
            -Debug:$script:Debug -Verbose:$script:Verbose);
          $Changed = $Classification.Changed;
          $IsTagged = $LastRelease.IsTagged;
          $PreviousCommit = $LastRelease.Hash;
          $PreviousVersion = "$($LastRelease.Major).$($LastRelease.Minor).$($LastRelease.Patch)";
          [PSCustomObject[]] $AllAuthors = @();

          ForEach ($Commit in $CommitsSet.Commits) {
            [string] $Key = "$($Commit.Author) <$($Commit.AuthorEmail)>";

            If ($Null -eq ($AllAuthors | Where-Object { $_.FullName -eq $Key })) {
              [PSCustomObject] $Author = [PSCustomObject]::new();
              $Author | Add-Member -MemberType NoteProperty -Name 'FullName' -Value $Key                `
                -Debug:$script:Debug -Verbose:$script:Verbose;
              $Author | Add-Member -MemberType NoteProperty -Name 'Name'     -Value $Commit.Author      `
                -Debug:$script:Debug -Verbose:$script:Verbose;
              $Author | Add-Member -MemberType NoteProperty -Name 'Email'    -Value $Commit.AuthorEmail `
                -Debug:$script:Debug -Verbose:$script:Verbose;
              $Author | Add-Member -MemberType NoteProperty -Name 'Commits'  -Value 0                   `
                -Debug:$script:Debug -Verbose:$script:Verbose;
              $AllAuthors += $Author;
            } Else {
              ($AllAuthors | Where-Object { $_.FullName -eq $Key }).Commits++;
            }
          }

          [PSCustomObject[]] $AuthorsList = @($AllAuthors | Sort-Object -Property Commits -Descending);
          [string] $Authors = (Format-Users -List $AuthorsList -Config $Config -Debug:$script:Debug -Verbose:$script:Verbose);
        }
      } End {
        [PSCustomObject] $Outputs = [PSCustomObject]::new();
        $Outputs | Add-Member -MemberType NoteProperty -Name "Major"           -Value $Major                   `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "Minor"           -Value $Minor                   `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "Patch"           -Value $Patch                   `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "Increment"       -Value $Increment               `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "VersionType"     -Value ($VersionType.ToLower()) `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "Version"         -Value $FormattedVersion        `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "VersionTag"      -Value $VersionTag              `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "Changed"         -Value $Changed                 `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "IsTagged"        -Value $IsTagged                `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "Authors"         -Value $Authors                 `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "CurrentCommit"   -Value $CurrentCommit           `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "PreviousCommit"  -Value $PreviousCommit          `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "PreviousVersion" -Value $PreviousVersion         `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Outputs | Add-Member -MemberType NoteProperty -Name "DebugOutput"     -Value $DebugOutput             `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        $Output  | Add-Member -MemberType NoteProperty -Name "Outputs"         -Value $Outputs                 `
          -Debug:$script:Debug -Verbose:$script:Verbose;
        Write-Output -NoEnumerate -InputObject $Output;
      }
    }

    [PSCustomObject] $SemVersion = $Null;
    If ($PSBoundParameters.ContainsKey('VersionOverride')) {
      # Validate the Version override
      If ($VersionOverride -is [Hashtable]) {
        [Hashtable] $Outputs = $Null;

        If ($VersionOverride.ContainsKey('Outputs')) {
          $Outputs = $VersionOverride.Outputs;
        } Else {
          $Outputs = $VersionOverride;
        }

        If (-not $Outputs.ContainsKey('Version') -or `
            -not $Outputs.ContainsKey('Major') -or `
            -not $Outputs.ContainsKey('Minor') -or `
            -not $Outputs.ContainsKey('Patch') -or `
            -not $Outputs.ContainsKey('Increment') -or `
            -not $Outputs.ContainsKey('CurrentCommit') -or `
            -not $Outputs.ContainsKey('VersionTag')) {
          Throw [ArgumentException]::new('Invalid Version Override, should contain properties "Version", "Major", "Minor", "Patch", "Increment", "CurrentCommit", and "VersionTag"', 'VersionOverride');
        }

        $SemVersion = ([PSCustomObject]@{
          Outputs = ([PSCustomObject]$Outputs);
        });
      } Else {
        [PSCustomObject] $Outputs = $Null;

        If ($VersionOverride.PSCustomObject.Properties.Match('Outputs').Count -eq 1) {
          $Outputs = $VersionOverride.Outputs;
        } Else {
          $Outputs = $VersionOverride;
        }

        If ($Outputs.PSCustomObject.Properties.Match('Version').Count -ne 1 -or `
            $Outputs.PSCustomObject.Properties.Match('Major').Count -ne 1 -or `
            $Outputs.PSCustomObject.Properties.Match('Minor').Count -ne 1 -or `
            $Outputs.PSCustomObject.Properties.Match('Patch').Count -ne 1 -or `
            $Outputs.PSCustomObject.Properties.Match('Increment').Count -ne 1 -or `
            $Outputs.PSCustomObject.Properties.Match('CurrentCommit').Count -ne 1 -or `
            $Outputs.PSCustomObject.Properties.Match('VersionTag').Count -ne 1) {
          Throw [ArgumentException]::new('Invalid Version Override, should contain properties "Version", "Major", "Minor", "Patch", "Increment", "CurrentCommit", and "VersionTag"', 'VersionOverride');
        }

        $SemVersion = $VersionOverride;
      }
    } Else {
      $SemVersion = (Get-SemanticVersion -UseLastVersion:$UseLastVersion.IsPresent -VersionFormat $VersionFormat -ChangePath @('app', 'libs', 'submodules', 'themes') `
        -Debug:$script:Debug -Verbose:$script:Verbose);
    }
    # Make (overwrite) version.xml

    Remove-Item -Force 'version.xml' `
      -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
    Set-Content -LiteralPath 'version.xml' -Value @"
<version>
  <version>$($SemVersion.Outputs.Version)</version>
  <major>$($SemVersion.Outputs.Major)</major>
  <minor>$($SemVersion.Outputs.Minor)</minor>
  <patch>$($SemVersion.Outputs.Patch)</patch>
  <increment>$($SemVersion.Outputs.Increment)</increment>
  <commit>$($SemVersion.Outputs.CurrentCommit)</commit>
  <tag>$($SemVersion.Outputs.VersionTag)</tag>
</version>
"@ -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

    [bool] $SkipInstall = (Test-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '.installed') `
      -Debug:$script:Debug -Verbose:$script:Verbose);

    If (-not $SkipInstall) {
      # Setup Python
      [CommandInfo] $Pip = (Get-Command -Name 'pip' `
        -Debug:$script:Debug -Verbose:$script:Verbose);
      [CommandInfo] $Python = (Get-Command -Name 'python' `
        -Debug:$script:Debug -Verbose:$script:Verbose);

      Get-ChildItem -LiteralPath $PWD -Recurse -Filter 'requirements.txt' `
        -Debug:$script:Debug -Verbose:$script:Verbose `
      | ForEach-Object {
        Invoke-Process -Command $Pip -Arguments @('install', '-r', "$($_)") -Raw `
          -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
      }

      # Install Dependencies

      Invoke-Process -Command $Pip -Arguments @('install', '-r', 'requirements.txt', '-r', 'requirements_build.txt') -Raw `
        -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

      # Build Actions

      $ErrorActionPreference = 'Stop';
      Invoke-Process -Command $Python -Arguments @( `
          'distribute.py', `
          '--skip-pip', `
          "--product-version=`"$($SemVersion.Outputs.Major).$($SemVersion.Outputs.Minor).$($SemVersion.Outputs.Patch).$($SemVersion.Outputs.Increment)`"", `
          '--skip-build' `
        ) -Raw `
          -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

      New-Item -Path .installed -ItemType File `
        -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose `
        | Out-Null;
    }

    # Build
    # TODO: https://github.com/Nuitka/Nuitka-Action
    Function Invoke-NuitkaAction {
      [CmdletBinding(SupportsShouldProcess = $True)]
      Param(
        # Specifies a switch that determines whether to skip install methods.
        [Parameter(Mandatory = $True,
                   HelpMessage = 'A switch that determines whether to skip install methods.')]
        [switch]
        $SkipInstall,
        ### Tags for building Nuitka ###
        # Directory to run nuitka in if not top level.
        [Parameter(Mandatory = $False,
                   HelpMessage = 'Directory to run nuitka in if not top level.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WorkingDirectory = '.',
        # Version of nuitka to use, branches, tags work.
        [Parameter(Mandatory = $False,
                   HelpMessage = 'Version of nuitka to use, branches, tags work.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $NuitkaVersion = 'main',
        # Path to python script that is to be built.
        [Parameter(Mandatory = $True,
                   HelpMessage = 'Path to python script that is to be built.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ScriptName,
        # Github personal access token of an account authorized to access the Nuitka-commercial repo.
        [Parameter(Mandatory = $False,
                   HelpMessage = 'Github personal access token of an account authorized to access the Nuitka-commercial repo.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $AccessToken,
        # Mode in which to compile. Accelerated runs in your Python
        # installation and depends on it. Standalone creates a folder
        # with an executable contained to run it. Onefile creates a
        # single executable to deploy. App is onefile except on macOS
        # where it's not to be used. Module makes a module, and
        # package includes also all sub-modules and sub-packages. Dll
        # is currently under development and not for users yet.
        # Default is 'accelerated'.
        [Parameter(Mandatory = $False,
                   HelpMessage = "Mode in which to compile. Accelerated runs in your Python installation and depends on it. Standalone creates a folder with an executable contained to run it. Onefile creates a single executable to deploy. App is onefile except on macOS where it's not to be used. Module makes a module, and package includes also all sub-modules and sub-packages. Dll is currently under development and not for users yet. Default is 'accelerated'.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Mode = 'app',
        # Description of the file used in version information. Windows only at this time. Defaults to binary filename.
        [Parameter(Mandatory = $False,
                   HelpMessage = 'Description of the file used in version information. Windows only at this time. Defaults to binary filename.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $FileDescription,
        # Include data files by filenames in the distribution. There are many
        # allowed forms. With '--include-data-files=/path/to/file/*.txt=folder_name/some.txt' it
        # will copy a single file and complain if it's multiple. With
        # '--include-data-files=/path/to/files/*.txt=folder_name/' it will put
        # all matching files into that folder. For recursive copy there is a
        # form with 3 values that '--include-data-files=/path/to/scan=folder_name/=**/*.txt'
        # that will preserve directory structure. Default empty.
        [Parameter(Mandatory = $False,
                   HelpMessage = "Include data files by filenames in the distribution. There are many allowed forms. With '--include-data-files=/path/to/file/*.txt=folder_name/some.txt' it will copy a single file and complain if it's multiple. With '--include-data-files=/path/to/files/*.txt=folder_name/' it will put all matching files into that folder. For recursive copy there is a form with 3 values that '--include-data-files=/path/to/scan=folder_name/=**/*.txt' that will preserve directory structure. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeDataFiles,
        # Product version to use in version information. Same rules as for file version.
        # Defaults to unused.
        [Parameter(Mandatory = $False,
                   HelpMessage = "Product version to use in version information. Same rules as for file version. Defaults to unused.")]
        [AllowNull()]
        [string]
        $ProductVersion
      )

      Begin {
        Push-Location -LiteralPath $WorkingDirectory `
          -Debug:$script:Debug -Verbose:$script:Verbose;

          $env:NUITKA_CACHE_DIR = (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path 'nuitka' -ChildPath 'cache'));

        [CommandInfo] $Python = (Get-Command -Name 'python' `
          -Debug:$script:Debug -Verbose:$script:Verbose);

        $env:PYTHON_VERSION = ((((Invoke-Process -Command $Python -Arguments @('--version') `
          -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose) -split '\s+' `
            | Select-Object -Index 1) -split '\.' `
              | Select-Object -First 2) -join '.');

              [CommandInfo] $Pip = (Get-Command -Name 'pip' `
          -Debug:$script:Debug -Verbose:$script:Verbose);

        If (-not $SkipInstall) {
          Invoke-Process -Command $Pip -Arguments @('install', '-r', "$(Join-Path -Path $PSScriptRoot -ChildPath 'requirements.txt'))") -Raw `
            -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

          # With commercial access token, use that repository.
          If (-not [string]::IsNullOrWhiteSpace($env:NuitkaAccessToken)) {
            $RepoUrl = "git+https://$($AccessToken)@github.com/Nuitka/Nuitka-commercial.git";
          } Else {
            $RepoUrl = 'git+https://$@github.com/Nuitka/Nuitka.git'
          }

          Invoke-Process -Command $Pip -Arguments @('install', "$($RepoUrl)/@$($NuitkaVersion)#egg=nuitka") -Raw `
            -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

          If ($IsLinux) {
            [CommandInfo] $Sudo = (Get-Command -Name 'sudo' `
              -Debug:$script:Debug -Verbose:$script:Verbose);
            Invoke-Process -Command $Sudo -Arguments @('apt-get', 'install', '-y', 'cache') -Raw `
              -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
          }
        }
      } Process {
        $env:NUITKA_WORKFLOW_INPUTS = (@{
            'nuitka-version'                        = "$($NuitkaVersion)";
            'script-name'                           = "$($ScriptName)";
            'mode'                                  = "$($Mode)";
            'static-libpython'                      = 'auto';
            'product-version'                       = "$($ProductVersion -replace '^v', '')";
            'file-description'                      = "$($FileDescription)";
            'include-data-files'                    = "$(@($IncludeDataFiles | ForEach-Object { @($_, $_) -join '=' }) -join "`n")`n";
            'working-directory'                     = '.';
            'access-token'                          = "$($env:NuitkaAccessToken)";
            'python-flag'                           = '';
            'python-debug'                          = '';
            'enable-plugins'                        = '';
            'user-plugin'                           = '';
            'plugin-no-detection'                   = '';
            'module-parameter'                      = '';
            'include-qt-plugins'                    = '';
            'noinclude-qt-plugins'                  = '';
            'report'                                = '';
            'report-diffable'                       = '';
            'report-user-provided'                  = '';
            'report-template'                       = '';
            'quiet'                                 = '';
            'show-scons'                            = '';
            'show-memory'                           = '';
            'include-package-data'                  = '';
            'include-data-dir'                      = '';
            'noinclude-data-files'                  = '';
            'include-onefile-external-data'         = '';
            'include-raw-dir'                       = '';
            'include-package'                       = '';
            'include-module'                        = '';
            'include-plugin-directory'              = '';
            'include-plugin-files'                  = '';
            'prefer-source-code'                    = '';
            'nofollow-import-to'                    = '';
            'user-package-configuration-file'       = '';
            'onefile-tempdir-spec'                  = '';
            'onefile-child-grace-time'              = '';
            'onefile-no-compression'                = '';
            'warn-implicit-exceptions'              = '';
            'warn-unusual-code'                     = '';
            'assume-yes-for-downloads'              = 'true';
            'nowarn-mnemonic'                       = '';
            'deployment'                            = '';
            'no-deployment-flag'                    = '';
            'output-dir'                            = 'build';
            'output-file'                           = '';
            'disable-console'                       = '';
            'enable-console'                        = '';
            'company-name'                          = '';
            'product-name'                          = "$($FileDescription)";
            'file-version'                          = "$($ProductVersion -replace '^v', '')";
            'copyright'                             = '';
            'trademarks'                            = '';
            'force-stdout-spec'                     = '';
            'force-stderr-spec'                     = '';
            'windows-console-mode'                  = '';
            'windows-icon-from-ico'                 = './themes/default-icons/AppIcon.ico';
            'windows-icon-from-exe'                 = '';
            'onefile-windows-splash-screen-image'   = '';
            'windows-uac-admin'                     = '';
            'windows-uac-uiaccess'                  = '';
            'macos-target-arch'                     = '';
            'macos-app-icon'                        = './themes/default-icons/AppIcon_a.icns';
            'macos-signed-app-name'                 = '';
            'macos-app-name'                        = "$($FileDescription)";
            'macos-app-mode'                        = '';
            'macos-sign-identity'                   = '';
            'macos-sign-notarization'               = '';
            'macos-app-version'                     = "$($ProductVersion -replace '^v', '')";
            'macos-app-protected-resource'          = '';
            'linux-icon'                            = './themes/default-icons/AppIcon_a.png';
            'embed-data-files-compile-time-pattern' = '';
            'embed-data-files-run-time-pattern'     = '';
            'embed-data-files-qt-resource-pattern'  = '';
            'embed-debug-qt-resources'              = '';
            'encryption-key'                        = '';
            'encrypt-stdout'                        = '';
            'encrypt-stderr'                        = '';
            'clang'                                 = '';
            'mingw64'                               = '';
            'msvc'                                  = '';
            'jobs'                                  = '';
            'lto'                                   = '';
            'cf-protection'                         = '';
            'debug'                                 = '';
            'no-debug-immortal-assumptions'         = '';
            'unstripped'                            = '';
            'trace-execution'                       = '';
            'xml'                                   = '';
            'experimental'                          = '';
            'low-memory'                            = '';
          } | ConvertTo-Json -Compress);
        $ErrorActionPreference = 'Stop';
        Invoke-Process -Command $Python -Arguments @('-m', 'nuitka', '--github-workflow-options') -Raw `
          -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
      } End {
        Pop-Location `
          -Debug:$script:Debug -Verbose:$script:Verbose;
      }
    }

    [string] $Mode = [string]::Empty;

    If ($IsMacOS) {
      $Mode = 'app';
    } Else {
      $Mode = 'standalone';
      $Mode = 'onefile';
    }

    Invoke-NuitkaAction -SkipInstall:$SkipInstall -NuitkaVersion 'main' -ScriptName 'app/__main__.py' -Mode $Mode `
      -FileDescription 'RimSort' -IncludeDataFiles @('version.xml') -ProductVersion $SemVersion.Outputs.VersionTag `
      -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

    # Set FILENAME
    [string] $FILENAME = $Platform;
    $FILENAME += $Arch;
    $env:FILENAME = "$FILENAME";

    [string] $OutExec = "RimSort";

    If ($IsWIndows) {
      $OutExec = "$($OutExec).exe";
    }

    # Find Executable
    [FileInfo] $Executable = (Get-ChildItem -LiteralPath . -Recurse -File -Filter $OutExec `
      -Debug:$script:Debug -Verbose:$script:Verbose | Select-Object -First 1);
    $env:EXECUTABLE = "$($Executable.FullName)";
    Write-Information -MessageData "Executable found at $($Executable)";

    # Generate executable attestations
    # TODO: https://github.com/actions/attest-build-provenance
    Function Invoke-AtTestBuildProvenance {
      [CmdletBinding(SupportsShouldProcess = $True)]
      Param(
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $SubjectPath
      )

      Begin {
        [PSCustomObject] $Output = [PSCustomObject]::new();
      } Process {
      } End {
        Write-Output -NoEnumerate -InputObject $Output;
      }
    }

    If ($AtTest) {
      Invoke-AtTestBuildProvenance -SubjectPath $env:EXECUTABLE `
        -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
    }

    # Rename new build
    Push-Location -LiteralPath (Join-Path -Path $PWD -ChildPath 'build') `
      -Debug:$script:Debug -Verbose:$script:Verbose;
    Move-Item -LiteralPath (Join-Path -Path $PWD -ChildPath $env:BUILD_OUTPUT) -Destination (Join-Path -Path $PWD -ChildPath 'output') `
      -Debug:$script:Debug -Verbose:$script:Verbose;
    [string] $CompressedFileName = "$($env:FILENAME).tar";
    If ($IsWindows) {
      $CompressedFileName = "$($env:FILENAME).zip";
    }

    If ($IsWindows) {
      If (Test-Path -Path (Join-Path -Path $PWD -ChildPath $CompressedFileName) -PathType Leaf `
        -Debug:$script:Debug -Verbose:$script:Verbose) {
        Remove-Item -LiteralPath (Join-Path -Path $PWD -ChildPath $CompressedFileName) `
          -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
      }

      Compress-Archive -LiteralPath (Join-Path -Path $PWD -ChildPath 'output') `
        -DestinationPath (Join-Path -Path $PWD -ChildPath $CompressedFileName) `
        -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
    } Else {
      [CommandInfo] $Tar = (Get-Command -Name 'tar' `
        -Debug:$script:Debug -Verbose:$script:Verbose);
      Invoke-Process -Command $Tar -Arguments @('-cvf', "'$($CompressedFileName)'", '"output"') -Raw `
        -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
    }

    Remove-Item -Recurse -Force -LiteralPath (Join-Path -Path $PWD -ChildPath 'output') `
      -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
    Pop-Location `
      -Debug:$script:Debug -Verbose:$script:Verbose;

    # Generate artifact attestation

    If ($AtTest) {
      Invoke-AtTestBuildProvenance -SubjectPath (Join-Path -Path $PSScriptRoot -ChildPath 'build' -AdditionalChildPath @($CompressedFileName)) `
        -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
    }

    # Upload folder as artifact

    Function Invoke-UploadArtifact {
      [CmdletBinding(SupportsShouldProcess = $True)]
      Param(
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Name,
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Path,
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [ValidateSet('Error')]
        [string]
        $IfNoFilesFound
      )

      Begin {

      } Process {

      } End {

      }
    }

    Invoke-UploadArtifact -Name $env:FILENAME -Path (Join-Path -Path $PSScriptRoot -ChildPath 'build' -AdditionalChildPath @($CompressedFileName)) -IfNoFilesFound 'error' `
      -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
  } Finally {
    $env:GitHubToken = $Null;
  }
} End {
  Pop-Location;
}