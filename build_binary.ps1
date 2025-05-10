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

  [bool] $DidNotStartPyEnv = $True;
  [string] $PyEnvActivateScript = (Join-Path -Path $PWD -ChildPath '*' -AdditionalChildPath @('Scripts', 'activate.ps1'));
  [FileInfo] $PythonEnvActivatePath = $Null;
  [CommandInfo] $PythonCommand = (Get-Command -Name 'python' -ErrorAction SilentlyContinue -Debug:$script:Debug -Verbose:$script:Verbose);

  If (Test-Path -Path $PyEnvActivateScript -PathType Leaf -Debug:$script:Debug -Verbose:$script:Verbose) {
    $PythonEnvActivatePath = (Get-Item -Path "$($PWD.Path)\*\Scripts\activate.ps1" -Debug:$script:Debug -Verbose:$script:Verbose);

    If ($Null -ne $PythonCommand -and (Get-Item -LiteralPath $PythonCommand.Source -Debug:$script:Debug -Verbose:$script:Verbose).Directory.FullName -ne $PythonEnvActivatePath.Directory.FullName) {
      & ($PythonEnvActivatePath | Select-Object -First 1).FullName | Out-Host;
    }

    $DidNotStartPyEnv = $False;
  }

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

        ####################################
        ##### Tags for building Nuitka #####
        ####################################

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

        ### Only Required Input ###

        # Path to python script that is to be built.
        [Parameter(Mandatory = $True,
                  HelpMessage = 'Path to python script that is to be built.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ScriptName,

        # Enable Nuitka Commercial features of Nuitka using a PAT (personal access token)

        # Github personal access token of an account authorized to access the Nuitka-commercial repo.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Github personal access token of an account authorized to access the Nuitka-commercial repo.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $AccessToken = $env:NuitkaAccessToken,

        ### Nuitka Modes ###

        # Mode in which to compile. Accelerated runs in your Python
        # installation and depends on it. Standalone creates a folder
        # with an executable contained to run it. Onefile creates a
        # single executable to deploy. App is onefile except on macOS
        # where it's not to be used. Module makes a module, and
        # package includes also all sub-modules and sub-packages. Dll
        # is currently under development and not for users yet.
        # Default is 'accelerated'.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Mode in which to compile. Accelerated runs in your Python`ninstallation and depends on it. Standalone creates a folder`nwith an executable contained to run it. Onefile creates a`nsingle executable to deploy. App is onefile except on macOS`nwhere it's not to be used. Module makes a module, and`npackage includes also all sub-modules and sub-packages. Dll`nis currently under development and not for users yet.`nDefault is 'accelerated'.")]
        [ValidateSet('accelerated', 'onefile', 'standalone', 'app', 'module', 'dll')]
        [string]
        $Mode = 'accelerated',
        # Python flags to use. Default is what you are using to run Nuitka, this
        # enforces a specific mode. These are options that also exist to standard
        # Python executable. Currently supported: "-S" (alias "no_site"),
        # "static_hashes" (do not use hash randomization), "no_warnings" (do not
        # give Python run time warnings), "-O" (alias "no_asserts"), "no_docstrings"
        # (do not use doc strings), "-u" (alias "unbuffered"), "isolated" (do not
        # load outside code) and "-m" (package mode, compile as "package.__main__").
        # Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Python flags to use. Default is what you are using to run Nuitka, this`nenforces a specific mode. These are options that also exist to standard`nPython executable. Currently supported: `"-S`" (alias `"no_site`"),`n`"static_hashes`" (do not use hash randomization), `"no_warnings`" (do not`ngive Python run time warnings), `"-O`" (alias `"no_asserts`"), `"no_docstrings`"`n(do not use doc strings), `"-u`" (alias `"unbuffered`"), `"isolated`" (do not`nload outside code) and `"-m`" (package mode, compile as `"package.__main__`").`nDefault empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $PythonFlag = @(),
        # Use debug version or not. Default uses what you are using to run Nuitka, most
        # likely a non-debug version. Only for debugging and testing purposes.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Use debug version or not. Default uses what you are using to run Nuitka, most`nlikely a non-debug version. Only for debugging and testing purposes.')]
        [switch]
        $PythonDebug,

        ### Nuitka Plugins to enable. ###

        # Enabled plugins. Must be plug-in names. Use '--plugin-list' to query the
        # full list and exit. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Enabled plugins. Must be plug-in names. Use '--plugin-list' to query the`nfull list and exit. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $EnablePlugins = @(),
        # The file name of user plugin. Can be given multiple times. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'The file name of user plugin. Can be given multiple times. Default empty.')]
        [string]
        $UserPlugin = [string]::Empty,
        # Plugins can detect if they might be used, and the you can disable the warning
        # via "--disable-plugin=plugin-that-warned", or you can use this option to disable
        # the mechanism entirely, which also speeds up compilation slightly of course as
        # this detection code is run in vain once you are certain of which plugins to
        # use. Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Plugins can detect if they might be used, and the you can disable the warning`nvia `"--disable-plugin=plugin-that-warned`", or you can use this option to disable`nthe mechanism entirely, which also speeds up compilation slightly of course as`nthis detection code is run in vain once you are certain of which plugins to`nuse. Defaults to off.")]
        [switch]
        $PluginNoDetection,
        # Provide a module parameter. You are asked by some packages
        # to provide extra decisions. Format is currently
        # --module-parameter=module.name-option-name=value
        # Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Provide a module parameter. You are asked by some packages`nto provide extra decisions. Format is currently`n--module-parameter=module.name-option-name=value`nDefault empty.")]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $ModuleParameter = @{},

        ### Nuitka Tracing/Reporting features

        # Report module, data files, compilation, plugin, etc. details in an XML output file. This
        # is also super useful for issue reporting. These reports can e.g. be used to re-create
        # the environment easily using it with '--create-environment-from-report', but contain a
        # lot of information. Default is off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Report module, data files, compilation, plugin, etc. details in an XML output file. This`nis also super useful for issue reporting. These reports can e.g. be used to re-create`nthe environment easily using it with '--create-environment-from-report', but contain a`nlot of information. Default is off.")]
        [switch]
        $Report,
        # Report data in diffable form, i.e. no timing or memory usage values that vary from run
        # to run. Default is off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Report data in diffable form, i.e. no timing or memory usage values that vary from run`nto run. Default is off.")]
        [switch]
        $ReportDiffable,
        # Report data from you. This can be given multiple times and be
        # anything in 'key=value' form, where key should be an identifier, e.g. use
        # '--report-user-provided=pipenv-lock-hash=64a5e4' to track some input values.
        # Default is empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Report data from you. This can be given multiple times and be`nanything in 'key=value' form, where key should be an identifier, e.g. use`n'--report-user-provided=pipenv-lock-hash=64a5e4' to track some input values.`nDefault is empty.")]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $ReportUserProvided = @{},
        # Report via template. Provide template and output filename 'template.rst.j2:output.rst'. For
        # built-in templates, check the User Manual for what these are. Can be given multiple times.
        # Default is empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Report via template. Provide template and output filename 'template.rst.j2:output.rst'. For`nbuilt-in templates, check the User Manual for what these are. Can be given multiple times.`nDefault is empty.")]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $ReportTemplate = @{},
        # Disable all information outputs, but show warnings.
        # Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Disable all information outputs, but show warnings.`nDefaults to off.")]
        [switch]
        $Quiet,
        # Run the C building backend Scons with verbose information, showing the executed commands,
        # detected compilers. Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Run the C building backend Scons with verbose information, showing the executed commands,`ndetected compilers. Defaults to off.")]
        [switch]
        $ShowScons,
        # Provide memory information and statistics.
        # Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Provide memory information and statistics.`nDefaults to off.")]
        [switch]
        $ShowMemory,

        ### Control the inclusion of data files in result. ###

        # Include data files for the given package name. DLLs and extension modules
        # are not data files and never included like this. Can use patterns the
        # filenames as indicated below. Data files of packages are not included
        # by default, but package configuration can do it.
        # This will only include non-DLL, non-extension modules, i.e. actual data
        # files. After a ":" optionally a filename pattern can be given as
        # well, selecting only matching files. Examples:
        # "--include-package-data=package_name" (all files)
        # "--include-package-data=package_name:*.txt" (only certain type)
        # "--include-package-data=package_name:some_filename.dat (concrete file)
        # Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Include data files for the given package name. DLLs and extension modules`nare not data files and never included like this. Can use patterns the`nfilenames as indicated below. Data files of packages are not included`nby default, but package configuration can do it.`nThis will only include non-DLL, non-extension modules, i.e. actual data`nfiles. After a `":`" optionally a filename pattern can be given as`nwell, selecting only matching files. Examples:`n`"--include-package-data=package_name`" (all files)`n`"--include-package-data=package_name:*.txt`" (only certain type)`n`"--include-package-data=package_name:some_filename.dat (concrete file)`nDefault empty.")]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $IncludePackageData = @{},
        # Include data files from complete directory in the distribution. This is
        # recursive. Check '--include-data-files' with patterns if you want non-recursive
        # inclusion. An example would be '--include-data-dir=/path/some_dir=data/some_dir'
        # for plain copy, of the whole directory. All non-code files are copied, if you
        # want to use '--noinclude-data-files' option to remove them. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Include data files from complete directory in the distribution. This is`nrecursive. Check '--include-data-files' with patterns if you want non-recursive`ninclusion. An example would be '--include-data-dir=/path/some_dir=data/some_dir'`nfor plain copy, of the whole directory. All non-code files are copied, if you`nwant to use '--noinclude-data-files' option to remove them. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $IncludeDataDir = @{},
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
        [Hashtable]
        $IncludeDataFiles = @{},
        # Do not include data files matching the filename pattern given. This is against
        # the target filename, not source paths. So to ignore a file pattern from package
        # data for 'package_name' should be matched as 'package_name/*.txt'. Or for the
        # whole directory simply use 'package_name'. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Do not include data files matching the filename pattern given. This is against`nthe target filename, not source paths. So to ignore a file pattern from package`ndata for 'package_name' should be matched as 'package_name/*.txt'. Or for the`nwhole directory simply use 'package_name'. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $NoIncludeDataFiles = @(),
        # Include the specified data file patterns outside of the onefile binary,
        # rather than on the inside. Makes only sense in case of '--onefile'
        # compilation. First files have to be specified as included with other
        # `--include-*data*` options, and then this refers to target paths
        # inside the distribution. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Include the specified data file patterns outside of the onefile binary,`nrather than on the inside. Makes only sense in case of '--onefile'`ncompilation. First files have to be specified as included with other`n`--include-*data*` options, and then this refers to target paths`ninside the distribution. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeOnefileExternalData = @(),
        # Include raw directories completely in the distribution. This is
        # recursive. Check '--include-data-dir' to use the sane option.
        # Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Include raw directories completely in the distribution. This is`nrecursive. Check '--include-data-dir' to use the sane option.`nDefault empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeRawDir = @(),

        ### Control the inclusion of modules and packages in result. ###

        # Include a whole package. Give as a Python namespace, e.g. "some_package.sub_package" and Nuitka will then find it and include it and all the modules found below that disk location in the binary or extension module it creates, and make it available for import by the code. To avoid unwanted sub packages, e.g. tests you can e.g. do this "--nofollow-import-to=*.tests". Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Include a whole package. Give as a Python namespace, e.g. "some_package.sub_package" and Nuitka will then find it and include it and all the modules found below that disk location in the binary or extension module it creates, and make it available for import by the code. To avoid unwanted sub packages, e.g. tests you can e.g. do this "--nofollow-import-to=*.tests". Default empty.')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludePackage = @(),
        # Include a single module. Give as a Python namespace, e.g. "some_package.some_module" and Nuitka will then find it and include it in the binary or extension module it creates, and make it available for import by the code. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Include a single module. Give as a Python namespace, e.g. "some_package.some_module" and Nuitka will then find it and include it in the binary or extension module it creates, and make it available for import by the code. Default empty.')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeModule = @(),
        # Include the content of that directory, no matter if it is used by the given main program in a visible form. Overrides all other inclusion options. Can be given multiple times. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Include the content of that directory, no matter if it is used by the given main program in a visible form. Overrides all other inclusion options. Can be given multiple times. Default empty.')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludePluginDirectory = @(),
        # Include into files matching the PATTERN. Overrides all other follow options. Can be given multiple times. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Include into files matching the PATTERN. Overrides all other follow options. Can be given multiple times. Default empty.')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludePluginFiles = @(),
        # For already compiled extension modules, where there is both a source file and an extension module, normally the extension module is used, but it should be better to compile the module from available source code for best performance. If not desired, there is --no-prefer-source-code to disable warnings about it. Default off.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'For already compiled extension modules, where there is both a source file and an extension module, normally the extension module is used, but it should be better to compile the module from available source code for best performance. If not desired, there is --no- prefer-source-code to disable warnings about it. Default off.')]
        [switch]
        $PreferSourceCode,
        # Do not follow to that module name even if used, or if a package name, to the whole package in any case, overrides all other options. Can be given multiple times. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Do not follow to that module name even if used, or if a package name, to the whole package in any case, overrides all other options. Can be given multiple times. Default empty.')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $NoFollowImportTo = @(),
        # User provided YAML file with package configuration. You can include DLLs, remove bloat, add hidden dependencies. Check User Manual for a complete description of the format to use. Can be given multiple times. Defaults to empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'User provided YAML file with package configuration. You can include DLLs, remove bloat, add hidden dependencies. Check User Manual for a complete description of the format to use. Can be given multiple times. Defaults to empty.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $UserPackageConfigurationFile,

        ### Onefile behavior details ###
        # Use this as a folder to unpack onefile. Defaults to '%TEMP%\onefile_%PID%_%TIME%', but e.g. '%CACHE_DIR%/%COMPANY%/%PRODUCT%/%VERSION%' would be cached and good too.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Use this as a folder to unpack onefile. Defaults to '%TEMP%\onefile_%PID%_%TIME%', but e.g. '%CACHE_DIR%/%COMPANY%/%PRODUCT%/%VERSION%' would be cached and good too.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $OnefileTempDirSpec = '%TEMP%\onefile_%PID%_%TIME%',
        # When stopping the child, e.g. due to CTRL-C or shutdown, how much time to allow before killing it the hard way. Unit is ms. Default 5000.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'When stopping the child, e.g. due to CTRL-C or shutdown, how much time to allow before killing it the hard way. Unit is ms. Default 5000.')]
        [long]
        $OnefileChildGraceTime = 5000,
        # When creating the onefile, disable compression of the payload. Default is false.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'When creating the onefile, disable compression of the payload. Default is false.')]
        [switch]
        $OnefileNoCompression,
        # Enable warnings for implicit exceptions detected at compile time.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Enable warnings for implicit exceptions detected at compile time.')]
        [switch]
        $WarnImplicitExceptions,
        # Enable warnings for unusual code detected at compile time.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Enable warnings for unusual code detected at compile time.')]
        [switch]
        $WarnUnusualCode,
        # Allow Nuitka to download external code if necessary, e.g. dependency
        # walker, ccache, and even gcc on Windows. To disable, redirect input
        # from nul device, e.g. "</dev/null" or "<NUL:". Default is to prompt.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Allow Nuitka to download external code if necessary, e.g. dependency`nwalker, ccache, and even gcc on Windows. To disable, redirect input`nfrom nul device, e.g. `"</dev/null`" or `"<NUL:`". Default is to prompt.")]
        [switch]
        $AssumeYesforDownloads,
        # Disable warning for a given mnemonic. These are given to make sure you are aware of
        # certain topics, and typically point to the Nuitka website. The mnemonic is the part
        # of the URL at the end, without the HTML suffix. Can be given multiple times and
        # accepts shell pattern. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Disable warning for a given mnemonic. These are given to make sure you are aware of`ncertain topics, and typically point to the Nuitka website. The mnemonic is the part`nof the URL at the end, without the HTML suffix. Can be given multiple times and`naccepts shell pattern. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $NoWarnMnemonic = @(),

        ### Deployment modes ###

        # Disable code aimed at making finding compatibility issues easier. This
        # will e.g. prevent execution with "-c" argument, which is often used by
        # code that attempts run a module, and causes a program to start itself
        # over and over potentially. Disable once you deploy to end users, for
        # finding typical issues, this is very helpful during development. Default
        # off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Disable code aimed at making finding compatibility issues easier. This`nwill e.g. prevent execution with `"-c`" argument, which is often used by`ncode that attempts run a module, and causes a program to start itself`nover and over potentially. Disable once you deploy to end users, for`nfinding typical issues, this is very helpful during development. Default`noff.")]
        [switch]
        $Deployment,
        # Keep deployment mode, but disable selectively parts of it. Errors from
        # deployment mode will output these identifiers. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Keep deployment mode, but disable selectively parts of it. Errors from`ndeployment mode will output these identifiers. Default empty.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $NoDeploymentFlag = @(),

        ### Output choices ##

        # Directory for output builds
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Directory for output builds')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $OutputDir,
        # Specify how the executable should be named. For extension modules there is no choice, also not for standalone mode and using it will be an error. This may include path information that needs to exist though. Defaults to '<program_name>' on this platform. .exe)
        [Parameter(Mandatory = $False,
                  HelpMessage = "Specify how the executable should be named. For extension modules there is no choice, also not for standalone mode and using it will be an error. This may include path information that needs to exist though. Defaults to '<program_name>' on this platform. .exe)")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $OutputFile = '<program_name>',

        ### Console handling ###

        # Obsolete as of Nuitka 2.3: When compiling for Windows or macOS, disable the console window and create a GUI application. Defaults to false.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Obsolete as of Nuitka 2.3: When compiling for Windows or macOS, disable the console window and create a GUI application. Defaults to false.')]
        [switch]
        $DisableConsole,
        # Obsolete as of Nuitka 2.3: When compiling for Windows or macOS, enable the console window and create a GUI application. Defaults to false and tells Nuitka your choice is intentional.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Obsolete as of Nuitka 2.3: When compiling for Windows or macOS, enable the console window and create a GUI application. Defaults to false and tells Nuitka your choice is intentional.')]
        [switch]
        $EnableConsole,

        ### Version information ###

        # Name of the company to use in version information. Defaults to unused.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Name of the company to use in version information. Defaults to unused.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $CompanyName,
        # Name of the product to use in version information. Defaults to base filename of the binary.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Name of the product to use in version information. Defaults to base filename of the binary.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ProductName = $ScriptName,
        # File version to use in version information. Must be a sequence of up to 4
        # numbers, e.g. 1.0 or 1.0.0.0, no more digits are allowed, no strings are
        # allowed. Defaults to unused.
        [Parameter(Mandatory = $False,
                  HelpMessage = "File version to use in version information. Must be a sequence of up to 4`nnumbers, e.g. 1.0 or 1.0.0.0, no more digits are allowed, no strings are`nallowed. Defaults to unused.")]
        [ValidatePattern('^v?(\d+\.){1,3}\d+$')]
        [string]
        $FileVersion,
        # Product version to use in version information. Same rules as for file version.
        # Defaults to unused.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Product version to use in version information. Same rules as for file version.`nDefaults to unused.")]
        [ValidatePattern('^v?(\d+\.){1,3}\d+$')]
        [string]
        $ProductVersion,
        # Description of the file used in version information. Windows only at this time. Defaults to binary filename.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Description of the file used in version information. Windows only at this time. Defaults to binary filename.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $FileDescription,
        # Copyright used in version information. Windows/macOS only at this time. Defaults to not present.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Copyright used in version information. Windows/macOS only at this time. Defaults to not present.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Copyright,
        # Trademark used in version information. Windows/macOS only at this time. Defaults to not present.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Trademark used in version information. Windows/macOS only at this time. Defaults to not present.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Trademarks,

        ### General OS controls ###

        # Force standard output of the program to go to this location. Useful for programs with
        # disabled console and programs using the Windows Services Plugin of Nuitka commercial.
        # Defaults to not active, use e.g. '{PROGRAM_BASE}.out.txt', i.e. file near your program,
        # check User Manual for full list of available values.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Force standard output of the program to go to this location. Useful for programs with`ndisabled console and programs using the Windows Services Plugin of Nuitka commercial.`nDefaults to not active, use e.g. '{PROGRAM_BASE}.out.txt', i.e. file near your program,`ncheck User Manual for full list of available values.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ForceStdOutSpec,
        # Force standard error of the program to go to this location. Useful for programs with
        # disabled console and programs using the Windows Services Plugin of Nuitka commercial.
        # Defaults to not active, use e.g. '{PROGRAM_BASE}.err.txt', i.e. file near your program,
        # check User Manual for full list of available values.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Force standard error of the program to go to this location. Useful for programs with`ndisabled console and programs using the Windows Services Plugin of Nuitka commercial.`nDefaults to not active, use e.g. '{PROGRAM_BASE}.err.txt', i.e. file near your program,`ncheck User Manual for full list of available values.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ForceStdErrSpec,

        ### Windows specific controls ###

        # Select console mode to use. Default mode is 'force' and creates a
        # console window unless the program was started from one. With 'disable'
        # it doesn't create or use a console at all. With 'attach' an existing
        # console will be used for outputs. With 'hide' a newly spawned console
        # will be hidden and an already existing console will behave like
        # 'force'. Default is 'force'.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Select console mode to use. Default mode is 'force' and creates a`nconsole window unless the program was started from one. With 'disable'`nit doesn't create or use a console at all. With 'attach' an existing`nconsole will be used for outputs. With 'hide' a newly spawned console`nwill be hidden and an already existing console will behave like`n'force'. Default is 'force'.")]
        [ValidateSet('force', 'attach', 'hide')]
        [string]
        $WindowsConsoleMode = 'force',
        # Add executable icon. Can be given multiple times for different resolutions
        # or files with multiple icons inside. In the later case, you may also suffix
        # with #<n> where n is an integer index starting from 1, specifying a specific
        # icon to be included, and all others to be ignored.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Add executable icon. Can be given multiple times for different resolutions`nor files with multiple icons inside. In the later case, you may also suffix`nwith #<n> where n is an integer index starting from 1, specifying a specific`nicon to be included, and all others to be ignored.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsIconFromIco,
        # Copy executable icons from this existing executable (Windows only).
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Copy executable icons from this existing executable (Windows only).')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsIconFromExe,
        # When compiling for Windows and onefile, show this while loading the application. Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'When compiling for Windows and onefile, show this while loading the application. Defaults to off.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $OnefileWindowsSplashScreenImage,
        # Request Windows User Control, to grant admin rights on execution. (Windows only). Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Request Windows User Control, to grant admin rights on execution. (Windows only). Defaults to off.')]
        [switch]
        $WindowsUacAdmin,
        # Request Windows User Control, to enforce running from a few folders only, remote
        # desktop access. (Windows only). Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Request Windows User Control, to enforce running from a few folders only, remote`ndesktop access. (Windows only). Defaults to off.")]
        [switch]
        $WindowsUacUiAccess,

        ### macOS specific controls: ###

        # What architectures is this to supposed to run on. Default and limit
        # is what the running Python allows for. Default is "native" which is
        # the architecture the Python is run with.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What architectures is this to supposed to run on. Default and limit`nis what the running Python allows for. Default is `"native`" which is`nthe architecture the Python is run with.")]
        [ValidateSet('native', 'universal', 'arm64', 'x86_64')]
        [string]
        $MacOsTargetArch = 'native',
        # Add icon for the application bundle to use. Can be given only one time. Defaults to Python icon if available.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Add icon for the application bundle to use. Can be given only one time. Defaults to Python icon if available.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MacOsAppIcon,
        # Name of the application to use for macOS signing. Follow "com.YourCompany.AppName"
        # naming results for best results, as these have to be globally unique, and will
        # potentially grant protected API accesses.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Name of the application to use for macOS signing. Follow `"com.YourCompany.AppName`"`nnaming results for best results, as these have to be globally unique, and will`npotentially grant protected API accesses.")]
        [ValidatePattern('^(\w+\.)+\.\w+$')]
        [string]
        $MacOsSignedAppName,
        # Name of the product to use in macOS bundle information. Defaults to base
        # filename of the binary.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Name of the product to use in macOS bundle information. Defaults to base`nfilename of the binary.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MacOsAppName = $ScriptName,
        # Mode of application for the application bundle. When launching a Window, and appearing
        # in Docker is desired, default value "gui" is a good fit. Without a Window ever, the
        # application is a "background" application. For UI elements that get to display later,
        # "ui-element" is in-between. The application will not appear in dock, but get full
        # access to desktop when it does open a Window later.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Mode of application for the application bundle. When launching a Window, and appearing`nin Docker is desired, default value `"gui`" is a good fit. Without a Window ever, the`napplication is a `"background`" application. For UI elements that get to display later,`n`"ui-element`" is in-between. The application will not appear in dock, but get full`naccess to desktop when it does open a Window later.")]
        [ValidateSet('gui', 'background', 'ui-element')]
        [string]
        $MacOsAppMode = 'gui',
        # When signing on macOS, by default an ad-hoc identify will be used, but with this
        # option your get to specify another identity to use. The signing of code is now
        # mandatory on macOS and cannot be disabled. Use "auto" to detect your only identity
        # installed. Default "ad-hoc" if not given.
        [Parameter(Mandatory = $False,
                  HelpMessage = "When signing on macOS, by default an ad-hoc identify will be used, but with this`noption your get to specify another identity to use. The signing of code is now`nmandatory on macOS and cannot be disabled. Use `"auto`" to detect your only identity`ninstalled. Default `"ad-hoc`" if not given.")]
        [ValidateSet('auto', 'ad-hoc')]
        [string]
        $MacOsSignIdentity = 'ad-hoc',
        # When signing for notarization, using a proper TeamID identity from Apple, use
        # the required runtime signing option, such that it can be accepted.
        [Parameter(Mandatory = $False,
                  HelpMessage = "When signing for notarization, using a proper TeamID identity from Apple, use`nthe required runtime signing option, such that it can be accepted.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MacOsSignNotarization,
        # Product version to use in macOS bundle information. Defaults to "1.0" if
        # not given.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Product version to use in macOS bundle information. Defaults to `"1.0`" if`nnot given.")]
        [ValidatePattern('^v?(\d+\.){1,3}\d+$')]
        [string]
        $MacOsAppVersion,
        # Request an entitlement for access to a macOS protected resources, e.g.
        # "NSMicrophoneUsageDescription:Microphone access for recording audio."
        # requests access to the microphone and provides an informative text for
        # the user, why that is needed. Before the colon, is an OS identifier for
        # an access right, then the informative text. Legal values can be found on
        # https://developer.apple.com/documentation/bundleresources/information_property_list/protected_resources and
        # the option can be specified multiple times. Default empty.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Request an entitlement for access to a macOS protected resources, e.g.`n`"NSMicrophoneUsageDescription:Microphone access for recording audio.`"`nrequests access to the microphone and provides an informative text for`nthe user, why that is needed. Before the colon, is an OS identifier for`nan access right, then the informative text. Legal values can be found on`nhttps://developer.apple.com/documentation/bundleresources/information_property_list/protected_resources and`nthe option can be specified multiple times. Default empty.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MacOsAppProtectedResource,

        ### Linux specific controls: ###

        # Add executable icon for onefile binary to use. Can be given only one time. Defaults to Python icon if available.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Add executable icon for onefile binary to use. Can be given only one time. Defaults to Python icon if available.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $LinuxIcon,

        ### Backend C compiler choices. ###

        # Enforce the use of clang. On Windows this requires a working Visual
        # Studio version to piggy back on. Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Enforce the use of clang. On Windows this requires a working Visual`nStudio version to piggy back on. Defaults to off.")]
        [switch]
        $Clang,
        # Enforce the use of MinGW64 on Windows. Defaults to off unless MSYS2 with MinGW Python is used.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Enforce the use of MinGW64 on Windows. Defaults to off unless MSYS2 with MinGW Python is used.')]
        [switch]
        $Mingw64,
        # Enforce the use of specific MSVC version on Windows. Allowed values
        # are e.g. "14.3" (MSVC 2022) and other MSVC version numbers, specify
        # "list" for a list of installed compilers, or use "latest".
        #
        # Defaults to latest MSVC being used if installed, otherwise MinGW64
        # is used.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Enforce the use of specific MSVC version on Windows. Allowed values`nare e.g. `"14.3`" (MSVC 2022) and other MSVC version numbers, specify`n`"list`" for a list of installed compilers, or use `"latest`".`n`nDefaults to latest MSVC being used if installed, otherwise MinGW64`nis used.")]
        [string]
        $MSVC = 'latest',
        # Specify the allowed number of parallel C compiler jobs. Negative values
        # are system CPU minus the given value. Defaults to the full system CPU
        # count unless low memory mode is activated, then it defaults to 1.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Specify the allowed number of parallel C compiler jobs. Negative values`nare system CPU minus the given value. Defaults to the full system CPU`ncount unless low memory mode is activated, then it defaults to 1.")]
        [int]
        $Jobs = 1,
        # Use link time optimizations (MSVC, gcc, clang). Allowed values are
        # "yes", "no", and "auto" (when it's known to work). Defaults to
        # "auto".
        [Parameter(Mandatory = $False,
                  HelpMessage = "Use link time optimizations (MSVC, gcc, clang). Allowed values are`n`"yes`", `"no`", and `"auto`" (when it's known to work). Defaults to`n`"auto`".")]
        [ValidateSet('yes', 'no', 'auto')]
        [string]
        $Lto = 'auto',
        # Use static link library of Python. Allowed values are "yes", "no",
        # and "auto" (when it's known to work). Defaults to "auto".
        [Parameter(Mandatory = $False,
                  HelpMessage = "Use static link library of Python. Allowed values are `"yes`", `"no`",`nand `"auto`" (when it's known to work). Defaults to `"auto`".")]
        [ValidateSet('yes', 'no', 'auto')]
        [string]
        $StaticLibPython = 'auto',
        # This option is gcc specific. For the gcc compiler, select the
        # "cf-protection" mode. Default "auto" is to use the gcc default
        # value, but you can override it, e.g. to disable it with "none"
        # value. Refer to gcc documentation for "-fcf-protection" for the
        # details.
        [Parameter(Mandatory = $False,
                  HelpMessage = "This option is gcc specific. For the gcc compiler, select the`n`"cf-protection`" mode. Default `"auto`" is to use the gcc default`nvalue, but you can override it, e.g. to disable it with `"none`"`nvalue. Refer to gcc documentation for `"-fcf-protection`" for the`ndetails.")]
        [ValidateSet('auto', 'full', 'branch', 'return', 'none', 'check')]
        [string]
        $CfProtection = 'auto',

        ### Debug features. ###

        # Disable check normally done with "--debug". With Python3.12+ do not check known
        # immortal object assumptions. Some C libraries corrupt them. Defaults to check
        # being made if "--debug" is on.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Disable check normally done with `"--debug`". With Python3.12+ do not check known`nimmortal object assumptions. Some C libraries corrupt them. Defaults to check`nbeing made if `"--debug`" is on.")]
        [switch]
        $NoDebugImmortalAssumptions,
        # Disable check normally done with "--debug". The C compilation may produce
        # warnings, which it often does for some packages without these being issues,
        # esp. for unused values.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Disable check normally done with `"--debug`". The C compilation may produce`nwarnings, which it often does for some packages without these being issues,`nesp. for unused values.")]
        [switch]
        $NoDebugCWarnings,
        # Keep debug info in the resulting object file for better debugger interaction.
        # Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Keep debug info in the resulting object file for better debugger interaction.`nDefaults to off.")]
        [switch]
        $Unstripped,
        # Traced execution output, output the line of code before executing it.
        # Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Traced execution output, output the line of code before executing it.`nDefaults to off.")]
        [switch]
        $TraceExecution,
        # Write the internal program structure, result of optimization in XML form to given filename.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Write the internal program structure, result of optimization in XML form to given filename.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Xml,
        # Use features declared as 'experimental'. May have no effect if no experimental
        # features are present in the code. Uses secret tags (check source) per
        # experimented feature.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Use features declared as 'experimental'. May have no effect if no experimental`nfeatures are present in the code. Uses secret tags (check source) per`nexperimented feature.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Experimental = @(),
        # Attempt to use less memory, by forking less C compilation jobs and using
        # options that use less memory. For use on embedded machines. Use this in
        # case of out of memory problems. Defaults to off.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Attempt to use less memory, by forking less C compilation jobs and using`noptions that use less memory. For use on embedded machines. Use this in`ncase of out of memory problems. Defaults to off.")]
        [switch]
        $LowMemory,

        ### Plugin options of 'anti-bloat' (categories: core) ###

        # What to do if a 'setuptools' or import is encountered. This package can be big with
        # dependencies, and should definitely be avoided. Also handles 'setuptools_scm'.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a 'setuptools' or import is encountered. This package can be big with`ndependencies, and should definitely be avoided. Also handles 'setuptools_scm'.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludeSetupToolsMode,
        # What to do if a 'pytest' import is encountered. This package can be big with
        # dependencies, and should definitely be avoided. Also handles 'nose' imports.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a 'pytest' import is encountered. This package can be big with`ndependencies, and should definitely be avoided. Also handles 'nose' imports.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludePyTestMode,
        # What to do if a unittest import is encountered. This package can be big with
        # dependencies, and should definitely be avoided.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a unittest import is encountered. This package can be big with`ndependencies, and should definitely be avoided.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludeUnitTestMode,
        # What to do if a pydoc import is encountered. This package use is mark of useless
        # code for deployments and should be avoided.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a pydoc import is encountered. This package use is mark of useless`ncode for deployments and should be avoided.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludePyDocMode,
        # What to do if a IPython import is encountered. This package can be big with
        # dependencies, and should definitely be avoided.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a IPython import is encountered. This package can be big with`ndependencies, and should definitely be avoided.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludeIPythonMode,
        # What to do if a 'dask' import is encountered. This package can be big with
        # dependencies, and should definitely be avoided.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a 'dask' import is encountered. This package can be big with`ndependencies, and should definitely be avoided.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludeDaskMode,
        # What to do if a 'numba' import is encountered. This package can be big with
        # dependencies, and is currently not working for standalone. This package is
        # big with dependencies, and should definitely be avoided.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a 'numba' import is encountered. This package can be big with`ndependencies, and is currently not working for standalone. This package is`nbig with dependencies, and should definitely be avoided.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludeNumbaMode,
        # This actually provides the default "warning" value for above options, and
        # can be used to turn all of these on.
        [Parameter(Mandatory = $False,
                  HelpMessage = "This actually provides the default `"warning`" value for above options, and`ncan be used to turn all of these on.")]
        [ValidateSet('warning', 'error', 'nofollow', 'allow')]
        [string]
        $NoIncludeDefaultMode,
        # What to do if a specific import is encountered. Format is module name,
        # which can and should be a top level package and then one choice, "error",
        # "warning", "nofollow", e.g. PyQt5:error.
        [Parameter(Mandatory = $False,
                  HelpMessage = "What to do if a specific import is encountered. Format is module name,`nwhich can and should be a top level package and then one choice, `"error`",`n`"warning`", `"nofollow`", e.g. PyQt5:error.")]
        [ValidatePattern('^.+?:(warning|error|nofollow|allow)$')]
        [string[]]
        $NoIncludeCustomMode = @(),

        ### Plugin options of 'pmw-freezer' (categories: package-support) ###

        # Should 'Pmw.Blt' not be included, Default is to include it.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Should 'Pmw.Blt' not be included, Default is to include it.")]
        [switch]
        $IncludePmwBlt,
        # Should 'Pmw.Color' not be included, Default is to include it.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Should 'Pmw.Color' not be included, Default is to include it.")]
        [switch]
        $IncludePmwColor,

        ### Plugin options of 'tk-inter' (categories: package-support) ###

        # The Tcl library dir. See comments for Tk library dir.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'The Tcl library dir. See comments for Tk library dir.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $TclLibraryDir,
        # The Tk library dir. Nuitka is supposed to automatically detect it, but you can
        # override it here. Default is automatic detection.
        [Parameter(Mandatory = $False,
                  HelpMessage = "The Tk library dir. Nuitka is supposed to automatically detect it, but you can`noverride it here. Default is automatic detection.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $TkLibraryDir,

        ### Plugin options of 'pyside6' (same for 'pyside2', 'pyqt6', 'pyqt5' plugins) (categories: package-support, qt-binding) ####

        # Which Qt plugins to include. These can be big with dependencies, so
        # by default only the "sensible" ones are included, but you can also put
        # "all" or list them individually. If you specify something that does
        # not exist, a list of all available will be given.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Which Qt plugins to include. These can be big with dependencies, so`nby default only the `"sensible`" ones are included, but you can also put`n`"all`" or list them individually. If you specify something that does`nnot exist, a list of all available will be given.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeQtPlugins = @(),
        # Which Qt plugins to not include. This removes things, so you can
        # ask to include "all" and selectively remove from there, or even
        # from the default sensible list.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Which Qt plugins to not include. This removes things, so you can`nask to include `"all`" and selectively remove from there, or even`nfrom the default sensible list.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $NoIncludeQtPlugins = @(),
        # Include Qt translations with QtWebEngine if used. These can be a lot
        # of files that you may not want to be included.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Include Qt translations with QtWebEngine if used. These can be a lot`nof files that you may not want to be included.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $NoIncludeQtTranslations = @(),

        ### Plugin options of 'upx' (categories: integration) ###

        # The UPX binary to use or the directory it lives in, by default `upx` from PATH is used.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'The UPX binary to use or the directory it lives in, by default `upx` from PATH is used.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $UpxBinary,
        # Do not cache UPX compression result, by default DLLs are cached, exe files are not.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Do not cache UPX compression result, by default DLLs are cached, exe files are not.')]
        [switch]
        $UpxDisableCache,

        ### Plugin options of 'anti-debugger' (categories: commercial, protection) ###

        # Enables debug outputs for the debugger plugin, so that it e.g. says
        # why it rejects something.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Enables debug outputs for the debugger plugin, so that it e.g. says`nwhy it rejects something.")]
        [switch]
        $AntiDebuggerDebugging,

        ### Plugin options of 'automatic-updates' (categories: commercial, feature) ###

        # URL to check for automatic updates. Default empty, i.e. not updates.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'URL to check for automatic updates. Default empty, i.e. not updates.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $AutoUpdateUrlSpec,
        # Debug automatic updates at runtime printing messages. Default False.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Debug automatic updates at runtime printing messages. Default False.')]
        [switch]
        $AutoUpdateDebug,

        ### Plugin options of 'data-hiding' (categories: commercial, protection) ###

        # Salt value to make encryption result unique.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Salt value to make encryption result unique.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $DataHidingSaltValue,

        ### Plugin options of 'datafile-inclusion-ng' (categories: commercial, protection) ###

        # Pattern of data files to embed for use during compile time. These should
        # match target filenames.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Pattern of data files to embed for use during compile time. These should`nmatch target filenames.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $EmbedDataFilesCompileTimePattern,
        # Pattern of data files to embed for use during run time. These should
        # match target filenames.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Pattern of data files to embed for use during run time. These should`nmatch target filenames.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $EmbedDataFilesRunTimePattern,
        # Pattern of data files to embed for use with Qt at run time. These should
        # match target filenames.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Pattern of data files to embed for use with Qt at run time. These should`nmatch target filenames.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $EmbedDataFilesQtResourcePattern,
        # For debugging purposes, print out information for Qt resources not found.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'For debugging purposes, print out information for Qt resources not found.')]
        [switch]
        $EmbedDebugQtResources,

        ### Plugin options of 'signing' (categories: commercial, integration) ###

        # The 'signtool' executable. You may make this a wrapper script should you want very
        # specific options, by default `signtool` from PATH or used MSVC used is used.
        [Parameter(Mandatory = $False,
                  HelpMessage = "The 'signtool' executable. You may make this a wrapper script should you want very`nspecific options, by default `signtool` from PATH or used MSVC used is used.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsSigningTool,
        # Name of the certificate to use. This will be used to sign the binary.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Name of the certificate to use. This will be used to sign the binary.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsCertificateName,
        # Checksum of the certificate to use. This will be used to sign the binary.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Checksum of the certificate to use. This will be used to sign the binary.')]
        [ValidatePattern('^[a-fA-F0-9]{40}$')]
        [string]
        $WindowsCertificateSha1,
        # Filename of the certificate, typically a ".pfx" file. This will be used to sign
        # the binary.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Filename of the certificate, typically a `".pfx`" file. This will be used to sign`nthe binary.")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsCertificateFileName,
        # Password of the certificate filename used. Defaults to empty, must be
        # provided to successfully sign if certificate file has one.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Password of the certificate filename used. Defaults to empty, must be`nprovided to successfully sign if certificate file has one.")]
        [SecureString]
        $WindowsCertificatePassword,
        # Comment to be used for the signed comments. Optional, defaults to not given.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Comment to be used for the signed comments. Optional, defaults to not given.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsSignedContentComment,

        ### Plugin options of 'traceback-encryption' (categories: commercial, protection) ###

        # The encryption key to use.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'The encryption key to use.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $EncryptionKey,
        # Apply encryption to standard output.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Apply encryption to standard output.')]
        [switch]
        $EncryptStdOut,
        # Apply encryption to standard error.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Apply encryption to standard error.')]
        [switch]
        $EncryptStdErr,
        # In case the encryption fails to install, do not abort, but run normally and trace error unencrypted.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'In case the encryption fails to install, do not abort, but run normally and trace error unencrypted.')]
        [switch]
        $EncryptDebugInit,
        # These are two very similar packages that can both do the encryption, and
        # to avoid duplication in case one of your packages requires the other,
        # you get to select which one to use by the plugin code. By default
        # "pycryptodomex" is used and only legacy code uses that. However it
        # will fallback to "pycryptodome" if that's the only one installed,
        # and you can enforce Nuitka choice if both are for some reason.
        [Parameter(Mandatory = $False,
                  HelpMessage = "These are two very similar packages that can both do the encryption, and`nto avoid duplication in case one of your packages requires the other,`nyou get to select which one to use by the plugin code. By default`n`"pycryptodomex`" is used and only legacy code uses that. However it`nwill fallback to `"pycryptodome`" if that's the only one installed,`nand you can enforce Nuitka choice if both are for some reason.")]
        [string]
        $EncryptCryptoPackage = 'pycryptodomex',

        ### Plugin options of 'windows-service' (categories: commercial, feature) ###

        # The Windows service name.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'The Windows service name.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WindowsServiceName,
        # For shutdown, wait this extra time before killing. Unit is ms, and default is 2000,
        # i.e. it waits 2 seconds to allow cleanup. Increase if you need more time, decrease
        # if you want faster service shutdown.
        [Parameter(Mandatory = $False,
                  HelpMessage = "For shutdown, wait this extra time before killing. Unit is ms, and default is 2000,`ni.e. it waits 2 seconds to allow cleanup. Increase if you need more time, decrease`nif you want faster service shutdown.")]
        [long]
        $WindowsServiceGraceTime = 2000,
        # Pick the service start mode, value "auto" starts automatically at
        # reboot without login, "demand" (default) must be started manually,
        # and "disabled" cannot be started, requires further action to
        # change it.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Pick the service start mode, value `"auto`" starts automatically at`nreboot without login, `"demand`" (default) must be started manually,`nand `"disabled`" cannot be started, requires further action to`nchange it.")]
        [ValidateSet('auto', 'demand', 'disabled')]
        [string]
        $WindowsServiceStartMode = 'demand',
        # Should the program allow to be ran from the command line. By default
        # it does not and only outputs a message it is disallowed.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Should the program allow to be ran from the command line. By default`nit does not and only outputs a message it is disallowed.")]
        [switch]
        $WindowsServiceCli,

        ### Action controls ###

        # Disables caching of compiled binaries. Defaults to false.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'Disables caching of compiled binaries. Defaults to false.')]
        [ValidateSet($True, 'ccache', $False)]
        [object]
        $DisableCache
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
          [string] $RepoUrl = 'git+https://$@github.com/Nuitka/Nuitka.git';
          If (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
            $RepoUrl = "git+https://$($AccessToken)@github.com/Nuitka/Nuitka-commercial.git";
          }

          Invoke-Process -Command $Pip -Arguments @('install', "$($RepoUrl)/@$($NuitkaVersion)#egg=nuitka") -Raw `
            -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;

          If ($IsLinux -and $DisableCache -ne 'ccache') {
            [CommandInfo] $Sudo = (Get-Command -Name 'sudo' -Debug:$script:Debug -Verbose:$script:Verbose);
            Invoke-Process -Command $Sudo -Arguments @('apt-get', 'install', '-y', 'ccache') -Raw `
              -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
          }
        }
      } Process {
        Function Get-ProcessedSwitch {
          [CmdletBinding()]
          [OutputType([string])]
          Param(
            # Specifies a boolean that represents the state of the switch.
            [Parameter(Mandatory = $True,
                      HelpMessage = 'A boolean that represents the state of the switch.')]
            [ValidateNotNull()]
            [bool]
            $State
          )

          Begin {
            [string] $Output = [string]::Empty;
          } Process {
            If ($State -eq $True) {
              $Output = $State.IsPresent.ToString().ToLower()
            }
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        [string] $_LowMemory = (Get-ProcessedSwitch -State $LowMemory.IsPresent);
        [string] $_PythonDebug = (Get-ProcessedSwitch -State $PythonDebug.IsPresent);
        [string] $_PluginNoDetection = (Get-ProcessedSwitch -State $PluginNoDetection.IsPresent);
        [string] $_Report = (Get-ProcessedSwitch -State $Report.IsPresent);
        [string] $_ReportDiffable = (Get-ProcessedSwitch -State $ReportDiffable.IsPresent);
        [string] $_Quiet = (Get-ProcessedSwitch -State $Quiet.IsPresent);
        [string] $_ShowScons = (Get-ProcessedSwitch -State $ShowScons.IsPresent);
        [string] $_ShowMemory = (Get-ProcessedSwitch -State $ShowMemory.IsPresent);
        [string] $_PreferSourceCode = (Get-ProcessedSwitch -State $PreferSourceCode.IsPresent);
        [string] $_OnefileNoCompression = (Get-ProcessedSwitch -State $OnefileNoCompression.IsPresent);
        [string] $_WarnImplicitExceptions = (Get-ProcessedSwitch -State $WarnImplicitExceptions.IsPresent);
        [string] $_WarnUnusualCode = (Get-ProcessedSwitch -State $WarnUnusualCode.IsPresent);
        [string] $_AssumeYesforDownloads = (Get-ProcessedSwitch -State $AssumeYesforDownloads.IsPresent);
        [string] $_Deployment = (Get-ProcessedSwitch -State $Deployment.IsPresent);
        [string] $_DisableConsole = (Get-ProcessedSwitch -State $DisableConsole.IsPresent);
        [string] $_EnableConsole = (Get-ProcessedSwitch -State $EnableConsole.IsPresent);
        [string] $_WindowsUacAdmin = (Get-ProcessedSwitch -State $WindowsUacAdmin.IsPresent);
        [string] $_WindowsUacUiAccess = (Get-ProcessedSwitch -State $WindowsUacUiAccess.IsPresent);
        [string] $_EmbedDebugQtResources = (Get-ProcessedSwitch -State $EmbedDebugQtResources.IsPresent);
        [string] $_EncryptStdOut = (Get-ProcessedSwitch -State $EncryptStdOut.IsPresent);
        [string] $_EncryptStdErr = (Get-ProcessedSwitch -State $EncryptStdErr.IsPresent);
        [string] $_Clang = (Get-ProcessedSwitch -State $Clang.IsPresent);
        [string] $_Mingw64 = (Get-ProcessedSwitch -State $Mingw64.IsPresent);
        [string] $_Debug = (Get-ProcessedSwitch -State ($PSBoundParameters.ContainsKey('Debug') -and $PSBoundParameters['Debug']));
        [string] $_NoDebugImmortalAssumptions = (Get-ProcessedSwitch -State $NoDebugImmortalAssumptions.IsPresent);
        [string] $_Unstripped = (Get-ProcessedSwitch -State $Unstripped.IsPresent);
        [string] $_TraceExecution = (Get-ProcessedSwitch -State $TraceExecution.IsPresent);

        $env:NUITKA_WORKFLOW_INPUTS = (@{
            'nuitka-version'                        = $NuitkaVersion
            'script-name'                           = $ScriptName
            'mode'                                  = $Mode
            'static-libpython'                      = $StaticLibPython;
            'product-version'                       = "$($ProductVersion -replace '^v', '')";
            'file-description'                      = $FileDescription;
            'include-data-files'                    = "$(@($IncludeDataFiles.Keys | ForEach-Object { @($_, $IncludeDataFiles.Item($_)) -join '=' }) -join "`n")";
            'working-directory'                     = $WorkingDirectory;
            'access-token'                          = $AccessToken;
            'python-flag'                           = "$($PythonFlag -join "`n")";
            'python-debug'                          = $_PythonDebug;
            'enable-plugins'                        = "$($EnablePlugins -join "`n")";
            'user-plugin'                           = $UserPlugin;
            'plugin-no-detection'                   = $_PluginNoDetection;
            'module-parameter'                      = "$(@($ModuleParameter.Keys | ForEach-Object { @($_, $ModuleParameter.Item($_)) -join '=' }) -join "`n")";
            'include-qt-plugins'                    = "$($IncludeQtPlugins -join "`n")";
            'noinclude-qt-plugins'                  = "$($IncludeQtPlugins -join "`n")";
            'report'                                = $_Report;
            'report-diffable'                       = $_ReportDiffable;
            'report-user-provided'                  = "$(@($ReportUserProvided.Keys | ForEach-Object { @($_, $ReportUserProvided.Item($_)) -join '=' }) -join "`n")";
            'report-template'                       = "$(@($ReportTemplate.Keys | ForEach-Object { @($_, $ReportTemplate.Item($_)) -join '=' }) -join "`n")";
            'quiet'                                 = $_Quiet;
            'show-scons'                            = $_ShowScons;
            'show-memory'                           = $_ShowMemory;
            'include-package-data'                  = "$(@($IncludePackageData.Keys | ForEach-Object { @($_, $IncludePackageData.Item($_)) -join '=' }) -join "`n")";
            'include-data-dir'                      = "$(@($IncludeDataDir.Keys | ForEach-Object { @($_, $IncludeDataDir.Item($_)) -join '=' }) -join "`n")";
            'noinclude-data-files'                  = "$($NoIncludeDataFiles -join "`n")";
            'include-onefile-external-data'         = "$($IncludeOnefileExternalData -join "`n")";
            'include-raw-dir'                       = "$($IncludeRawDir -join "`n")";
            'include-package'                       = "$($IncludePackage -join "`n")";
            'include-module'                        = "$($IncludeModule -join "`n")";
            'include-plugin-directory'              = "$($IncludePluginDirectory -join "`n")";
            'include-plugin-files'                  = "$($IncludePluginFiles -join "`n")";
            'prefer-source-code'                    = $_PreferSourceCode;
            'nofollow-import-to'                    = "$($NoFollowImportTo -join "`n")";
            'user-package-configuration-file'       = $UserPackageConfigurationFile;
            'onefile-tempdir-spec'                  = $OnefileTempDirSpec;
            'onefile-child-grace-time'              = "$($OnefileChildGraceTime)";
            'onefile-no-compression'                = $_OnefileNoCompression;
            'warn-implicit-exceptions'              = $_WarnImplicitExceptions;
            'warn-unusual-code'                     = $_WarnUnusualCode;
            'assume-yes-for-downloads'              = $_AssumeYesforDownloads;
            'nowarn-mnemonic'                       = "$($NoWarnMnemonic -join "`n")";
            'deployment'                            = $_Deployment;
            'no-deployment-flag'                    = "$($NoDeploymentFlag -join "`n")";
            'output-dir'                            = $OutputDir;
            'output-file'                           = $OutputFile;
            'disable-console'                       = $_DisableConsole;
            'enable-console'                        = $_EnableConsole;
            'company-name'                          = $CompanyName;
            'product-name'                          = $FileDescription
            'file-version'                          = "$($FileVersion -replace '^v', '')";
            'copyright'                             = $Copyright;
            'trademarks'                            = $Trademarks;
            'force-stdout-spec'                     = $ForceStdOutSpec;
            'force-stderr-spec'                     = $ForceStdErrSpec;
            'windows-console-mode'                  = $WindowsConsoleMode;
            'windows-icon-from-ico'                 = $WindowsIconFromIco;
            'windows-icon-from-exe'                 = $WindowsIconFromExe;
            'onefile-windows-splash-screen-image'   = $OnefileWindowsSplashScreenImage;
            'windows-uac-admin'                     = $_WindowsUacAdmin;
            'windows-uac-uiaccess'                  = $_WindowsUacUiAccess;
            'macos-target-arch'                     = $MacOsTargetArch;
            'macos-app-icon'                        = $MacOsAppIcon;
            'macos-signed-app-name'                 = $MacOsSignedAppName;
            'macos-app-name'                        = $MacOsAppName;
            'macos-app-mode'                        = $MacOsAppMode;
            'macos-sign-identity'                   = $MacOsSignIdentity;
            'macos-sign-notarization'               = $MacOsSignNotarization;
            'macos-app-version'                     = "$($MacOsAppVersion -replace '^v', '')";
            'macos-app-protected-resource'          = $MacOsAppProtectedResource;
            'linux-icon'                            = $LinuxIcon;
            'embed-data-files-compile-time-pattern' = $EmbedDataFilesCompileTimePattern;
            'embed-data-files-run-time-pattern'     = $EmbedDataFilesRunTimePattern;
            'embed-data-files-qt-resource-pattern'  = $EmbedDataFilesQtResourcePattern;
            'embed-debug-qt-resources'              = $_EmbedDebugQtResources;
            'encryption-key'                        = $EncryptionKey;
            'encrypt-stdout'                        = $_EncryptStdOut;
            'encrypt-stderr'                        = $_EncryptStdErr;
            'clang'                                 = $_Clang;
            'mingw64'                               = $_Mingw64;
            'msvc'                                  = $MSVC;
            'jobs'                                  = "$($Jobs)";
            'lto'                                   = $Lto;
            'cf-protection'                         = $CfProtection;
            'debug'                                 = $_Debug;
            'no-debug-immortal-assumptions'         = $_NoDebugImmortalAssumptions;
            'unstripped'                            = $_Unstripped;
            'trace-execution'                       = $_TraceExecution;
            'xml'                                   = $Xml;
            'experimental'                          = "$($Experimental -join "`n")";
            'low-memory'                            = $_LowMemory;
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

    [Hashtable] $DataFiles = @{'version.xml'='version.xml'};

    # If ($IsWindows) {
    #   $DataFiles.Add("$((Get-Item -LiteralPath './themes/default-icons/AppIcon_alt.ico').FullName)", 'icon.ico');
    # }

    Invoke-NuitkaAction -SkipInstall:$SkipInstall -NuitkaVersion 'main' -ScriptName 'app/__main__.py' -Mode $Mode `
      -FileDescription 'RimSort' -IncludeDataFiles $DataFiles -ProductVersion $SemVersion.Outputs.VersionTag `
      -FileVersion $SemVersion.Outputs.VersionTag -MacOsAppVersion $SemVersion.Outputs.VersionTag `
      -WindowsIconFromIco './themes/default-icons/AppIcon_alt.ico' -LinuxIcon './themes/default-icons/RimSort_Icon_64x64_alt.svg' `
      -MacOsAppIcon './themes/default-icons/AppIcon_a.icns' -WindowsConsoleMode 'attach' `
      -OneFileTempDirSpec '{CACHE_DIR}/{PRODUCT}/{VERSION}' `
      -WhatIf:$script:WhatIf -Debug:$script:Debug -Verbose:$script:Verbose;
      # this is used to add an exception to Windows Defender or other Anti-Virus,
      # because Windows Defender is annoying when it comes to Nuitka compiles

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
      [OutputType([PSCustomObject])]
      Param(
        # Specifies a string that determines the name of the artifact.
        [Parameter(Mandatory = $False,
                  HelpMessage = 'A string that determines the name of the artifact.')]
        [ValidateNotNullOrWhiteSpace()]
        [Alias('Name')]
        [string]
        $ArtifactName = 'artifact',
        # Specifies a string the determines the file ot deirectory or wildcard pattern of the artifact.
        [Parameter(Mandatory = $True,
                  HelpMessage = 'A string the determines the file ot deirectory or wildcard pattern of the artifact.')]
        [ValidateNotNullOrWhiteSpace()]
        [Alias('Path', 'PSPath')]
        [SupportsWildcards()]
        [string]
        $SearchPath,
        # The desired behavior if no files are found using the provided path.
        #
        # Available Options:
        #   warn: Output a warning but do not fail the action.
        #   error: Fail the action with an error message.
        #   ignore: Do not output any warnings or errors, the action does not fail.
        [Parameter(Mandatory = $False,
                  HelpMessage = "The desired behavior if no files are found using the provided path.`n`nAvailable Options:`n  warn: Output a warning but do not fail the action.`n  error: Fail the action with an error message.`n  ignore: Do not output any warnings or errors, the action does not fail.")]
        [ValidateNotNullOrWhiteSpace()]
        [ValidateSet('Error', 'Warn', 'Ignore')]
        [string]
        $IfNoFilesFound,
        # Duration after which artifact will expire in days. 0 means using default retention.
        #
        # Minimum 1 day.
        # Maximum 90 days unless changed from the repository settings page.
        [Parameter(Mandatory = $False,
                  HelpMessage = "Duration after which artifact will expire in days. 0 means using default retention.`n`nMinimum 1 day.`nMaximum 90 days unless changed from the repository settings page.")]
        [ValidateRange(1, 90)]
        [int]
        $RetentionDays = $Null,
        # The level of compression for Zlib to be applied to the artifact archive.
        # The value can range from 0 to 9:
        # - 0: No compression
        # - 1: Best speed
        # - 6: Default compression (same as GNU Gzip)
        # - 9: Best compression
        # Higher levels will result in better compression, but will take longer to complete.
        # For large files that are not easily compressed, a value of 0 is recommended for significantly faster uploads.
        [Parameter(Mandatory = $False,
                  HelpMessage = "The level of compression for Zlib to be applied to the artifact archive.`nThe value can range from 0 to 9:`n- 0: No compression`n- 1: Best speed`n- 6: Default compression (same as GNU Gzip)`n- 9: Best compression`nHigher levels will result in better compression, but will take longer to complete.`nFor large files that are not easily compressed, a value of 0 is recommended for significantly faster uploads.")]
        [AllowNull()]
        [ValidateRange(0, 9)]
        [int]
        $CompressionLevel = 6,
        # If true, an artifact with a matching name will be deleted before a new one is uploaded.
        # If false, the action will fail if an artifact for the given name already exists.
        # Does not fail if the artifact does not exist.
        [Parameter(Mandatory = $False,
                  HelpMessage = "If true, an artifact with a matching name will be deleted before a new one is uploaded.`nIf false, the action will fail if an artifact for the given name already exists.`nDoes not fail if the artifact does not exist.")]
        [switch]
        $Overwrite,
        # If true, hidden files will be included in the artifact.
        # If false, hidden files will be excluded from the artifact.
        [Parameter(Mandatory = $False,
                  HelpMessage = "If true, hidden files will be included in the artifact.`nIf false, hidden files will be excluded from the artifact.")]
        [switch]
        $IncludeHiddenFiles
      )

      Begin {
        [PSCustomObject] $Output = [PSCustomObject]::new();
      } Process {
        # Adapted from: https://stackoverflow.com/a/24867012/1112800
        Function Get-LongestCommonPrefix {
          [CmdletBinding()]
          [OutputType([DirectoryInfo])]
          Param(
            # Specifies a path to one or more locations.
            [Parameter(Mandatory = $True,
                      HelpMessage = "Path to one or more locations.")]
            [ValidateNotNullOrEmpty()]
            [Alias('PSPath')]
            [string[]]
            $Path
          )

          Process {
            [int] $K = $Path[0].Length;
            For ([int] $I = 1; $I -lt $Path.Length; $I++) {
              $K = [Math]::Min($K, $Path[$I].Length);
              For ([int] $J = 0; $J -lt $K; $J++) {
                If ($Path[$I][$J] -ne $Path[0][$J]) {
                  $K = $J;
                }
              }
            }
          } End {
            Write-Output -NoEnumerate -InputObject (Get-Item -LiteralPath ($Files[0].Substring(0, $K)));
          }
        }

        Function Get-FilesToUpload {
          [CmdletBinding()]
          [OutputType([PSCustomObject])]
          Param(
            # Specifies a string the determines the file ot deirectory or wildcard pattern of the artifact.
            [Parameter(Mandatory = $True,
                      HelpMessage = 'A string the determines the file ot deirectory or wildcard pattern of the artifact.')]
            [ValidateNotNullOrWhiteSpace()]
            [Alias('Path', 'PSPath')]
            [SupportsWildcards()]
            [string]
            $SearchPath,
            # If true, hidden files will be included in the artifact.
            # If false, hidden files will be excluded from the artifact.
            [Parameter(Mandatory = $False,
                      HelpMessage = "If true, hidden files will be included in the artifact.`nIf false, hidden files will be excluded from the artifact.")]
            [switch]
            $IncludeHiddenFiles
          )

          Begin {
            [PSCustomObject] $Output = [PSCustomObject]::new();
          } Process {
            [FileSystemInfo[]] $FilesToUpload = (Get-ChildItem -Path $SearchPath);

            If ($IncludeHiddenFiles.IsPresent) {
              $FilesToUpload = @(@($FilesToUpload) + @(Get-ChildItem -Path $SearchPath -Hidden));
            }

            [DirectoryInfo] $RootDirectory = (Get-LongestCommonPrefix -Path $FilesToUpload);
          } End {
            $Output | Add-Member -MemberType NoteProperty -Name 'FilesToUpload' -Value $FilesToUpload;
            $Output | Add-Member -MemberType NoteProperty -Name 'RootDirectory' -Value $RootDirectory;
          }
        }

        Function Invoke-UploadArtifact {
          [CmdletBinding()]
          [OutputType([PSCustomObject])]
          Param(
            # Specifies a string that determines the name of the artifact.
            [Parameter(Mandatory = $True,
                      HelpMessage = 'A string that determines the name of the artifact.')]
            [ValidateNotNullOrWhiteSpace()]
            [Alias('Name')]
            [string]
            $ArtifactName,
            # Specifies a collection of files to upload.
            [Parameter(Mandatory = $True,
                      HelpMessage = 'A collection of files to upload.')]
            [ValidateNotNullOrEmpty()]
            [FileSystemInfo[]]
            $FilesToUpload,
            # Specifies the common root directory of each file to upload.
            [Parameter(Mandatory = $True,
                      HelpMessage = 'The common root directory of each file to upload.')]
            [ValidateNotNullOrEmpty()]
            [DirectoryInfo]
            $RootDirectory,
            # Specifies the upload options to use.
            [Parameter(Mandatory = $True,
                      HelpMessage = 'The upload options to use.')]
            [ValidateNotNull()]
            [Hashtable]
            $Options
          )

          Begin {
            [PSCustomObject] $Output = [PSCustomObject]::new();
          } Process {
            # NOTE: do not actually upload the artifact.
            [Hashtable] $Github = @{context=@{serverUrl=$Null;repo=@{owner=$Null;repo=$Null};runId=$Null}};
            [Hashtable] $UploadResponse = @{id = $Null;size=$Null;digest=$Null};
            Write-Information -MessageData "Artifact $($ArtifactName) has been successfully uploaded! Final size is $($UploadResponse.size) bytes. Artifact ID is $($UploadResponse.id).";
            $Repository = $Github.context.repo;
            [string] $ArtifactUrl = "$($Github.context.serverUrl)/$($Repository.owner)/$($Repository.repo)/actions/runs/$($Github.context.runId)/artifacts/$($UploadResponse.id)";
          } End {
            $Output | Add-Member -MemberType NoteProperty -Name 'ArtifactId' -Value $UploadResponse.id;
            $Output | Add-Member -MemberType NoteProperty -Name 'ArtifactDigest' -Value $UploadResponse.digest;
            $Output | Add-Member -MemberType NoteProperty -Name 'ArtifactUrl' -Value $ArtifactUrl;
          }
        }

        [PSCustomObject] $SearchResult = (Get-FilesToUpload -SearchPath $SearchPath -IncludeHiddenFiles:($IncludeHiddenFiles.IsPresent));

        If ($SearchResult.FilesToUpload.Length -eq 0) {
          Switch ($IfNoFilesFound) {
            'Warn' {
              Write-Warning -Message "No files were found with the provided path: $($SearchPath). No artifacts will be uploaded.";
            }
            'Error' {
              Throw "No files were found with the provided path: $($SearchPath). No artifacts will be uploaded.";
            }
            'Ignore' {
              Write-Information -MessageData "No files were found with the provided path: $($SearchPath). No artifacts will be uploaded.";
            }
          }
        } Else {
          [string] $Plural = '';
          If ($SearchResult.FilesToUpload.Length -eq 1) {
            $Plural = 's';
          }

          Write-Information -MessageData "With the provided path, there will be $($SearchResult.FilesToUpload.Length) file$($Plural) uploaded.";
          Write-Debug -Message "Root artifact directory is $($SearchResult.RootDirectory)";

          If ($Overwrite.IsPresent) {
            Delete-ArtifactIfExists -Name $ArtifactName;
          }

          [OrderedHashtable] $Options = @{};
          If ($Null -ne $RetentionDays -and $RetentionDays -is [int]) {
            $Options.Add('retentionDays', $RetentionDays);
          }

          If ($Null -ne $CompressionLevel -and $CompressionLevel -is [int]) {
            $Options.Add('compressionLevel', $CompressionLevel);
          }

          $Output = (Invoke-UploadArtifact -ArtifactName $ArtifactName -FilesToUpload $SearchResult.FilesToUpload -RootDirectory $SearchResult.RootDirectory -Options $Options);
        }
      } End {
        Write-Output -NoEnumerate -InputObject $Output;
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