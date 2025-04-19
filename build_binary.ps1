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

# cSpell:ignore uiaccess, idgs

[CmdletBinding()]
Param (
  [Parameter(Mandatory = $False,
    HelpMessage = 'Versioning format')]
  [ValidateNotNullOrWhiteSpace()]
  [string]
  $VersionFormat = 'v${major}.${minor}.${patch}',
  [Parameter(Mandatory = $False,
    HelpMessage = 'Generate attestations')]
  [ValidateNotNull()]
  [bool]
  $AtTest = $True,
  [Parameter(Mandatory = $False,
    HelpMessage = 'Github Secret')]
  [AllowNull()]
  [SecureString]
  $GitHubToken
)

Begin {
  Push-Location -LiteralPath $PSScriptRoot;
  [string] $Platform = 'Windows';
  [string] $Arch = 'x86_64';
  [string] $env:BUILD_OUTPUT = '__main__.dist';
  [string] $env:Executable = 'RimSort.exe';

  If ($PSBoundParameters.ContainsKey('GitHubToken') -and $Null -ne $GitHubToken) {
    $env:GitHubToken = (ConvertFrom-SecureString -SecureString $GitHubToken -AsPlainText);
  } ElseIf ($PSBoundParameters.ContainsKey('GitHubToken') -and $Null -eq $GitHubToken) {
    $env:GitHubToken = (Read-Host -Prompt 'GitHub Token:' -MaskInput);
  } ElseIf (-not $PSBoundParameters.ContainsKey('GitHubToken') -and $Null -eq $GitHubToken -and $Null -ne $env:GitHubToken) {
    $env:GitHubToken = $env:GitHubToken;
  }

  [FileInfo[]] $PythonEnvActivatePath = @(Get-ChildItem -Path "$($PWD.Path)\*\Scripts\activate.ps1");
  & ($PythonEnvActivatePath | Select-Object -First 1).FullName 2>&1 | Out-Host;

  Function Invoke-Process {

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
      & brew remove --force --ignore-dependencies 'openssl@3' 2>&1 | Out-Host;
      & brew cleanup 'openssl@3' 2>&1 | Out-Host;
    }

    # Get semantic version
    Function Get-SemanticVersion {
      [CmdletBinding()]
      [OutputType([PSCustomObject])]
      Param(
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
          HelpMessage = "A string which indicates the flags used by the `MajorPattern` regular expression. Supported flags: idgs")]
        [ValidatePattern('[idgs]{1,4}')]
        [string]
        $MajorRegExpFlags = [string]::Empty,
        [Parameter(Mandatory = $False,
          HelpMessage = "Same as above except indicating a minor change, supports regular expressions wrapped with '/'")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MinorPattern = '(MINOR)',
        [Parameter(Mandatory = $False,
          HelpMessage = "A string which indicates the flags used by the `MinorPattern` regular expression. Supported flags: idgs")]
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
        [bool]
        $BumpEachCommit = $False,
        [Parameter(Mandatory = $False,
          HelpMessage = 'If true, the body of commits will also be searched for major/minor patterns to determine the version type.')]
        [bool]
        $SearchCommitBody = $False,
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
        [bool]
        $EnablePrereleaseMode = $True,
        [Parameter(Mandatory = $False,
          HelpMessage = 'If true, the branch will be used to select the maximum version.')]
        [bool]
        $VersionFromBranch = $False
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
      } Process {
        Function Test-IsEmptyRepo {
          [CmdletBinding()]
          [OutputType([bool])]
          Param()

          Begin {
            [bool] $Output = $False;
          } Process {
            [string] $Command = (@(git 'rev-parse' HEAD 2>&1) -join "`n").Trim();
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
          [CmdletBinding()]
          [OutputType([string])]
          Param()

          Begin {
            [string] $Output = [string]::Empty;
          } Process {
            $Output = (@(git 'rev-parse' HEAD 2>&1) -join "`n").Trim();

            If ($Output -isnot [string] -or $Output -notmatch '^[a-f0-9]{40}$') {
              $global:ResolveCurrentCommitError = $Output;
              Throw [InvalidOperationException]::new("Failed to run the command `"git rev-parse HEAD`". Get the command output at `"`$global:.ResolveCurrentCommitError`"");
            }
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Resolve-LastRelease {
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param(
            # Specifies a PSObject determining the current commit.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSObject determining the current commit.')]
            [ValidateNotNull()]
            [PSObject]
            $CurrentCommit,
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
            $Config
          )

          Begin {
            [PSObject] $Output = [PSObject]::new();
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
            [string] $CurrentTag = (git 'tag' '--points-at' "$($CurrentCommit)" "$($TagFormat)" 2>&1);
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
                $Command = (git 'for-each-ref' '--sort=-v:*refname' '--format=%(refname:short)' "--merged=$($CurrentCommit)" "$($RefPrefixPattern)$($TagFormat)" 2>&1).Trim();
                $Tags = @($Command -split "`n| ");
                $TagsCount = $Tags.Length;
                $Tag = ($Tags | Where-Object { $_ -match $TagFormat -and $_ -ne $CurrentTag } | Select-Object -First 1);
              } Else {
                $Command = (git 'for-each-ref' '--sort=-v:*refname' '--format=%(refname:short)' "--merged=$($CurrentCommit)" "$($RefPrefixPattern)$($TagFormat)" 2>&1).Trim();
                $Tags = @($Command -split "`n| ");
                $TagsCount = $Tags.Length;
                $Tag = ($Tags | Where-Object { $_ -match $TagFormat } | Select-Object -First 1);
              }

              If ([string]::IsNullOrWhiteSpace($Tag)) {
                $Tag = [string]::Empty;
              }

              $Tag = $Tag.Trim();
            } Catch {
              Write-Debug -Message $_;
              $Tag = [string]::Empty;
            }

            [Version] $ParsedTag = $Null;

            If ([string]::IsNullOrWhiteSpace($Tag)) {
              If ([string]::IsNullOrWhiteSpace("$(git 'remote' 2>&1)")) {

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

              $Root = (git 'merge-base' "$($Tag)" "$($CurrentCommit)" 2>&1);
            }
          } End {
            $Output | Add-Member -Name 'Major' -MemberType NoteProperty -Value $Major;
            $Output | Add-Member -Name 'Minor' -MemberType NoteProperty -Value $Minor;
            $Output | Add-Member -Name 'Patch' -MemberType NoteProperty -Value $Patch;
            $Output | Add-Member -Name 'Hash' -MemberType NoteProperty -Value $Root.Trim();
            $Output | Add-Member -Name 'CurrentMajor' -MemberType NoteProperty -Value $CurrentMajor;
            $Output | Add-Member -Name 'CurrentMinor' -MemberType NoteProperty -Value $CurrentMinor;
            $Output | Add-Member -Name 'CurrentPatch' -MemberType NoteProperty -Value $CurrentPatch;
            $Output | Add-Member -Name 'IsTagged' -MemberType NoteProperty -Value $IsTagged;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Get-AllCommits {
          [SuppressMessage('PSUseSingularNouns', 'Get-AllCommits')]
          [SuppressMessage('PSAvoidUsingInvokeExpression', '', Justification='No other way to do this as it is not a PowerShell script.')]
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param(
            # Specifies the hash for the last release.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'The hash for the last release.')]
            [AllowEmptyString()]
            [AllowNull()]
            [string]
            $EndHash,
            # Specifies a PSObject determining the current commit.
            [Parameter(Mandatory = $True,
                       HelpMessage = 'A PSObject determining the current commit.')]
            [ValidateNotNull()]
            [string]
            $StartHash,
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
            $Config
          )

          Begin {
            [PSObject] $Output = [PSObject]::new();
            [PSObject[]] $Commits = @();
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
            [string] $LogCommand = "git log --pretty=`"$($Pretty)`" --author-date-order $($HashCheck)";
            If (-not [string]::IsNullOrWhiteSpace($Config.ChangePath)) {
              $LogCommand += " -- $($Config.ChangePath)";
            }
            $LogCommand += " 2>&1";
          } Process {
            [string] $Log = (Invoke-Expression -Command $LogCommand);
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

              [PSObject] $CommitInfo = [PSObject]::new();
              $CommitInfo | Add-Member -Name "Hash" -MemberType NoteProperty -Value $Fields.hash;
              $CommitInfo | Add-Member -Name "Subject" -MemberType NoteProperty -Value $Fields.subject;
              $CommitInfo | Add-Member -Name "Body" -MemberType NoteProperty -Value $Fields.body;
              $CommitInfo | Add-Member -Name "Author" -MemberType NoteProperty -Value $Fields.author;
              $CommitInfo | Add-Member -Name "AuthorEmail" -MemberType NoteProperty -Value $Fields.authorEmail;
              $CommitInfo | Add-Member -Name "Date" -MemberType NoteProperty -Value ([DateTime]::Parse($Fields.authorDate));
              $CommitInfo | Add-Member -Name "Committer" -MemberType NoteProperty -Value $Fields.committer;
              $CommitInfo | Add-Member -Name "CommitterEmail" -MemberType NoteProperty -Value $Fields.committerEmail;
              $CommitInfo | Add-Member -Name "CommitterDate" -MemberType NoteProperty -Value ([DateTime]::Parse($Fields.committerDate));
              $CommitInfo | Add-Member -Name "Tags" -MemberType NoteProperty -Value $Tags;
              $Commits += $CommitInfo;
            }
          } End {
            $Output | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
            $Output | Add-Member -Name "Commits" -MemberType NoteProperty -Value $Commits;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Invoke-ClassifyVersion {
          # [SuppressMessage("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param(
            # Specifies a PSObject that determines the last release.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the last release.')]
            [PSObject]
            $LastRelease,
            # Specifies a PSObject that determines the set of commits in the repository.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the set of commits in the repository.')]
            [PSObject]
            $CommitsSet,
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
            $Config
          )

          Begin {
            Function Get-ParsedPattern {
              [CmdletBinding()]
              [OutputType([PSObject])]
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
                # Specifies a PSObject that determines the config of the commands.
                [Parameter(Mandatory = $True,
                  HelpMessage = 'A PSObject that determines the config of the commands.')]
                [PSObject]
                $Config
              )

              Begin {
                [PSObject] $Output = [PSObject]::new();
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
                        # Specifies a PSObject containing commit information.
                        [Parameter(Mandatory = $True,
                          HelpMessage = "A PSObject containing commit information.")]
                        [PSObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Regex -or $Commit.Body -match $script:Regex;
                    }
                  } Else {
                    $ScriptBlock = {
                      Param(
                        # Specifies a PSObject containing commit information.
                        [Parameter(Mandatory = $True,
                          HelpMessage = "A PSObject containing commit information.")]
                        [PSObject]
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
                        # Specifies a PSObject containing commit information.
                        [Parameter(Mandatory = $True,
                          HelpMessage = "A PSObject containing commit information.")]
                        [PSObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Pattern -or $Commit.Body -match $script:Pattern;
                    }
                  } Else {
                    $ScriptBlock = {
                      Param(
                        # Specifies a PSObject containing commit information.
                        [Parameter(Mandatory = $True,
                          HelpMessage = "A PSObject containing commit information.")]
                        [PSObject]
                        $Commit
                      )

                      Return $Commit.Subject -match $script:Pattern;
                    }
                  }
                }
              } End {
                $Output | Add-Member -MemberType NoteProperty -Name 'ScriptBlock' -Value ($ScriptBlock);
                Write-Output -InputObject $Output;
              }
            }

            Function Get-NextVersion {
              [CmdletBinding()]
              [OutputType([PSObject])]
              Param(
                # Specifies a PSObject that determines the current release information.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSObject that determines the current release information.')]
                [PSObject]
                $Current,
                # Specifies a string that determines the version type.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A string that determines the version type.')]
                [ValidateSet('Major', 'Minor', 'Patch', 'None')]
                [string]
                $Type
              )

              Begin {
                [PSObject] $Output = [PSObject]::new();
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
                $Output | Add-Member -Name "Major" -MemberType NoteProperty -Value $Major;
                $Output | Add-Member -Name "Minor" -MemberType NoteProperty -Value $Minor;
                $Output | Add-Member -Name "Patch" -MemberType NoteProperty -Value $Patch;
                Write-Output -NoEnumerate -InputObject $Output;
              }
            }

            Function Resolve-CommitType {
              [CmdletBinding()]
              [OutputType([PSObject])]
              Param(
                # Specifies a PSObject that determines the last release.
                [Parameter(Mandatory = $True,
                  HelpMessage = 'A PSObject that determines the last release.')]
                [PSObject]
                $LastRelease,
                # Specifies a PSObject that determines the current release information.
                [Parameter(Mandatory = $True,
                           HelpMessage = 'A PSObject that determines the current release information.')]
                [PSObject]
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
                # Specifies a PSObject that determines the config of the commands.
                [Parameter(Mandatory = $True,
                  HelpMessage = 'A PSObject that determines the config of the commands.')]
                [PSObject]
                $Config
              )

              Begin {
                [PSObject] $Output = [PSObject]::new();
                [string] $Type = 'None';
                [int] $Increment = 0;
                [bool] $Changed = $False;
              } Process {
                If ($CommitsSet.Commits.Length -ne 0) {
                  [List[PSObject]] $Commits = [List[PSObject]]::new($CommitsSet.Commits);
                  $Commits.Reverse();

                  If ($Config.BumpEachCommit) {
                    ForEach ($Commit in $Commits) {
                      If (Invoke-Command -ScriptBlock $MajorPattern -ArgumentList @($Commit)) {
                        $Type = 'Major';
                      } ElseIf (Invoke-Command -ScriptBlock $MinorPattern -ArgumentList @($Commit)) {
                        $Type = 'Major';
                      } ElseIf ((Invoke-Command -ScriptBlock $PatchPattern -ArgumentList @($Commit)) -or ($LastRelease.Major -eq 0 -and $LastRelease.Minor -eq 0 -and $LastRelease.Patch -eq 0 -and $Commits.Count -gt 0)) {
                        $Type = 'Patch';
                      } Else {
                        $Type = 'None';
                      }

                      $Changed = $True;
                    }
                  } Else {
                    [int] $Index = 1;
                    ForEach ($Commit in $Commits) {
                      If (Invoke-Command -ScriptBlock $MajorPattern -ArgumentList @($Commit)) {
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
                        If (Invoke-Command -ScriptBlock $MinorPattern -ArgumentList @($Commit)) {
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
                $Output | Add-Member -Name "Type" -MemberType NoteProperty -Value $Type;
                $Output | Add-Member -Name "Increment" -MemberType NoteProperty -Value $Increment;
                $Output | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
                Write-Output -NoEnumerate -InputObject $Output;
              }
            }

            [PSObject] $Output = [PSObject]::new();
            [ScriptBlock] $MajorPattern = (Get-ParsedPattern -Pattern $Config.MajorPattern -Flags $Config.MajorRegExpFlags -Config $Config).ScriptBlock;
            [ScriptBlock] $MinorPattern = (Get-ParsedPattern -Pattern $Config.MinorPattern -Flags $Config.MinorRegExpFlags -Config $Config).ScriptBlock;
            [ScriptBlock] $PatchPattern = (Get-ParsedPattern -Pattern $Config.BumpEachCommitPatchPattern -Flags '' -Config $Config).ScriptBlock;
            [bool] $EnablePrereleaseMode = $EnablePrereleaseMode;
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
                [List[PSObject]] $Commits = [List[PSObject]]::new($CommitsSet.Commits);
                $Commits.Reverse();
                [PSObject] $ResolvedCommitType = (Resolve-CommitType -LastRelease $LastRelease -CommitsSet $Commits -MajorPattern $MajorPattern -MinorPattern $MinorPattern -PatchPattern $PatchPattern -Config $Config);
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
              [PSObject] $ResolvedCommitType = (Resolve-CommitType -LastRelease $LastRelease -CommitsSet $CommitsSet -MajorPattern $MajorPattern -MinorPattern $MinorPattern -PatchPattern $PatchPattern -Config $Config);

              $Type = $ResolvedCommitType.Type;
              $Increment = $ResolvedCommitType.Increment;
              $Changed = $ResolvedCommitType.Changed;
              [PSObject] $NextVersion = (Get-NextVersion -Type $Type -Current $LastRelease);
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
            $Output | Add-Member -Name "Type" -MemberType NoteProperty -Value $Type;
            $Output | Add-Member -Name "Increment" -MemberType NoteProperty -Value $Increment;
            $Output | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
            $Output | Add-Member -Name "Major" -MemberType NoteProperty -Value $Major;
            $Output | Add-Member -Name "Minor" -MemberType NoteProperty -Value $Minor;
            $Output | Add-Member -Name "Patch" -MemberType NoteProperty -Value $Patch;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Format-Version {
          [SuppressMessage("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([string])]
          Param(
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Major,
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Minor,
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Patch,
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Increment,
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
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
          [SuppressMessage("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([string])]
          Param(
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Major,
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Minor,
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [int]
            $Patch,
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
            $Config
          )

          Begin {
            [string] $Output = $Null;
            [string] $NamespaceSeperator = '-';
            [bool] $OnVersionBranch = $False;
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
            # Specifies a PSObject determining the version info to use.
            [Parameter(Mandatory = $True,
                       ParameterSetName = 'Version',
                       HelpMessage = 'A PSObject determining the version info to use.')]
            [PSObject[]]
            $List,
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
            $Config
          )

          Begin {
            [string] $Output = $Null;
          } Process {
            If ($Config.UserFormatType -eq 'json') {
              $Output = ($List | ForEach-Object { @{
                name = $_.Name;
                email = $_.Email
              } } | ConvertTo-Json -AsArray -Depth 100);
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
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param(
            # Specifies a PSObject that determines the config of the commands.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the config of the commands.')]
            [PSObject]
            $Config
          )

          Begin {
            [PSObject] $Output = [PSObject]::new();
            $Major = -1;
            $Minor = -1;
            $OnVersionBranch = $False;
          } Process {
            [string] $BranchName = $Config.Branch;

            If ($BranchName -eq 'HEAD') {
              $BranchName = (git 'rev-parse' '--abbrev-ref' 'HEAD' 2>&1);
            }

            $BranchName = $BranchName.Trim();
            [Regex] $Pattern = $Null;
            [int] $RegexEnd = 0;
            [string] $ParsedFlags = [string]::Empty;
            If ($Config.VersionFromBranch -is [bool] -and $Config.VersionFromBranch -eq $True) {
              $Pattern = [Regex]::new("[0-9]+.[0-9]+$|[0-9]+$");
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
            $Config | Add-Member -Name 'Major' -MemberType NoteProperty -Value $Major;
            $Config | Add-Member -Name 'Minor' -MemberType NoteProperty -Value $Minor;
            $Config | Add-Member -Name 'OnVersionBranch' -MemberType NoteProperty -Value $OnVersionBranch;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        [string] $NamespaceSeperator = '-';
        [PSObject] $Config = [PSObject]::new();
        $Config | Add-Member -Name "MajorPattern" -MemberType NoteProperty -Value $MajorPattern;
        $Config | Add-Member -Name "MajorRegExpFlags" -MemberType NoteProperty -Value $MajorRegExpFlags;
        $Config | Add-Member -Name "MinorPattern" -MemberType NoteProperty -Value $MinorPattern;
        $Config | Add-Member -Name "MinorRegExpFlags" -MemberType NoteProperty -Value $MinorRegExpFlags;
        $Config | Add-Member -Name "ChangePath" -MemberType NoteProperty -Value $ChangePath;
        $Config | Add-Member -Name "Namespace" -MemberType NoteProperty -Value $Namespace;
        $Config | Add-Member -Name "BumpEachCommit" -MemberType NoteProperty -Value $BumpEachCommit;
        $Config | Add-Member -Name "TagPrefix" -MemberType NoteProperty -Value $TagPrefix;
        $Config | Add-Member -Name "VersionFormat" -MemberType NoteProperty -Value $VersionFormat;
        $Config | Add-Member -Name "BumpEachCommitPatchPattern" -MemberType NoteProperty -Value $BumpEachCommitPatchPattern;
        $Config | Add-Member -Name "UserFormatType" -MemberType NoteProperty -Value $UserFormatType;
        $Config | Add-Member -Name "EnablePrereleaseMode" -MemberType NoteProperty -Value $EnablePrereleaseMode;
        $Config | Add-Member -Name "VersionFromBranch" -MemberType NoteProperty -Value $VersionFromBranch;
        $Config | Add-Member -Name "UseBranches" -MemberType NoteProperty -Value $False;
        $Config | Add-Member -Name "SearchCommitBody" -MemberType NoteProperty -Value $SearchCommitBody;

        [string] $CurrentCommit = (Resolve-CurrentCommit);

        If (-not (Test-IsEmptyRepo)) {
          $BranchNameMajor = -1;
          $BranchNameMinor = -1;
          $OnVersionBranch = $False;

          If ($Config.VersionFromBranch) {
            [PSObject] $BranchInformation = (Resolve-BranchName -Config $Config);
            $BranchNameMajor = $BranchInformation.Major;
            $BranchNameMinor = $BranchInformation.Minor;
            $OnVersionBranch = $BranchInformation.OnVersionBranch;
          }

          $Config | Add-Member -Name "BranchNameMajor" -MemberType NoteProperty -Value $BranchNameMajor;
          $Config | Add-Member -Name "BranchNameMinor" -MemberType NoteProperty -Value $BranchNameMinor;
          $Config | Add-Member -Name "OnVersionBranch" -MemberType NoteProperty -Value $OnVersionBranch;

          [PSObject] $LastRelease = (Resolve-LastRelease -CurrentCommit $CurrentCommit -Config $Config);
          [PSObject] $CommitsSet = (Get-AllCommits -StartHash $LastRelease.Hash -EndHash $CurrentCommit -Config $Config);
          [PSObject] $Classification = (Invoke-ClassifyVersion -LastRelease $LastRelease -CommitsSet $CommitsSet -Config $Config);

          $Patch = $Classification.Patch;
          $Increment = $Classification.Increment;
          $VersionType = $Classification.Type;
          $FormattedVersion = (Format-Version -Major $Major -Minor $Minor -Patch $Patch -Increment $Increment -Config $Config);
          $VersionTag = (Format-Tag -Major $Major -Minor $Minor -Patch $Patch -Config $Config);
          $Changed = $Classification.Changed;
          $IsTagged = $LastRelease.IsTagged;
          $PreviousCommit = $LastRelease.Hash;
          $PreviousVersion = "$($LastRelease.Major).$($LastRelease.Minor).$($LastRelease.Patch)";
          [PSObject[]] $AllAuthors = @();
          ForEach ($Commit in $CommitsSet.Commits) {
            [string] $Key = "$($Commit.Author) <$($Commit.AuthorEmail)>";
            If ($Null -eq ($AllAuthors | Where-Object { $_.FullName -eq $Key })) {
              [PSObject] $Author = [PSObject]::new();
              $Author | Add-Member -MemberType NoteProperty -Name 'FullName' -Value $Key;
              $Author | Add-Member -MemberType NoteProperty -Name 'Name' -Value $Commit.Author;
              $Author | Add-Member -MemberType NoteProperty -Name 'Email' -Value $Commit.AuthorEmail;
              $Author | Add-Member -MemberType NoteProperty -Name 'Commits' -Value 0;
              $AllAuthors += $Author;
            } Else {
              ($AllAuthors | Where-Object { $_.FullName -eq $Key }).Commits++
            }
          }
          [PSObject[]] $AuthorsList = @($AllAuthors | Sort-Object -Property Commits -Descending);
          [string] $Authors = (Format-Users -List $AuthorsList -Config $Config);
        }
      } End {
        [PSObject] $Outputs = [PSObject]::new();
        $Outputs | Add-Member -Name "Major" -MemberType NoteProperty -Value $Major;
        $Outputs | Add-Member -Name "Minor" -MemberType NoteProperty -Value $Minor;
        $Outputs | Add-Member -Name "Patch" -MemberType NoteProperty -Value $Patch;
        $Outputs | Add-Member -Name "Increment" -MemberType NoteProperty -Value $Increment;
        $Outputs | Add-Member -Name "VersionType" -MemberType NoteProperty -Value $VersionType.ToLower();
        $Outputs | Add-Member -Name "Version" -MemberType NoteProperty -Value $FormattedVersion;
        $Outputs | Add-Member -Name "VersionTag" -MemberType NoteProperty -Value $VersionTag;
        $Outputs | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
        $Outputs | Add-Member -Name "IsTagged" -MemberType NoteProperty -Value $IsTagged;
        $Outputs | Add-Member -Name "Authors" -MemberType NoteProperty -Value $Authors;
        $Outputs | Add-Member -Name "CurrentCommit" -MemberType NoteProperty -Value $CurrentCommit;
        $Outputs | Add-Member -Name "PreviousCommit" -MemberType NoteProperty -Value $PreviousCommit;
        $Outputs | Add-Member -Name "PreviousVersion" -MemberType NoteProperty -Value $PreviousVersion;
        $Outputs | Add-Member -Name "DebugOutput" -MemberType NoteProperty -Value $DebugOutput;
        $Output | Add-Member -Name "Outputs" -MemberType NoteProperty -Value $Outputs;
        Write-Output -NoEnumerate -InputObject $Output;
      }
    }

    [PSCustomObject] $SemVersion = (Get-SemanticVersion -VersionFormat $VersionFormat -ChangePath @('app', 'libs', 'submodules', 'themes'));
    # Make (overwrite) version.xml

    Remove-Item -Force 'version.xml'
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
"@;

    [bool] $SkipInstall = ($Null -ne (Get-Item -LiteralPath '.installed' -ErrorAction SilentlyContinue));

    If (-not $SkipInstall) {
      # Setup Python

      Get-ChildItem -LiteralPath $PWD -Recurse -Filter 'requirements.txt' | ForEach-Object {
        & pip install -r $_ 2>&1 | Out-Host;
      }

      # Install Dependencies

      pip install -r requirements.txt -r requirements_build.txt 2>&1 | Out-Host;

      # Build Actions

      $ErrorActionPreference = 'Stop';
      python distribute.py `
        --skip-pip `
        --product-version="$($SemVersion.Outputs.Major).$($SemVersion.Outputs.Minor).$($SemVersion.Outputs.Patch).$($SemVersion.Outputs.Increment)" `
        --skip-build 2>&1 | Out-Host;

      New-Item -Path .installed -ItemType File | Out-Null;
    }

    # Build
    # TODO: https://github.com/Nuitka/Nuitka-Action
    Function Invoke-NuitkaAction {
      [CmdletBinding()]
      Param(
        [Parameter(Mandatory = $True,
          HelpMessage = 'Skips install methods')]
        [bool]
        $SkipInstall,

        ### Tags for building Nuitka ###

        [Parameter(Mandatory = $False,
          HelpMessage = 'Directory to run nuitka in if not top level')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WorkingDirectory = '.',

        [Parameter(Mandatory = $False,
          HelpMessage = 'Version of nuitka to use, branches, tags work')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $NuitkaVersion = 'main',

        [Parameter(Mandatory = $True,
          HelpMessage = 'Path to python script that is to be built.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ScriptName,

        [Parameter(Mandatory = $False,
          HelpMessage = 'Github personal access token of an account authorized to access the Nuitka-commercial repo')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $AccessToken,

        [Parameter(Mandatory = $False,
          HelpMessage = @"
Mode in which to compile. Accelerated runs in your Python
installation and depends on it. Standalone creates a folder
with an executable contained to run it. Onefile creates a
single executable to deploy. App is onefile except on macOS
where it's not to be used. Module makes a module, and
package includes also all sub-modules and sub-packages. Dll
is currently under development and not for users yet.
Default is 'accelerated'.
"@)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Mode = 'app',

        [Parameter(Mandatory = $False,
          HelpMessage = 'Description of the file used in version information. Windows only at this time. Defaults to binary filename.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $FileDescription,

        [Parameter(Mandatory = $False,
          HelpMessage = @"
Include data files by filenames in the distribution. There are many
allowed forms. With '--include-data-files=/path/to/file/*.txt=folder_name/some.txt' it
will copy a single file and complain if it's multiple. With
'--include-data-files=/path/to/files/*.txt=folder_name/' it will put
all matching files into that folder. For recursive copy there is a
form with 3 values that '--include-data-files=/path/to/scan=folder_name/=**/*.txt'
that will preserve directory structure. Default empty.
"@)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeDataFiles,

        [Parameter(Mandatory = $False,
          HelpMessage = @"
Product version to use in version information. Same rules as for file version.
Defaults to unused.
"@)]
        [AllowNull()]
        [string]
        $ProductVersion
      )

      Begin {
        Push-Location -LiteralPath $WorkingDirectory;
        $env:NUITKA_CACHE_DIR = (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path 'nuitka' -ChildPath 'cache'));
        $env:PYTHON_VERSION = (((((python --version 2>&1) -split '\s+' | Select-Object -Index 1) -split '\.') | Select-Object -First 2) -join '.')
        If (-not $SkipInstall) {
          pip install -r (Join-Path -Path $PSScriptRoot -ChildPath 'requirements.txt') 2>&1 | Out-Host;

          # With commercial access token, use that repository.
          If (-not [string]::IsNullOrWhiteSpace($env:NuitkaAccessToken)) {
            $RepoUrl = "git+https://$($AccessToken)@github.com/Nuitka/Nuitka-commercial.git";
          } Else {
            $RepoUrl = 'git+https://$@github.com/Nuitka/Nuitka.git'
          }

          pip install "$($RepoUrl)/@$($NuitkaVersion)#egg=nuitka" 2>&1 | Out-Host;

          If ($IsLinux) {
            sudo apt-get install -y ccache 2>&1 | Out-Host;
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
            'product-name'                          = '';
            'file-version'                          = '';
            'copyright'                             = '';
            'trademarks'                            = '';
            'force-stdout-spec'                     = '';
            'force-stderr-spec'                     = '';
            'windows-console-mode'                  = '';
            'windows-icon-from-ico'                 = '';
            'windows-icon-from-exe'                 = '';
            'onefile-windows-splash-screen-image'   = '';
            'windows-uac-admin'                     = '';
            'windows-uac-uiaccess'                  = '';
            'macos-target-arch'                     = '';
            'macos-app-icon'                        = '';
            'macos-signed-app-name'                 = '';
            'macos-app-name'                        = '';
            'macos-app-mode'                        = '';
            'macos-sign-identity'                   = '';
            'macos-sign-notarization'               = '';
            'macos-app-version'                     = '';
            'macos-app-protected-resource'          = '';
            'linux-icon'                            = '';
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
        python -m nuitka --github-workflow-options | Out-Host;
      } End {
        Pop-Location;
      }
    }

    [string] $Mode = [string]::Empty;

    If ($IsMacOS) {
      $Mode = 'app';
    } Else {
      $Mode = 'standalone';
      $Mode = 'onefile';
    }

    Invoke-NuitkaAction -SkipInstall $SkipInstall -NuitkaVersion 'main' -ScriptName 'app/__main__.py' -Mode $Mode -FileDescription 'RimSort' -IncludeDataFiles @('version.xml') -ProductVersion $SemVersion.Outputs.VersionTag;

    # Set FILENAME
    [string] $FILENAME = $Platform;
    $FILENAME += $Arch;
    $env:FILENAME = "$FILENAME";

    [string] $OutExec = "RimSort";

    If ($IsWIndows) {
      $OutExec = "$($OutExec).exe";
    }

    # Find Executable
    [FileInfo] $Executable = (Get-ChildItem -LiteralPath . -Recurse -File -Filter $OutExec | Select-Object -First 1);
    $env:EXECUTABLE = "$Executable";
    Write-Information -MessageData "Executable found at $Executable";

    # Generate executable attestations
    # TODO: https://github.com/actions/attest-build-provenance
    Function Invoke-AtTestBuildProvenance {
      [CmdletBinding()]
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
      Invoke-AtTestBuildProvenance -SubjectPath $env:EXECUTABLE
    }

    # Rename new build
    Push-Location -LiteralPath build;
    Move-Item -LiteralPath $env:BUILD_OUTPUT -Destination "output";

    If ($IsWindows) {
      If (Test-Path -Path "$($env:FILENAME).zip" -PathType Leaf) {
        Remove-Item "$($env:FILENAME).zip";
      }

      Compress-Archive -LiteralPath "output" -DestinationPath "$($env:FILENAME).zip";
    } Else {
      tar -cvf "$($env:FILENAME).tar" "output" 2>&1 | Out-Host;
    }

    Remove-Item -Recurse -Force -LiteralPath "output";
    Pop-Location;

    # Generate artifact attestation

    If ($AtTest -and $IsWindows) {
      Invoke-AtTestBuildProvenance -SubjectPath "./build/$($env:FILENAME).zip"
    } ElseIf ($AtTest) {
      Invoke-AtTestBuildProvenance -SubjectPath "./build/$($env:FILENAME).tar"
    }

    # Upload folder as artifact

    Function Invoke-UploadArtifact {
      [CmdletBinding()]
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

    Invoke-UploadArtifact -Name $env:FILENAME -Path "./build/$($env:FILENAME).tar" -IfNoFilesFound 'error';
  } Finally {
    $env:GitHubToken = $Null;
  }
} End {
  Pop-Location;
}